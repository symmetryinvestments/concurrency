module concurrency.io.epoll;

version(linux):

import concurrency.data.queue.mpsc;
import concurrency.stoptoken;
import concurrency.receiver : setErrno, setValueOrError;
static import concurrency.io.buffer;
static import concurrency.ioscheduler;
import core.time : Duration, msecs, hnsecs;
import core.thread : ThreadID;
static import core.sys.posix.netinet.in_;
static import core.sys.posix.sys.socket;
import std.socket : socket_t;
import std.process : thisThreadID;

private struct CommandHeader {
	CommandHeader* next;
	void* owner;
	bool function(void*) @trusted nothrow execute;
	void function(void*) @trusted nothrow cancel;

	void initialize(void* owner_, bool function(void*) @trusted nothrow execute_,
		void function(void*) @trusted nothrow cancel_) @safe nothrow {
		owner = owner_;
		execute = execute_;
		cancel = cancel_;
	}
}

/// Intrusive readiness action.  It deliberately contains no class reference:
/// operations which own their action can embed this header directly.
private struct ActionHeader {
	void* owner;
	int fd;
	bool readDirection;
	bool armed;
	void function(void*) @trusted nothrow retry;
	void function(void*) @trusted nothrow finishDone;
	void function(void*, int) @trusted nothrow finishErrno;
	void function(void*) @trusted nothrow finishPolicy;
	void function(void*) @trusted nothrow finishConflict;
	void function(void*, int) @trusted nothrow finishControl;

	void initialize(void* owner_, int fd_, bool readDirection_,
		void function(void*) @trusted nothrow retry_,
		void function(void*) @trusted nothrow finishDone_,
		void function(void*, int) @trusted nothrow finishErrno_,
		void function(void*) @trusted nothrow finishPolicy_,
		void function(void*) @trusted nothrow finishConflict_,
		void function(void*, int) @trusted nothrow finishControl_) @safe nothrow {
		owner = owner_;
		fd = fd_;
		readDirection = readDirection_;
		armed = false;
		retry = retry_;
		finishDone = finishDone_;
		finishErrno = finishErrno_;
		finishPolicy = finishPolicy_;
		finishConflict = finishConflict_;
		finishControl = finishControl_;
	}
}

private struct EpollSlot {
	int fd = -1;
	ulong generation = 1;
	uint installedMask;
	ActionHeader* readWaiter;
	ActionHeader* writeWaiter;
	bool active;
	bool closing;
	bool quarantined;
}

private final class EpollBufferPool {
	enum slotSize = 4096;
	ubyte[] storage;
	shared size_t[] available;
	uint capacity;

	this(uint capacity) @trusted {
		import core.checkedint : mulu;
		bool overflow;
		auto bytes = mulu(cast(size_t) capacity, cast(size_t) slotSize, overflow);
		if (overflow)
			throw new Exception("epoll managed buffer pool capacity overflow");
		this.capacity = capacity;
		storage.length = bytes;
		available.length = (capacity + size_t.sizeof * 8 - 1) / (size_t.sizeof * 8);
		foreach (i; 0 .. available.length) available[i] = size_t.max;
		if (available.length && capacity % (size_t.sizeof * 8))
			available[$ - 1] = (size_t(1) << (capacity % (size_t.sizeof * 8))) - 1;
	}

	ubyte[] lease() @trusted nothrow {
		import core.atomic : atomicLoad, cas, MemoryOrder;
		foreach (word, ref bits; available) for (;;) {
			auto current = atomicLoad!(MemoryOrder.acq)(bits);
			if (!current) break;
			import core.bitop : bsf;
			auto bit = bsf(current);
			auto expected = current;
			if ((&bits).cas!(MemoryOrder.acq_rel, MemoryOrder.acq)(expected, current & ~(size_t(1) << bit)))
				return storage[(word * size_t.sizeof * 8 + bit) * slotSize .. (word * size_t.sizeof * 8 + bit + 1) * slotSize];
		}
		return null;
	}

	version(unittest) size_t freeCount() @trusted nothrow {
		import core.atomic : atomicLoad, MemoryOrder;
		import core.bitop : popcnt;
		size_t result;
		foreach (bits; available) result += popcnt(atomicLoad!(MemoryOrder.acq)(bits));
		return result;
	}

	void release(scope ubyte[] base) shared @trusted nothrow @nogc {
		import core.atomic : atomicLoad, cas, MemoryOrder;
		auto self = cast(EpollBufferPool) this;
		auto offset = base.ptr - self.storage.ptr;
		assert(offset >= 0 && offset % slotSize == 0 && base.length == slotSize);
		auto index = cast(size_t) (offset / slotSize);
		assert(index < capacity && base.ptr is self.storage.ptr + index * slotSize);
		auto word = index / (size_t.sizeof * 8);
		auto mask = size_t(1) << (index % (size_t.sizeof * 8));
		for (;;) {
			auto current = atomicLoad!(MemoryOrder.acq)(available[word]);
			auto expected = current;
			if ((&available[word]).cas!(MemoryOrder.acq_rel, MemoryOrder.acq)(expected, current | mask)) return;
		}
	}
}

private final class EpollContextState {
	import concurrency.scheduler : Timer, TimerCommand, TimerCommandNode, TimerTrigger, TimingWheels;

	private MPSCQueue!CommandHeader requests;
	private MPSCQueue!(TimerCommandNode!Timer) timers;
	private TimingWheels wheels;
	private ThreadID threadId;
	private int epollFd = -1;
	private int eventFd = -1;
	private EpollBufferPool bufferPool;
	private EpollSlot[] slots;
	private size_t[int] fdSlots;
	private size_t[] freeSlots;
	private size_t[] retiredSlots;
	private ActionHeader*[] retirements;
	private bool processingBatch;
	private enum ulong wakeToken = ulong.max;
	private enum ulong indexMask = (ulong(1) << 24) - 1;
	private enum ulong generationMask = (ulong(1) << 40) - 1;
	private shared bool wakeArmed;
	private shared size_t admission;
	private shared size_t liveWork;
	private enum Duration tickSize = 1.msecs;
	private enum size_t closedBit = size_t(1) << (size_t.sizeof * 8 - 1);
	version(unittest) {
		import core.sync.event : Event;
		private shared(Event)* commandReserved;
		private shared(Event)* commandRelease;
		private shared(Event)* commandPublished;
		private shared(Event)* commandPublishRelease;
		private shared(Event)* timerReserved;
		private shared(Event)* timerRelease;
		private shared(Event)* epollWaitReached;
		private shared(Event)* epollWaitRelease;
		private shared bool epollWaitPauseActive;
		private shared(Event)* admissionClosed;
		private shared ThreadID observedDriver;
		private int forcedAddControlError;
		private int forcedModControlError;
		private int forcedDelControlError;
		private bool forcedAddControlFailureConsumed;
		private bool forcedModControlFailureConsumed;
		private bool forcedDelControlFailureConsumed;
		private int forcedCloseError;
		private size_t closeCalls;
	}

	private this(uint capacity) @trusted {
		import core.sys.linux.epoll;
		import core.sys.linux.sys.eventfd;
		import core.stdc.errno : errno;
		import core.sys.posix.unistd : close;
		import std.exception : ErrnoException;

		epollFd = epoll_create1(EPOLL_CLOEXEC);
		if (epollFd < 0)
			throw new ErrnoException("epoll_create1 failed", errno);
		scope(failure) close(epollFd);
		eventFd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
		if (eventFd < 0)
			throw new ErrnoException("eventfd failed", errno);
		scope(failure) close(eventFd);
		epoll_event event;
		event.events = EPOLLIN;
		event.data.u64 = wakeToken;
		if (epoll_ctl(epollFd, EPOLL_CTL_ADD, eventFd, &event) < 0)
			throw new ErrnoException("epoll_ctl failed", errno);
		requests = new MPSCQueue!CommandHeader;
		timers = new MPSCQueue!(TimerCommandNode!Timer);
		bufferPool = new EpollBufferPool(capacity);
		wheels.initialize();
		threadId = thisThreadID;
	}

	~this() @trusted {
		closeFds();
	}

	private void closeFds() @trusted nothrow {
		import core.sys.posix.unistd : close;
		if (eventFd >= 0)
			close(eventFd);
		if (epollFd >= 0)
			close(epollFd);
		eventFd = -1;
		epollFd = -1;
	}

	version(unittest) void pauseCommandAfterReserve(shared(Event)* reached,
		shared(Event)* release) @trusted {
		commandReserved = reached;
		commandRelease = release;
	}

	version(unittest) void pauseCommandAfterPublish(shared(Event)* reached,
		shared(Event)* release) @trusted {
		commandPublished = reached;
		commandPublishRelease = release;
	}

	version(unittest) void pauseTimerAfterReserve(shared(Event)* reached,
		shared(Event)* release) @trusted {
		timerReserved = reached;
		timerRelease = release;
	}

	version(unittest) void pauseAfterEpollWait(shared(Event)* reached,
		shared(Event)* release) @trusted {
		epollWaitReached = reached;
		epollWaitRelease = release;
	}

	version(unittest) void activatePauseAfterEpollWait() @trusted shared {
		import core.atomic : atomicStore, MemoryOrder;
		atomicStore!(MemoryOrder.rel)(epollWaitPauseActive, true);
	}

	version(unittest) void observeAdmissionClose(shared(Event)* observed) @trusted {
		admissionClosed = observed;
	}

	version(unittest) ThreadID driverThread() @safe nothrow {
		return observedDriver;
	}

	version(unittest) void forceNextAddControlFailure(int error) @safe nothrow {
		forcedAddControlFailureConsumed = false;
		forcedAddControlError = error;
	}
	version(unittest) void forceNextModControlFailure(int error) @safe nothrow {
		forcedModControlFailureConsumed = false;
		forcedModControlError = error;
	}
	version(unittest) void forceNextDelControlFailure(int error) @safe nothrow {
		forcedDelControlFailureConsumed = false;
		forcedDelControlError = error;
	}
	version(unittest) bool addControlFailureConsumed() @safe nothrow { return forcedAddControlFailureConsumed; }
	version(unittest) bool modControlFailureConsumed() @safe nothrow { return forcedModControlFailureConsumed; }
	version(unittest) bool delControlFailureConsumed() @safe nothrow { return forcedDelControlFailureConsumed; }
	version(unittest) void forceCloseError(int error) @safe nothrow { forcedCloseError = error; }
	version(unittest) size_t closeCallCount() @safe nothrow { return closeCalls; }

	version(unittest) struct RegistryFixture {
		ulong token;
		size_t index;
		ulong generation;
		bool quarantined;
		size_t freeSlots;
		size_t retirements;
	}

	version(unittest) RegistryFixture fixtureSlot(int fd, ulong generation) @trusted {
		assert(generation != 0 && generation <= generationMask);
		size_t index;
		if (freeSlots.length) {
			index = freeSlots[$ - 1];
			freeSlots.length--;
		} else {
			index = slots.length;
			assert(index < indexMask);
			slots.length++;
		}
		slots[index] = EpollSlot.init;
		slots[index].fd = fd;
		slots[index].generation = generation;
		slots[index].active = true;
		fdSlots[fd] = index;
		return RegistryFixture(token(index, generation), index, generation, false,
			freeSlots.length, retirements.length);
	}

	version(unittest) RegistryFixture registryFixture(int fd) @trusted {
		auto index = *(fd in fdSlots);
		auto slot = &slots[index];
		return RegistryFixture(token(index, slot.generation), index, slot.generation,
			slot.quarantined, freeSlots.length, retirements.length);
	}

	version(unittest) RegistryFixture fixtureInvalidate(int fd) @trusted {
		auto index = *(fd in fdSlots);
		auto slot = &slots[index];
		if (slot.generation == generationMask) slot.quarantined = true;
		else slot.generation++;
		return RegistryFixture(slot.quarantined ? 0 : token(index, slot.generation),
			index, slot.generation, slot.quarantined, freeSlots.length, retirements.length);
	}

	version(unittest) void fixtureDetach(int fd) @trusted {
		auto index = *(fd in fdSlots);
		auto slot = &slots[index];
		assert(slot.readWaiter is null && slot.writeWaiter is null);
		fdSlots.remove(fd);
		slot.active = false;
		slot.fd = -1;
		if (processingBatch) retiredSlots ~= index;
		else freeSlots ~= index;
	}

	version(unittest) struct QuiescenceSnapshot {
		bool closed;
		size_t reservations;
		size_t live;
		bool requestsEmpty;
		bool timersEmpty;
		ulong wheelTimers;
		size_t activeRecords;
		size_t readWaiters;
		size_t writeWaiters;
		size_t retirementEntries;
	}

	version(unittest) int[2] fileDescriptors() @safe nothrow {
		return [epollFd, eventFd];
	}

	version(unittest) QuiescenceSnapshot quiescenceSnapshot() @trusted {
		import core.atomic : atomicLoad, MemoryOrder;
		auto gate = atomicLoad!(MemoryOrder.acq)(admission);
		size_t activeRecords;
		size_t readWaiters;
		size_t writeWaiters;
		foreach (ref slot; slots) {
			if (slot.active) activeRecords++;
			if (slot.readWaiter !is null) readWaiters++;
			if (slot.writeWaiter !is null) writeWaiters++;
		}
		return QuiescenceSnapshot((gate & closedBit) != 0, gate & ~closedBit,
			atomicLoad!(MemoryOrder.acq)(liveWork), requests.empty(), timers.empty(),
			wheels.totalTimers, activeRecords, readWaiters, writeWaiters,
			retirements.length + retiredSlots.length);
	}

	auto run(Sender)(Sender sender) @safe nothrow { return EpollRunSender!Sender(this, sender); }

	private bool reserveAdmission() @trusted shared nothrow {
		import core.atomic : atomicLoad, cas, MemoryOrder;
		for (;;) {
			auto current = atomicLoad!(MemoryOrder.acq)(admission);
			if (current & closedBit)
				return false;
			assert((current & ~closedBit) != ~closedBit);
			auto expected = current;
			if ((&admission).cas!(MemoryOrder.acq_rel, MemoryOrder.acq)(expected, current + 1))
				return true;
		}
	}

	private void releasePublication() @trusted shared nothrow {
		import core.atomic : atomicFetchSub, MemoryOrder;
		auto previous = atomicFetchSub!(MemoryOrder.acq_rel)(admission, 1);
		assert((previous & ~closedBit) != 0);
	}

	private void closeAdmission() @trusted nothrow {
		import core.atomic : atomicLoad, cas, MemoryOrder;
		for (;;) {
			auto current = atomicLoad!(MemoryOrder.acq)(admission);
			if (current & closedBit)
				return;
			auto expected = current;
			if ((&admission).cas!(MemoryOrder.acq_rel, MemoryOrder.acq)(expected, current | closedBit)) {
				version(unittest) if (admissionClosed !is null)
					(cast(Event*) admissionClosed).setIfInitialized();
				return;
			}
		}
	}

	private void addLiveWork() @trusted shared nothrow {
		import core.atomic : atomicFetchAdd, MemoryOrder;
		atomicFetchAdd!(MemoryOrder.acq_rel)(liveWork, 1);
	}

	private void beforeCommandPublication() @trusted shared nothrow {
		version(unittest) if (commandReserved !is null) {
			(cast(Event*) commandReserved).setIfInitialized();
			(cast(Event*) commandRelease).wait();
		}
	}

	private void beforeTimerPublication() @trusted shared nothrow {
		version(unittest) if (timerReserved !is null) {
			(cast(Event*) timerReserved).setIfInitialized();
			(cast(Event*) timerRelease).wait();
		}
	}

	private void afterCommandPublication() @trusted shared nothrow {
		version(unittest) if (commandPublished !is null) {
			(cast(Event*) commandPublished).setIfInitialized();
			(cast(Event*) commandPublishRelease).wait();
		}
	}

	private void afterEpollWait() @trusted nothrow {
		version(unittest) {
			import core.atomic : atomicLoad, atomicStore, MemoryOrder;
			if (epollWaitReached is null
				|| !atomicLoad!(MemoryOrder.acq)(epollWaitPauseActive))
				return;
			auto reached = epollWaitReached;
			auto release = epollWaitRelease;
			(cast(Event*) reached).setIfInitialized();
			(cast(Event*) release).wait();
			epollWaitReached = null;
			epollWaitRelease = null;
			atomicStore!(MemoryOrder.rel)(epollWaitPauseActive, false);
		}
	}

	private void releaseLiveWork() @trusted nothrow {
		import core.atomic : atomicFetchSub, MemoryOrder;
		auto previous = atomicFetchSub!(MemoryOrder.acq_rel)(liveWork, 1);
		assert(previous != 0);
	}

	private void rejectedAdmission() @trusted shared nothrow {
		version(unittest) {
			import core.exception : onAssertErrorMsg;
			onAssertErrorMsg(__FILE__, __LINE__,
				"Epoll scheduler operations must start within the associated run lifetime");
		} else debug assert(false,
			"Epoll scheduler operations must start within the associated run lifetime");
	}

	private void push(CommandHeader* command) @trusted shared nothrow {
		if (!reserveAdmission()) {
			rejectedAdmission();
			return;
		}
		addLiveWork();
		scope(exit) releasePublication();
		beforeCommandPublication();
		requests.push(cast(CommandHeader*) command);
		signalIfArmed();
		afterCommandPublication();
	}

	private void addTimer(ref Timer timer) @trusted shared {
		enqueueTimer(&timer, TimerCommand.Register);
	}

	private void addTimer(ref Timer timer, Duration duration) @trusted shared {
		timer.setScheduledAt(duration);
		addTimer(timer);
	}

	private void cancelTimer(ref Timer timer) @trusted shared {
		setTimerCancelled(timer);
		enqueueTimer(&timer, TimerCommand.Cancel);
	}

	private static void setTimerCancelled(ref Timer timer) @trusted nothrow {
		import core.atomic : atomicStore, MemoryOrder;
		atomicStore!(MemoryOrder.rel)(*cast(shared(ushort)*) &timer.command,
			cast(ushort) TimerCommand.Cancel);
	}

	private static bool timerIsRegistered(Timer* timer) @trusted nothrow {
		import core.atomic : atomicLoad, MemoryOrder;
		return atomicLoad!(MemoryOrder.acq)(*cast(shared(ushort)*) &timer.command)
			== TimerCommand.Register;
	}

	private static bool claimTimer(Timer* timer, int terminal) @trusted nothrow {
		import core.atomic : cas, MemoryOrder;
		return (&timer.terminal).cas!(MemoryOrder.rel, MemoryOrder.acq)(0, terminal);
	}

	private void enqueueTimer(Timer* timer, TimerCommand command) @trusted shared {
		auto node = command == TimerCommand.Register
			? &timer.registerCommand : &timer.cancelCommand;
		node.owner = timer;
		node.command = command;
		if (!reserveAdmission()) {
			rejectedAdmission();
			return;
		}
		addLiveWork();
		scope(exit) releasePublication();
		beforeTimerPublication();
		timers.push(cast(TimerCommandNode!Timer*) node);
		signalIfArmed();
	}

	private void wakeup() @trusted shared nothrow {
		import core.atomic : atomicStore, MemoryOrder;
		atomicStore!(MemoryOrder.rel)(wakeArmed, true);
		signalIfArmed();
	}

	private void signalIfArmed() @trusted shared nothrow {
		import core.atomic : atomicStore, cas, MemoryOrder;
		import core.stdc.errno : errno, EINTR, EAGAIN;
		import core.sys.posix.unistd : write;
		size_t one = 1;
		if (!(&wakeArmed).cas!(MemoryOrder.rel, MemoryOrder.acq)(true, false))
			return;
		while (write(eventFd, &one, one.sizeof) < 0) {
			if (errno == EINTR)
				continue;
			if (errno == EAGAIN)
				return;
			atomicStore!(MemoryOrder.rel)(wakeArmed, true);
			return;
		}
	}

	private void drainCommands(bool cancel = false) @safe nothrow {
		while (auto command = requests.pop()) {
			if (cancel)
				command.cancel(command.owner);
			else if (!command.execute(command.owner)) {
				continue;
			}
			releaseLiveWork();
		}
	}

	private ulong token(size_t index, ulong generation) @safe nothrow {
		assert(index < indexMask);
		assert(generation != 0 && generation <= generationMask);
		return (generation << 24) | index;
	}

	private uint desiredMask(ref EpollSlot slot) @safe nothrow {
		import core.sys.linux.epoll : EPOLLIN, EPOLLOUT, EPOLLRDHUP;
		uint mask;
		if (slot.readWaiter !is null) mask |= EPOLLIN | EPOLLRDHUP;
		if (slot.writeWaiter !is null) mask |= EPOLLOUT;
		return mask;
	}

	private void reconcile(size_t index, ActionHeader* affected = null,
		bool tokenChanged = false) @trusted nothrow {
		import core.sys.linux.epoll;
		import core.stdc.errno : errno, EPERM, ENOENT, EBADF;
		auto slot = &slots[index];
		auto desired = desiredMask(*slot);
		if (desired == slot.installedMask && (!tokenChanged || desired == 0)) return;
		epoll_event event;
		event.events = desired;
		event.data.u64 = token(index, slot.generation);
		auto op = slot.installedMask == 0 ? EPOLL_CTL_ADD : desired == 0 ? EPOLL_CTL_DEL : EPOLL_CTL_MOD;
		version(unittest) {
			int* forcedError;
			bool* consumed;
			final switch (op) {
			case EPOLL_CTL_ADD:
				forcedError = &forcedAddControlError;
				consumed = &forcedAddControlFailureConsumed;
				break;
			case EPOLL_CTL_MOD:
				forcedError = &forcedModControlError;
				consumed = &forcedModControlFailureConsumed;
				break;
			case EPOLL_CTL_DEL:
				forcedError = &forcedDelControlError;
				consumed = &forcedDelControlFailureConsumed;
				break;
			}
			if (*forcedError) {
				errno = *forcedError;
				*forcedError = 0;
				*consumed = true;
				goto controlFailure;
			}
		}
		if (epoll_ctl(epollFd, op, slot.fd, desired == 0 ? null : &event) < 0) {
		controlFailure:
			// A descriptor can be closed by its owner while its final DEL is in flight.
			if (op == EPOLL_CTL_DEL && (errno == ENOENT || errno == EBADF)) {
				slot.installedMask = 0;
				return;
			}
			if (op == EPOLL_CTL_DEL) {
				// The old registration may still exist, so this slot is never reused.
				slot.quarantined = true;
				slot.installedMask = 0;
				if (affected !is null)
					affected.finishControl(affected.owner, errno);
				return;
			}
			if (affected !is null) {
				if (errno == EPERM) affected.finishPolicy(affected.owner);
				else affected.finishControl(affected.owner, errno);
			}
			return;
		}
		slot.installedMask = desired;
	}

	private void attach(ActionHeader* action) @trusted nothrow {
		auto found = action.fd in fdSlots;
		size_t index;
		if (found is null) {
			if (freeSlots.length) { index = freeSlots[$ - 1]; freeSlots.length--; }
			else {
				if (slots.length >= indexMask) {
					action.finishPolicy(action.owner);
					return;
				}
				index = slots.length;
				slots.length++;
			}
			slots[index].fd = action.fd;
			slots[index].active = true;
			fdSlots[action.fd] = index;
		} else index = *found;
		auto slot = &slots[index];
		auto existing = action.readDirection ? slot.readWaiter : slot.writeWaiter;
		if (existing !is null) { action.finishConflict(action.owner); return; }
		if (action.readDirection) slot.readWaiter = action; else slot.writeWaiter = action;
		action.armed = true;
		reconcile(index, action);
	}

	private bool validateDescriptor(ActionHeader* action) @trusted nothrow {
		import core.sys.posix.fcntl : fcntl, F_GETFL, O_NONBLOCK;
		import core.sys.posix.sys.stat : fstat, stat_t, S_ISREG;
		import core.stdc.errno : errno;
		auto flags = fcntl(action.fd, F_GETFL);
		if (flags < 0) { action.finishErrno(action.owner, errno); return false; }
		stat_t info;
		if (fstat(action.fd, &info) < 0) { action.finishErrno(action.owner, errno); return false; }
		if ((flags & O_NONBLOCK) == 0 || S_ISREG(info.st_mode)) {
			action.finishPolicy(action.owner);
			return false;
		}
		return true;
	}

	private EpollBufferPool managedPool() @safe nothrow { return bufferPool; }
	version(unittest) concurrency.io.buffer.ManagedBuffer fixtureManagedBuffer() @trusted {
		import concurrency.io.buffer : ManagedBuffer;
		auto base = bufferPool.lease();
		assert(base !is null);
		auto sharedPool = cast(shared(EpollBufferPool)) bufferPool;
		ManagedBuffer.Release release = &sharedPool.release;
		return ManagedBuffer.adopt(release, base, 0);
	}
	version(unittest) size_t fixtureFreeBuffers() @trusted nothrow { return bufferPool.freeCount(); }

	private void closeDescriptor(int fd) @trusted nothrow {
		auto found = fd in fdSlots;
		if (found is null) return;
		auto index = *found;
		auto slot = &slots[index];
		slot.closing = true;
		auto read = slot.readWaiter;
		auto write = slot.writeWaiter;
		slot.readWaiter = null;
		slot.writeWaiter = null;
		if (read !is null) read.armed = false;
		if (write !is null) write.armed = false;
		if (read !is null) read.finishDone(read.owner);
		if (write !is null) write.finishDone(write.owner);
		reconcile(index);
		invalidate(*slot);
		fdSlots.remove(fd);
		slot.active = false;
		slot.fd = -1;
		if (!slot.quarantined) {
			if (processingBatch) retiredSlots ~= index;
			else freeSlots ~= index;
		}
	}

	private int closeOnce(int fd, out int error) @trusted nothrow {
		import core.stdc.errno : errno;
		import core.sys.posix.unistd : close;
		version(unittest) {
			closeCalls++;
			if (forcedCloseError) {
				error = forcedCloseError;
				forcedCloseError = 0;
				return -1;
			}
		}
		auto result = close(fd);
		error = errno;
		return result;
	}

	private void releaseRetirements() @safe nothrow {
		retirements.length = 0;
		foreach (index; retiredSlots)
			if (!slots[index].quarantined) freeSlots ~= index;
		retiredSlots.length = 0;
	}

	private void retire(ActionHeader* action) @safe nothrow {
		if (processingBatch)
			retirements ~= action;
	}

	private bool invalidate(ref EpollSlot slot) @safe nothrow {
		if (slot.generation == generationMask) {
			slot.quarantined = true;
			return false;
		}
		slot.generation++;
		return true;
	}

	private void detached(ActionHeader* action) @trusted nothrow {
		import core.stdc.errno : EOVERFLOW;
		auto found = action.fd in fdSlots;
		if (found is null) return;
		auto index = *found;
		auto slot = &slots[index];
		if (action.readDirection && slot.readWaiter is action) slot.readWaiter = null;
		else if (!action.readDirection && slot.writeWaiter is action) slot.writeWaiter = null;
		else return;
		action.armed = false;
		auto survivor = slot.readWaiter !is null ? slot.readWaiter : slot.writeWaiter;
		if (slot.generation == generationMask) {
			// A max-generation token cannot be refreshed without colliding with wakeToken.
			// Retire this slot permanently and fail any remaining direction rather than
			// leaving it armed behind a token that dispatch will reject.
			fdSlots.remove(action.fd);
			slot.active = false;
			slot.fd = -1;
			slot.quarantined = true;
			if (survivor !is null)
				survivor.finishControl(survivor.owner, EOVERFLOW);
			return;
		}
		auto reusable = invalidate(*slot);
		reconcile(index, survivor is null ? action : survivor, reusable);
		if (slot.readWaiter is null && slot.writeWaiter is null) {
			fdSlots.remove(action.fd);
			slot.active = false;
			slot.fd = -1;
			if (reusable && !slot.quarantined) {
				if (processingBatch) retiredSlots ~= index;
				else freeSlots ~= index;
			}
		}
	}

	private void completeTimer(Timer* timer, int terminal) @safe nothrow {
		import concurrency.scheduler : TimerTrigger;
		if (!claimTimer(timer, terminal))
			return;
		timer.userdata(terminal == 1 ? TimerTrigger.trigger : TimerTrigger.cancel);
		releaseLiveWork();
	}

	private void scheduleTimers(bool cancel = false) @trusted nothrow {
		import std.datetime.systime : Clock;
		while (auto item = timers.pop()) {
			auto timer = item.owner;
			auto command = item.command;
			if (command == TimerCommand.Register) {
				if (!cancel && timerIsRegistered(timer)) {
					auto delay = (Clock.currStdTime - wheels.currStdTime(tickSize)).hnsecs;
					wheels.schedule(timer, (timer.scheduled_at.hnsecs + delay) / tickSize);
				} else
					completeTimer(timer, 2);
			} else {
				wheels.cancel(timer);
				completeTimer(timer, 2);
				releaseLiveWork();
			}
		}
	}

	private void expireTimers() @safe nothrow {
		import concurrency.scheduler : TimerTrigger;
		import std.datetime.systime : Clock;
		auto ticks = wheels.ticksToCatchUp(tickSize, Clock.currStdTime);
		if (ticks <= 0)
			return;
		Timer* timer;
		wheels.advance(ticks, timer);
		while (timer !is null) {
			auto next = timer.next;
			completeTimer(timer, 1);
			timer = next;
		}
	}

	private int timeout() @safe nothrow {
		import std.datetime.systime : Clock;
		auto next = wheels.timeUntilNextEvent(tickSize, Clock.currStdTime);
		if (next.isNull)
			return -1;
		auto remaining = next.get.split!"hnsecs".hnsecs;
		if (remaining <= 0)
			return 0;
		auto millisecond = 1.msecs.split!"hnsecs".hnsecs;
		auto rounded = (remaining + millisecond - 1) / millisecond;
		return cast(int) (rounded > int.max ? int.max : rounded);
	}

	private void drainEvent() @trusted nothrow {
		import core.sys.posix.unistd : read;
		ulong value;
		while (read(eventFd, &value, value.sizeof) > 0) {}
	}

	private void cancelTimers() @safe nothrow {
		import concurrency.scheduler : TimerTrigger;
		Timer* timer;
		wheels.clear(timer);
		while (timer !is null) {
			auto next = timer.next;
			timer.next = null;
			timer.prev = null;
			completeTimer(timer, 2);
			timer = next;
		}
	}

	private void cancelArmed() @trusted nothrow {
		ActionHeader*[] pending;
		foreach (ref slot; slots) {
			if (slot.readWaiter !is null) pending ~= slot.readWaiter;
			if (slot.writeWaiter !is null) pending ~= slot.writeWaiter;
		}
		foreach (action; pending) action.finishDone(action.owner);
	}

	private int drive(scope shared StopToken stopToken) @trusted nothrow {
		import core.atomic : atomicLoad, atomicStore, MemoryOrder;
		import core.stdc.errno : errno, EINTR;
		import core.sys.linux.epoll;

		assert(threadId == thisThreadID,
			"Thread that started EpollContext must also drive it.");
		version(unittest) observedDriver = thisThreadID;
		epoll_event[16] events;
		for (;;) {
			drainCommands();
			scheduleTimers();
			expireTimers();
			if (stopToken.isStopRequested()) {
				closeAdmission();
				for (;;) {
					cancelArmed();
					releaseRetirements();
					drainEvent();
					drainCommands(true);
					scheduleTimers(true);
					cancelTimers();
					auto gate = atomicLoad!(MemoryOrder.acq)(admission);
					if ((gate & closedBit) && (gate & ~closedBit) == 0
						&& requests.empty() && timers.empty()
						&& wheels.totalTimers == 0
						&& atomicLoad!(MemoryOrder.acq)(liveWork) == 0
						&& retirements.length == 0 && retiredSlots.length == 0) {
						assert((gate & closedBit) && (gate & ~closedBit) == 0
							&& requests.empty() && timers.empty()
							&& wheels.totalTimers == 0
							&& atomicLoad!(MemoryOrder.acq)(liveWork) == 0
							&& retirements.length == 0 && retiredSlots.length == 0,
							"EpollContext stopped without quiescing accepted work");
						closeFds();
						return 0;
					}
				}
			}
			atomicStore!(MemoryOrder.rel)(wakeArmed, true);
			if ((atomicLoad!(MemoryOrder.acq)(admission) & ~closedBit) != 0
				|| !requests.empty() || !timers.empty()) {
				atomicStore!(MemoryOrder.rel)(wakeArmed, false);
				continue;
			}
			auto count = epoll_wait(epollFd, events.ptr, cast(int) events.length, timeout());
			atomicStore!(MemoryOrder.rel)(wakeArmed, false);
			if (count < 0) {
				if (errno == EINTR)
					continue;
				return -errno;
			}
			ulong[16] values;
			foreach (i; 0 .. count) values[i] = events[i].data.u64;
			afterEpollWait();
			dispatchBatch(values[0 .. count]);
		}
	}

	private void dispatchBatch(scope const(ulong)[] values) @trusted nothrow {
		processingBatch = true;
		foreach (value; values) {
				if (value == wakeToken) { drainEvent(); continue; }
				auto index = cast(size_t) (value & indexMask);
				auto generation = value >> 24;
				if (index >= slots.length || !slots[index].active || slots[index].generation != generation)
					continue;
				auto read = slots[index].readWaiter;
				auto write = slots[index].writeWaiter;
				if (read !is null) read.retry(read.owner);
				if (write !is null) write.retry(write.owner);
		}
		processingBatch = false;
		releaseRetirements();
	}
}

struct EpollContext {
	private EpollContextState state;

	static auto construct(uint capacity) @safe {
		return EpollContext(new EpollContextState(capacity));
	}

	auto run(Sender)(Sender sender) @safe nothrow {
		return EpollRunSender!Sender(state, sender);
	}

	auto scheduler() @trusted nothrow { return EpollScheduler(cast(shared) state); }

	version(unittest) {
		import core.sync.event : Event;
		void pauseCommandAfterReserve(shared(Event)* reached, shared(Event)* release) @trusted {
			state.pauseCommandAfterReserve(reached, release);
		}
		void pauseCommandAfterPublish(shared(Event)* reached, shared(Event)* release) @trusted {
			state.pauseCommandAfterPublish(reached, release);
		}
		void pauseTimerAfterReserve(shared(Event)* reached, shared(Event)* release) @trusted {
			state.pauseTimerAfterReserve(reached, release);
		}
		void pauseAfterEpollWait(shared(Event)* reached, shared(Event)* release) @trusted {
			state.pauseAfterEpollWait(reached, release);
		}
		void activatePauseAfterEpollWait() @trusted {
			(cast(shared) state).activatePauseAfterEpollWait();
		}
		void observeAdmissionClose(shared(Event)* observed) @trusted { state.observeAdmissionClose(observed); }
		void forceNextAddControlFailure(int error) @safe nothrow { state.forceNextAddControlFailure(error); }
		void forceNextModControlFailure(int error) @safe nothrow { state.forceNextModControlFailure(error); }
		void forceNextDelControlFailure(int error) @safe nothrow { state.forceNextDelControlFailure(error); }
		bool addControlFailureConsumed() @safe nothrow { return state.addControlFailureConsumed(); }
		bool modControlFailureConsumed() @safe nothrow { return state.modControlFailureConsumed(); }
		bool delControlFailureConsumed() @safe nothrow { return state.delControlFailureConsumed(); }
		void forceCloseError(int error) @safe nothrow { state.forceCloseError(error); }
		size_t closeCallCount() @safe nothrow { return state.closeCallCount(); }
		void dispatchSynthetic(ulong[] values) @trusted { state.dispatchBatch(values); }
		ulong wakeToken() @safe nothrow { return ulong.max; }
		alias RegistryFixture = EpollContextState.RegistryFixture;
		RegistryFixture fixtureSlot(int fd, ulong generation) @trusted { return state.fixtureSlot(fd, generation); }
		RegistryFixture registryFixture(int fd) @trusted { return state.registryFixture(fd); }
		RegistryFixture fixtureInvalidate(int fd) @trusted { return state.fixtureInvalidate(fd); }
		void fixtureDetach(int fd) @trusted { state.fixtureDetach(fd); }
		alias QuiescenceSnapshot = EpollContextState.QuiescenceSnapshot;
		QuiescenceSnapshot quiescenceSnapshot() @trusted { return state.quiescenceSnapshot(); }
		int[2] fileDescriptors() @safe nothrow { return state.fileDescriptors(); }
		concurrency.io.buffer.ManagedBuffer fixtureManagedBuffer() @trusted { return state.fixtureManagedBuffer(); }
		size_t fixtureFreeBuffers() @trusted nothrow { return state.fixtureFreeBuffers(); }
	}
}

private struct EpollTimer {
	import concurrency.scheduler : Timer;
	shared(EpollContextState) context;
	void addTimer(ref Timer timer) @safe { context.addTimer(timer); }
	void addTimer(ref Timer timer, Duration duration) @safe { context.addTimer(timer, duration); }
	void cancelTimer(ref Timer timer) @safe { context.cancelTimer(timer); }
}

/// Scheduler operations must start within the associated structured EpollContext.run scope.
struct EpollScheduler {
	import std.socket : socket_t;
	import concurrency.io.buffer : ManagedBuffer;
	import concurrency.ioscheduler : Client;
	shared(EpollContextState) context;

	version(unittest) void activatePauseAfterEpollWait() @trusted shared {
		context.activatePauseAfterEpollWait();
	}

	auto schedule() @safe nothrow @nogc {
		import concurrency.scheduler : ScheduleAfterSender;
		return ScheduleAfterSender!EpollTimer(EpollTimer(context), 0.msecs);
	}
	auto scheduleAfter(Duration duration) @safe nothrow @nogc {
		import concurrency.scheduler : ScheduleAfterSender;
		return ScheduleAfterSender!EpollTimer(EpollTimer(context), duration);
	}
	auto nop() @safe nothrow @nogc { return EpollNopSender(context); }
	auto recv(socket_t fd, uint len = 0) @safe nothrow @nogc { return EpollManagedRecvSender(context, cast(int) fd, len); }
	auto recv(socket_t fd, return ubyte[] buffer, long len = 0) @safe nothrow @nogc { return EpollBufferSender!(ubyte[], true, false, false)(context, cast(int) fd, buffer, len); }
	auto read(socket_t fd, return ubyte[] buffer, long len = 0) @safe nothrow @nogc { return EpollBufferSender!(ubyte[], false, true, false)(context, cast(int) fd, buffer, len); }
	auto accept(socket_t fd) @safe nothrow @nogc { return EpollAcceptSender(context, cast(int) fd); }
	auto connect(socket_t fd, return string address, ushort port) @safe nothrow @nogc { return EpollConnectSender(context, cast(int) fd, address, port); }
	auto send(socket_t fd, return const(ubyte)[] buffer) @safe nothrow @nogc { return EpollBufferSender!(int, false, false, true)(context, cast(int) fd, buffer, 0); }
	auto write(socket_t fd, return const(ubyte)[] buffer, long offset = 0) @safe nothrow @nogc { return EpollBufferSender!(int, false, false, false)(context, cast(int) fd, buffer, offset); }
	auto close(socket_t fd) @safe nothrow @nogc { return EpollCloseSender(context, cast(int) fd); }
}

private struct EpollNopSender {
	alias Value = int;
	shared(EpollContextState) context;
	auto connect(Receiver)(return Receiver receiver) @safe return scope {
		return EpollNopOp!Receiver(context, receiver);
	}
}

private struct EpollNopOp(Receiver) {
	shared(EpollContextState) context;
	Receiver receiver;
	CommandHeader command;
	@disable this(this);
	void start() @trusted nothrow scope {
		command.initialize(cast(void*) &this, &execute, &cancel);
		context.push(&command);
	}
	private static bool execute(void* owner) @trusted nothrow { auto op = cast(EpollNopOp!Receiver*) owner; op.receiver.setValueOrError(0); op.receiver = Receiver.init; return true; }
	private static void cancel(void* owner) @trusted nothrow { auto op = cast(EpollNopOp!Receiver*) owner; op.receiver.setDone(); op.receiver = Receiver.init; }
}

private struct EpollBufferAction(Receiver, bool receiving, bool reading, bool sending) {
	ActionHeader header;
	CommandHeader command;
	CommandHeader cancelCommand;
	shared(EpollContextState) context;
	Receiver receiver;
	int fd;
	static if (receiving || reading) ubyte[] buffer; else const(ubyte)[] buffer;
	long offset;
	shared StopCallback stopCallback;
	bool terminal;
	bool started;
	int controlError;

	void initialize(shared(EpollContextState) context_, int fd_, typeof(buffer) buffer_, long offset_, Receiver receiver_) @trusted nothrow {
		context = context_; fd = fd_; buffer = buffer_; offset = offset_; receiver = receiver_;
		header.initialize(cast(void*) &this, fd, receiving || reading, &retryHeader,
			&finishDoneHeader, &finishErrnoHeader, &finishPolicyHeader,
			&finishConflictHeader, &finishControlHeader);
		command.initialize(cast(void*) &this, &executeCommand, &cancelCommandCallback);
		cancelCommand.initialize(cast(void*) &this, &executeCancel, &cancelCancel);
	}
	private static bool executeCommand(void* owner) @trusted nothrow { return (cast(EpollBufferAction*) owner).execute(); }
	private static void cancelCommandCallback(void* owner) @trusted nothrow { (cast(EpollBufferAction*) owner).finishDone(); }
	private static bool executeCancel(void* owner) @trusted nothrow { (cast(EpollBufferAction*) owner).finishDone(); return true; }
	private static void cancelCancel(void* owner) @trusted nothrow { (cast(EpollBufferAction*) owner).finishDone(); }
	private static void retryHeader(void* owner) @trusted nothrow { (cast(EpollBufferAction*) owner).retry(); }
	private static void finishDoneHeader(void* owner) @trusted nothrow { (cast(EpollBufferAction*) owner).finishDone(); }
	private static void finishErrnoHeader(void* owner, int error) @trusted nothrow { (cast(EpollBufferAction*) owner).finishErrno(error); }
	private static void finishPolicyHeader(void* owner) @trusted nothrow { (cast(EpollBufferAction*) owner).finishPolicy(); }
	private static void finishConflictHeader(void* owner) @trusted nothrow { (cast(EpollBufferAction*) owner).finishConflict(); }
	private static void finishControlHeader(void* owner, int error) @trusted nothrow { (cast(EpollBufferAction*) owner).finishControl(error); }

	private bool execute() @trusted nothrow {
		started = true;
		auto token = receiver.getStopToken();
		stopCallback.register(token, &(cast(shared) &this).onStop);
		if (token.isStopRequested) finishDone();
		else if ((cast(EpollContextState) context).validateDescriptor(&header)) retry();
		return false;
	}
	private void onStop() @trusted nothrow shared { context.push(cast(CommandHeader*) &cancelCommand); }
	private void retry() @trusted nothrow {
		if (terminal) return;
		import core.stdc.errno : errno, EINTR, EAGAIN, EWOULDBLOCK;
		import core.sys.posix.unistd : read, write, pread, pwrite;
		import core.sys.posix.sys.socket : recv, send;
		ptrdiff_t result;
		for (;;) {
			static if (receiving) result = recv(fd, buffer.ptr, buffer.length, 0);
			else static if (reading) result = offset == 0 ? read(fd, buffer.ptr, buffer.length) : pread(fd, buffer.ptr, buffer.length, offset);
			else static if (sending) result = send(fd, buffer.ptr, buffer.length, 0);
			else result = offset == 0 ? write(fd, buffer.ptr, buffer.length) : pwrite(fd, buffer.ptr, buffer.length, offset);
			if (result < 0 && errno == EINTR) continue;
			break;
		}
		if (result > 0) {
			static if (receiving || reading) finishValue(buffer[0 .. result]); else finishValue(cast(int) result);
		} else if (result == 0) finishDone();
		else if (errno == EAGAIN || errno == EWOULDBLOCK) { if (!header.armed) (cast(EpollContextState) context).attach(&header); }
		else finishErrno(errno);
	}
	private void prepareTerminal() @trusted nothrow {
		if (header.armed) (cast(EpollContextState) context).detached(&header);
		stopCallback.dispose();
		if (started) (cast(EpollContextState) context).releaseLiveWork();
		(cast(EpollContextState) context).retire(&header);
	}
	private void finishValue(T)(T value) @trusted nothrow { if (terminal) return; terminal = true; prepareTerminal(); if (controlError) receiver.setErrno("epoll_ctl failed", controlError); else receiver.setValueOrError(value); }
	private void finishDone() @trusted nothrow { if (terminal) return; terminal = true; prepareTerminal(); if (controlError) receiver.setErrno("epoll_ctl failed", controlError); else receiver.setDone(); }
	private void finishErrno(int error) @trusted nothrow { if (terminal) return; terminal = true; prepareTerminal(); static if (receiving) receiver.setErrno("Receive failed", error); else static if (reading) receiver.setErrno("Read failed", error); else static if (sending) receiver.setErrno("Send failed", error); else receiver.setErrno("Write failed", error); }
	private void finishPolicy() @trusted nothrow { finishException("epoll supports only nonblocking sockets and pipes"); }
	private void finishConflict() @trusted nothrow { finishException(header.readDirection ? "epoll already has a read waiter for this descriptor" : "epoll already has a write waiter for this descriptor"); }
	private void finishControl(int error) @trusted nothrow { if (terminal) { controlError = error; return; } terminal = true; prepareTerminal(); receiver.setErrno("epoll_ctl failed", error); }
	private void finishException(string message) @trusted nothrow { if (terminal) return; terminal = true; prepareTerminal(); receiver.setError(new Exception(message)); }
}

private struct EpollBufferSender(ReceiverValue, bool receiving, bool reading, bool sending) {
	alias Value = ReceiverValue;
	shared(EpollContextState) context;
	int fd;
	static if (receiving || reading) ubyte[] buffer; else const(ubyte)[] buffer;
	long offset;
	auto connect(Receiver)(return Receiver receiver) @safe return scope {
		return EpollBufferOp!(Receiver, receiving, reading, sending)(context, fd, buffer, offset, receiver);
	}
}

private struct EpollBufferOp(Receiver, bool receiving, bool reading, bool sending) {
	shared(EpollContextState) context;
	int fd;
	static if (receiving || reading) ubyte[] buffer; else const(ubyte)[] buffer;
	long offset;
	Receiver receiver;
	EpollBufferAction!(Receiver, receiving, reading, sending) action;
	@disable this(this);
	void start() @trusted nothrow scope {
		action.initialize(context, fd, buffer, offset, receiver);
		receiver = Receiver.init;
		context.push(&action.command);
	}
}

extern(C) int accept4(int, core.sys.posix.sys.socket.sockaddr*,
	core.sys.posix.sys.socket.socklen_t*, int) nothrow @nogc;

private struct EpollAcceptAction(Receiver) {
	ActionHeader header;
	CommandHeader command;
	CommandHeader cancelCommand;
	shared(EpollContextState) context;
	Receiver receiver;
	int fd;
	shared StopCallback stopCallback;
	bool terminal;
	bool started;
	core.sys.posix.sys.socket.sockaddr_storage address;
	core.sys.posix.sys.socket.socklen_t addressLength = address.sizeof;

	void initialize(shared(EpollContextState) context_, int fd_, Receiver receiver_) @trusted nothrow {
		context = context_; fd = fd_; receiver = receiver_;
		header.initialize(cast(void*) &this, fd, true, &retryHeader,
			&finishDoneHeader, &finishErrnoHeader, &finishPolicyHeader,
			&finishConflictHeader, &finishControlHeader);
		command.initialize(cast(void*) &this, &executeCommand, &cancelCommandCallback);
		cancelCommand.initialize(cast(void*) &this, &executeCancel, &cancelCancel);
	}
	private static bool executeCommand(void* owner) @trusted nothrow { return (cast(EpollAcceptAction*) owner).execute(); }
	private static void cancelCommandCallback(void* owner) @trusted nothrow { (cast(EpollAcceptAction*) owner).finishDone(); }
	private static bool executeCancel(void* owner) @trusted nothrow { (cast(EpollAcceptAction*) owner).finishDone(); return true; }
	private static void cancelCancel(void* owner) @trusted nothrow { (cast(EpollAcceptAction*) owner).finishDone(); }
	private static void retryHeader(void* owner) @trusted nothrow { (cast(EpollAcceptAction*) owner).retry(); }
	private static void finishDoneHeader(void* owner) @trusted nothrow { (cast(EpollAcceptAction*) owner).finishDone(); }
	private static void finishErrnoHeader(void* owner, int error) @trusted nothrow { (cast(EpollAcceptAction*) owner).finishErrno(error); }
	private static void finishPolicyHeader(void* owner) @trusted nothrow { (cast(EpollAcceptAction*) owner).finishPolicy(); }
	private static void finishConflictHeader(void* owner) @trusted nothrow { (cast(EpollAcceptAction*) owner).finishConflict(); }
	private static void finishControlHeader(void* owner, int error) @trusted nothrow { (cast(EpollAcceptAction*) owner).finishControl(error); }

	private bool execute() @trusted nothrow { started = true; auto token = receiver.getStopToken(); stopCallback.register(token, &(cast(shared) &this).onStop); if (token.isStopRequested) finishDone(); else if ((cast(EpollContextState) context).validateDescriptor(&header)) retry(); return false; }
	private void onStop() @trusted nothrow shared { context.push(cast(CommandHeader*) &cancelCommand); }
	private void retry() @trusted nothrow {
		if (terminal) return;
		import core.stdc.errno : errno, EINTR, EAGAIN, EWOULDBLOCK;
		import core.sys.posix.fcntl : O_NONBLOCK, O_CLOEXEC;
		int result;
		for (;;) { addressLength = address.sizeof; result = accept4(fd, cast(core.sys.posix.sys.socket.sockaddr*) &address, &addressLength, O_NONBLOCK | O_CLOEXEC); if (result < 0 && errno == EINTR) continue; break; }
		if (result >= 0) {
			import concurrency.ioscheduler : Client;
			import concurrency.io.socket : Socket;
			finishValue(Client(Socket(cast(socket_t) result), *cast(core.sys.posix.sys.socket.sockaddr*) &address, addressLength));
		} else if (errno == EAGAIN || errno == EWOULDBLOCK) { if (!header.armed) (cast(EpollContextState) context).attach(&header); }
		else finishErrno(errno);
	}
	private void prepareTerminal() @trusted nothrow { if (header.armed) (cast(EpollContextState) context).detached(&header); stopCallback.dispose(); if (started) (cast(EpollContextState) context).releaseLiveWork(); (cast(EpollContextState) context).retire(&header); }
	private void finishValue(T)(T value) @trusted nothrow { if (terminal) return; terminal = true; prepareTerminal(); auto receiver_ = receiver; receiver = Receiver.init; receiver_.setValueOrError(value); }
	private void finishDone() @trusted nothrow { if (terminal) return; terminal = true; prepareTerminal(); auto receiver_ = receiver; receiver = Receiver.init; receiver_.setDone(); }
	private void finishErrno(int error) @trusted nothrow { if (terminal) return; terminal = true; prepareTerminal(); auto receiver_ = receiver; receiver = Receiver.init; receiver_.setErrno("Accept failed", error); }
	private void finishPolicy() @trusted nothrow { finishException("epoll supports only nonblocking sockets and pipes"); }
	private void finishConflict() @trusted nothrow { finishException("epoll already has a read waiter for this descriptor"); }
	private void finishControl(int error) @trusted nothrow { finishErrno(error); }
	private void finishException(string message) @trusted nothrow { if (terminal) return; terminal = true; prepareTerminal(); auto receiver_ = receiver; receiver = Receiver.init; receiver_.setError(new Exception(message)); }
}

private struct EpollAcceptSender {
	alias Value = concurrency.ioscheduler.Client;
	shared(EpollContextState) context; int fd;
	auto connect(Receiver)(return Receiver receiver) @safe return scope { return EpollAcceptOp!Receiver(context, fd, receiver); }
}
private struct EpollAcceptOp(Receiver) {
	shared(EpollContextState) context; int fd; Receiver receiver; EpollAcceptAction!Receiver action; @disable this(this);
	void start() @trusted nothrow scope { action.initialize(context, fd, receiver); receiver = Receiver.init; context.push(&action.command); }
}

private struct EpollConnectAction(Receiver) {
	ActionHeader header; CommandHeader command; CommandHeader cancelCommand;
	shared(EpollContextState) context; Receiver receiver; int fd; shared StopCallback stopCallback; bool terminal; bool started;
	core.sys.posix.netinet.in_.sockaddr_in address;
	void initialize(shared(EpollContextState) context_, int fd_, string host, ushort port, Receiver receiver_) @trusted nothrow {
		import core.sys.posix.netinet.in_ : AF_INET, htons, ntohl, htonl, inet_addr, INADDR_NONE;
		import std.string : toStringz;
		context = context_; fd = fd_; receiver = receiver_;
		address.sin_family = AF_INET; address.sin_port = htons(port);
		auto numeric = ntohl(inet_addr(host.toStringz()));
		if (numeric == INADDR_NONE) address.sin_addr.s_addr = INADDR_NONE;
		else address.sin_addr.s_addr = htonl(numeric);
		header.initialize(cast(void*) &this, fd, false, &retryHeader,
			&finishDoneHeader, &finishErrnoHeader, &finishPolicyHeader,
			&finishConflictHeader, &finishControlHeader);
		command.initialize(cast(void*) &this, &executeCommand, &cancelCommandCallback);
		cancelCommand.initialize(cast(void*) &this, &executeCancel, &cancelCancel);
	}
	private static bool executeCommand(void* owner) @trusted nothrow { return (cast(EpollConnectAction*) owner).execute(); }
	private static void cancelCommandCallback(void* owner) @trusted nothrow { (cast(EpollConnectAction*) owner).finishDone(); }
	private static bool executeCancel(void* owner) @trusted nothrow { (cast(EpollConnectAction*) owner).finishDone(); return true; }
	private static void cancelCancel(void* owner) @trusted nothrow { (cast(EpollConnectAction*) owner).finishDone(); }
	private static void retryHeader(void* owner) @trusted nothrow { (cast(EpollConnectAction*) owner).retry(); }
	private static void finishDoneHeader(void* owner) @trusted nothrow { (cast(EpollConnectAction*) owner).finishDone(); }
	private static void finishErrnoHeader(void* owner, int error) @trusted nothrow { (cast(EpollConnectAction*) owner).finishErrno(error); }
	private static void finishPolicyHeader(void* owner) @trusted nothrow { (cast(EpollConnectAction*) owner).finishPolicy(); }
	private static void finishConflictHeader(void* owner) @trusted nothrow { (cast(EpollConnectAction*) owner).finishConflict(); }
	private static void finishControlHeader(void* owner, int error) @trusted nothrow { (cast(EpollConnectAction*) owner).finishControl(error); }
	private bool execute() @trusted nothrow { started = true; auto token = receiver.getStopToken(); stopCallback.register(token, &(cast(shared) &this).onStop); if (token.isStopRequested) finishDone(); else if ((cast(EpollContextState) context).validateDescriptor(&header)) retry(); return false; }
	private void onStop() @trusted nothrow shared { context.push(cast(CommandHeader*) &cancelCommand); }
	private void retry() @trusted nothrow {
		if (terminal) return;
		import core.stdc.errno : errno, EINTR, EINPROGRESS, EALREADY;
		import core.sys.posix.sys.socket : connect, getsockopt, SOL_SOCKET, SO_ERROR, socklen_t;
		int result, error; socklen_t size = error.sizeof;
		if (!header.armed) {
			for (;;) { result = connect(fd, cast(core.sys.posix.sys.socket.sockaddr*) &address, address.sizeof); if (result < 0 && errno == EINTR) continue; break; }
			if (result == 0) { finishValue(); return; }
			if (errno == EINPROGRESS || errno == EALREADY) { (cast(EpollContextState) context).attach(&header); return; }
			finishErrno(errno); return;
		}
		if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) < 0) { finishErrno(errno); return; }
		if (error == 0) finishValue(); else finishErrno(error);
	}
	private void prepareTerminal() @trusted nothrow { if (header.armed) (cast(EpollContextState) context).detached(&header); stopCallback.dispose(); if (started) (cast(EpollContextState) context).releaseLiveWork(); (cast(EpollContextState) context).retire(&header); }
	private void finishValue() @trusted nothrow { if (terminal) return; terminal = true; prepareTerminal(); auto receiver_ = receiver; receiver = Receiver.init; receiver_.setValueOrError(); }
	private void finishDone() @trusted nothrow { if (terminal) return; terminal = true; prepareTerminal(); auto receiver_ = receiver; receiver = Receiver.init; receiver_.setDone(); }
	private void finishErrno(int error) @trusted nothrow { if (terminal) return; terminal = true; prepareTerminal(); auto receiver_ = receiver; receiver = Receiver.init; receiver_.setErrno("Connect failed", error); }
	private void finishPolicy() @trusted nothrow { finishException("epoll supports only nonblocking sockets and pipes"); }
	private void finishConflict() @trusted nothrow { finishException("epoll already has a write waiter for this descriptor"); }
	private void finishControl(int error) @trusted nothrow { finishErrno(error); }
	private void finishException(string message) @trusted nothrow { if (terminal) return; terminal = true; prepareTerminal(); auto receiver_ = receiver; receiver = Receiver.init; receiver_.setError(new Exception(message)); }
}
private struct EpollConnectSender { alias Value = void; shared(EpollContextState) context; int fd; string address; ushort port; auto connect(Receiver)(return Receiver receiver) @safe return scope { return EpollConnectOp!Receiver(context, fd, address, port, receiver); } }
private struct EpollConnectOp(Receiver) { shared(EpollContextState) context; int fd; string address; ushort port; Receiver receiver; EpollConnectAction!Receiver action; @disable this(this); void start() @trusted nothrow scope { action.initialize(context, fd, address, port, receiver); receiver = Receiver.init; context.push(&action.command); } }

private struct EpollManagedRecvSender { alias Value = concurrency.io.buffer.ManagedBuffer; shared(EpollContextState) context; int fd; uint length; auto connect(Receiver)(return Receiver receiver) @safe return scope { return EpollManagedRecvOp!Receiver(context: context, fd: fd, length: length, receiver: receiver); } }
private struct EpollManagedRecvOp(Receiver) {
	ActionHeader header;
	CommandHeader command;
	CommandHeader cancelCommand;
	shared(EpollContextState) context;
	int fd;
	uint length;
	Receiver receiver;
	shared StopCallback stopCallback;
	bool terminal;
	bool started;

	@disable this(this);

	void start() @trusted nothrow scope {
		header.initialize(cast(void*) &this, fd, true, &retryHeader,
			&finishDoneHeader, &finishErrnoHeader, &finishPolicyHeader,
			&finishConflictHeader, &finishControlHeader);
		command.initialize(cast(void*) &this, &executeCommand, &cancelCommandCallback);
		cancelCommand.initialize(cast(void*) &this, &executeCancel, &cancelCancel);
		context.push(&command);
	}

	private static bool executeCommand(void* owner) @trusted nothrow {
		return (cast(EpollManagedRecvOp!Receiver*) owner).execute();
	}
	private static void cancelCommandCallback(void* owner) @trusted nothrow {
		(cast(EpollManagedRecvOp!Receiver*) owner).finishDone();
	}
	private static bool executeCancel(void* owner) @trusted nothrow {
		(cast(EpollManagedRecvOp!Receiver*) owner).finishDone();
		return true;
	}
	private static void cancelCancel(void* owner) @trusted nothrow {
		(cast(EpollManagedRecvOp!Receiver*) owner).finishDone();
	}
	private static void retryHeader(void* owner) @trusted nothrow {
		(cast(EpollManagedRecvOp!Receiver*) owner).retry();
	}
	private static void finishDoneHeader(void* owner) @trusted nothrow {
		(cast(EpollManagedRecvOp!Receiver*) owner).finishDone();
	}
	private static void finishErrnoHeader(void* owner, int error) @trusted nothrow {
		(cast(EpollManagedRecvOp!Receiver*) owner).finishErrno(error);
	}
	private static void finishPolicyHeader(void* owner) @trusted nothrow {
		(cast(EpollManagedRecvOp!Receiver*) owner).finishPolicy();
	}
	private static void finishConflictHeader(void* owner) @trusted nothrow {
		(cast(EpollManagedRecvOp!Receiver*) owner).finishConflict();
	}
	private static void finishControlHeader(void* owner, int error) @trusted nothrow {
		(cast(EpollManagedRecvOp!Receiver*) owner).finishControl(error);
	}

	private bool execute() @trusted nothrow {
		started = true;
		if (length > EpollBufferPool.slotSize) {
			finishException("epoll managed buffer request exceeds 4096-byte slot");
			return false;
		}
		auto token = receiver.getStopToken();
		stopCallback.register(token, &(cast(shared) &this).onStop);
		if (token.isStopRequested) finishDone();
		else if ((cast(EpollContextState) context).validateDescriptor(&header)) retry();
		// The initial command's live-work unit stays held until this operation terminates.
		return false;
	}
	private void onStop() @trusted nothrow shared {
		context.push(cast(CommandHeader*) &cancelCommand);
	}
	private void retry() @trusted nothrow {
		if (terminal) return;
		import core.stdc.errno : errno, EINTR, EAGAIN, EWOULDBLOCK;
		import core.sys.posix.sys.socket : recv;
		auto pool = (cast(EpollContextState) context).managedPool();
		auto base = pool.lease();
		if (base is null) { finishException("epoll managed buffer pool has no free slots"); return; }
		ptrdiff_t result;
		auto requested = length == 0 ? base.length : length;
		for (;;) {
			result = recv(fd, base.ptr, requested, 0);
			if (result < 0 && errno == EINTR) continue;
			break;
		}
		if (result > 0) {
			import concurrency.io.buffer : ManagedBuffer;
			auto sharedPool = cast(shared(EpollBufferPool)) pool;
			ManagedBuffer.Release release = &sharedPool.release;
			finishValue(ManagedBuffer.adopt(release, base, cast(uint) result));
			return;
		}
		(cast(shared(EpollBufferPool)) pool).release(base);
		if (result == 0) finishDone();
		else if (errno == EAGAIN || errno == EWOULDBLOCK) {
			if (!header.armed) (cast(EpollContextState) context).attach(&header);
		} else finishErrno(errno);
	}
	private void prepareTerminal() @trusted nothrow {
		if (header.armed) (cast(EpollContextState) context).detached(&header);
		stopCallback.dispose();
		if (started) (cast(EpollContextState) context).releaseLiveWork();
		(cast(EpollContextState) context).retire(&header);
	}
	private void finishValue(T)(return scope T value) @trusted nothrow {
		if (terminal) return;
		terminal = true;
		prepareTerminal();
		auto receiver_ = receiver;
		receiver = Receiver.init;
		receiver_.setValueOrError(value);
	}
	private void finishDone() @trusted nothrow {
		if (terminal) return;
		terminal = true;
		prepareTerminal();
		auto receiver_ = receiver;
		receiver = Receiver.init;
		receiver_.setDone();
	}
	private void finishErrno(int error) @trusted nothrow {
		if (terminal) return;
		terminal = true;
		prepareTerminal();
		auto receiver_ = receiver;
		receiver = Receiver.init;
		receiver_.setErrno("Receive failed", error);
	}
	private void finishPolicy() @trusted nothrow {
		finishException("epoll supports only nonblocking sockets and pipes");
	}
	private void finishConflict() @trusted nothrow {
		finishException("epoll already has a read waiter for this descriptor");
	}
	private void finishControl(int error) @trusted nothrow { finishErrno(error); }
	private void finishException(string message) @trusted nothrow {
		if (terminal) return;
		terminal = true;
		prepareTerminal();
		auto receiver_ = receiver;
		receiver = Receiver.init;
		receiver_.setError(new Exception(message));
	}
}

private struct EpollCloseSender { alias Value = void; shared(EpollContextState) context; int fd; auto connect(Receiver)(return Receiver receiver) @safe return scope { return EpollCloseOp!Receiver(context, fd, receiver); } }
private struct EpollCloseOp(Receiver) {
	shared(EpollContextState) context; int fd; Receiver receiver; CommandHeader command;
	@disable this(this);
	void start() @trusted nothrow scope { command.initialize(cast(void*) &this, &execute, &cancel); context.push(&command); }
	private static bool execute(void* owner) @trusted nothrow { finish(cast(EpollCloseOp!Receiver*) owner, false); return true; }
	private static void cancel(void* owner) @trusted nothrow { finish(cast(EpollCloseOp!Receiver*) owner, true); }
	private static void finish(EpollCloseOp!Receiver* op, bool cancelled) @trusted nothrow {
		auto context = cast(EpollContextState) op.context;
		context.closeDescriptor(op.fd); int error; auto result = context.closeOnce(op.fd, error);
		if (cancelled) op.receiver.setDone(); else if (result == 0) op.receiver.setValueOrError(); else op.receiver.setErrno("Close failed", error);
		op.receiver = Receiver.init;
	}
}

private struct EpollRunSender(Sender) {
	alias Value = Sender.Value;
	EpollContextState context;
	Sender sender;
	auto connect(Receiver)(return Receiver receiver) @trusted return scope {
		return EpollRunOp!(Sender, Receiver)(context, sender, receiver);
	}
}

private struct EpollRunOp(Sender, Receiver) {
	import concurrency : justFrom;
	import concurrency.sender : OpType, JustFromSender;
	import concurrency.operations.dofinally;
	import concurrency.operations.whenall;
	import concurrency.operations.withscheduler;
	import concurrency.operations.withioscheduler;

	alias LoopSender = JustFromSender!(void delegate() @trusted shared);
	alias SenderWithScheduler = WithSchedulerSender!(Sender, EpollScheduler);
	alias SenderWithIOScheduler = WithIOSchedulerSender!(SenderWithScheduler, EpollScheduler);
	alias Finalized = DoFinallySender!(SenderWithIOScheduler, void delegate() @safe nothrow shared);
	alias Combined = WhenAllSender!(Finalized, LoopSender);
	alias Op = OpType!(Combined, Receiver);

	EpollContextState context;
	Sender sender;
	Receiver receiver;
	shared StopSource stopSource;
	Op op;
	@disable this(this);
	this(EpollContextState context, Sender sender, return Receiver receiver) @trusted return scope {
		this.context = context;
		this.sender = sender;
		this.receiver = receiver;
	}
	void start() @trusted nothrow scope {
		import concurrency.sender : emplaceOperationalState;
		shared(EpollContextState) sharedContext = cast(shared) context;
		auto scheduler = EpollScheduler(sharedContext);
		auto combined = whenAll(
			sender.withScheduler(scheduler).withIOScheduler(scheduler).doFinally(&(cast(shared) this).stop),
			justFrom(&(cast(shared) this).drive),
		);
		op.emplaceOperationalState(combined, receiver);
		op.start();
	}
	private void stop() @safe nothrow shared {
		stopSource.stop();
		(cast(shared(EpollContextState)) context).wakeup();
	}
	private void drive() @trusted shared {
		import std.exception : ErrnoException;
		with (cast() this) {
			auto result = context.drive(stopSource.token());
			if (result < 0)
				throw new ErrnoException("epoll_wait failed", -result);
		}
	}
}
