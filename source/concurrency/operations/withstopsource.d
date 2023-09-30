module concurrency.operations.withstopsource;

import concurrency;
import concurrency.receiver;
import concurrency.sender;
import concurrency.stoptoken;
import concepts;
import std.traits;

template withStopSource(Sender) {
	auto withStopSource(Sender sender, StopSource stopSource) {
		return SSSender!(Sender, StopSource)(sender, stopSource);
	}

	auto withStopSource(Sender sender, shared StopSource stopSource) @trusted {
		return SSSender!(Sender, StopSource)(sender, cast() stopSource);
	}

	auto withStopSource(Sender sender, ref shared InPlaceStopSource stopSource) @trusted {
		return SSSender!(Sender, shared InPlaceStopSource*)(sender, &stopSource);
	}
}

private struct SSReceiver(Receiver, Value) {
	private {
		Receiver receiver;
		SSState* state;
	}

	static if (is(Value == void)) {
		void setValue() @safe {
			resetStopCallback();
			receiver.setValueOrError();
		}
	} else {
		void setValue(Value value) @safe {
			resetStopCallback();
			receiver.setValueOrError(value);
		}
	}

	void setDone() @safe nothrow {
		resetStopCallback();
		receiver.setDone();
	}

	// TODO: would be good if we only emit this function in the Sender actually could call it
	void setError(Throwable e) @safe nothrow {
		resetStopCallback();
		receiver.setError(e);
	}

	auto getStopToken() nothrow @trusted scope {
		return StopToken(state.combinedStopSource);
	}

	mixin ForwardExtensionPoints!receiver;

	private void resetStopCallback() {
		state.cbs[0].dispose();
		state.cbs[1].dispose();
	}
}

struct SSState {
	shared InPlaceStopSource combinedStopSource;
	StopCallback[2] cbs;
}

struct SSOp(Receiver, OuterStopSource, Sender) {
	SSState state;
	alias Op = OpType!(Sender, SSReceiver!(Receiver, Sender.Value));
	Op op;

	@disable
	this(ref return scope typeof(this) rhs);
	@disable
	this(this);
	this(Receiver receiver, OuterStopSource outerStopSource, Sender sender) @trusted {
		state.cbs[0] = receiver.getStopToken().onStop(cast(void delegate() shared @safe nothrow)&state.combinedStopSource.stop);
		static if (is(OuterStopSource == shared InPlaceStopSource*)) {
			state.cbs[1] = onStop(*outerStopSource, cast(void delegate() shared @safe nothrow)&state.combinedStopSource.stop);
		} else {
			state.cbs[1] = outerStopSource.onStop(cast(void delegate() shared @safe nothrow)&state.combinedStopSource.stop);
		}

		try {
		op = sender.connect(SSReceiver!(Receiver, Sender.Value)(receiver, &state));
		} catch (Exception e) {
			state.cbs[0].dispose();
			state.cbs[1].dispose();
			throw e;
		}
	}

	void start() @safe nothrow {
		// because we start op only afterwards, we can be sure that the cb's are created beforehand
		op.start();
	}
}

struct SSSender(Sender, StopSource) if (models!(Sender, isSender)) {
	static assert(models!(typeof(this), isSender));
	alias Value = Sender.Value;
	Sender sender;
	StopSource stopSource;
	auto connect(Receiver)(return Receiver receiver) @trusted return scope {
		// ensure NRVO
		auto op = SSOp!(Receiver, StopSource, Sender)(receiver, stopSource, sender);
		return op;
	}
}
