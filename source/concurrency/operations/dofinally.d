module concurrency.operations.dofinally;

import concurrency;
import concurrency.receiver;
import concurrency.sender;
import concurrency.stoptoken;
import concepts;

/// runs a side-effect whenever the underlying sender completes
auto doFinally(Sender, SideEffect)(Sender sender, SideEffect effect) {
	import concurrency.utils : isThreadSafeFunction;
	static assert(isThreadSafeFunction!SideEffect);
	return DoFinallySender!(Sender, SideEffect)(sender, effect);
}

private struct DoFinallyReceiver(Value, SideEffect, Receiver) {
	Receiver receiver;
	SideEffect sideEffect;
	static if (is(Value == void))
		// TODO: mustn't this be nothrow?
		void setValue() @safe {
			sideEffect();
			receiver.setValue();
		}

	else
		void setValue(Value value) @safe {
			sideEffect();
			receiver.setValue(value);
		}

	void setDone() @safe nothrow {
		sideEffect();
		receiver.setDone();
	}

	void setError(Throwable t) @safe nothrow {
		sideEffect();
		receiver.setError(t);
	}

	mixin ForwardExtensionPoints!receiver;
}

struct DoFinallySender(Sender, SideEffect) if (models!(Sender, isSender)) {
	alias Value = Sender.Value;
	Sender sender;
	SideEffect effect;
	auto connect(Receiver)(return Receiver receiver) @safe return scope {
		// ensure NRVO
		auto op = sender.connect(
			DoFinallyReceiver!(Sender.Value, SideEffect, Receiver)(receiver,
			                                                          effect));
		return op;
	}
}
