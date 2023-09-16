module concurrency.syncwait;

import concurrency.stoptoken;
import concurrency.sender;
import concurrency.thread;
import concepts;
import std.sumtype;

bool isMainThread() @trusted {
	import core.thread : Thread;
	return Thread.getThis().isMainThread();
}

package struct SyncWaitReceiver2(Value) {
	static struct State {
		LocalThreadWorker worker;
		bool canceled;
		static if (!is(Value == void))
			Value result;
		Throwable throwable;
		StopSource stopSource;

		this(StopSource stopSource) {
			this.stopSource = stopSource;
			worker = LocalThreadWorker(getLocalThreadExecutor());
		}
	}

	State* state;
	void setDone() nothrow @safe {
		state.canceled = true;
		state.worker.stop();
	}

	void setError(Throwable e) nothrow @safe {
		state.throwable = e;
		state.worker.stop();
	}

	static if (is(Value == void))
		void setValue() nothrow @safe {
			state.worker.stop();
		}

	else
		void setValue(Value value) nothrow @trusted {
			state.result = value;
			state.worker.stop();
		}

	auto getStopToken() nothrow @safe @nogc {
		return StopToken(state.stopSource);
	}

	auto getScheduler() nothrow @safe {
		import concurrency.scheduler : SchedulerAdapter;
		return SchedulerAdapter!(LocalThreadWorker*)(&state.worker);
	}
}

struct Cancelled {
}

template isA(T) {
	bool isA(S)(ref S s) if (isSumType!S) {
		return std.sumtype.match!((ref T t) => true, x => false)(s);
	}
}

struct Completed {
}

struct Result(T) {
	static if (is(T == void)) {
		alias Value = Completed;
	} else {
		alias Value = T;
	}

	alias V = SumType!(Cancelled, Exception, Value);
	
	V result;
	this(P)(P p) {
		result = p;
	}

	bool isCancelled() {
		return result.isA!Cancelled;
	}

	bool isError() {
		return result.isA!Exception;
	}

	bool isOk() {
		return result.isA!Value;
	}

	auto value() {
		static if (is(T == void))
			alias valueHandler = (Completed c) {};
		else
			alias valueHandler = (T t) => t;

		return std.sumtype.match!(valueHandler, function T(Cancelled C) {
			throw new Exception("Cancelled");
		},
		function T(Exception e) {
			throw e;
		})(result);
	}

	auto get(T)() {
		return std.sumtype.match!((T t) => t, function T(x) { throw new Exception("Unexpected value"); })(result);
	}

	auto assumeOk() {
		return value();
	}
}

/// matches over the result of syncWait
template match(Handlers...) {
	// has to be separate because of dual-context limitation
	auto match(T)(Result!T r) {
		return std.sumtype.match!(Handlers)(r.result);
	}
}

/// Start the Sender and waits until it completes, cancels, or has an error.
auto syncWait(Sender, StopSource)(auto ref Sender sender,
                                  StopSource stopSource) {
	return syncWaitImpl(sender, (() @trusted => cast() stopSource)());
}

auto syncWait(Sender)(auto scope ref Sender sender) {
	import concurrency.signal : globalStopSource;
	auto childStopSource = new shared StopSource();
	auto cb = InPlaceStopCallback(() shared {
		childStopSource.stop();
	});
	StopToken parentStopToken = StopToken(globalStopSource);
	// parentStopToken.onStop(cb);
	auto result =
		syncWaitImpl(sender, (() @trusted => cast() childStopSource)());
	// detach stopSource
	cb.dispose();
	return result;
}

private
Result!(Sender.Value) syncWaitImpl(Sender)(auto scope ref Sender sender,
                                           StopSource stopSource) @safe {
	static assert(models!(Sender, isSender));
	import concurrency.signal;
	import core.stdc.signal : SIGTERM, SIGINT;

	alias Value = Sender.Value;
	alias Receiver = SyncWaitReceiver2!(Value);

	auto state = Receiver.State(stopSource);
	scope receiver = (() @trusted => Receiver(&state))();
	auto op = sender.connect(receiver);
	op.start();

	state.worker.start();

	if (state.canceled)
		return Result!Value(Cancelled());

	if (state.throwable !is null) {
		if (auto e = cast(Exception) state.throwable)
			return Result!Value(e);
		throw state.throwable;
	}

	static if (is(Value == void))
		return Result!Value(Completed());
	else
		return Result!Value(state.result);
}
