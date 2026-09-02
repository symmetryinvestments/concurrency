module concurrency.receiver;

import concepts;

/// checks that T is a Receiver
void checkReceiver(T)() {
	T t = T.init;
	import std.traits;
	alias Params = Parameters!(T.setValue);
	static if (Params.length == 0)
		t.setValue();
	else
		t.setValue(Params[0].init);
	(() nothrow => t.setDone())();
	(() nothrow => t.setError(new Throwable("test")))();
}

enum isReceiver(T) = is(typeof(checkReceiver!T));

mixin template ForwardExtensionPoints(alias receiver) {
	auto getStopToken() nothrow @safe {
		return receiver.getStopToken();
	}

	auto getScheduler() nothrow @safe {
		return receiver.getScheduler();
	}

	static if (__traits(compiles, receiver.getIOScheduler())) {
		auto getIOScheduler() nothrow @safe {
			return receiver.getIOScheduler();
		}
	}
}

/// A polymorphic receiver of type T
interface ReceiverObjectBase(T) {
	import concurrency.stoptoken : StopToken;
	import concurrency.scheduler : SchedulerObjectBase;
	import concurrency.ioscheduler : IOSchedulerObjectBase;
	static assert(models!(ReceiverObjectBase!T, isReceiver));
	static if (is(T == void))
		void setValue() @safe;
	else
		void setValue(T value = T.init) @safe;
	void setDone() nothrow @safe;
	void setError(Throwable e) nothrow @safe;
	shared(StopToken) getStopToken() nothrow @safe;
	SchedulerObjectBase getScheduler() scope nothrow @safe;
	IOSchedulerObjectBase getIOScheduler() scope nothrow @safe;
}

struct NullReceiver(T) {
	void setDone() nothrow @safe @nogc {}

	void setError(Throwable e) nothrow @safe @nogc {}

	static if (is(T == void))
		void setValue() nothrow @safe @nogc {}

	else
		void setValue(T t) nothrow @safe @nogc {}
}

struct ThrowingNullReceiver(T) {
	void setDone() nothrow @safe @nogc {}

	void setError(Throwable e) nothrow @safe @nogc {}

	static if (is(T == void))
		void setValue() @safe {
			throw new Exception("ThrowingNullReceiver");
		}

	else
		void setValue(T t) @safe {
			throw new Exception("ThrowingNullReceiver");
		}
}

void setValueOrError(Receiver)(auto ref Receiver receiver) @trusted {
	import std.traits;
	static if (hasFunctionAttributes!(receiver.setValue, "nothrow")) {
		receiver.setValue();
	} else {
		try {
			receiver.setValue();
		} catch (Exception e) {
			receiver.setError(e);
		} catch (Throwable t) {
	        import concurrency.error : clone;
			receiver.setError(t.clone);
		}
	}
}

void setValueOrError(Receiver, T)(auto ref Receiver receiver,
                                  T value) @trusted {
	return setValueOrError(receiver, value);
}

void setValueOrError(Receiver, T)(auto ref Receiver receiver,
                                  ref T value) @trusted {
	import std.algorithm : move;
	import std.traits;
	static if (hasFunctionAttributes!(receiver.setValue, "nothrow")) {
		receiver.setValue(value);
	} else {
		try {
			receiver.setValue(value);
		} catch (Exception e) {
			receiver.setError(e);
		} catch (Throwable t) {
	        import concurrency.error : clone;
			receiver.setError(t.clone);
		}
	}
}

void setErrno(Receiver)(ref Receiver receiver, string msg, int n) @trusted nothrow {
    import std.exception : ErrnoException;
	try {
		receiver.setError(new ErrnoException(msg, n));
	} catch (Exception e) {
		receiver.setError(e);
	} catch (Throwable e) {
		receiver.setError(e);
	}
}
