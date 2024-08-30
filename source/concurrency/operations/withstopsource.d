module concurrency.operations.withstopsource;

import concurrency;
import concurrency.receiver;
import concurrency.sender;
import concurrency.stoptoken;
import concepts;
import std.traits;

// TODO: return scope?
auto withStopSource(Sender)(Sender sender, ref shared StopSource stopSource) @trusted {
	return SSSender!(Sender)(sender, &stopSource);
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

	auto getStopToken() nothrow @safe scope {
		return state.combinedStopSource.token();
	}

	mixin ForwardExtensionPoints!receiver;

	private void resetStopCallback() {
		state.left.dispose();
		state.right.dispose();
	}
}

struct SSState {
	shared StopSource combinedStopSource;
	shared StopCallback left;
	shared StopCallback right;
	~this() @safe scope @nogc nothrow {}
}

struct SSOp(Receiver, Sender) {
	SSState state;
	alias Op = OpType!(Sender, SSReceiver!(Receiver, Sender.Value));
	Op op;

	@disable
	this(ref return scope typeof(this) rhs);
	@disable
	this(this);

    @disable void opAssign(typeof(this) rhs) nothrow @safe @nogc;
    @disable void opAssign(ref typeof(this) rhs) nothrow @safe @nogc;

	~this() @trusted scope @nogc nothrow {}
	this(Receiver receiver, shared StopSource* outerStopSource, Sender sender) @trusted {
		auto token = receiver.getStopToken();
		auto outerToken = outerStopSource.token();

		state.left.register(token, cast(void delegate() @safe shared nothrow)&state.combinedStopSource.stop);
		state.right.register(outerToken, cast(void delegate() @safe shared nothrow)&state.combinedStopSource.stop);

		try {
			op = sender.connect(SSReceiver!(Receiver, Sender.Value)(receiver, &state));
		} catch (Exception e) {
			state.left.dispose();
			state.right.dispose();
			throw e;
		}
	}

	void start() @safe nothrow {
		// because we start op only afterwards, we can be sure that the cb's are created beforehand
		op.start();
	}
}

struct SSSender(Sender) if (models!(Sender, isSender)) {
	static assert(models!(typeof(this), isSender));
	alias Value = Sender.Value;
	Sender sender;
	shared StopSource* stopSource;
	auto connect(Receiver)(return Receiver receiver) @trusted return scope {
		// ensure NRVO
		auto op = SSOp!(Receiver, Sender)(receiver, stopSource, sender);
		return op;
	}
}
