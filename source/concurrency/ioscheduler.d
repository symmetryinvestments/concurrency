module concurrency.ioscheduler;

import concurrency.sender : SenderObjectBase, isSender;
import core.time : Duration;
import std.typecons : Nullable, nullable;

void checkIOScheduler(T)() {
	import concurrency.sender : checkSender;
	import core.time : msecs;
	import std.traits : ReturnType;
	alias ReadSender = ReturnType!(T.read);
	checkSender!ReadSender();
	// TODO: add other function checks
}

enum isIOScheduler(T) = is(typeof(checkIOScheduler!T));

struct Client {
	import std.socket : socket_t;
	version(Windows) {
		import core.sys.windows.windows : sockaddr, socklen_t;
	} else version(Posix) {
		import core.sys.posix.sys.socket : sockaddr, socklen_t;
	}

	socket_t fd;
	sockaddr addr;
	socklen_t addrlen;
}

/// polymorphic IOScheduler
interface IOSchedulerObjectBase {
	import std.socket : socket_t;
	// TODO: read/write/close aren't just for sockets really
	SenderObjectBase!(ubyte[]) read(socket_t fd, return ubyte[] buffer, long offset = 0) @safe;
	SenderObjectBase!(Client) accept(socket_t fd) @safe;
	SenderObjectBase!(socket_t) connect(socket_t fd, return string address, ushort port) @safe;
	SenderObjectBase!(int) write(socket_t fd, return const(ubyte)[] buffer, long offset = 0) @safe;
	SenderObjectBase!(void) close(socket_t fd) @safe;
}

struct NullIOScheduler {
	import std.socket : socket_t;
	import concurrency.sender : ValueSender;

	string errorMsg;

	ValueSender!(ubyte[]) read(socket_t fd, return ubyte[] buffer, long offset = 0) @safe {
		throw new Exception(errorMsg);
	}
	ValueSender!(Client) accept(socket_t fd) @safe {
		throw new Exception(errorMsg);
	}
	ValueSender!(socket_t) connect(socket_t fd, return string address, ushort port) @safe {
		throw new Exception(errorMsg);
	}
	ValueSender!(int) write(socket_t fd, return const(ubyte)[] buffer, long offset = 0) @safe {
		throw new Exception(errorMsg);
	}
	ValueSender!(void) close(socket_t fd) @safe {
		throw new Exception(errorMsg);
	}
}

class IOSchedulerObject(S) : IOSchedulerObjectBase {
	import concurrency.sender : toSenderObject;
	S scheduler;
	this(S scheduler) {
		this.scheduler = scheduler;
	}

	SenderObjectBase!(ubyte[]) read(socket_t fd, return ubyte[] buffer, long offset = 0) @safe {
		return scheduler.read(fd, buffer, offset).toSenderObject();
	}
	SenderObjectBase!(Client) accept(socket_t fd) @safe {
		return scheduler.accept(fd).toSenderObject();
	}
	// TODO: is trusted because of scope string address
	SenderObjectBase!(socket_t) connect(socket_t fd, return string address, ushort port) @trusted {
		string adr = address;
		return scheduler.connect(fd, adr, port).toSenderObject();
	}
	SenderObjectBase!(int) write(socket_t fd, return const(ubyte)[] buffer, long offset = 0) @safe {
		return scheduler.write(fd, buffer, offset).toSenderObject();
	}
	SenderObjectBase!(void) close(socket_t fd) @safe {
		return scheduler.close(fd).toSenderObject();
	}
}

IOSchedulerObjectBase toIOSchedulerObject(S)(S scheduler) {
	return new IOSchedulerObject!(S)(scheduler);
}
