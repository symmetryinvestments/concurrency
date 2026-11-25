module ut.concurrency.epoll;

version(linux):

import concurrency;
import concurrency.io;
import concurrency.ioscheduler : Client, isIOScheduler, toIOSchedulerObject;
import concurrency.io.iouring : IOUringContext;
import concurrency.sender : SenderObjectBase, OperationalStateBase, connectHeap;
import concurrency.sender : DoneSender, ErrorSender;
import concurrency.stoptoken : StopSource, StopToken;
import concurrency.operations : race, letValue, whenAll;
import concurrency.thread : ThreadSender;
import core.atomic : atomicFetchAdd, atomicLoad, atomicStore, MemoryOrder;
import core.sync.event : Event;
import core.thread : Thread, ThreadID;
import core.time : msecs;
import core.sys.posix.unistd : close;
import std.process : thisThreadID;
import std.socket : socket_t;
import unit_threaded;

private int[2] epollSocketPair(bool nonblocking = true) @trusted {
	import core.sys.posix.sys.socket : socketpair, AF_UNIX, SOCK_STREAM;

	enum SOCK_NONBLOCK = 0x800;
	int[2] fds;
	auto type = SOCK_STREAM | (nonblocking ? SOCK_NONBLOCK : 0);
	assert(socketpair(AF_UNIX, type, 0, fds) == 0);
	return fds;
}

private int[2] epollPipePair() @trusted {
	import core.sys.posix.unistd : pipe2;
	enum O_NONBLOCK = 0x800;
	enum O_CLOEXEC = 0x80000;
	int[2] fds;
	assert(pipe2(fds, O_NONBLOCK | O_CLOEXEC) == 0);
	return fds;
}

private int[2] loopbackTcpPair() @trusted {
	import core.stdc.errno : errno, EINPROGRESS;
	import core.sys.posix.sys.socket : socket, bind, listen, connect, accept, sockaddr, socklen_t,
		setsockopt, getsockname, AF_INET, SOCK_STREAM, SOL_SOCKET, SO_REUSEADDR;
	import core.sys.posix.netinet.in_ : sockaddr_in, htons, htonl, INADDR_LOOPBACK;
	import core.sys.posix.fcntl : fcntl, F_GETFL, F_SETFL, O_NONBLOCK;
	import core.sys.posix.unistd : close;
	enum SOCK_NONBLOCK = 0x800;
	enum SOCK_CLOEXEC = 0x80000;
	auto listener = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
	assert(listener >= 0);
	scope(failure) close(listener);
	int yes = 1;
	assert(setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, yes.sizeof) == 0);
	sockaddr_in address;
	address.sin_family = AF_INET;
	address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	address.sin_port = htons(0);
	assert(bind(listener, cast(sockaddr*) &address, address.sizeof) == 0);
	assert(listen(listener, 1) == 0);
	socklen_t length = address.sizeof;
	assert(getsockname(listener, cast(sockaddr*) &address, &length) == 0);
	auto client = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
	assert(client >= 0);
	scope(failure) close(client);
	auto connected = connect(client, cast(sockaddr*) &address, address.sizeof);
	assert(connected == 0 || errno == EINPROGRESS);
	auto server = accept(listener, null, null);
	assert(server >= 0);
	scope(failure) close(server);
	assert(fcntl(server, F_SETFL, fcntl(server, F_GETFL) | O_NONBLOCK) == 0);
	close(listener);
	return [client, server];
}

private int temporaryRegularFile() @trusted {
	import core.sys.posix.fcntl : fcntl, F_GETFL, F_SETFL, O_NONBLOCK;
	import core.sys.posix.stdlib : mkstemp;
	import core.sys.posix.unistd : unlink;
	char[] path = "/tmp/concurrency-epoll-unit-file-XXXXXX\0".dup;
	auto fd = mkstemp(path.ptr);
	assert(fd >= 0);
	scope(failure) close(fd);
	assert(fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0);
	assert(unlink(path.ptr) == 0);
	return fd;
}

private ptrdiff_t sendSocketBytes(int fd, const(ubyte)[] bytes) @trusted nothrow {
	import core.sys.posix.sys.socket : send;
	return send(fd, bytes.ptr, bytes.length, 0);
}

private void fillSocketSendBuffer(int fd) @trusted {
	ubyte[4096] bytes;
	while (sendSocketBytes(fd, bytes[]) > 0) {}
}

private size_t fillSocketSendBufferCounted(int fd) @trusted {
	import core.stdc.errno : errno, EAGAIN, EWOULDBLOCK;

	ubyte[4096] bytes;
	size_t total;
	for (;;) {
		auto written = sendSocketBytes(fd, bytes[]);
		if (written > 0) {
			total += cast(size_t) written;
			continue;
		}
		assert(written == -1);
		assert(errno == EAGAIN || errno == EWOULDBLOCK);
		return total;
	}
}

private ptrdiff_t receiveSocketBytes(int fd, ubyte[] bytes) @trusted nothrow {
	import core.sys.posix.sys.socket : recv;
	return recv(fd, bytes.ptr, bytes.length, 0);
}

private void drainSocketReceiveBuffer(int fd) @trusted nothrow {
	ubyte[4096] bytes;
	while (receiveSocketBytes(fd, bytes[]) > 0) {}
}

private void drainSocketReceiveBufferExactly(int fd, size_t length) @trusted {
	ubyte[4096] bytes;
	while (length) {
		auto count = length < bytes.length ? length : bytes.length;
		auto received = receiveSocketBytes(fd, bytes[0 .. count]);
		assert(received > 0);
		length -= cast(size_t) received;
	}
}

private void receiveSocketBytesExactly(int fd, ubyte[] bytes) @trusted {
	size_t offset;
	while (offset < bytes.length) {
		auto received = receiveSocketBytes(fd, bytes[offset .. $]);
		assert(received > 0);
		offset += cast(size_t) received;
	}
}

private size_t configureSocketSendBuffer(int fd) @trusted {
	import core.sys.posix.sys.socket : getsockopt, setsockopt, socklen_t, SOL_SOCKET, SO_SNDBUF;

	enum requested = 64 * 1024;
	int requestedSize = requested;
	assert(setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &requestedSize, requestedSize.sizeof) == 0);
	int effectiveSize;
	socklen_t effectiveLength = effectiveSize.sizeof;
	assert(getsockopt(fd, SOL_SOCKET, SO_SNDBUF, &effectiveSize, &effectiveLength) == 0);
	assert(effectiveLength == effectiveSize.sizeof);
	assert(effectiveSize > 0);
	return cast(size_t) effectiveSize;
}

private ubyte[] eagainRecoveryPayload(size_t sendBufferSize, size_t multiplier, size_t offset) @trusted {
	enum maxPayloadLength = 16 * 1024 * 1024;
	assert(sendBufferSize <= (maxPayloadLength - 1) / 2);
	auto payload = new ubyte[sendBufferSize * 2 + 1];
	foreach (i; 0 .. payload.length) payload[i] = cast(ubyte) (i * multiplier + offset);
	return payload;
}

private final class EpollSocketTestState {
	Event contextReady;
	Event armed;
	Event firstTerminal;
	Event secondTerminal;
	Event terminal;
	Event stopInput;
	Event finished;
	shared EpollScheduler scheduler;
	shared ThreadID driver;
	shared int firstValues;
	shared int secondValues;
	shared int values;
	shared int dones;
	shared int errors;
	shared int terminals;
	shared int result;

	this() @trusted shared {
		foreach (event; [ &contextReady, &armed, &firstTerminal, &secondTerminal,
			&terminal, &stopInput, &finished ])
			(cast() *event).initialize(false, false);
	}

	void publish(EpollContext* value) @trusted shared {
		scheduler = cast(shared) value.scheduler;
		driver = thisThreadID;
		(cast() contextReady).setIfInitialized();
	}

	void waitContext() @trusted shared { (cast() contextReady).wait(); }
	void signalArmed() @trusted shared nothrow { (cast() armed).setIfInitialized(); }
	void waitArmed() @trusted shared { (cast() armed).wait(); }
	void signalFirstTerminal() @trusted shared nothrow { (cast() firstTerminal).setIfInitialized(); }
	void waitFirstTerminal() @trusted shared { (cast() firstTerminal).wait(); }
	void signalSecondTerminal() @trusted shared nothrow { (cast() secondTerminal).setIfInitialized(); }
	void waitSecondTerminal() @trusted shared { (cast() secondTerminal).wait(); }
	void signalTerminal() @trusted shared nothrow { (cast() terminal).setIfInitialized(); }
	void waitTerminal() @trusted shared { (cast() terminal).wait(); }
	void stop() @trusted shared nothrow { (cast() stopInput).setIfInitialized(); }
	void waitStop() @trusted shared { (cast() stopInput).wait(); }
	void signalFinished() @trusted shared nothrow { (cast() finished).setIfInitialized(); }
	void waitFinished() @trusted shared { (cast() finished).wait(); }
}

private struct EpollSocketArmedReceiver {
	shared EpollSocketTestState state;
	void setValue(int value) @trusted nothrow {
		assert(value == 0);
		assert(thisThreadID == atomicLoad!(MemoryOrder.acq)(state.driver));
		state.signalArmed();
	}
	void setDone() @safe nothrow { assert(false, "arming nop was cancelled"); }
	void setError(Throwable) @safe nothrow { assert(false, "arming nop failed"); }
	shared(StopToken) getStopToken() @safe nothrow { return shared(StopToken).init; }
}

private struct EpollSocketBufferReceiver {
	shared EpollSocketTestState state;
	ubyte[] expected;
	bool first;
	void setValue(ubyte[] value) @trusted nothrow {
		assert(value == expected);
		assert(thisThreadID == atomicLoad!(MemoryOrder.acq)(state.driver));
		atomicFetchAdd!(MemoryOrder.acq_rel)(state.values, 1);
		atomicFetchAdd!(MemoryOrder.acq_rel)(state.terminals, 1);
		if (first) {
			atomicFetchAdd!(MemoryOrder.acq_rel)(state.firstValues, 1);
			state.signalFirstTerminal();
		} else {
			atomicFetchAdd!(MemoryOrder.acq_rel)(state.secondValues, 1);
			state.signalSecondTerminal();
		}
	}
	void setDone() @safe nothrow { assert(false, "socket receive was cancelled"); }
	void setError(Throwable) @safe nothrow { assert(false, "socket receive failed"); }
	shared(StopToken) getStopToken() @safe nothrow { return shared(StopToken).init; }
}

private struct EpollSocketRecoveryReceiver {
	shared EpollSocketTestState state;
	int maximum;
	void setValue(int value) @trusted nothrow {
		assert(value > 0 && value < maximum);
		assert(thisThreadID == atomicLoad!(MemoryOrder.acq)(state.driver));
		atomicStore!(MemoryOrder.rel)(state.result, value);
		atomicFetchAdd!(MemoryOrder.acq_rel)(state.values, 1);
		atomicFetchAdd!(MemoryOrder.acq_rel)(state.terminals, 1);
		state.signalTerminal();
	}
	void setDone() @safe nothrow { assert(false, "socket write was cancelled"); }
	void setError(Throwable) @safe nothrow { assert(false, "socket write failed"); }
	shared(StopToken) getStopToken() @safe nothrow { return shared(StopToken).init; }
}

private final class EpollShutdownState {
	Event contextReady;
	Event stopInput;
	Event reserved;
	Event release;
	Event closed;
	Event terminal;
	Event finished;
	shared EpollScheduler scheduler;
	shared ThreadID driver;
	shared int terminals;
	shared int producerReturned;
	shared int dones;
	shared int finalClosed;
	shared int finalReservations;
	shared int finalLive;
	shared int finalRequestsEmpty;
	shared int finalTimersEmpty;
	shared int finalWheelTimers;
	shared int finalActiveRecords;
	shared int finalReadWaiters;
	shared int finalWriteWaiters;
	shared int finalRetirementEntries;
	shared int finalCloseCalls;

	this() @trusted shared {
		foreach (event; [ &contextReady, &stopInput, &reserved, &release,
			&closed, &terminal, &finished ])
			(cast() *event).initialize(false, false);
	}

	void publish(EpollContext* value) @trusted shared {
		scheduler = cast(shared) value.scheduler;
		driver = thisThreadID;
		(cast() contextReady).setIfInitialized();
	}

	void waitContext() @trusted shared { (cast() contextReady).wait(); }
	void stop() @trusted shared { (cast() stopInput).setIfInitialized(); }
	void waitStop() @trusted shared { (cast() stopInput).wait(); }
	void waitReserved() @trusted shared { (cast() reserved).wait(); }
	void releaseProducer() @trusted shared { (cast() release).setIfInitialized(); }
	void signalClosed() @trusted shared { (cast() closed).setIfInitialized(); }
	void waitClosed() @trusted shared { (cast() closed).wait(); }
	void signalTerminal() @trusted shared nothrow { (cast() terminal).setIfInitialized(); }
	void waitTerminal() @trusted shared { (cast() terminal).wait(); }
	void signalFinished() @trusted shared { (cast() finished).setIfInitialized(); }
	void waitFinished() @trusted shared { (cast() finished).wait(); }

	void record(EpollContext.QuiescenceSnapshot snapshot) @trusted shared {
		atomicStore!(MemoryOrder.rel)(finalClosed, snapshot.closed ? 1 : 0);
		atomicStore!(MemoryOrder.rel)(finalReservations,
			cast(int) snapshot.reservations);
		atomicStore!(MemoryOrder.rel)(finalLive, cast(int) snapshot.live);
		atomicStore!(MemoryOrder.rel)(finalRequestsEmpty,
			snapshot.requestsEmpty ? 1 : 0);
		atomicStore!(MemoryOrder.rel)(finalTimersEmpty,
			snapshot.timersEmpty ? 1 : 0);
		atomicStore!(MemoryOrder.rel)(finalWheelTimers,
			cast(int) snapshot.wheelTimers);
		atomicStore!(MemoryOrder.rel)(finalActiveRecords,
			cast(int) snapshot.activeRecords);
		atomicStore!(MemoryOrder.rel)(finalReadWaiters,
			cast(int) snapshot.readWaiters);
		atomicStore!(MemoryOrder.rel)(finalWriteWaiters,
			cast(int) snapshot.writeWaiters);
		atomicStore!(MemoryOrder.rel)(finalRetirementEntries,
			cast(int) snapshot.retirementEntries);
	}
}

private void checkQuiescent(shared EpollShutdownState state) @trusted {
	atomicLoad!(MemoryOrder.acq)(state.finalClosed).should == 1;
	atomicLoad!(MemoryOrder.acq)(state.finalReservations).should == 0;
	atomicLoad!(MemoryOrder.acq)(state.finalLive).should == 0;
	atomicLoad!(MemoryOrder.acq)(state.finalRequestsEmpty).should == 1;
	atomicLoad!(MemoryOrder.acq)(state.finalTimersEmpty).should == 1;
	atomicLoad!(MemoryOrder.acq)(state.finalWheelTimers).should == 0;
	atomicLoad!(MemoryOrder.acq)(state.finalActiveRecords).should == 0;
	atomicLoad!(MemoryOrder.acq)(state.finalReadWaiters).should == 0;
	atomicLoad!(MemoryOrder.acq)(state.finalWriteWaiters).should == 0;
	atomicLoad!(MemoryOrder.acq)(state.finalRetirementEntries).should == 0;
}

private final class EpollReadinessCancelState {
	Event contextReady;
	Event armed;
	Event paused;
	Event release;
	Event terminal;
	Event drained;
	Event stopInput;
	Event finished;
	shared EpollScheduler scheduler;
	shared ThreadID driver;
	shared int values;
	shared int dones;
	shared int errors;
	shared int terminals;

	this() @trusted shared {
		foreach (event; [ &contextReady, &armed, &paused, &release, &terminal,
			&drained, &stopInput, &finished ])
			(cast() *event).initialize(false, false);
	}

	void publish(EpollContext* value) @trusted shared {
		scheduler = cast(shared) value.scheduler;
		driver = thisThreadID;
		(cast() contextReady).setIfInitialized();
	}

	void waitContext() @trusted shared { (cast() contextReady).wait(); }
	void signalArmed() @trusted shared nothrow { (cast() armed).setIfInitialized(); }
	void waitArmed() @trusted shared { (cast() armed).wait(); }
	void waitPaused() @trusted shared { (cast() paused).wait(); }
	void releaseDriver() @trusted shared nothrow { (cast() release).setIfInitialized(); }
	void signalTerminal() @trusted shared nothrow { (cast() terminal).setIfInitialized(); }
	void waitTerminal() @trusted shared { (cast() terminal).wait(); }
	void signalDrained() @trusted shared nothrow { (cast() drained).setIfInitialized(); }
	void waitDrained() @trusted shared { (cast() drained).wait(); }
	void stop() @trusted shared nothrow { (cast() stopInput).setIfInitialized(); }
	void waitStop() @trusted shared { (cast() stopInput).wait(); }
	void signalFinished() @trusted shared nothrow { (cast() finished).setIfInitialized(); }
	void waitFinished() @trusted shared { (cast() finished).wait(); }
}

private struct EpollReadinessCancelArmedReceiver {
	shared EpollReadinessCancelState state;
	void setValue(int value) @trusted nothrow {
		assert(value == 0);
		assert(thisThreadID == atomicLoad!(MemoryOrder.acq)(state.driver));
		state.signalArmed();
	}
	void setDone() @safe nothrow { assert(false, "arming barrier was cancelled"); }
	void setError(Throwable) @safe nothrow { assert(false, "arming barrier failed"); }
	shared(StopToken) getStopToken() @safe nothrow { return shared(StopToken).init; }
}

private struct EpollReadinessCancelDrainedReceiver {
	shared EpollReadinessCancelState state;
	void setValue(int value) @trusted nothrow {
		assert(value == 0);
		assert(thisThreadID == atomicLoad!(MemoryOrder.acq)(state.driver));
		state.signalDrained();
	}
	void setDone() @safe nothrow { assert(false, "drain barrier was cancelled"); }
	void setError(Throwable) @safe nothrow { assert(false, "drain barrier failed"); }
	shared(StopToken) getStopToken() @safe nothrow { return shared(StopToken).init; }
}

@("EpollScheduler.IOScheduler") @safe
unittest {
	static assert(isIOScheduler!EpollScheduler);
	auto erased = EpollScheduler.init.toIOSchedulerObject;
	static assert(is(typeof(erased.nop()) == SenderObjectBase!int));
	static assert(is(typeof(erased.recv(socket_t.init, uint.init))
		== SenderObjectBase!ManagedBuffer));
	static assert(is(typeof(erased.recv(socket_t.init, ubyte[].init, long.init))
		== SenderObjectBase!(ubyte[])));
	static assert(is(typeof(erased.read(socket_t.init, ubyte[].init, long.init))
		== SenderObjectBase!(ubyte[])));
	static assert(is(typeof(erased.accept(socket_t.init)) == SenderObjectBase!Client));
	static assert(is(typeof(erased.connect(socket_t.init, string.init, ushort.init)) == SenderObjectBase!void));
	static assert(is(typeof(erased.send(socket_t.init, const(ubyte[]).init)) == SenderObjectBase!int));
	static assert(is(typeof(erased.write(socket_t.init, const(ubyte[]).init, long.init)) == SenderObjectBase!int));
	static assert(is(typeof(erased.close(socket_t.init)) == SenderObjectBase!void));
	static assert(is(IOContext == IOUringContext));
}

@("EpollContext.synthetic tokens reject reserved and out-of-range values") @trusted
unittest {
	auto context = EpollContext.construct(8);
	ulong[] batch = [context.wakeToken, 0, 0x0000000100ffffffUL,
		0x0000000200000001UL];
	context.dispatchSynthetic(batch);
	auto snapshot = context.quiescenceSnapshot();
	snapshot.activeRecords.should == 0;
	snapshot.readWaiters.should == 0;
	snapshot.writeWaiters.should == 0;
	snapshot.retirementEntries.should == 0;
}

@("EpollContext.registry fixture rejects stale and quarantines exhausted generations") @trusted
unittest {
	auto context = EpollContext.construct(8);
	auto original = context.fixtureSlot(91, 1);
	auto current = context.fixtureInvalidate(91);
	current.generation.should == 2;
	context.dispatchSynthetic([original.token, original.token]);
	auto exhausted = context.fixtureSlot(92, (ulong(1) << 40) - 1);
	auto quarantined = context.fixtureInvalidate(92);
	quarantined.quarantined.should == true;
	quarantined.token.should == 0;
	context.dispatchSynthetic([exhausted.token]);
}

@("EpollContext.synthetic dispatch rejects an old token after forced numeric fd reuse") @trusted
unittest {
	import core.sys.posix.unistd : dup2;

	final class State {
		EpollContext* context;
		int fd;
		int peer;
		ubyte[8] current;
		int detachedValues;
		int currentValues;
		OperationalStateBase currentOperation;
	}
	static struct CurrentReceiver {
		State state;
		void setValue(ubyte[] value) @trusted {
			ubyte[] expected = [72];
			assert(value == expected);
			state.currentValues++;
		}
		void setDone() @safe nothrow { assert(false, "current operation was cancelled"); }
		void setError(Throwable) @safe nothrow { assert(false, "current operation failed"); }
		shared(StopToken) getStopToken() @safe nothrow { return shared(StopToken).init; }
	}
	static struct DetachedReceiver {
		State state;
		void setValue(ubyte[] value) @trusted {
			ubyte[] expected = [71];
			assert(value == expected);
			state.detachedValues++;
			close(state.fd);
			close(state.peer);
			auto replacement = epollSocketPair();
			if (replacement[0] != state.fd) {
				assert(dup2(replacement[0], state.fd) == state.fd);
				close(replacement[0]);
			}
			state.peer = replacement[1];
			state.currentOperation = state.context.scheduler.recv(cast(socket_t) state.fd,
				state.current).connectHeap(CurrentReceiver(state));
			state.currentOperation.start();
		}
		void setDone() @safe nothrow { assert(false, "detached operation was cancelled"); }
		void setError(Throwable) @safe nothrow { assert(false, "detached operation failed"); }
		shared(StopToken) getStopToken() @safe nothrow { return shared(StopToken).init; }
	}

	auto fds = epollSocketPair();
	auto context = EpollContext.construct(8);
	auto state = new State;
	state.context = &context;
	state.fd = fds[0];
	state.peer = fds[1];
	scope(exit) close(state.fd);
	scope(exit) close(state.peer);
	auto detached = context.fixtureSlot(state.fd, 1);
	auto original = context.scheduler.recv(cast(socket_t) state.fd, state.current)
		.connect(DetachedReceiver(state));
	original.start();

	context.run(context.scheduler.nop().letValue((int) @trusted {
		ubyte[] initial = [71];
		sendSocketBytes(state.peer, initial).should == initial.length;
		context.dispatchSynthetic([detached.token]);
		return context.scheduler.nop().letValue((int) @trusted {
			state.detachedValues.should == 1;
			ubyte[] current = [72];
			sendSocketBytes(state.peer, current).should == current.length;
			auto replacement = detached.token + (ulong(1) << 24);
			context.dispatchSynthetic([detached.token, replacement]);
			return just();
		});
	})).syncWait.assumeOk;

	state.detachedValues.should == 1;
	state.currentValues.should == 1;
	auto snapshot = context.quiescenceSnapshot();
	snapshot.reservations.should == 0;
	snapshot.live.should == 0;
	snapshot.requestsEmpty.should == true;
	snapshot.timersEmpty.should == true;
	snapshot.wheelTimers.should == 0;
	snapshot.activeRecords.should == 0;
	snapshot.readWaiters.should == 0;
	snapshot.writeWaiters.should == 0;
	snapshot.retirementEntries.should == 0;
}

@("EpollContext.synthetic copied batch defers retirement reuse until completion") @trusted
unittest {

	final class State {
		EpollContext* context;
		int firstValues;
		int secondValues;
		size_t firstRetirements;
		size_t secondRetirements;
		EpollContext.RegistryFixture first;
		EpollContext.RegistryFixture held;
	}
	static struct FirstReceiver {
		State state;
		void setValue(ubyte[] value) @trusted {
			ubyte[] expected = [81];
			assert(value == expected);
			state.firstValues++;
			state.firstRetirements = state.context.quiescenceSnapshot().retirementEntries;
			state.held = state.context.fixtureSlot(401, 1);
			state.held.index.shouldNotEqual(state.first.index);
			state.context.fixtureDetach(401);
		}
		void setDone() @safe nothrow { assert(false, "first operation was cancelled"); }
		void setError(Throwable) @safe nothrow { assert(false, "first operation failed"); }
		shared(StopToken) getStopToken() @safe nothrow { return shared(StopToken).init; }
	}
	static struct SecondReceiver {
		State state;
		void setValue(ubyte[] value) @trusted {
			ubyte[] expected = [82];
			assert(value == expected);
			state.secondValues++;
			state.secondRetirements = state.context.quiescenceSnapshot().retirementEntries;
		}
		void setDone() @safe nothrow { assert(false, "second operation was cancelled"); }
		void setError(Throwable) @safe nothrow { assert(false, "second operation failed"); }
		shared(StopToken) getStopToken() @safe nothrow { return shared(StopToken).init; }
	}
	auto firstFds = epollSocketPair();
	auto secondFds = epollSocketPair();
	scope(exit) if (firstFds[0] >= 0) close(firstFds[0]);
	scope(exit) if (firstFds[1] >= 0) close(firstFds[1]);
	scope(exit) if (secondFds[0] >= 0) close(secondFds[0]);
	scope(exit) if (secondFds[1] >= 0) close(secondFds[1]);
	auto context = EpollContext.construct(8);
	auto state = new State;
	state.context = &context;
	auto first = context.fixtureSlot(firstFds[0], 1);
	state.first = first;
	auto second = context.fixtureSlot(secondFds[0], 1);
	ubyte[8] firstStorage;
	ubyte[8] secondStorage;
	auto firstOperation = context.scheduler.recv(cast(socket_t) firstFds[0], firstStorage)
		.connect(FirstReceiver(state));
	auto secondOperation = context.scheduler.recv(cast(socket_t) secondFds[0], secondStorage)
		.connect(SecondReceiver(state));
	firstOperation.start();
	secondOperation.start();

	context.run(context.scheduler.nop().letValue((int) @trusted {
		ubyte[] firstBytes = [81];
		ubyte[] secondBytes = [82];
		sendSocketBytes(firstFds[1], firstBytes).should == firstBytes.length;
		sendSocketBytes(secondFds[1], secondBytes).should == secondBytes.length;
		context.dispatchSynthetic([first.token, second.token]);
		auto firstReusable = context.fixtureSlot(402, 1);
		auto secondReusable = context.fixtureSlot(403, 1);
		auto thirdReusable = context.fixtureSlot(404, 1);
		(firstReusable.index == first.index || secondReusable.index == first.index
			|| thirdReusable.index == first.index).should == true;
		context.fixtureDetach(402);
		context.fixtureDetach(403);
		context.fixtureDetach(404);
		return just();
	})).syncWait.assumeOk;

	state.firstValues.should == 1;
	state.secondValues.should == 1;
	state.firstRetirements.shouldNotEqual(0);
	assert(state.secondRetirements > state.firstRetirements);
	auto snapshot = context.quiescenceSnapshot();
	snapshot.reservations.should == 0;
	snapshot.live.should == 0;
	snapshot.requestsEmpty.should == true;
	snapshot.timersEmpty.should == true;
	snapshot.wheelTimers.should == 0;
	snapshot.activeRecords.should == 0;
	snapshot.readWaiters.should == 0;
	snapshot.writeWaiters.should == 0;
	snapshot.retirementEntries.should == 0;
}

@("EpollContext.timer cancellation race") @safe
unittest {
	auto context = EpollContext.construct(8);
	context.run(race(
		ScheduleAfter(2_000.msecs),
		ThreadSender().letValue(() => ScheduleAfter(5.msecs)),
	)).syncWait.assumeOk;
}

@("EpollContext.immediate value done error") @safe
unittest {
	auto valueContext = EpollContext.construct(8);
	valueContext.run(just(1)).syncWait().value.should == 1;
	auto doneContext = EpollContext.construct(8);
	doneContext.run(DoneSender()).syncWait.isCancelled.should == true;
	auto errorContext = EpollContext.construct(8);
	errorContext.run(ErrorSender(new Exception("epoll user error")))
		.syncWait().value.shouldThrowWithMessage!Exception("epoll user error");
}

@("EpollContext.run sender retains facade state") @safe
unittest {
	auto makeRun() {
		auto context = EpollContext.construct(8);
		return context.run(just(42));
	}
	makeRun().syncWait().value.should == 42;
}

@("EpollContext.fd cycles") @trusted
unittest {
	import core.stdc.errno : errno, EBADF;
	import core.sys.posix.fcntl : fcntl, F_GETFD;
	foreach (_; 0 .. 16) {
		auto context = EpollContext.construct(8);
		auto fds = context.fileDescriptors();
		context.run(just()).syncWait.assumeOk;
		foreach (fd; fds) {
			errno = 0;
			fcntl(fd, F_GETFD).should == -1;
			errno.should == EBADF;
		}
	}
}

@("EpollContext.nop is queued") @trusted
unittest {
	shared int calls;
	static struct Receiver {
		shared int* calls;
		void setValue(int value) @safe { assert(value == 0); atomicStore!(MemoryOrder.rel)(*calls, 1); }
		void setDone() @safe nothrow {}
		void setError(Throwable) @safe nothrow { assert(false); }
	}
	auto context = EpollContext.construct(8);
	auto operation = context.scheduler.nop().connect(Receiver(&calls));
	operation.start();
	atomicLoad!(MemoryOrder.acq)(calls).should == 0;
	context.run(just()).syncWait.assumeOk;
	atomicLoad!(MemoryOrder.acq)(calls).should == 1;
}

@("EpollContext.nop terminal is non-reentrant and runs on the driver") @trusted
unittest {
	final class State {
		Event started;
		Event returned;
		ThreadID driver;
		shared int calls;
		shared void* operation;

		this(ThreadID driver) @trusted shared {
			this.driver = driver;
			(cast() started).initialize(false, false);
			(cast() returned).initialize(false, false);
		}

		void signalStarted() @trusted shared {
			(cast() started).setIfInitialized();
		}

		void waitStarted() @trusted shared {
			(cast() started).wait();
		}

		void signalReturned() @trusted shared {
			(cast() returned).setIfInitialized();
		}

		void waitReturned() @trusted shared {
			(cast() returned).wait();
		}

		bool isDriver() @trusted shared {
			return thisThreadID == atomicLoad!(MemoryOrder.acq)(driver);
		}
	}

	struct Receiver {
		shared State state;

		void setValue(int value) @trusted {
			assert(value == 0);
			assert(state.isDriver(),
				"Epoll terminal callback must run on the driving thread");
			atomicStore!(MemoryOrder.rel)(state.calls, 1);
		}

		void setDone() @safe nothrow { assert(false, "nop was cancelled"); }
		void setError(Throwable) @safe nothrow { assert(false, "nop failed"); }
	}

	auto context = EpollContext.construct(8);
	auto state = new shared State(thisThreadID);
	auto producer = new Thread({
		import core.stdc.stdlib : malloc;
		import std.conv : emplace;
		auto source = context.scheduler.nop()
			.connect(Receiver(state));
		alias Operation = typeof(source);
		auto operation = emplace!Operation(cast(Operation*) malloc(Operation.sizeof),
			source.context, source.receiver);
		state.operation = cast(shared void*) operation;
		state.signalStarted();
		operation.start();
		state.signalReturned();
	}).start();

	state.waitStarted();
	state.waitReturned();
	producer.join();
	atomicLoad!(MemoryOrder.acq)(state.calls).should == 0;

	context.run(just()).syncWait.assumeOk;
	atomicLoad!(MemoryOrder.acq)(state.calls).should == 1;
	import core.stdc.stdlib : free;
	free(cast(void*) atomicLoad!(MemoryOrder.acq)(state.operation));
}

@("EpollContext.driver nop is queued") @trusted
unittest {
	final class State { shared int returned; shared int calls; }
	static struct Receiver {
		shared State state;
		void setValue(int value) @trusted nothrow {
			assert(value == 0);
			assert(atomicLoad!(MemoryOrder.acq)(state.returned) != 0);
			atomicFetchAdd!(MemoryOrder.acq_rel)(state.calls, 1);
		}
		void setDone() @safe nothrow { assert(false); }
		void setError(Throwable) @safe nothrow { assert(false); }
	}

	auto context = EpollContext.construct(8);
	shared EpollScheduler sharedContext = cast(shared) context.scheduler;
	auto state = new shared State;
	auto operation = (cast() sharedContext).nop().connect(Receiver(state));
	shared typeof(operation)* operationPtr = cast(shared typeof(operation)*) &operation;
	context.run(justFrom(() shared @trusted {
		(cast(typeof(operation)*) operationPtr).start();
		assert(atomicLoad!(MemoryOrder.acq)(state.calls) == 0);
		atomicStore!(MemoryOrder.rel)(state.returned, 1);
	})).syncWait.assumeOk;
	atomicLoad!(MemoryOrder.acq)(state.calls).should == 1;
}

@("EpollContext.close error and timer terminals run on driver") @trusted
unittest {
	static struct State { ThreadID driver; int errors; int dones; }
	static struct ErrorReceiver {
		State* state;
		void setValue() @safe nothrow { assert(false); }
		void setDone() @safe nothrow { assert(false); }
		void setError(Throwable error) @trusted nothrow {
			assert(error.msg[0 .. "Close failed".length] == "Close failed");
			assert(thisThreadID == state.driver);
			state.errors++;
		}
	}
	static struct TimerReceiver {
		State* state;
		void setValue() @safe nothrow { assert(false); }
		void setDone() @trusted nothrow { assert(thisThreadID == state.driver); state.dones++; }
		void setError(Throwable) @safe nothrow { assert(false); }
		shared(StopToken) getStopToken() @safe nothrow { return shared(StopToken).init; }
	}

	auto context = EpollContext.construct(8);
	State state = State(thisThreadID, 0, 0);
	auto error = context.scheduler.close(cast(socket_t) -1)
		.connect(ErrorReceiver(&state));
	auto timer = context.scheduler.scheduleAfter(60_000.msecs)
		.connect(TimerReceiver(&state));
	error.start();
	timer.start();
	context.run(just()).syncWait.assumeOk;
	state.errors.should == 1;
	state.dones.should == 1;
}

@("EpollContext.after-close admission is diagnosed") @trusted
unittest {
	import core.exception : AssertError;
	static struct Receiver {
		int* calls;
		void setValue(int) @safe { (*calls)++; }
		void setDone() @safe nothrow { (*calls)++; }
		void setError(Throwable) @safe nothrow { (*calls)++; }
	}

	auto context = EpollContext.construct(8);
	context.run(just()).syncWait.assumeOk;
	int calls;
	auto operation = context.scheduler.nop()
		.connect(Receiver(&calls));
	bool diagnosed;
	try operation.start();
	catch (AssertError) diagnosed = true;
	diagnosed.should == true;
	calls.should == 0;
}

@("EpollContext.after-close timer admission is diagnosed") @trusted
unittest {
	import core.exception : AssertError;
	static struct Receiver {
		int* calls;
		void setValue() @safe nothrow { assert(false); }
		void setDone() @safe nothrow { assert(false); }
		void setError(Throwable error) @safe nothrow {
			assert(cast(AssertError) error !is null);
			(*calls)++;
		}
		shared(StopToken) getStopToken() @safe nothrow { return shared(StopToken).init; }
	}

	auto context = EpollContext.construct(8);
	context.run(just()).syncWait.assumeOk;
	int calls;
	auto operation = context.scheduler.scheduleAfter(60_000.msecs)
		.connect(Receiver(&calls));
	operation.start();
	calls.should == 1;
}

@("EpollContext.shutdown cancels a nop reserved before publication") @trusted
unittest {
	struct Receiver {
		shared EpollShutdownState state;

		void setValue(int) @safe { assert(false, "reserved nop was executed"); }
		void setDone() @trusted nothrow {
			assert(thisThreadID == atomicLoad!(MemoryOrder.acq)(state.driver));
			atomicFetchAdd!(MemoryOrder.acq_rel)(state.terminals, 1);
			atomicFetchAdd!(MemoryOrder.acq_rel)(state.dones, 1);
			state.signalTerminal();
		}
		void setError(Throwable) @safe nothrow { assert(false, "reserved nop failed"); }
	}

	auto state = new shared EpollShutdownState;
	auto driver = new Thread({
		auto context = EpollContext.construct(8);
		context.pauseCommandAfterReserve(&state.reserved, &state.release);
		context.observeAdmissionClose(&state.closed);
		state.publish(&context);
		context.run(ThreadSender().letValue(() @trusted {
			state.waitStop();
			return just();
		}))
			.syncWait.assumeOk;
		state.record(context.quiescenceSnapshot());
		state.signalFinished();
	}).start();

	state.waitContext();
	auto producer = new Thread({
		auto operation = (cast() state.scheduler).nop().connect(Receiver(state));
		operation.start();
		state.waitTerminal();
	}).start();
	state.waitReserved();

	state.stop();
	state.waitClosed();
	state.releaseProducer();
	producer.join();
	state.waitFinished();
	driver.join();

	atomicLoad!(MemoryOrder.acq)(state.terminals).should == 1;
	atomicLoad!(MemoryOrder.acq)(state.dones).should == 1;
	checkQuiescent(state);
}

@("EpollContext.shutdown consumes a reserved close descriptor") @trusted
unittest {
	import concurrency.io.socket : tcpSocket;
	import core.stdc.errno : errno, EBADF;
	import core.sys.posix.fcntl : fcntl, F_GETFD;
	static struct Receiver {
		shared EpollShutdownState state;
		void setValue() @safe nothrow { assert(false); }
		void setDone() @trusted nothrow { assert(thisThreadID == atomicLoad!(MemoryOrder.acq)(state.driver)); atomicFetchAdd!(MemoryOrder.acq_rel)(state.terminals, 1); atomicFetchAdd!(MemoryOrder.acq_rel)(state.dones, 1); state.signalTerminal(); }
		void setError(Throwable) @safe nothrow { assert(false); }
		shared(StopToken) getStopToken() @safe nothrow { return shared(StopToken).init; }
	}
	auto socket = tcpSocket(); auto fd = socket.release();
	auto state = new shared EpollShutdownState;
	auto driver = new Thread({ auto context = EpollContext.construct(8); context.pauseCommandAfterReserve(&state.reserved, &state.release); context.observeAdmissionClose(&state.closed); state.publish(&context); context.run(ThreadSender().letValue(() @trusted { state.waitStop(); return just(); })).syncWait.assumeOk; state.record(context.quiescenceSnapshot()); atomicStore!(MemoryOrder.rel)(state.finalCloseCalls, cast(int) context.closeCallCount); state.signalFinished(); }).start();
	state.waitContext();
	auto producer = new Thread({ auto operation = (cast() state.scheduler).close(fd).connect(Receiver(state)); operation.start(); state.waitTerminal(); }).start();
	state.waitReserved(); state.stop(); state.waitClosed(); state.releaseProducer(); producer.join(); state.waitFinished(); driver.join();
	atomicLoad!(MemoryOrder.acq)(state.terminals).should == 1; atomicLoad!(MemoryOrder.acq)(state.dones).should == 1;
	atomicLoad!(MemoryOrder.acq)(state.finalCloseCalls).should == 1;
	assert(fcntl(fd, F_GETFD) == -1); errno.should == EBADF;
	checkQuiescent(state);
}

@("EpollContext.foreign nop remains owned after publication") @trusted
unittest {
	struct Receiver {
		shared EpollShutdownState state;
		void setValue(int value) @trusted nothrow {
			assert(value == 0);
			assert(thisThreadID == atomicLoad!(MemoryOrder.acq)(state.driver));
			assert(atomicLoad!(MemoryOrder.acq)(state.producerReturned) == 0);
			atomicFetchAdd!(MemoryOrder.acq_rel)(state.terminals, 1);
			state.signalTerminal();
		}
		void setDone() @safe nothrow { assert(false); }
		void setError(Throwable) @safe nothrow { assert(false); }
	}

	auto state = new shared EpollShutdownState;
	auto driver = new Thread({
		auto context = EpollContext.construct(8);
		context.pauseCommandAfterPublish(&state.reserved, &state.release);
		state.publish(&context);
		context.run(ThreadSender().letValue(() @trusted {
			state.waitStop();
			return just();
		})).syncWait.assumeOk;
		state.record(context.quiescenceSnapshot());
		state.signalFinished();
	}).start();
	state.waitContext();
	auto producer = new Thread({
		auto operation = (cast() state.scheduler).nop().connect(Receiver(state));
		operation.start();
		atomicStore!(MemoryOrder.rel)(state.producerReturned, 1);
	}).start();
	state.waitReserved();
	state.waitTerminal();
	atomicLoad!(MemoryOrder.acq)(state.terminals).should == 1;
	state.releaseProducer();
	producer.join();
	atomicLoad!(MemoryOrder.acq)(state.producerReturned).should == 1;
	state.stop();
	state.waitFinished();
	driver.join();
	checkQuiescent(state);
}

@("EpollContext.shutdown cancels a timer reserved before publication") @trusted
unittest {
	struct Receiver {
		shared EpollShutdownState state;

		void setValue() @safe { assert(false, "reserved timer was triggered"); }
		void setDone() @trusted nothrow {
			assert(thisThreadID == atomicLoad!(MemoryOrder.acq)(state.driver));
			atomicFetchAdd!(MemoryOrder.acq_rel)(state.terminals, 1);
			atomicFetchAdd!(MemoryOrder.acq_rel)(state.dones, 1);
			state.signalTerminal();
		}
		void setError(Throwable) @safe nothrow { assert(false, "reserved timer failed"); }
		shared(StopToken) getStopToken() @safe nothrow {
			return shared(StopToken).init;
		}
	}

	auto state = new shared EpollShutdownState;
	auto driver = new Thread({
		auto context = EpollContext.construct(8);
		context.pauseTimerAfterReserve(&state.reserved, &state.release);
		context.observeAdmissionClose(&state.closed);
		state.publish(&context);
		context.run(ThreadSender().letValue(() @trusted {
			state.waitStop();
			return just();
		}))
			.syncWait.assumeOk;
		state.record(context.quiescenceSnapshot());
		state.signalFinished();
	}).start();

	state.waitContext();
	auto producer = new Thread({
		auto operation = (cast() state.scheduler).scheduleAfter(60_000.msecs)
			.connect(Receiver(state));
		operation.start();
		state.waitTerminal();
	}).start();
	state.waitReserved();

	state.stop();
	state.waitClosed();
	state.releaseProducer();
	producer.join();
	state.waitFinished();
	driver.join();

	atomicLoad!(MemoryOrder.acq)(state.terminals).should == 1;
	atomicLoad!(MemoryOrder.acq)(state.dones).should == 1;
	checkQuiescent(state);
}

@("EpollContext.cross-thread wake") @safe
unittest {
	auto context = EpollContext.construct(8);
	context.run(ThreadSender().letValue(() => nopAsync()))
		.syncWait().value.should == 0;
}

@("EpollContext.multi-producer nops") @safe
unittest {
	auto context = EpollContext.construct(16);
	auto result = context.run(whenAll(
		ThreadSender().letValue(() => nopAsync()),
		ThreadSender().letValue(() => nopAsync()),
		ThreadSender().letValue(() => nopAsync()),
		ThreadSender().letValue(() => nopAsync()),
	)).syncWait().value;
	result[0].should == 0;
	result[1].should == 0;
	result[2].should == 0;
	result[3].should == 0;
}

@("EpollContext.multi-producer shutdown drains mixed work") @trusted
unittest {
	final class Item {
		shared int value, done, error;
		shared ThreadID callback;
		Event started;
		Event terminal;
		this() @trusted shared {
			(cast() started).initialize(false, false);
			(cast() terminal).initialize(false, false);
		}
	}
	struct NopReceiver {
		shared Item item;
		void setValue(int value) @trusted nothrow { assert(value == 0); atomicFetchAdd!(MemoryOrder.acq_rel)(item.value, 1); item.callback = thisThreadID; (cast() item.terminal).setIfInitialized(); }
		void setDone() @trusted nothrow { atomicFetchAdd!(MemoryOrder.acq_rel)(item.done, 1); item.callback = thisThreadID; (cast() item.terminal).setIfInitialized(); }
		void setError(Throwable) @trusted nothrow { atomicFetchAdd!(MemoryOrder.acq_rel)(item.error, 1); item.callback = thisThreadID; (cast() item.terminal).setIfInitialized(); }
	}
	struct TimerReceiver {
		shared Item item;
		void setValue() @trusted nothrow { atomicFetchAdd!(MemoryOrder.acq_rel)(item.value, 1); item.callback = thisThreadID; (cast() item.terminal).setIfInitialized(); }
		void setDone() @trusted nothrow { atomicFetchAdd!(MemoryOrder.acq_rel)(item.done, 1); item.callback = thisThreadID; (cast() item.terminal).setIfInitialized(); }
		void setError(Throwable) @trusted nothrow { atomicFetchAdd!(MemoryOrder.acq_rel)(item.error, 1); item.callback = thisThreadID; (cast() item.terminal).setIfInitialized(); }
		shared(StopToken) getStopToken() @safe nothrow { return shared(StopToken).init; }
	}
	auto state = new shared EpollShutdownState;
	shared Item[8] items;
	foreach (ref item; items) item = new shared Item;
	auto driver = new Thread({
		auto context = EpollContext.construct(32);
		state.publish(&context);
		context.run(ThreadSender().letValue(() @trusted {
			state.waitStop();
			return just();
		})).syncWait.assumeOk;
		state.record(context.quiescenceSnapshot());
		state.signalFinished();
	}).start();
	(cast() state.contextReady).wait(10_000.msecs).should == true;
	Thread makeProducer(shared EpollScheduler scheduler, shared Item nopItem,
		shared Item timerItem) @trusted {
		return new Thread({
			auto nop = (cast() scheduler).nop().connect(NopReceiver(nopItem));
			auto timer = (cast() scheduler).scheduleAfter(60_000.msecs)
				.connect(TimerReceiver(timerItem));
			nop.start();
			timer.start();
			(cast() nopItem.started).setIfInitialized();
			(cast() timerItem.terminal).wait(10_000.msecs).should == true;
		}).start();
	}
	Thread[4] producers;
	foreach (i; 0 .. producers.length)
		producers[i] = makeProducer(state.scheduler, items[i * 2], items[i * 2 + 1]);
	foreach (i; 0 .. 4)
		(cast() items[i * 2].started).wait(10_000.msecs).should == true;
	state.stop();
	(cast() state.finished).wait(10_000.msecs).should == true;
	foreach (producer; producers) producer.join();
	driver.join();
	foreach (i, item; items) {
		(atomicLoad!(MemoryOrder.acq)(item.value) + atomicLoad!(MemoryOrder.acq)(item.done)
			+ atomicLoad!(MemoryOrder.acq)(item.error)).should == 1;
		atomicLoad!(MemoryOrder.acq)(item.callback).should
			== atomicLoad!(MemoryOrder.acq)(state.driver);
		if (i % 2) {
			atomicLoad!(MemoryOrder.acq)(item.done).should == 1;
			atomicLoad!(MemoryOrder.acq)(item.value).should == 0;
		}
	}
	import core.exception : AssertError;
	auto rejected = new shared Item;
	auto rejectedNop = (cast() state.scheduler).nop().connect(NopReceiver(rejected));
	bool diagnosed;
	try rejectedNop.start();
	catch (AssertError) diagnosed = true;
	diagnosed.should == true;
	(atomicLoad!(MemoryOrder.acq)(rejected.value) + atomicLoad!(MemoryOrder.acq)(rejected.done)
		+ atomicLoad!(MemoryOrder.acq)(rejected.error)).should == 0;
	checkQuiescent(state);
}

@("EpollContext.earlier timer preempts") @safe
unittest {
	auto context = EpollContext.construct(8);
	context.run(whenAll(
		ScheduleAfter(50.msecs),
		ThreadSender().letValue(() => ScheduleAfter(1.msecs)),
	)).syncWait.assumeOk;
}

@("EpollContext.cancelled timers drain") @safe
unittest {
	auto context = EpollContext.construct(16);
	context.run(race(
		ScheduleAfter(1.msecs),
		whenAll(ScheduleAfter(100.msecs), ScheduleAfter(100.msecs),
			ScheduleAfter(100.msecs)),
	)).syncWait.assumeOk;
}

@("EpollContext.run.nop") @safe
unittest {
	auto context = EpollContext.construct(8);
	context.run(nopAsync()).syncWait().value.should == 0;
}

@("EpollContext.timer") @safe
unittest {
	auto context = EpollContext.construct(8);
	context.run(ScheduleAfter(1.msecs)).syncWait.assumeOk;
}

@("EpollScheduler.recv completes immediately for preloaded socket data") @trusted
unittest {
	auto fds = epollSocketPair();
	scope(exit) close(fds[0]);
	scope(exit) close(fds[1]);
	ubyte[] expected = [11, 12, 13, 14];
	sendSocketBytes(fds[1], expected).should == expected.length;

	auto context = EpollContext.construct(8);
	ubyte[16] storage;
	auto received = context.run(context.scheduler.recv(cast(socket_t) fds[0], storage))
		.syncWait().value;
	received.should == expected;
}

@("EpollScheduler.recv arms an empty socket then completes after peer send") @trusted
unittest {
	auto fds = epollSocketPair();
	scope(exit) close(fds[0]);
	scope(exit) close(fds[1]);
	ubyte[] expected = [21, 22, 23, 24];
	ubyte[16] storage;
	auto context = EpollContext.construct(8);

	auto result = context.run(whenAll(
		context.scheduler.recv(cast(socket_t) fds[0], storage),
		context.scheduler.scheduleAfter(2.msecs)
			.letValue(() => context.scheduler.send(cast(socket_t) fds[1], expected)),
	)).syncWait().value;
	result[0].should == expected;
	result[1].should == expected.length;
}

@("EpollScheduler.read and write transfer caller buffers") @trusted
unittest {
	auto fds = epollSocketPair();
	scope(exit) close(fds[0]);
	scope(exit) close(fds[1]);
	ubyte[] expected = [31, 32, 33, 34];
	ubyte[16] storage;
	auto context = EpollContext.construct(8);

	auto result = context.run(whenAll(
		context.scheduler.write(cast(socket_t) fds[0], expected),
		context.scheduler.read(cast(socket_t) fds[1], storage),
	)).syncWait().value;
	result[0].should == expected.length;
	result[1].should == expected;
}

@("EpollScheduler.recv repeats immediate and armed caller-buffer receives on one descriptor") @trusted
unittest {
	auto fds = epollSocketPair();
	scope(exit) close(fds[0]);
	scope(exit) close(fds[1]);
	ubyte[] first = [71, 72, 73];
	ubyte[] second = [74, 75, 76, 77];
	sendSocketBytes(fds[1], first).should == first.length;

	auto state = new shared EpollSocketTestState;
	auto quiescence = new shared EpollShutdownState;
	auto driver = new Thread({
		auto context = EpollContext.construct(8);
		state.publish(&context);
		context.run(ThreadSender().letValue(() @trusted {
			state.waitStop();
			return just();
		})).syncWait.assumeOk;
		quiescence.record(context.quiescenceSnapshot());
		state.signalFinished();
	}).start();
	bool stopped;
	scope(exit) if (!stopped) {
		state.stop();
		state.waitFinished();
		driver.join();
	}

	state.waitContext();
	ubyte[16] firstStorage;
	auto immediate = (cast() state.scheduler).recv(cast(socket_t) fds[0], firstStorage)
		.connect(EpollSocketBufferReceiver(state, first, true));
	immediate.start();
	state.waitFirstTerminal();

	ubyte[16] secondStorage;
	auto armedReceive = (cast() state.scheduler).recv(cast(socket_t) fds[0], secondStorage)
		.connect(EpollSocketBufferReceiver(state, second, false));
	auto fence = (cast() state.scheduler).nop().connect(EpollSocketArmedReceiver(state));
	armedReceive.start();
	fence.start();
	state.waitArmed();
	atomicLoad!(MemoryOrder.acq)(state.terminals).should == 1;
	sendSocketBytes(fds[1], second).should == second.length;
	state.waitSecondTerminal();

	atomicLoad!(MemoryOrder.acq)(state.firstValues).should == 1;
	atomicLoad!(MemoryOrder.acq)(state.secondValues).should == 1;
	atomicLoad!(MemoryOrder.acq)(state.values).should == 2;
	atomicLoad!(MemoryOrder.acq)(state.dones).should == 0;
	atomicLoad!(MemoryOrder.acq)(state.errors).should == 0;
	atomicLoad!(MemoryOrder.acq)(state.terminals).should == 2;
	state.stop();
	state.waitFinished();
	driver.join();
	stopped = true;
	checkQuiescent(quiescence);
}

@("EpollScheduler.read repeats immediate and armed caller-buffer reads on one descriptor") @trusted
unittest {
	auto fds = epollSocketPair();
	scope(exit) close(fds[0]);
	scope(exit) close(fds[1]);
	ubyte[] first = [81, 82, 83];
	ubyte[] second = [84, 85, 86, 87];
	sendSocketBytes(fds[1], first).should == first.length;

	auto state = new shared EpollSocketTestState;
	auto quiescence = new shared EpollShutdownState;
	auto driver = new Thread({
		auto context = EpollContext.construct(8);
		state.publish(&context);
		context.run(ThreadSender().letValue(() @trusted {
			state.waitStop();
			return just();
		})).syncWait.assumeOk;
		quiescence.record(context.quiescenceSnapshot());
		state.signalFinished();
	}).start();
	bool stopped;
	scope(exit) if (!stopped) {
		state.stop();
		state.waitFinished();
		driver.join();
	}

	state.waitContext();
	ubyte[16] firstStorage;
	auto immediate = (cast() state.scheduler).read(cast(socket_t) fds[0], firstStorage)
		.connect(EpollSocketBufferReceiver(state, first, true));
	immediate.start();
	state.waitFirstTerminal();

	ubyte[16] secondStorage;
	auto armedRead = (cast() state.scheduler).read(cast(socket_t) fds[0], secondStorage)
		.connect(EpollSocketBufferReceiver(state, second, false));
	auto fence = (cast() state.scheduler).nop().connect(EpollSocketArmedReceiver(state));
	armedRead.start();
	fence.start();
	state.waitArmed();
	atomicLoad!(MemoryOrder.acq)(state.terminals).should == 1;
	sendSocketBytes(fds[1], second).should == second.length;
	state.waitSecondTerminal();

	atomicLoad!(MemoryOrder.acq)(state.firstValues).should == 1;
	atomicLoad!(MemoryOrder.acq)(state.secondValues).should == 1;
	atomicLoad!(MemoryOrder.acq)(state.values).should == 2;
	atomicLoad!(MemoryOrder.acq)(state.dones).should == 0;
	atomicLoad!(MemoryOrder.acq)(state.errors).should == 0;
	atomicLoad!(MemoryOrder.acq)(state.terminals).should == 2;
	state.stop();
	state.waitFinished();
	driver.join();
	stopped = true;
	checkQuiescent(quiescence);
}

@("EpollScheduler.send recovers from EAGAIN with one partial caller-buffer result") @trusted
unittest {
	auto fds = epollSocketPair();
	scope(exit) close(fds[0]);
	scope(exit) close(fds[1]);
	auto sendBufferSize = configureSocketSendBuffer(fds[0]);
	auto prefill = fillSocketSendBufferCounted(fds[0]);
	auto payload = eagainRecoveryPayload(sendBufferSize, 37, 19);

	auto state = new shared EpollSocketTestState;
	auto quiescence = new shared EpollShutdownState;
	auto driver = new Thread({
		auto context = EpollContext.construct(8);
		state.publish(&context);
		context.run(ThreadSender().letValue(() @trusted {
			state.waitStop();
			return just();
		})).syncWait.assumeOk;
		quiescence.record(context.quiescenceSnapshot());
		state.signalFinished();
	}).start();
	bool stopped;
	scope(exit) if (!stopped) {
		state.stop();
		state.waitFinished();
		driver.join();
	}

	state.waitContext();
	auto send = (cast() state.scheduler).send(cast(socket_t) fds[0], payload)
		.connect(EpollSocketRecoveryReceiver(state, cast(int) payload.length));
	auto fence = (cast() state.scheduler).nop().connect(EpollSocketArmedReceiver(state));
	send.start();
	fence.start();
	state.waitArmed();
	atomicLoad!(MemoryOrder.acq)(state.terminals).should == 0;
	drainSocketReceiveBufferExactly(fds[1], prefill);
	state.waitTerminal();

	auto count = atomicLoad!(MemoryOrder.acq)(state.result);
	ubyte[] received = new ubyte[count];
	receiveSocketBytesExactly(fds[1], received);
	received.should == payload[0 .. count];
	atomicLoad!(MemoryOrder.acq)(state.values).should == 1;
	atomicLoad!(MemoryOrder.acq)(state.dones).should == 0;
	atomicLoad!(MemoryOrder.acq)(state.errors).should == 0;
	atomicLoad!(MemoryOrder.acq)(state.terminals).should == 1;
	state.stop();
	state.waitFinished();
	driver.join();
	stopped = true;
	checkQuiescent(quiescence);
}

@("EpollScheduler.write recovers from EAGAIN with one partial caller-buffer result") @trusted
unittest {
	auto fds = epollSocketPair();
	scope(exit) close(fds[0]);
	scope(exit) close(fds[1]);
	auto sendBufferSize = configureSocketSendBuffer(fds[0]);
	auto prefill = fillSocketSendBufferCounted(fds[0]);
	auto payload = eagainRecoveryPayload(sendBufferSize, 53, 23);

	auto state = new shared EpollSocketTestState;
	auto quiescence = new shared EpollShutdownState;
	auto driver = new Thread({
		auto context = EpollContext.construct(8);
		state.publish(&context);
		context.run(ThreadSender().letValue(() @trusted {
			state.waitStop();
			return just();
		})).syncWait.assumeOk;
		quiescence.record(context.quiescenceSnapshot());
		state.signalFinished();
	}).start();
	bool stopped;
	scope(exit) if (!stopped) {
		state.stop();
		state.waitFinished();
		driver.join();
	}

	state.waitContext();
	auto write = (cast() state.scheduler).write(cast(socket_t) fds[0], payload)
		.connect(EpollSocketRecoveryReceiver(state, cast(int) payload.length));
	auto fence = (cast() state.scheduler).nop().connect(EpollSocketArmedReceiver(state));
	write.start();
	fence.start();
	state.waitArmed();
	atomicLoad!(MemoryOrder.acq)(state.terminals).should == 0;
	drainSocketReceiveBufferExactly(fds[1], prefill);
	state.waitTerminal();

	auto count = atomicLoad!(MemoryOrder.acq)(state.result);
	ubyte[] received = new ubyte[count];
	receiveSocketBytesExactly(fds[1], received);
	received.should == payload[0 .. count];
	atomicLoad!(MemoryOrder.acq)(state.values).should == 1;
	atomicLoad!(MemoryOrder.acq)(state.dones).should == 0;
	atomicLoad!(MemoryOrder.acq)(state.errors).should == 0;
	atomicLoad!(MemoryOrder.acq)(state.terminals).should == 1;
	state.stop();
	state.waitFinished();
	driver.join();
	stopped = true;
	checkQuiescent(quiescence);
}

@("EpollScheduler permits one read and one write waiter on a descriptor") @trusted
unittest {
	auto fds = epollSocketPair();
	scope(exit) close(fds[0]);
	scope(exit) close(fds[1]);
	ubyte[] outbound = [41, 42];
	ubyte[] inbound = [43, 44, 45];
	ubyte[16] received;
	ubyte[16] peerReceived;
	auto context = EpollContext.construct(8);

	auto result = context.run(whenAll(
		context.scheduler.recv(cast(socket_t) fds[0], received),
		context.scheduler.send(cast(socket_t) fds[0], outbound),
		context.scheduler.recv(cast(socket_t) fds[1], peerReceived),
		context.scheduler.send(cast(socket_t) fds[1], inbound),
	)).syncWait().value;
	result[0].should == inbound;
	result[1].should == outbound.length;
	result[2].should == outbound;
	result[3].should == inbound.length;
}

@("EpollScheduler rejects a second read waiter without replacing the first") @trusted
unittest {
	static struct State {
		int peer;
		ubyte[] bytes;
		int firstValues;
		int conflicts;
	}
	static struct FirstReceiver {
		State* state;
		void setValue(ubyte[] value) @trusted nothrow {
			assert(value == state.bytes);
			state.firstValues++;
		}
		void setDone() @safe nothrow { assert(false, "first read waiter was cancelled"); }
		void setError(Throwable) @safe nothrow { assert(false, "first read waiter failed"); }
		shared(StopToken) getStopToken() @safe nothrow { return shared(StopToken).init; }
	}
	static struct SecondReceiver {
		State* state;
		void setValue(ubyte[]) @safe nothrow { assert(false, "second read waiter succeeded"); }
		void setDone() @safe nothrow { assert(false, "second read waiter was cancelled"); }
		void setError(Throwable error) @trusted nothrow {
			assert(error.msg == "epoll already has a read waiter for this descriptor");
			state.conflicts++;
			assert(sendSocketBytes(state.peer, state.bytes) == state.bytes.length);
		}
		shared(StopToken) getStopToken() @safe nothrow { return shared(StopToken).init; }
	}

	auto fds = epollSocketPair();
	scope(exit) close(fds[0]);
	scope(exit) close(fds[1]);
	ubyte[8] first;
	ubyte[8] second;
	ubyte[] expected = [46, 47];
	State state = State(fds[1], expected, 0, 0);
	auto context = EpollContext.construct(8);
	auto original = context.scheduler.recv(cast(socket_t) fds[0], first)
		.connect(FirstReceiver(&state));
	auto duplicate = context.scheduler.read(cast(socket_t) fds[0], second)
		.connect(SecondReceiver(&state));
	original.start();
	duplicate.start();
	context.run(ScheduleAfter(5.msecs)).syncWait.assumeOk;
	state.conflicts.should == 1;
	state.firstValues.should == 1;
}

@("EpollScheduler rejects a second write waiter without replacing the first") @trusted
unittest {
	final class State {
		int peer;
		int byteCount;
		shared int firstValues;
		shared int conflicts;
		Event firstTerminal;
		this(int peer, int byteCount) @trusted shared {
			this.peer = peer;
			this.byteCount = byteCount;
			(cast() firstTerminal).initialize(false, false);
		}
		void signalFirst() @trusted shared nothrow { (cast() firstTerminal).setIfInitialized(); }
		void waitFirst() @trusted shared { (cast() firstTerminal).wait(); }
	}
	static struct FirstReceiver {
		shared State state;
		void setValue(int value) @trusted nothrow {
			assert(value == state.byteCount);
			atomicFetchAdd!(MemoryOrder.acq_rel)(state.firstValues, 1);
			state.signalFirst();
		}
		void setDone() @safe nothrow { assert(false, "first write waiter was cancelled"); }
		void setError(Throwable) @safe nothrow { assert(false, "first write waiter failed"); }
		shared(StopToken) getStopToken() @safe nothrow { return shared(StopToken).init; }
	}
	static struct SecondReceiver {
		shared State state;
		void setValue(int) @safe nothrow { assert(false, "second write waiter succeeded"); }
		void setDone() @safe nothrow { assert(false, "second write waiter was cancelled"); }
		void setError(Throwable error) @trusted nothrow {
			assert(error.msg == "epoll already has a write waiter for this descriptor");
			atomicFetchAdd!(MemoryOrder.acq_rel)(state.conflicts, 1);
			drainSocketReceiveBuffer(state.peer);
		}
		shared(StopToken) getStopToken() @safe nothrow { return shared(StopToken).init; }
	}

	auto fds = epollSocketPair();
	scope(exit) close(fds[0]);
	scope(exit) close(fds[1]);
	ubyte[] bytes = [51];
	fillSocketSendBuffer(fds[0]);
	auto state = new shared State(fds[1], cast(int) bytes.length);
	auto context = EpollContext.construct(8);
	auto original = context.scheduler.send(cast(socket_t) fds[0], bytes)
		.connect(FirstReceiver(state));
	auto duplicate = context.scheduler.write(cast(socket_t) fds[0], bytes)
		.connect(SecondReceiver(state));
	original.start();
	duplicate.start();
	context.run(ThreadSender().letValue(() @trusted {
		state.waitFirst();
		return just();
	})).syncWait.assumeOk;
	atomicLoad!(MemoryOrder.acq)(state.conflicts).should == 1;
	atomicLoad!(MemoryOrder.acq)(state.firstValues).should == 1;
}

@("EpollScheduler copied readiness wins over cancellation after epoll_wait") @trusted
unittest {
	static struct Receiver {
		shared EpollReadinessCancelState state;
		shared(StopSource)* source;
		void setValue(ubyte[] value) @trusted nothrow {
			ubyte[] expected = [61, 62];
			assert(value == expected);
			assert(thisThreadID == atomicLoad!(MemoryOrder.acq)(state.driver));
			atomicFetchAdd!(MemoryOrder.acq_rel)(state.values, 1);
			atomicFetchAdd!(MemoryOrder.acq_rel)(state.terminals, 1);
			state.signalTerminal();
		}
		void setDone() @safe nothrow { assert(false, "copied readiness lost to cancellation"); }
		void setError(Throwable) @safe nothrow { assert(false, "copied readiness failed"); }
		shared(StopToken) getStopToken() @safe nothrow { return source.token; }
	}

	auto fds = epollSocketPair();
	scope(exit) close(fds[0]);
	scope(exit) close(fds[1]);
	auto state = new shared EpollReadinessCancelState;
	auto quiescence = new shared EpollShutdownState;
	shared source = StopSource();
	auto driver = new Thread({
		auto context = EpollContext.construct(8);
		context.pauseAfterEpollWait(&state.paused, &state.release);
		state.publish(&context);
		context.run(ThreadSender().letValue(() @trusted {
			state.waitStop();
			return just();
		})).syncWait.assumeOk;
		quiescence.record(context.quiescenceSnapshot());
		state.signalFinished();
	}).start();
	bool stopped;
	scope(exit) if (!stopped) {
		state.releaseDriver();
		state.stop();
		state.waitFinished();
		driver.join();
	}

	state.waitContext();
	ubyte[8] storage;
	auto operation = (cast() state.scheduler).recv(cast(socket_t) fds[0], storage)
		.connect(Receiver(state, &source));
	auto armed = (cast() state.scheduler).nop().connect(EpollReadinessCancelArmedReceiver(state));
	operation.start();
	armed.start();
	state.waitArmed();
	ubyte[] bytes = [61, 62];
	state.scheduler.activatePauseAfterEpollWait();
	sendSocketBytes(fds[1], bytes).should == bytes.length;
	state.waitPaused();
	source.stop();
	auto drained = (cast() state.scheduler).nop().connect(EpollReadinessCancelDrainedReceiver(state));
	drained.start();
	state.releaseDriver();
	state.waitTerminal();
	state.waitDrained();
	atomicLoad!(MemoryOrder.acq)(state.values).should == 1;
	atomicLoad!(MemoryOrder.acq)(state.dones).should == 0;
	atomicLoad!(MemoryOrder.acq)(state.errors).should == 0;
	atomicLoad!(MemoryOrder.acq)(state.terminals).should == 1;
	state.stop();
	state.waitFinished();
	driver.join();
	stopped = true;
	checkQuiescent(quiescence);
}

@("EpollScheduler reverse-ready receives preserve B-before-A fairness with nop and expired timer") @trusted
unittest {
	final class State {
		Event contextReady;
		Event armed;
		Event paused;
		Event release;
		Event aTerminal;
		Event bTerminal;
		Event nopTerminal;
		Event timerTerminal;
		Event stopInput;
		Event finished;
		shared EpollScheduler scheduler;
		shared ThreadID driver;
		shared int aValues;
		shared int bValues;
		shared int nopValues;
		shared int timerValues;
		shared int sequence;
		shared int aSequence;
		shared int bSequence;

		this() @trusted shared {
			foreach (event; [ &contextReady, &armed, &paused, &release, &aTerminal,
				&bTerminal, &nopTerminal, &timerTerminal, &stopInput, &finished ])
				(cast() *event).initialize(false, false);
		}
		void publish(EpollContext* value) @trusted shared {
			scheduler = cast(shared) value.scheduler;
			driver = thisThreadID;
			(cast() contextReady).setIfInitialized();
		}
		void waitContext() @trusted shared { (cast() contextReady).wait(); }
		void signalArmed() @trusted shared nothrow { (cast() armed).setIfInitialized(); }
		void waitArmed() @trusted shared { (cast() armed).wait(); }
		void waitPaused() @trusted shared { (cast() paused).wait(); }
		void releaseDriver() @trusted shared nothrow { (cast() release).setIfInitialized(); }
		void signalA() @trusted shared nothrow { (cast() aTerminal).setIfInitialized(); }
		void waitA() @trusted shared { (cast() aTerminal).wait(); }
		void signalB() @trusted shared nothrow { (cast() bTerminal).setIfInitialized(); }
		void waitB() @trusted shared { (cast() bTerminal).wait(); }
		void signalNop() @trusted shared nothrow { (cast() nopTerminal).setIfInitialized(); }
		void waitNop() @trusted shared { (cast() nopTerminal).wait(); }
		void signalTimer() @trusted shared nothrow { (cast() timerTerminal).setIfInitialized(); }
		void waitTimer() @trusted shared { (cast() timerTerminal).wait(); }
		void stop() @trusted shared nothrow { (cast() stopInput).setIfInitialized(); }
		void waitStop() @trusted shared { (cast() stopInput).wait(); }
		void signalFinished() @trusted shared nothrow { (cast() finished).setIfInitialized(); }
		void waitFinished() @trusted shared { (cast() finished).wait(); }
	}
	static struct ArmedReceiver {
		shared State state;
		void setValue(int value) @trusted nothrow {
			assert(value == 0);
			assert(thisThreadID == atomicLoad!(MemoryOrder.acq)(state.driver));
			state.signalArmed();
		}
		void setDone() @safe nothrow { assert(false, "arming fence was cancelled"); }
		void setError(Throwable) @safe nothrow { assert(false, "arming fence failed"); }
		shared(StopToken) getStopToken() @safe nothrow { return shared(StopToken).init; }
	}
	static struct ReceiveReceiver {
		shared State state;
		ubyte[] expected;
		bool isB;
		void setValue(ubyte[] value) @trusted nothrow {
			assert(value == expected);
			assert(thisThreadID == atomicLoad!(MemoryOrder.acq)(state.driver));
			auto order = atomicFetchAdd!(MemoryOrder.acq_rel)(state.sequence, 1) + 1;
			if (isB) {
				atomicFetchAdd!(MemoryOrder.acq_rel)(state.bValues, 1);
				atomicStore!(MemoryOrder.rel)(state.bSequence, order);
				state.signalB();
			} else {
				atomicFetchAdd!(MemoryOrder.acq_rel)(state.aValues, 1);
				atomicStore!(MemoryOrder.rel)(state.aSequence, order);
				state.signalA();
			}
		}
		void setDone() @safe nothrow { assert(false, "armed receive was cancelled"); }
		void setError(Throwable) @safe nothrow { assert(false, "armed receive failed"); }
		shared(StopToken) getStopToken() @safe nothrow { return shared(StopToken).init; }
	}
	static struct NopReceiver {
		shared State state;
		void setValue(int value) @trusted nothrow {
			assert(value == 0);
			assert(thisThreadID == atomicLoad!(MemoryOrder.acq)(state.driver));
			atomicFetchAdd!(MemoryOrder.acq_rel)(state.nopValues, 1);
			state.signalNop();
		}
		void setDone() @safe nothrow { assert(false, "queued nop was cancelled"); }
		void setError(Throwable) @safe nothrow { assert(false, "queued nop failed"); }
		shared(StopToken) getStopToken() @safe nothrow { return shared(StopToken).init; }
	}
	static struct TimerReceiver {
		shared State state;
		void setValue() @trusted {
			assert(thisThreadID == atomicLoad!(MemoryOrder.acq)(state.driver));
			atomicFetchAdd!(MemoryOrder.acq_rel)(state.timerValues, 1);
			state.signalTimer();
		}
		void setDone() @safe nothrow { assert(false, "expired timer was cancelled"); }
		void setError(Throwable) @safe nothrow { assert(false, "expired timer failed"); }
		shared(StopToken) getStopToken() @safe nothrow { return shared(StopToken).init; }
	}

	auto a = epollSocketPair();
	auto b = epollSocketPair();
	scope(exit) close(a[0]);
	scope(exit) close(a[1]);
	scope(exit) close(b[0]);
	scope(exit) close(b[1]);
	auto state = new shared State;
	auto quiescence = new shared EpollShutdownState;
	auto driver = new Thread({
		auto context = EpollContext.construct(8);
		context.pauseAfterEpollWait(&state.paused, &state.release);
		state.publish(&context);
		context.run(ThreadSender().letValue(() @trusted {
			state.waitStop();
			return just();
		})).syncWait.assumeOk;
		quiescence.record(context.quiescenceSnapshot());
		state.signalFinished();
	}).start();
	bool stopped;
	bool pauseActivated;
	scope(failure) if (pauseActivated) state.releaseDriver();
	scope(exit) if (!stopped) {
		if (pauseActivated) state.releaseDriver();
		state.stop();
		state.waitFinished();
		driver.join();
	}

	state.waitContext();
	ubyte[] aPayload = [91, 92, 93];
	ubyte[] bPayload = [101, 102, 103, 104];
	ubyte[16] aStorage;
	ubyte[16] bStorage;
	auto aReceive = (cast() state.scheduler).recv(cast(socket_t) a[0], aStorage)
		.connect(ReceiveReceiver(state, aPayload, false));
	auto bReceive = (cast() state.scheduler).recv(cast(socket_t) b[0], bStorage)
		.connect(ReceiveReceiver(state, bPayload, true));
	auto armed = (cast() state.scheduler).nop().connect(ArmedReceiver(state));
	aReceive.start();
	bReceive.start();
	armed.start();
	state.waitArmed();
	atomicLoad!(MemoryOrder.acq)(state.aValues).should == 0;
	atomicLoad!(MemoryOrder.acq)(state.bValues).should == 0;

	state.scheduler.activatePauseAfterEpollWait();
	pauseActivated = true;
	sendSocketBytes(b[1], bPayload).should == bPayload.length;
	state.waitPaused();
	sendSocketBytes(a[1], aPayload).should == aPayload.length;
	auto nop = (cast() state.scheduler).nop().connect(NopReceiver(state));
	auto timer = (cast() state.scheduler).scheduleAfter(0.msecs).connect(TimerReceiver(state));
	nop.start();
	timer.start();
	state.releaseDriver();
	state.waitB();
	state.waitA();
	state.waitNop();
	state.waitTimer();

	assert(atomicLoad!(MemoryOrder.acq)(state.bSequence)
		< atomicLoad!(MemoryOrder.acq)(state.aSequence));
	atomicLoad!(MemoryOrder.acq)(state.aValues).should == 1;
	atomicLoad!(MemoryOrder.acq)(state.bValues).should == 1;
	atomicLoad!(MemoryOrder.acq)(state.nopValues).should == 1;
	atomicLoad!(MemoryOrder.acq)(state.timerValues).should == 1;
	state.stop();
	state.waitFinished();
	driver.join();
	stopped = true;
	checkQuiescent(quiescence);
}

@("EpollScheduler cancellation wins before later readiness") @trusted
unittest {
	static struct Receiver {
		shared EpollReadinessCancelState state;
		shared(StopSource)* source;
		void setValue(ubyte[]) @safe nothrow { assert(false, "cancelled operation received data"); }
		void setDone() @trusted nothrow {
			assert(thisThreadID == atomicLoad!(MemoryOrder.acq)(state.driver));
			atomicFetchAdd!(MemoryOrder.acq_rel)(state.dones, 1);
			atomicFetchAdd!(MemoryOrder.acq_rel)(state.terminals, 1);
			state.signalTerminal();
		}
		void setError(Throwable) @safe nothrow { assert(false, "cancelled operation failed"); }
		shared(StopToken) getStopToken() @safe nothrow { return source.token; }
	}

	auto fds = epollSocketPair();
	scope(exit) close(fds[0]);
	scope(exit) close(fds[1]);
	auto state = new shared EpollReadinessCancelState;
	auto quiescence = new shared EpollShutdownState;
	shared source = StopSource();
	auto driver = new Thread({
		auto context = EpollContext.construct(8);
		state.publish(&context);
		context.run(ThreadSender().letValue(() @trusted {
			state.waitStop();
			return just();
		})).syncWait.assumeOk;
		quiescence.record(context.quiescenceSnapshot());
		state.signalFinished();
	}).start();
	bool stopped;
	scope(exit) if (!stopped) {
		state.stop();
		state.waitFinished();
		driver.join();
	}

	state.waitContext();
	ubyte[8] storage;
	auto operation = (cast() state.scheduler).recv(cast(socket_t) fds[0], storage)
		.connect(Receiver(state, &source));
	auto armed = (cast() state.scheduler).nop().connect(EpollReadinessCancelArmedReceiver(state));
	operation.start();
	armed.start();
	state.waitArmed();
	source.stop();
	state.waitTerminal();
	ubyte[] bytes = [63, 64];
	sendSocketBytes(fds[1], bytes).should == bytes.length;
	auto drained = (cast() state.scheduler).nop().connect(EpollReadinessCancelDrainedReceiver(state));
	drained.start();
	state.waitDrained();
	atomicLoad!(MemoryOrder.acq)(state.values).should == 0;
	atomicLoad!(MemoryOrder.acq)(state.dones).should == 1;
	atomicLoad!(MemoryOrder.acq)(state.errors).should == 0;
	atomicLoad!(MemoryOrder.acq)(state.terminals).should == 1;
	state.stop();
	state.waitFinished();
	driver.join();
	stopped = true;
	checkQuiescent(quiescence);
}

@("EpollScheduler.recv reports EOF as done") @trusted
unittest {
	auto fds = epollSocketPair();
	scope(exit) close(fds[0]);
	close(fds[1]);
	fds[1] = -1;
	ubyte[8] storage;
	auto context = EpollContext.construct(8);

	context.run(context.scheduler.recv(cast(socket_t) fds[0], storage))
		.syncWait().isCancelled.should == true;
}

@("EpollScheduler.recv reports invalid descriptor errors") @trusted
unittest {
	import std.exception : ErrnoException;

	ubyte[8] storage;
	auto context = EpollContext.construct(8);
	context.run(context.scheduler.recv(cast(socket_t) -1, storage))
		.syncWait().value.shouldThrowWithMessage!ErrnoException(
			"Receive failed (Bad file descriptor)");
}

@("EpollScheduler.ADD control failure is terminal once and leaves the registry reusable") @trusted
unittest {
	import core.stdc.errno : EIO;
	import std.exception : ErrnoException;

	final class State {
		EpollContext* context;
		int contextFd;
		int peer;
		ubyte[8] retryStorage;
		int controlErrors;
		int retryValues;
		int terminals;
		OperationalStateBase retryOperation;
	}
	static struct RetryReceiver {
		State state;
		void setValue(ubyte[] value) @trusted nothrow {
			ubyte[] expected = [71, 72];
			assert(value == expected);
			state.retryValues++;
			state.terminals++;
		}
		void setDone() @safe nothrow { assert(false, "retry read was cancelled"); }
		void setError(Throwable) @safe nothrow { assert(false, "retry read failed"); }
		shared(StopToken) getStopToken() @safe nothrow { return shared(StopToken).init; }
	}
	static struct FailedReceiver {
		State state;
		void setValue(ubyte[]) @safe nothrow { assert(false, "ADD failure read succeeded"); }
		void setDone() @safe nothrow { assert(false, "ADD failure read was cancelled"); }
		void setError(Throwable error) @trusted nothrow {
			auto control = cast(ErrnoException) error;
			assert(control !is null);
			assert(control.errno == EIO);
			assert(control.msg == "epoll_ctl failed (Input/output error)");
			state.controlErrors++;
			state.terminals++;
			ubyte[] bytes = [71, 72];
			assert(sendSocketBytes(state.peer, bytes) == bytes.length);
			state.retryOperation = state.context.scheduler.recv(cast(socket_t) state.contextFd,
				state.retryStorage).connectHeap(RetryReceiver(state));
			state.retryOperation.start();
		}
		shared(StopToken) getStopToken() @safe nothrow { return shared(StopToken).init; }
	}

	auto fds = epollSocketPair();
	scope(exit) close(fds[0]);
	scope(exit) close(fds[1]);
	ubyte[8] firstStorage;
	auto context = EpollContext.construct(8);
	auto state = new State;
	state.context = &context;
	state.contextFd = fds[0];
	state.peer = fds[1];
	auto first = context.scheduler.recv(cast(socket_t) fds[0], firstStorage)
		.connect(FailedReceiver(state));
	first.start();
	context.forceNextAddControlFailure(EIO);
	context.addControlFailureConsumed.should == false;
	context.run(context.scheduler.nop()).syncWait.assumeOk;

	state.controlErrors.should == 1;
	state.retryValues.should == 1;
	state.terminals.should == 2;
	context.addControlFailureConsumed.should == true;
	auto snapshot = context.quiescenceSnapshot();
	snapshot.closed.should == true;
	snapshot.reservations.should == 0;
	snapshot.requestsEmpty.should == true;
	snapshot.timersEmpty.should == true;
	snapshot.wheelTimers.should == 0;
	snapshot.activeRecords.should == 0;
	snapshot.readWaiters.should == 0;
	snapshot.writeWaiters.should == 0;
	snapshot.retirementEntries.should == 0;
	snapshot.live.should == 0;
}

@("EpollScheduler.MOD control failure preserves the opposite-direction waiter") @trusted
unittest {
	import core.stdc.errno : EIO;
	import std.exception : ErrnoException;

	final class State {
		int peer;
		int gatePeer;
		ubyte[] payload;
		int readControlErrors;
		int writeValues;
		int terminals;
	}
	static struct ReadReceiver {
		State state;
		void setValue(ubyte[]) @safe nothrow { assert(false, "MOD failure read succeeded"); }
		void setDone() @safe nothrow { assert(false, "MOD failure read was cancelled"); }
		void setError(Throwable error) @trusted nothrow {
			auto control = cast(ErrnoException) error;
			assert(control !is null);
			assert(control.errno == EIO);
			assert(control.msg == "epoll_ctl failed (Input/output error)");
			state.readControlErrors++;
			state.terminals++;
			drainSocketReceiveBuffer(state.peer);
		}
		shared(StopToken) getStopToken() @safe nothrow { return shared(StopToken).init; }
	}
	static struct WriteReceiver {
		State state;
		void setValue(int value) @trusted nothrow {
			assert(value == state.payload.length);
			state.writeValues++;
			state.terminals++;
			ubyte[] gate = [73];
			assert(sendSocketBytes(state.gatePeer, gate) == gate.length);
		}
		void setDone() @safe nothrow { assert(false, "incumbent write was cancelled"); }
		void setError(Throwable) @safe nothrow { assert(false, "incumbent write failed"); }
		shared(StopToken) getStopToken() @safe nothrow { return shared(StopToken).init; }
	}

	auto fds = epollSocketPair();
	auto gate = epollSocketPair();
	scope(exit) close(fds[0]);
	scope(exit) close(fds[1]);
	scope(exit) close(gate[0]);
	scope(exit) close(gate[1]);
	fillSocketSendBuffer(fds[0]);
	ubyte[8] readStorage;
	ubyte[8] gateStorage;
	auto state = new State;
	state.peer = fds[1];
	state.gatePeer = gate[1];
	state.payload = [81, 82, 83];
	auto context = EpollContext.construct(8);
	auto incumbent = context.scheduler.send(cast(socket_t) fds[0], state.payload)
		.connect(WriteReceiver(state));
	auto affected = context.scheduler.recv(cast(socket_t) fds[0], readStorage)
		.connect(ReadReceiver(state));
	incumbent.start();
	affected.start();
	context.forceNextModControlFailure(EIO);
	context.modControlFailureConsumed.should == false;
	auto gateValue = context.run(context.scheduler.recv(cast(socket_t) gate[0], gateStorage))
		.syncWait().value;
	ubyte[] expectedGate = [73];
	gateValue.should == expectedGate;

	state.readControlErrors.should == 1;
	state.writeValues.should == 1;
	state.terminals.should == 2;
	context.modControlFailureConsumed.should == true;
	auto snapshot = context.quiescenceSnapshot();
	snapshot.closed.should == true;
	snapshot.reservations.should == 0;
	snapshot.requestsEmpty.should == true;
	snapshot.timersEmpty.should == true;
	snapshot.wheelTimers.should == 0;
	snapshot.activeRecords.should == 0;
	snapshot.readWaiters.should == 0;
	snapshot.writeWaiters.should == 0;
	snapshot.retirementEntries.should == 0;
	snapshot.live.should == 0;
}

@("EpollScheduler.DEL control failure reports the affected terminal without leaking") @trusted
unittest {
	import core.stdc.errno : EIO;
	import std.exception : ErrnoException;

	static struct State {
		int controlErrors;
		int terminals;
		EpollContext.RegistryFixture failed;
	}
	static struct Receiver {
		State* state;
		void setValue(ubyte[]) @safe nothrow { assert(false, "DEL failure read succeeded"); }
		void setDone() @safe nothrow { assert(false, "DEL failure read was cancelled"); }
		void setError(Throwable error) @trusted nothrow {
			auto control = cast(ErrnoException) error;
			assert(control !is null);
			assert(control.errno == EIO);
			assert(control.msg == "epoll_ctl failed (Input/output error)");
			state.controlErrors++;
			state.terminals++;
		}
		shared(StopToken) getStopToken() @safe nothrow { return shared(StopToken).init; }
	}

	auto fds = epollSocketPair();
	scope(exit) close(fds[0]);
	scope(exit) close(fds[1]);
	ubyte[8] storage;
	State state;
	auto context = EpollContext.construct(8);
	auto operation = context.scheduler.recv(cast(socket_t) fds[0], storage)
		.connect(Receiver(&state));
	operation.start();
	context.run(context.scheduler.nop().letValue((int) @trusted {
		state.failed = context.registryFixture(fds[0]);
		context.forceNextDelControlFailure(EIO);
		context.delControlFailureConsumed.should == false;
		return just();
	})).syncWait.assumeOk;

	state.controlErrors.should == 1;
	state.terminals.should == 1;
	context.delControlFailureConsumed.should == true;
	context.dispatchSynthetic([state.failed.token]);
	state.controlErrors.should == 1;
	state.terminals.should == 1;
	auto replacement = context.fixtureSlot(97, 1);
	replacement.index.shouldNotEqual(state.failed.index);
	context.fixtureDetach(97);
	auto snapshot = context.quiescenceSnapshot();
	snapshot.closed.should == true;
	snapshot.reservations.should == 0;
	snapshot.requestsEmpty.should == true;
	snapshot.timersEmpty.should == true;
	snapshot.wheelTimers.should == 0;
	snapshot.activeRecords.should == 0;
	snapshot.readWaiters.should == 0;
	snapshot.writeWaiters.should == 0;
	snapshot.retirementEntries.should == 0;
	snapshot.live.should == 0;
}

@("EpollScheduler rejects blocking descriptors without stopping the loop") @trusted
unittest {
	static struct Receiver {
		int* errors;
		void setValue(ubyte[]) @safe nothrow { assert(false); }
		void setDone() @safe nothrow { assert(false); }
		void setError(Throwable error) @trusted nothrow { assert(error.msg == "epoll supports only nonblocking sockets and pipes"); (*errors)++; }
		shared(StopToken) getStopToken() @safe nothrow { return shared(StopToken).init; }
	}
	auto fds = epollSocketPair(false);
	scope(exit) close(fds[0]);
	scope(exit) close(fds[1]);
	ubyte[8] storage;
	auto context = EpollContext.construct(8);

	int errors;
	Receiver receiver = Receiver(&errors);
	auto operation = context.scheduler.recv(cast(socket_t) fds[0], storage).connect(receiver);
	operation.start();
	context.run(context.scheduler.nop()).syncWait().value.should == 0;
	errors.should == 1;
	auto snapshot = context.quiescenceSnapshot();
	snapshot.closed.should == true; snapshot.reservations.should == 0; snapshot.live.should == 0;
	snapshot.requestsEmpty.should == true; snapshot.timersEmpty.should == true; snapshot.wheelTimers.should == 0;
	snapshot.activeRecords.should == 0; snapshot.readWaiters.should == 0; snapshot.writeWaiters.should == 0; snapshot.retirementEntries.should == 0;
}

@("EpollScheduler caller-buffer invalid descriptors retain operation labels") @trusted
unittest {
	import core.stdc.errno : EBADF;
	import std.exception : ErrnoException;
	import std.algorithm.searching : startsWith;
	ubyte[8] storage;
	ubyte[] payload = [1];
	void check(alias operation)(string label) @trusted {
		auto context = EpollContext.construct(8);
		auto result = context.run(operation(context, storage[], payload)).syncWait();
		result.isError.should == true;
		auto error = cast(ErrnoException) result.get!Exception;
		assert(error !is null);
		error.errno.should == EBADF;
		assert(error.msg.startsWith(label));
	}
	check!((context, storage, payload) => context.scheduler.recv(cast(socket_t) -1, storage))("Receive failed");
	check!((context, storage, payload) => context.scheduler.read(cast(socket_t) -1, storage))("Read failed");
	check!((context, storage, payload) => context.scheduler.send(cast(socket_t) -1, payload))("Send failed");
	check!((context, storage, payload) => context.scheduler.write(cast(socket_t) -1, payload))("Write failed");
}

@("EpollScheduler caller-buffer closed descriptors retain operation labels") @trusted
unittest {
	import core.stdc.errno : EBADF;
	import core.sys.posix.fcntl : fcntl;
	import core.sys.posix.sys.resource : getrlimit, rlimit, rlim_t, RLIMIT_NOFILE, RLIM_INFINITY;
	import std.exception : ErrnoException;
	import std.algorithm.searching : startsWith;
	ubyte[8] storage;
	ubyte[] payload = [1];
	enum F_DUPFD_CLOEXEC = 1030;
	void check(alias operation)(string label) @trusted {
		auto context = EpollContext.construct(8);
		auto fds = epollSocketPair();
		scope(exit) if (fds[0] >= 0) close(fds[0]);
		rlimit limit;
		assert(getrlimit(RLIMIT_NOFILE, &limit) == 0);
		ulong ceiling;
		if (limit.rlim_cur == RLIM_INFINITY || limit.rlim_cur > cast(rlim_t) int.max)
			ceiling = cast(ulong) int.max;
		else ceiling = cast(ulong) limit.rlim_cur;
		assert(ceiling > 128, "closed-fd test requires descriptor headroom");
		auto minimumWide = ceiling - 64;
		assert(minimumWide <= cast(ulong) int.max);
		auto minimum = cast(int) minimumWide;
		assert(minimum >= 0);
		auto closedFd = fcntl(fds[0], F_DUPFD_CLOEXEC, minimum);
		assert(closedFd >= 0, "closed-fd test requires a high descriptor reservation");
		assert(closedFd >= minimum, "closed-fd test requires a high descriptor reservation");
		close(fds[0]);
		fds[0] = -1;
		scope(exit) close(fds[1]);
		close(closedFd);
		auto result = context.run(operation(context, cast(socket_t) closedFd, storage[], payload)).syncWait();
		result.isError.should == true;
		auto error = cast(ErrnoException) result.get!Exception;
		assert(error !is null);
		error.errno.should == EBADF;
		assert(error.msg.startsWith(label));
	}
	check!((context, fd, storage, payload) => context.scheduler.recv(fd, storage))("Receive failed");
	check!((context, fd, storage, payload) => context.scheduler.read(fd, storage))("Read failed");
	check!((context, fd, storage, payload) => context.scheduler.send(fd, payload))("Send failed");
	check!((context, fd, storage, payload) => context.scheduler.write(fd, payload))("Write failed");
}

@("EpollScheduler.recv reports unconnected TCP errors as receive failures") @trusted
unittest {
	import concurrency.io.socket : rawTCPSocket;
	import core.stdc.errno : ENOTCONN;
	import std.exception : ErrnoException;
	import std.algorithm.searching : startsWith;
	auto fd = rawTCPSocket();
	scope(exit) close(fd);
	ubyte[8] storage;
	auto context = EpollContext.construct(8);
	auto result = context.run(context.scheduler.recv(fd, storage)).syncWait();
	result.isError.should == true;
	auto error = cast(ErrnoException) result.get!Exception;
	assert(error !is null);
	error.errno.should == ENOTCONN;
	assert(error.msg.startsWith("Receive failed"));
}

@("EpollScheduler.pipe repeats empty-then-ready caller-buffer transfers") @trusted
unittest {
	import core.sys.posix.unistd : write;
	auto fds = epollPipePair();
	scope(exit) close(fds[0]);
	scope(exit) close(fds[1]);
	auto state = new shared EpollSocketTestState;
	auto quiescence = new shared EpollShutdownState;
	auto driver = new Thread({
		auto context = EpollContext.construct(8);
		state.publish(&context);
		context.run(ThreadSender().letValue(() @trusted { state.waitStop(); return just(); })).syncWait.assumeOk;
		quiescence.record(context.quiescenceSnapshot());
		state.signalFinished();
	}).start();
	bool stopped;
	scope(exit) if (!stopped) { state.stop(); state.waitFinished(); driver.join(); }
	state.waitContext();
	ubyte[] first = [101, 102, 103];
	ubyte[] second = [104, 105, 106, 107];
	ubyte[16] firstStorage;
	ubyte[16] secondStorage;
	auto firstRead = (cast() state.scheduler).read(cast(socket_t) fds[0], firstStorage)
		.connect(EpollSocketBufferReceiver(state, first, true));
	auto firstFence = (cast() state.scheduler).nop().connect(EpollSocketArmedReceiver(state));
	firstRead.start(); firstFence.start(); state.waitArmed();
	assert(write(fds[1], first.ptr, first.length) == first.length); state.waitFirstTerminal();
	auto secondRead = (cast() state.scheduler).read(cast(socket_t) fds[0], secondStorage)
		.connect(EpollSocketBufferReceiver(state, second, false));
	auto secondFence = (cast() state.scheduler).nop().connect(EpollSocketArmedReceiver(state));
	secondRead.start(); secondFence.start(); state.waitArmed();
	assert(write(fds[1], second.ptr, second.length) == second.length); state.waitSecondTerminal();
	atomicLoad!(MemoryOrder.acq)(state.terminals).should == 2;
	atomicLoad!(MemoryOrder.acq)(state.values).should == 2;
	atomicLoad!(MemoryOrder.acq)(state.dones).should == 0;
	atomicLoad!(MemoryOrder.acq)(state.errors).should == 0;
	state.stop(); state.waitFinished(); driver.join(); stopped = true;
	checkQuiescent(quiescence);
}

@("EpollScheduler.recv dispatches armed AF_UNIX RDHUP EOF after pause release") @trusted
unittest {
	import core.sys.posix.sys.socket : shutdown, SHUT_WR;
	static struct Receiver {
		shared EpollReadinessCancelState state;
		void setValue(ubyte[]) @safe nothrow { assert(false); }
		void setDone() @trusted nothrow { assert(thisThreadID == atomicLoad!(MemoryOrder.acq)(state.driver)); atomicFetchAdd!(MemoryOrder.acq_rel)(state.dones, 1); atomicFetchAdd!(MemoryOrder.acq_rel)(state.terminals, 1); state.signalTerminal(); }
		void setError(Throwable) @safe nothrow { assert(false); }
		shared(StopToken) getStopToken() @safe nothrow { return shared(StopToken).init; }
	}
	auto fds = epollSocketPair();
	scope(exit) close(fds[0]); scope(exit) close(fds[1]);
	auto state = new shared EpollReadinessCancelState; auto quiescence = new shared EpollShutdownState;
	auto driver = new Thread({ auto context = EpollContext.construct(8); context.pauseAfterEpollWait(&state.paused, &state.release); state.publish(&context); context.run(ThreadSender().letValue(() @trusted { state.waitStop(); return just(); })).syncWait.assumeOk; quiescence.record(context.quiescenceSnapshot()); state.signalFinished(); }).start();
	bool stopped;
	scope(exit) if (!stopped) { state.releaseDriver(); state.stop(); state.waitFinished(); driver.join(); }
	state.waitContext(); ubyte[8] storage;
	auto operation = (cast() state.scheduler).recv(cast(socket_t) fds[0], storage).connect(Receiver(state));
	auto fence = (cast() state.scheduler).nop().connect(EpollReadinessCancelArmedReceiver(state));
	operation.start(); fence.start(); state.waitArmed();
	state.scheduler.activatePauseAfterEpollWait(); assert(shutdown(fds[1], SHUT_WR) == 0); state.waitPaused();
	atomicLoad!(MemoryOrder.acq)(state.terminals).should == 0;
	state.releaseDriver(); state.waitTerminal();
	atomicLoad!(MemoryOrder.acq)(state.dones).should == 1; atomicLoad!(MemoryOrder.acq)(state.errors).should == 0; atomicLoad!(MemoryOrder.acq)(state.values).should == 0;
	state.stop(); state.waitFinished(); driver.join(); stopped = true; checkQuiescent(quiescence);
}

@("EpollScheduler.recv dispatches armed loopback TCP reset after pause release") @trusted
unittest {
	import core.stdc.errno : ECONNRESET;
	import core.sys.posix.sys.socket : setsockopt, linger, SOL_SOCKET, SO_LINGER;
	import std.exception : ErrnoException;
	import std.algorithm.searching : startsWith;
	static struct Receiver {
		shared EpollReadinessCancelState state;
		void setValue(ubyte[]) @safe nothrow { assert(false); }
		void setDone() @safe nothrow { assert(false); }
		void setError(Throwable value) @trusted nothrow {
			auto error = cast(ErrnoException) value; assert(error !is null);
			assert(error.errno == ECONNRESET); assert(error.msg.startsWith("Receive failed"));
			assert(thisThreadID == atomicLoad!(MemoryOrder.acq)(state.driver));
			atomicFetchAdd!(MemoryOrder.acq_rel)(state.errors, 1); atomicFetchAdd!(MemoryOrder.acq_rel)(state.terminals, 1); state.signalTerminal();
		}
		shared(StopToken) getStopToken() @safe nothrow { return shared(StopToken).init; }
	}
	auto fds = loopbackTcpPair();
	scope(exit) if (fds[0] >= 0) close(fds[0]); scope(exit) if (fds[1] >= 0) close(fds[1]);
	auto state = new shared EpollReadinessCancelState; auto quiescence = new shared EpollShutdownState;
	auto driver = new Thread({ auto context = EpollContext.construct(8); context.pauseAfterEpollWait(&state.paused, &state.release); state.publish(&context); context.run(ThreadSender().letValue(() @trusted { state.waitStop(); return just(); })).syncWait.assumeOk; quiescence.record(context.quiescenceSnapshot()); state.signalFinished(); }).start();
	bool stopped;
	scope(exit) if (!stopped) { state.releaseDriver(); state.stop(); state.waitFinished(); driver.join(); }
	state.waitContext(); ubyte[8] storage;
	auto operation = (cast() state.scheduler).recv(cast(socket_t) fds[0], storage).connect(Receiver(state));
	auto fence = (cast() state.scheduler).nop().connect(EpollReadinessCancelArmedReceiver(state));
	operation.start(); fence.start(); state.waitArmed();
	linger abortive; abortive.l_onoff = 1; abortive.l_linger = 0;
	assert(setsockopt(fds[1], SOL_SOCKET, SO_LINGER, &abortive, abortive.sizeof) == 0);
	state.scheduler.activatePauseAfterEpollWait(); close(fds[1]); fds[1] = -1; state.waitPaused();
	atomicLoad!(MemoryOrder.acq)(state.terminals).should == 0;
	state.releaseDriver(); state.waitTerminal();
	atomicLoad!(MemoryOrder.acq)(state.errors).should == 1; atomicLoad!(MemoryOrder.acq)(state.dones).should == 0; atomicLoad!(MemoryOrder.acq)(state.values).should == 0;
	state.stop(); state.waitFinished(); driver.join(); stopped = true; checkQuiescent(quiescence);
}

@("EpollScheduler rejects regular files without stopping the loop") @trusted
unittest {
	static struct Receiver {
		int* errors;
		void setValue(ubyte[]) @safe nothrow { assert(false); }
		void setDone() @safe nothrow { assert(false); }
		void setError(Throwable error) @trusted nothrow { assert(error.msg == "epoll supports only nonblocking sockets and pipes"); (*errors)++; }
		shared(StopToken) getStopToken() @safe nothrow { return shared(StopToken).init; }
	}
	auto fd = temporaryRegularFile();
	scope(exit) close(fd);
	ubyte[8] storage;
	auto context = EpollContext.construct(8);
	int errors;
	Receiver receiver = Receiver(&errors);
	auto operation = context.scheduler.read(cast(socket_t) fd, storage).connect(receiver);
	operation.start();
	context.run(context.scheduler.nop()).syncWait().value.should == 0;
	errors.should == 1;
	auto snapshot = context.quiescenceSnapshot();
	snapshot.closed.should == true; snapshot.reservations.should == 0; snapshot.live.should == 0;
	snapshot.requestsEmpty.should == true; snapshot.timersEmpty.should == true; snapshot.wheelTimers.should == 0;
	snapshot.activeRecords.should == 0; snapshot.readWaiters.should == 0; snapshot.writeWaiters.should == 0; snapshot.retirementEntries.should == 0;
}

@("EpollScheduler.recv stops before start before descriptor validation") @trusted
unittest {
	static struct Receiver {
		shared EpollReadinessCancelState state;
		shared(StopSource)* source;
		void setValue(ubyte[]) @safe nothrow { assert(false, "pre-stopped receive produced a value"); }
		void setDone() @trusted nothrow {
			assert(thisThreadID == atomicLoad!(MemoryOrder.acq)(state.driver));
			atomicFetchAdd!(MemoryOrder.acq_rel)(state.dones, 1);
			atomicFetchAdd!(MemoryOrder.acq_rel)(state.terminals, 1);
			state.signalTerminal();
		}
		void setError(Throwable) @safe nothrow { assert(false, "pre-stopped receive validated its descriptor"); }
		shared(StopToken) getStopToken() @safe nothrow { return source.token; }
	}
	auto state = new shared EpollReadinessCancelState;
	auto quiescence = new shared EpollShutdownState;
	shared source = StopSource();
	auto driver = new Thread({
		auto context = EpollContext.construct(8);
		state.publish(&context);
		context.run(ThreadSender().letValue(() @trusted { state.waitStop(); return just(); })).syncWait.assumeOk;
		quiescence.record(context.quiescenceSnapshot());
		state.signalFinished();
	}).start();
	bool stopped;
	scope(exit) if (!stopped) { state.stop(); state.waitFinished(); driver.join(); }
	state.waitContext();
	ubyte[8] storage;
	source.stop();
	auto operation = (cast() state.scheduler).recv(cast(socket_t) -1, storage).connect(Receiver(state, &source));
	operation.start(); state.waitTerminal(); source.assertNoCallbacks();
	auto drained = (cast() state.scheduler).nop().connect(EpollReadinessCancelDrainedReceiver(state));
	drained.start(); state.waitDrained();
	atomicLoad!(MemoryOrder.acq)(state.values).should == 0;
	atomicLoad!(MemoryOrder.acq)(state.dones).should == 1;
	atomicLoad!(MemoryOrder.acq)(state.errors).should == 0;
	atomicLoad!(MemoryOrder.acq)(state.terminals).should == 1;
	state.stop(); state.waitFinished(); driver.join(); stopped = true;
	checkQuiescent(quiescence);
}

@("EpollScheduler.send cancels while armed without peer drain") @trusted
unittest {
	static struct Receiver {
		shared EpollReadinessCancelState state;
		shared(StopSource)* source;
		void setValue(int) @safe nothrow { assert(false, "cancelled send produced a value"); }
		void setDone() @trusted nothrow {
			assert(thisThreadID == atomicLoad!(MemoryOrder.acq)(state.driver));
			atomicFetchAdd!(MemoryOrder.acq_rel)(state.dones, 1);
			atomicFetchAdd!(MemoryOrder.acq_rel)(state.terminals, 1);
			state.signalTerminal();
		}
		void setError(Throwable) @safe nothrow { assert(false, "cancelled send failed"); }
		shared(StopToken) getStopToken() @safe nothrow { return source.token; }
	}
	auto fds = epollSocketPair();
	scope(exit) close(fds[0]); scope(exit) close(fds[1]);
	assert(fillSocketSendBufferCounted(fds[0]) > 0);
	auto state = new shared EpollReadinessCancelState;
	auto quiescence = new shared EpollShutdownState;
	shared source = StopSource();
	auto driver = new Thread({
		auto context = EpollContext.construct(8);
		state.publish(&context);
		context.run(ThreadSender().letValue(() @trusted { state.waitStop(); return just(); })).syncWait.assumeOk;
		quiescence.record(context.quiescenceSnapshot());
		state.signalFinished();
	}).start();
	bool stopped;
	scope(exit) if (!stopped) { state.stop(); state.waitFinished(); driver.join(); }
	state.waitContext();
	ubyte[] bytes = [201, 202, 203];
	auto operation = (cast() state.scheduler).send(cast(socket_t) fds[0], bytes).connect(Receiver(state, &source));
	auto fence = (cast() state.scheduler).nop().connect(EpollReadinessCancelArmedReceiver(state));
	operation.start(); fence.start(); state.waitArmed();
	atomicLoad!(MemoryOrder.acq)(state.terminals).should == 0;
	source.stop(); state.waitTerminal(); source.assertNoCallbacks();
	auto drained = (cast() state.scheduler).nop().connect(EpollReadinessCancelDrainedReceiver(state));
	drained.start(); state.waitDrained();
	atomicLoad!(MemoryOrder.acq)(state.values).should == 0;
	atomicLoad!(MemoryOrder.acq)(state.dones).should == 1;
	atomicLoad!(MemoryOrder.acq)(state.errors).should == 0;
	atomicLoad!(MemoryOrder.acq)(state.terminals).should == 1;
	state.stop(); state.waitFinished(); driver.join(); stopped = true;
	checkQuiescent(quiescence);
}

@("EpollScheduler bufferless recv cancellation returns its armed slot") @trusted
unittest {
	static struct CancelReceiver {
		shared EpollReadinessCancelState state; shared(StopSource)* source;
		void setValue(ref ManagedBuffer) @safe nothrow { assert(false); }
		void setDone() @trusted nothrow { assert(thisThreadID == atomicLoad!(MemoryOrder.acq)(state.driver)); atomicFetchAdd!(MemoryOrder.acq_rel)(state.dones, 1); atomicFetchAdd!(MemoryOrder.acq_rel)(state.terminals, 1); state.signalTerminal(); }
		void setError(Throwable) @safe nothrow { assert(false); }
		shared(StopToken) getStopToken() @safe nothrow { return source.token; }
	}
	static struct ValueReceiver {
		shared EpollReadinessCancelState state; shared(Event)* terminal;
		void setValue(ref ManagedBuffer buffer) @trusted nothrow { ubyte[] expected = [91, 92, 93]; assert(buffer.view.data == expected); assert(buffer.capacity == 4096); buffer.releaseNow(); atomicFetchAdd!(MemoryOrder.acq_rel)(state.values, 1); (cast(Event*) terminal).setIfInitialized(); }
		void setDone() @safe nothrow { assert(false); }
		void setError(Throwable) @safe nothrow { assert(false); }
		shared(StopToken) getStopToken() @safe nothrow { return shared(StopToken).init; }
	}
	auto fds = epollSocketPair();
	scope(exit) close(fds[0]); scope(exit) close(fds[1]);
	auto state = new shared EpollReadinessCancelState; auto quiescence = new shared EpollShutdownState;
	shared source = StopSource();
	auto driver = new Thread({ auto context = EpollContext.construct(1); state.publish(&context); context.run(ThreadSender().letValue(() @trusted { state.waitStop(); return just(); })).syncWait.assumeOk; quiescence.record(context.quiescenceSnapshot()); state.signalFinished(); }).start();
	bool stopped;
	scope(exit) if (!stopped) { state.stop(); state.waitFinished(); driver.join(); }
	state.waitContext();
	auto first = (cast() state.scheduler).recv(cast(socket_t) fds[0], 0).connect(CancelReceiver(state, &source));
	auto fence = (cast() state.scheduler).nop().connect(EpollReadinessCancelArmedReceiver(state));
	first.start(); fence.start(); state.waitArmed();
	source.stop(); state.waitTerminal(); source.assertNoCallbacks();
	atomicLoad!(MemoryOrder.acq)(state.dones).should == 1;
	shared Event secondTerminal; (cast(Event*) &secondTerminal).initialize(false, false);
	ubyte[] payload = [91, 92, 93]; assert(sendSocketBytes(fds[1], payload) == payload.length);
	auto second = (cast() state.scheduler).recv(cast(socket_t) fds[0], 0).connect(ValueReceiver(state, &secondTerminal));
	second.start(); (cast(Event*) &secondTerminal).wait();
	atomicLoad!(MemoryOrder.acq)(state.values).should == 1;
	state.stop(); state.waitFinished(); driver.join(); stopped = true;
	checkQuiescent(quiescence);
}

@("EpollScheduler.shutdown cancels simultaneously armed read and write") @trusted
unittest {
	final class State {
		Event contextReady, armed, stopInput, readTerminal, writeTerminal, finished;
		shared EpollScheduler scheduler;
		shared ThreadID driver;
		shared int readValues, readDones, readErrors, readTerminals;
		shared int writeValues, writeDones, writeErrors, writeTerminals;
		this() @trusted shared { foreach (event; [&contextReady, &armed, &stopInput, &readTerminal, &writeTerminal, &finished]) (cast() *event).initialize(false, false); }
		void publish(EpollContext* context) @trusted shared { scheduler = cast(shared) context.scheduler; driver = thisThreadID; (cast() contextReady).setIfInitialized(); }
		void waitContext() @trusted shared { (cast() contextReady).wait(); }
		void signalArmed() @trusted shared nothrow { (cast() armed).setIfInitialized(); }
		void waitArmed() @trusted shared { (cast() armed).wait(); }
		void stop() @trusted shared nothrow { (cast() stopInput).setIfInitialized(); }
		void waitStop() @trusted shared { (cast() stopInput).wait(); }
		void signalRead() @trusted shared nothrow { (cast() readTerminal).setIfInitialized(); }
		void waitRead() @trusted shared { (cast() readTerminal).wait(); }
		void signalWrite() @trusted shared nothrow { (cast() writeTerminal).setIfInitialized(); }
		void waitWrite() @trusted shared { (cast() writeTerminal).wait(); }
		void signalFinished() @trusted shared nothrow { (cast() finished).setIfInitialized(); }
		void waitFinished() @trusted shared { (cast() finished).wait(); }
	}
	static struct ReadReceiver {
		shared State state;
		void setValue(ubyte[]) @safe nothrow { assert(false, "shutdown read produced a value"); }
		void setDone() @trusted nothrow { assert(thisThreadID == atomicLoad!(MemoryOrder.acq)(state.driver)); atomicFetchAdd!(MemoryOrder.acq_rel)(state.readDones, 1); atomicFetchAdd!(MemoryOrder.acq_rel)(state.readTerminals, 1); state.signalRead(); }
		void setError(Throwable) @safe nothrow { assert(false, "shutdown read failed"); }
		shared(StopToken) getStopToken() @safe nothrow { return shared(StopToken).init; }
	}
	static struct WriteReceiver {
		shared State state;
		void setValue(int) @safe nothrow { assert(false, "shutdown write produced a value"); }
		void setDone() @trusted nothrow { assert(thisThreadID == atomicLoad!(MemoryOrder.acq)(state.driver)); atomicFetchAdd!(MemoryOrder.acq_rel)(state.writeDones, 1); atomicFetchAdd!(MemoryOrder.acq_rel)(state.writeTerminals, 1); state.signalWrite(); }
		void setError(Throwable) @safe nothrow { assert(false, "shutdown write failed"); }
		shared(StopToken) getStopToken() @safe nothrow { return shared(StopToken).init; }
	}
	static struct FenceReceiver {
		shared State state;
		void setValue(int value) @trusted nothrow { assert(value == 0); assert(thisThreadID == atomicLoad!(MemoryOrder.acq)(state.driver)); state.signalArmed(); }
		void setDone() @safe nothrow { assert(false); }
		void setError(Throwable) @safe nothrow { assert(false); }
		shared(StopToken) getStopToken() @safe nothrow { return shared(StopToken).init; }
	}
	auto fds = epollSocketPair();
	scope(exit) close(fds[0]); scope(exit) close(fds[1]);
	assert(fillSocketSendBufferCounted(fds[0]) > 0);
	auto state = new shared State;
	auto quiescence = new shared EpollShutdownState;
	auto driver = new Thread({
		auto context = EpollContext.construct(8);
		state.publish(&context);
		context.run(ThreadSender().letValue(() @trusted { state.waitStop(); return just(); })).syncWait.assumeOk;
		quiescence.record(context.quiescenceSnapshot());
		state.signalFinished();
	}).start();
	state.waitContext();
	ubyte[8] storage;
	ubyte[] bytes = [211, 212, 213];
	auto read = (cast() state.scheduler).read(cast(socket_t) fds[0], storage).connect(ReadReceiver(state));
	auto write = (cast() state.scheduler).write(cast(socket_t) fds[0], bytes).connect(WriteReceiver(state));
	auto fence = (cast() state.scheduler).nop().connect(FenceReceiver(state));
	read.start(); write.start(); fence.start(); state.waitArmed();
	state.stop(); state.waitRead(); state.waitWrite(); state.waitFinished(); driver.join();
	atomicLoad!(MemoryOrder.acq)(state.readValues).should == 0;
	atomicLoad!(MemoryOrder.acq)(state.readDones).should == 1;
	atomicLoad!(MemoryOrder.acq)(state.readErrors).should == 0;
	atomicLoad!(MemoryOrder.acq)(state.readTerminals).should == 1;
	atomicLoad!(MemoryOrder.acq)(state.writeValues).should == 0;
	atomicLoad!(MemoryOrder.acq)(state.writeDones).should == 1;
	atomicLoad!(MemoryOrder.acq)(state.writeErrors).should == 0;
	atomicLoad!(MemoryOrder.acq)(state.writeTerminals).should == 1;
	checkQuiescent(quiescence);
}

@("EpollScheduler.accept/connect returns a nonblocking close-on-exec client") @trusted
unittest {
	import concurrency.io.socket : listenTcp, tcpSocket, getPort;
	import core.sys.posix.fcntl : fcntl, F_GETFL, F_GETFD, O_NONBLOCK, FD_CLOEXEC;

	auto listener = listenTcp("127.0.0.1", 0);
	auto client = tcpSocket();
	auto context = EpollContext.construct(8);

	context.run(whenAll(
		acceptAsync(listener).letValue((ref Client accepted) @trusted {
			auto fd = accepted.socket.release();
			scope(exit) close(fd);
			assert((fcntl(fd, F_GETFL) & O_NONBLOCK) != 0);
			assert((fcntl(fd, F_GETFD) & FD_CLOEXEC) != 0);
			return just();
		}),
		connectAsync(client, "127.0.0.1", listener.getPort()),
	)).syncWait().assumeOk;
}

@("EpollScheduler.connect reports loopback refusal from SO_ERROR") @trusted
unittest {
	import concurrency.io.socket : listenTcp, tcpSocket, getPort;
	import std.exception : ErrnoException;

	ushort port;
	{
		auto listener = listenTcp("127.0.0.1", 0);
		port = listener.getPort();
	}
	auto client = tcpSocket();
	auto context = EpollContext.construct(8);
	auto result = context.run(connectAsync(client, "127.0.0.1", port)).syncWait();
	result.isError.should == true;
	auto error = cast(ErrnoException) result.get!Exception;
	assert(error !is null);
	import std.algorithm.searching : startsWith;
	assert(error.msg.startsWith("Connect failed"));
}

@("EpollScheduler managed recv uses one 4096-byte slot and returns it after release") @trusted
unittest {
	final class State { EpollContext* context; int fd; int peer; int completions; OperationalStateBase nextOperation; }
	static struct SecondReceiver {
		State state;
		void setValue(ref ManagedBuffer buffer) @trusted nothrow { ubyte[] expected = [44, 45]; assert(buffer.view.data == expected); assert(buffer.length == expected.length); assert(buffer.capacity == 4096); buffer.releaseNow(); state.completions++; }
		void setDone() @safe nothrow { assert(false); }
		void setError(Throwable) @safe nothrow { assert(false); }
		shared(StopToken) getStopToken() @safe nothrow { return shared(StopToken).init; }
	}
	static struct FirstReceiver {
		State state;
		void setValue(ref ManagedBuffer buffer) @trusted nothrow { ubyte[] expected = [41, 42, 43]; assert(buffer.view.data == expected); assert(buffer.length == expected.length); assert(buffer.capacity == 4096); buffer.releaseNow(); state.completions++; assert(sendSocketBytes(state.peer, [44, 45]) == 2); state.nextOperation = state.context.scheduler.recv(cast(socket_t) state.fd, 2).connectHeap(SecondReceiver(state)); state.nextOperation.start(); }
		void setDone() @safe nothrow { assert(false); }
		void setError(Throwable) @safe nothrow { assert(false); }
		shared(StopToken) getStopToken() @safe nothrow { return shared(StopToken).init; }
	}
	auto fds = epollSocketPair();
	scope(exit) close(fds[0]);
	scope(exit) close(fds[1]);
	auto context = EpollContext.construct(1);
	auto state = new State; state.context = &context; state.fd = fds[0]; state.peer = fds[1];
	assert(sendSocketBytes(fds[1], [41, 42, 43]) == 3);
	auto first = context.scheduler.recv(cast(socket_t) fds[0], 0).connect(FirstReceiver(state));
	first.start();
	context.run(context.scheduler.nop()).syncWait().assumeOk;
	state.completions.should == 2;
}

@("EpollScheduler managed recv rejects oversized requests before pool exhaustion") @trusted
unittest {
	static struct Receiver {
		Exception* error;
		void setValue(ref ManagedBuffer) @safe nothrow { assert(false); }
		void setDone() @safe nothrow { assert(false); }
		void setError(Throwable value) @trusted nothrow { *error = cast(Exception) value; }
		shared(StopToken) getStopToken() @safe nothrow { return shared(StopToken).init; }
	}
	auto fds = epollSocketPair();
	scope(exit) close(fds[0]);
	scope(exit) close(fds[1]);
	auto context = EpollContext.construct(1);
	Exception error;
	auto operation = context.scheduler.recv(cast(socket_t) fds[0], 4097).connect(Receiver(&error));
	operation.start();
	context.run(context.scheduler.nop()).syncWait().assumeOk;
	assert(error !is null);
	error.msg.should == "epoll managed buffer request exceeds 4096-byte slot";
}

@("Socket.release transfers closeAsync ownership without a destructor close") @trusted
unittest {
	import concurrency.io.socket : tcpSocket;
	import core.stdc.errno : errno, EBADF;
	import core.sys.posix.fcntl : fcntl, F_GETFD;

	auto socket = tcpSocket();
	auto fd = socket.release();
	assert(fcntl(fd, F_GETFD) >= 0);
	auto context = EpollContext.construct(8);
	context.run(context.scheduler.close(fd)).syncWait().assumeOk;
	assert(fcntl(fd, F_GETFD) == -1);
	errno.should == EBADF;
}

@("EpollScheduler.close cancels armed directions and removes the descriptor") @trusted
unittest {
	static struct ReadReceiver {
		int* dones;
		void setValue(ubyte[]) @safe nothrow { assert(false); }
		void setDone() @trusted nothrow { (*dones)++; }
		void setError(Throwable) @safe nothrow { assert(false); }
		shared(StopToken) getStopToken() @safe nothrow { return shared(StopToken).init; }
	}
	static struct WriteReceiver {
		int* dones;
		void setValue(int) @safe nothrow { assert(false); }
		void setDone() @trusted nothrow { (*dones)++; }
		void setError(Throwable) @safe nothrow { assert(false); }
		shared(StopToken) getStopToken() @safe nothrow { return shared(StopToken).init; }
	}
	static struct CloseReceiver {
		int* values;
		void setValue() @trusted nothrow { (*values)++; }
		void setDone() @safe nothrow { assert(false); }
		void setError(Throwable) @safe nothrow { assert(false); }
		shared(StopToken) getStopToken() @safe nothrow { return shared(StopToken).init; }
	}
	auto fds = epollSocketPair();
	scope(exit) close(fds[1]);
	assert(fillSocketSendBufferCounted(fds[0]) > 0);
	auto context = EpollContext.construct(8);
	int readDones, writeDones, closes;
	ubyte[8] readStorage;
	ubyte[] writeStorage = [1, 2, 3];
	auto read = context.scheduler.read(cast(socket_t) fds[0], readStorage).connect(ReadReceiver(&readDones));
	auto write = context.scheduler.write(cast(socket_t) fds[0], writeStorage).connect(WriteReceiver(&writeDones));
	auto closeOperation = context.scheduler.close(cast(socket_t) fds[0]).connect(CloseReceiver(&closes));
	read.start(); write.start(); closeOperation.start();
	context.run(just()).syncWait().assumeOk;
	readDones.should == 1;
	writeDones.should == 1;
	closes.should == 1;
	import core.stdc.errno : errno, EBADF;
	import core.sys.posix.fcntl : fcntl, F_GETFD;
	assert(fcntl(fds[0], F_GETFD) == -1);
	errno.should == EBADF;
	auto snapshot = context.quiescenceSnapshot();
	snapshot.activeRecords.should == 0;
	snapshot.readWaiters.should == 0;
	snapshot.writeWaiters.should == 0;
	snapshot.retirementEntries.should == 0;
}

@("EpollScheduler.close does not retry an interrupted close") @trusted
unittest {
	import core.stdc.errno : EINTR;
	static struct Receiver {
		int* errors;
		void setValue() @safe nothrow { assert(false); }
		void setDone() @safe nothrow { assert(false); }
		void setError(Throwable error) @trusted nothrow { assert(error.msg[0 .. "Close failed".length] == "Close failed"); (*errors)++; }
		shared(StopToken) getStopToken() @safe nothrow { return shared(StopToken).init; }
	}
	auto fds = epollSocketPair();
	scope(exit) close(fds[0]);
	scope(exit) close(fds[1]);
	auto context = EpollContext.construct(8);
	context.forceCloseError(EINTR);
	int errors;
	auto operation = context.scheduler.close(cast(socket_t) fds[0]).connect(Receiver(&errors));
	operation.start();
	context.run(just()).syncWait().assumeOk;
	errors.should == 1;
	context.closeCallCount.should == 1;
}

@("EpollScheduler.close rejects a preserved token after numeric fd reuse") @trusted
unittest {
	import core.sys.posix.unistd : dup2;
	final class State {
		EpollContext* context; int fd; int peer; ulong oldToken; Event finished;
		int values, dones, errors, closes;
		OperationalStateBase closeOperation;
		OperationalStateBase nextOperation;
		this() @trusted { finished.initialize(false, false); }
	}
	static struct NewReceiver {
		State state;
		void setValue(ubyte[] value) @trusted nothrow { ubyte[] expected = [121, 122]; assert(value == expected); state.values++; state.finished.setIfInitialized(); }
		void setDone() @trusted nothrow { state.dones++; state.finished.setIfInitialized(); }
		void setError(Throwable) @trusted nothrow { state.errors++; state.finished.setIfInitialized(); }
		shared(StopToken) getStopToken() @safe nothrow { return shared(StopToken).init; }
	}
	static struct CloseReceiver {
		State state;
		void setValue() @trusted {
			state.closes++;
			auto replacement = epollSocketPair();
			if (replacement[0] != state.fd) { assert(dup2(replacement[0], state.fd) == state.fd); close(replacement[0]); }
			close(state.peer); state.peer = replacement[1];
			state.nextOperation = state.context.scheduler.recv(cast(socket_t) state.fd,
				new ubyte[8]).connectHeap(NewReceiver(state));
			state.nextOperation.start();
			state.context.dispatchSynthetic([state.oldToken]);
			assert(state.values == 0 && state.dones == 0 && state.errors == 0);
			ubyte[] payload = [121, 122]; assert(sendSocketBytes(state.peer, payload) == payload.length);
		}
		void setDone() @safe nothrow { assert(false); }
		void setError(Throwable) @safe nothrow { assert(false); }
		shared(StopToken) getStopToken() @safe nothrow { return shared(StopToken).init; }
	}
	static struct FenceReceiver {
		State state;
		void setValue(int) @trusted { state.oldToken = state.context.registryFixture(state.fd).token; state.closeOperation = state.context.scheduler.close(cast(socket_t) state.fd).connectHeap(CloseReceiver(state)); state.closeOperation.start(); }
		void setDone() @safe nothrow { assert(false); }
		void setError(Throwable) @safe nothrow { assert(false); }
		shared(StopToken) getStopToken() @safe nothrow { return shared(StopToken).init; }
	}
	static struct OldReceiver {
		void setValue(ubyte[]) @safe nothrow { assert(false); }
		void setDone() @safe nothrow {}
		void setError(Throwable) @safe nothrow { assert(false); }
		shared(StopToken) getStopToken() @safe nothrow { return shared(StopToken).init; }
	}
	auto fds = epollSocketPair();
	auto context = EpollContext.construct(8); auto state = new State;
	state.context = &context; state.fd = fds[0]; state.peer = fds[1];
	scope(exit) close(state.fd); scope(exit) close(state.peer);
	auto old = context.scheduler.recv(cast(socket_t) state.fd, new ubyte[8]).connect(OldReceiver());
	auto fence = context.scheduler.nop().connect(FenceReceiver(state));
	old.start(); fence.start();
	context.run(ThreadSender().letValue(() @trusted { state.finished.wait(); return just(); })).syncWait().assumeOk;
	state.closes.should == 1; state.values.should == 1; state.dones.should == 0; state.errors.should == 0;
	auto snapshot = context.quiescenceSnapshot(); snapshot.activeRecords.should == 0; snapshot.readWaiters.should == 0; snapshot.writeWaiters.should == 0; snapshot.retirementEntries.should == 0;
}

@("EpollContext managed pool fixture exhausts and returns slots once") @trusted
unittest {
	auto context = EpollContext.construct(1);
	context.fixtureFreeBuffers.should == 1;
	auto buffer = context.fixtureManagedBuffer();
	context.fixtureFreeBuffers.should == 0;
	buffer.capacity.should == 4096;
	buffer.releaseNow();
	context.fixtureFreeBuffers.should == 1;
	buffer.releaseNow();
	context.fixtureFreeBuffers.should == 1;
	foreach (_; 0 .. 4) {
		auto next = context.fixtureManagedBuffer();
		context.fixtureFreeBuffers.should == 0;
		next.releaseNow();
		context.fixtureFreeBuffers.should == 1;
	}
}

@("EpollContext managed pool release survives context facade and foreign thread") @trusted
unittest {
	ManagedBuffer* escaped;
	{
		import core.lifetime : moveEmplace;
		auto context = EpollContext.construct(1);
		escaped = new ManagedBuffer;
		auto buffer = context.fixtureManagedBuffer();
		moveEmplace(buffer, *escaped);
		assert(escaped.isValid);
	}
	auto releaser = new Thread({ (*escaped).releaseNow(); });
	releaser.start();
	releaser.join();
	assert(!escaped.isValid);
}

@("EpollScheduler received managed buffer survives its context facade") @trusted
unittest {
	import core.lifetime : moveEmplace;
	final class State { ManagedBuffer* buffer; int values; }
	static struct Receiver {
		State state;
		void setValue(ref ManagedBuffer buffer) @trusted nothrow { moveEmplace(buffer, *state.buffer); state.values++; }
		void setDone() @safe nothrow { assert(false); }
		void setError(Throwable) @safe nothrow { assert(false); }
		shared(StopToken) getStopToken() @safe nothrow { return shared(StopToken).init; }
	}
	auto fds = epollSocketPair();
	scope(exit) close(fds[0]); scope(exit) close(fds[1]);
	ubyte[] payload = [61, 62, 63]; assert(sendSocketBytes(fds[1], payload) == payload.length);
	auto state = new State; state.buffer = new ManagedBuffer;
	{
		auto context = EpollContext.construct(1);
		auto operation = context.scheduler.recv(cast(socket_t) fds[0], 0).connect(Receiver(state));
		operation.start(); context.run(just()).syncWait().assumeOk;
	}
	state.values.should == 1; (*state.buffer).view.data.should == payload; (*state.buffer).capacity.should == 4096;
	auto releaser = new Thread({ (*state.buffer).releaseNow(); }); releaser.start(); releaser.join();
	assert(!state.buffer.isValid);
}

@("EpollScheduler received managed buffer returns once from a foreign thread") @trusted
unittest {
	import core.lifetime : moveEmplace;
	final class State { EpollContext* context; int fd; int peer; ManagedBuffer* first; Event finished; Thread releaser; shared int released; int firstValues; int secondValues; OperationalStateBase secondOperation; this() @trusted { finished.initialize(false, false); } }
	static struct SecondReceiver {
		State state;
		void setValue(ref ManagedBuffer buffer) @trusted nothrow { ubyte[] expected = [71, 72]; assert(buffer.view.data == expected); assert(buffer.capacity == 4096); state.secondValues++; buffer.releaseNow(); state.finished.setIfInitialized(); }
		void setDone() @safe nothrow { assert(false); }
		void setError(Throwable) @safe nothrow { assert(false); }
		shared(StopToken) getStopToken() @safe nothrow { return shared(StopToken).init; }
	}
	static struct FirstReceiver {
		State state;
		void setValue(ref ManagedBuffer buffer) @trusted nothrow {
			moveEmplace(buffer, *state.first); state.firstValues++;
			state.releaser = new Thread({ (*state.first).releaseNow(); atomicStore!(MemoryOrder.rel)(state.released, 1); }); state.releaser.start();
			while (atomicLoad!(MemoryOrder.acq)(state.released) == 0) {}
			assert(state.context.fixtureFreeBuffers == 1);
			(*state.first).releaseNow(); assert(state.context.fixtureFreeBuffers == 1);
			ubyte[] payload = [71, 72]; assert(sendSocketBytes(state.peer, payload) == payload.length);
			state.secondOperation = state.context.scheduler.recv(cast(socket_t) state.fd,
				0).connectHeap(SecondReceiver(state));
			state.secondOperation.start();
		}
		void setDone() @safe nothrow { assert(false); }
		void setError(Throwable) @safe nothrow { assert(false); }
		shared(StopToken) getStopToken() @safe nothrow { return shared(StopToken).init; }
	}
	auto fds = epollSocketPair();
	scope(exit) close(fds[0]); scope(exit) close(fds[1]);
	auto state = new State; state.first = new ManagedBuffer;
	auto context = EpollContext.construct(1);
	state.context = &context; state.fd = fds[0]; state.peer = fds[1];
	ubyte[] firstPayload = [64, 65]; assert(sendSocketBytes(fds[1], firstPayload) == firstPayload.length);
	auto first = context.scheduler.recv(cast(socket_t) fds[0], 0).connect(FirstReceiver(state));
	first.start(); context.run(ThreadSender().letValue(() @trusted { state.finished.wait(); return just(); })).syncWait().assumeOk;
	state.releaser.join();
	state.firstValues.should == 1;
	state.secondValues.should == 1; context.fixtureFreeBuffers.should == 1;
}

@("EpollScheduler managed recv receives an exact full slot") @trusted
unittest {
	static struct Receiver {
		int* values;
		void setValue(ref ManagedBuffer buffer) @trusted nothrow {
			assert(buffer.length == 4096);
			assert(buffer.capacity == 4096);
			foreach (value; buffer.view.data) assert(value == 77);
			buffer.releaseNow();
			(*values)++;
		}
		void setDone() @safe nothrow { assert(false); }
		void setError(Throwable) @safe nothrow { assert(false); }
		shared(StopToken) getStopToken() @safe nothrow { return shared(StopToken).init; }
	}
	auto fds = epollSocketPair();
	scope(exit) close(fds[0]);
	scope(exit) close(fds[1]);
	ubyte[] payload; payload.length = 4096; payload[] = 77;
	assert(sendSocketBytes(fds[1], payload) == payload.length);
	auto context = EpollContext.construct(1);
	int values;
	auto operation = context.scheduler.recv(cast(socket_t) fds[0], 4096).connect(Receiver(&values));
	operation.start();
	context.run(just()).syncWait().assumeOk;
	values.should == 1;
	context.fixtureFreeBuffers.should == 1;
}

@("EpollScheduler managed recv returns its slot after EOF and recv error") @trusted
unittest {
	static struct DoneReceiver {
		int* dones;
		void setValue(ref ManagedBuffer) @safe nothrow { assert(false); }
		void setDone() @trusted nothrow { (*dones)++; }
		void setError(Throwable) @safe nothrow { assert(false); }
		shared(StopToken) getStopToken() @safe nothrow { return shared(StopToken).init; }
	}
	static struct ErrorReceiver {
		int* errors;
		void setValue(ref ManagedBuffer) @safe nothrow { assert(false); }
		void setDone() @safe nothrow { assert(false); }
		void setError(Throwable error) @trusted nothrow { assert(error.msg[0 .. "Receive failed".length] == "Receive failed"); (*errors)++; }
		shared(StopToken) getStopToken() @safe nothrow { return shared(StopToken).init; }
	}
	{
		import core.sys.posix.sys.socket : shutdown, SHUT_WR;
		auto fds = epollSocketPair();
		scope(exit) close(fds[0]); scope(exit) close(fds[1]);
		assert(shutdown(fds[1], SHUT_WR) == 0);
		auto context = EpollContext.construct(1); int dones;
		auto operation = context.scheduler.recv(cast(socket_t) fds[0], 0).connect(DoneReceiver(&dones));
		operation.start(); context.run(just()).syncWait().assumeOk;
		dones.should == 1; context.fixtureFreeBuffers.should == 1;
	}
	{
		import concurrency.io.socket : tcpSocket;
		auto socket = tcpSocket();
		auto fd = socket.release();
		scope(exit) close(fd);
		auto context = EpollContext.construct(1); int errors;
		auto operation = context.scheduler.recv(fd, 0).connect(ErrorReceiver(&errors));
		operation.start(); context.run(just()).syncWait().assumeOk;
		errors.should == 1; context.fixtureFreeBuffers.should == 1;
	}
}

@("EpollScheduler managed recv exhaustion preserves oversize precedence") @trusted
unittest {
	static struct ErrorReceiver {
		Exception* error;
		void setValue(ref ManagedBuffer) @safe nothrow { assert(false); }
		void setDone() @safe nothrow { assert(false); }
		void setError(Throwable value) @trusted nothrow { *error = cast(Exception) value; }
		shared(StopToken) getStopToken() @safe nothrow { return shared(StopToken).init; }
	}
	auto fds = epollSocketPair();
	scope(exit) close(fds[0]); scope(exit) close(fds[1]);
	auto context = EpollContext.construct(1);
	auto held = context.fixtureManagedBuffer();
	Exception first, second;
	auto ordinary = context.scheduler.recv(cast(socket_t) fds[0], 1).connect(ErrorReceiver(&first));
	auto oversized = context.scheduler.recv(cast(socket_t) fds[0], 4097).connect(ErrorReceiver(&second));
	ordinary.start(); oversized.start(); context.run(just()).syncWait().assumeOk;
	assert(first !is null && first.msg == "epoll managed buffer pool has no free slots");
	assert(second !is null && second.msg == "epoll managed buffer request exceeds 4096-byte slot");
	held.releaseNow(); context.fixtureFreeBuffers.should == 1;
}
