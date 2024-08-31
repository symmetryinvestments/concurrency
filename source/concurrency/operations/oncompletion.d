module concurrency.operations.oncompletion;

import concurrency;
import concurrency.receiver;
import concurrency.sender;
import concurrency.stoptoken;
import concepts;

/// runs a side-effect whenever the underlying sender completes with value or cancellation
auto onCompletion(Sender, SideEffect)(Sender sender, SideEffect effect) {
	import concurrency.utils : isThreadSafeFunction;
	static assert(isThreadSafeFunction!SideEffect);
	return OnCompletionSender!(Sender, SideEffect)(sender, effect);
}

private struct OnCompletionReceiver(Value, SideEffect, Receiver) {
	Receiver receiver;
	SideEffect sideEffect;
	static if (is(Value == void))
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

	void setError(Throwable e) @safe nothrow {
		receiver.setError(e);
	}

	mixin ForwardExtensionPoints!receiver;
}

struct OnCompletionSender(Sender, SideEffect) if (models!(Sender, isSender)) {
	alias Value = Sender.Value;
	Sender sender;
	SideEffect effect;
	auto connect(Receiver)(return Receiver receiver) @safe return scope {
		// ensure NRVO
		auto op = sender.connect(
			OnCompletionReceiver!(Sender.Value, SideEffect, Receiver)(receiver,
			                                                          effect));
		return op;
	}
}
