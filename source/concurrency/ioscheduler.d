module concurrency.ioscheduler;

import concurrency.sender : SenderObjectBase, isSender;
import concurrency.io.buffer : ManagedBuffer;
import core.time : Duration;
import concepts;
import std.typecons : Nullable, nullable;
import concurrency.io.socket : Socket;

void checkIOScheduler(T)() {
	import concurrency.sender : checkSender;
	import std.socket : socket_t;
	T t = T.init;
	alias RecvSender = typeof(t.recv(socket_t.init, uint.init));
	alias RecvBufferSender = typeof(t.recv(socket_t.init, ubyte[].init, long.init));
	alias ReadSender = typeof(t.read(socket_t.init, ubyte[].init, long.init));
	alias AcceptSender = typeof(t.accept(socket_t.init));
	alias ConnectSender = typeof(t.connect(socket_t.init, string.init, ushort.init));
	alias SendSender = typeof(t.send(socket_t.init, const(ubyte[]).init));
	alias WriteSender = typeof(t.write(socket_t.init, const(ubyte[]).init, long.init));
	alias CloseSender = typeof(t.close(socket_t.init));
	alias NopSender = typeof(t.nop());
	static assert(is(RecvSender.Value == ManagedBuffer));
	static assert(is(RecvBufferSender.Value == ubyte[]));
	static assert(is(ReadSender.Value == ubyte[]));
	static assert(is(AcceptSender.Value == Client));
	static assert(is(ConnectSender.Value == void));
	static assert(is(SendSender.Value == int));
	static assert(is(WriteSender.Value == int));
	static assert(is(CloseSender.Value == void));
	static assert(is(NopSender.Value == int));
	checkSender!RecvSender();
	checkSender!RecvBufferSender();
	checkSender!ReadSender();
	checkSender!AcceptSender();
	checkSender!ConnectSender();
	checkSender!SendSender();
	checkSender!WriteSender();
	checkSender!CloseSender();
	checkSender!NopSender();
}

enum isIOScheduler(T) = is(typeof(checkIOScheduler!T));

struct Client {
	version(Windows) {
		import core.sys.windows.windows : sockaddr, socklen_t;
	} else version(Posix) {
		import core.sys.posix.sys.socket : sockaddr, socklen_t;
	}

	Socket socket;
	sockaddr addr;
	socklen_t addrlen;
}

/// polymorphic IOScheduler
interface IOSchedulerObjectBase {
	import std.socket : socket_t;
	SenderObjectBase!(ManagedBuffer) recv(socket_t fd, uint len = 0) @safe;
	SenderObjectBase!(ubyte[]) recv(socket_t fd, return ubyte[] buffer, long len = 0) @safe;
	// TODO: read/write aren't just for sockets really
	SenderObjectBase!(ubyte[]) read(socket_t fd, return ubyte[] buffer, long len = 0) @safe;
	SenderObjectBase!(Client) accept(socket_t fd) @safe;
	SenderObjectBase!(void) connect(socket_t fd, return string address, ushort port) @safe;
	SenderObjectBase!(int) send(socket_t fd, return const(ubyte)[] buffer) @safe;
	SenderObjectBase!(int) write(socket_t fd, return const(ubyte)[] buffer, long offset = 0) @safe;
	SenderObjectBase!(void) close(socket_t fd) @safe;
	SenderObjectBase!(int) nop() @safe;
}

struct NullIOScheduler {
	import std.socket : socket_t;
	import concurrency.sender : ValueSender, VoidSender;

	string errorMsg;

	ValueSender!(ManagedBuffer) recv(socket_t fd, long len = 0) @safe {
		throw new Exception(errorMsg);
	}
	ValueSender!(ubyte[]) recv(socket_t fd, return ubyte[] buffer, long len = 0) @safe {
		throw new Exception(errorMsg);
	}
	ValueSender!(ubyte[]) read(socket_t fd, return ubyte[] buffer, long len = 0) @safe {
		throw new Exception(errorMsg);
	}
	SenderObjectBase!(Client) accept(socket_t fd) @safe {
		throw new Exception(errorMsg);
	}
	ValueSender!(void) connect(socket_t fd, return string address, ushort port) @safe {
		throw new Exception(errorMsg);
	}
	ValueSender!(int) send(socket_t fd, return const(ubyte)[] buffer) @safe {
		throw new Exception(errorMsg);
	}
	ValueSender!(int) write(socket_t fd, return const(ubyte)[] buffer, long offset = 0) @safe {
		throw new Exception(errorMsg);
	}
	ValueSender!(void) close(socket_t fd) @safe {
		throw new Exception(errorMsg);
	}
	ValueSender!int nop() @safe {
		throw new Exception(errorMsg);
	}
}

class IOSchedulerObject(S) : IOSchedulerObjectBase {
	import concurrency.sender : toSenderObject;
	S scheduler;
	this(S scheduler) {
		this.scheduler = scheduler;
	}

	SenderObjectBase!(ManagedBuffer) recv(socket_t fd, uint len = 0) @safe {
		static if (is(S == NullIOScheduler)) {
			// NullIOScheduler.recv always throws and cannot erase a move-only value.
			scheduler.recv(fd, len);
			assert(0);
		} else
			return scheduler.recv(fd, len).toSenderObject();
	}
	SenderObjectBase!(ubyte[]) recv(socket_t fd, return ubyte[] buffer, long len = 0) @safe {
		return scheduler.recv(fd, buffer, len).toSenderObject();
	}
	SenderObjectBase!(ubyte[]) read(socket_t fd, return ubyte[] buffer, long len = 0) @safe {
		return scheduler.read(fd, buffer, len).toSenderObject();
	}
	SenderObjectBase!(Client) accept(socket_t fd) @safe {
		return scheduler.accept(fd).toSenderObject();
	}
	// TODO: is trusted because of scope string address
	SenderObjectBase!(void) connect(socket_t fd, return string address, ushort port) @trusted {
		string adr = address;
		return scheduler.connect(fd, adr, port).toSenderObject();
	}
	SenderObjectBase!(int) send(socket_t fd, return const(ubyte)[] buffer) @safe {
		return scheduler.send(fd, buffer).toSenderObject();
	}
	SenderObjectBase!(int) write(socket_t fd, return const(ubyte)[] buffer, long offset = 0) @safe {
		return scheduler.write(fd, buffer, offset).toSenderObject();
	}
	SenderObjectBase!(void) close(socket_t fd) @safe {
		return scheduler.close(fd).toSenderObject();
	}
	SenderObjectBase!(int) nop() @safe {
		return scheduler.nop().toSenderObject();
	}
}

IOSchedulerObjectBase toIOSchedulerObject(S)(S scheduler) {
	return new IOSchedulerObject!(S)(scheduler);
}
