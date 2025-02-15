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

		static auto construct() {
			return State(LocalThreadWorker(getLocalThreadExecutor()));
		}
	}

	State* state;
	shared StopSource* stopSource;
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
		return stopSource.token();
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

	alias V = SumType!(Value, Cancelled, Exception);
	
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

	auto trustedGet(T)() {
		return std.sumtype.match!((T t) => t, function T(x) { assert(0, "nah"); })(result);
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
auto syncWait(Sender)(auto ref Sender sender,
					  shared ref StopSource stopSource) {
	return syncWaitImpl(sender, stopSource);
}

auto syncWait(Sender)(auto scope ref Sender sender) @trusted {
	import concurrency.signal : globalStopSource;
	shared StopSource childStopSource;
	shared parentStopToken = globalStopSource.token();
	shared StopCallback cb;
	cb.register(parentStopToken, () shared {
		childStopSource.stop();
	});

	try {
		auto result = syncWaitImpl(sender, childStopSource);

		version (unittest) childStopSource.assertNoCallbacks;
		// detach stopSource
		cb.dispose();
		return result;
	} catch (Throwable t) { // @suppress(dscanner.suspicious.catch_em_all)
		cb.dispose();
		throw t;
	}
}

private
Result!(Sender.Value) syncWaitImpl(Sender)(auto scope ref Sender sender,
                                           ref shared StopSource stopSource) @safe {
	static assert(models!(Sender, isSender));
	import concurrency.signal;
	import core.stdc.signal : SIGTERM, SIGINT;

	alias Value = Sender.Value;
	alias Receiver = SyncWaitReceiver2!(Value);

	auto state = Receiver.State.construct;
	scope receiver = (() @trusted => Receiver(&state, &stopSource))();
	auto op = sender.connect(receiver);
	op.start();

	state.worker.start();

	if (state.canceled)
		return Result!Value(Cancelled());

	if (state.throwable !is null) {
		if (auto e = cast(Exception) state.throwable)
			return Result!Value(e);
		auto throwable = (() @trusted => state.throwable)();
		throw throwable;
	}

	static if (is(Value == void))
		return Result!Value(Completed());
	else
		return Result!Value(state.result);
}
