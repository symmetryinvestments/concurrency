module concurrency.operations.ontermination;

import concurrency;
import concurrency.receiver;
import concurrency.sender;
import concurrency.stoptoken;
import concurrency.utils;

/// runs a side-effect whenever the underlying sender terminates
auto onTermination(Sender, SideEffect)(Sender sender, SideEffect effect) {
	import concurrency.utils : isThreadSafeFunction;
	static assert(isThreadSafeFunction!SideEffect);
	return OnTerminationSender!(Sender, SideEffect)(sender, effect);
}

private struct OnTerminationReceiver(Value, SideEffect, Receiver) {
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
			receiver.setValue(value.copyOrMove);
		}

	void setDone() @safe nothrow {
		sideEffect();
		receiver.setDone();
	}

	void setError(Throwable e) @safe nothrow {
		sideEffect();
		receiver.setError(e);
	}

	mixin ForwardExtensionPoints!receiver;
}

struct OnTerminationSender(Sender, SideEffect) {
	alias Value = Sender.Value;
	Sender sender;
	SideEffect effect;
	auto connect(Receiver)(return Receiver receiver) @safe return scope {
		// ensure NRVO
		auto op = sender.connect(
			OnTerminationReceiver!(Sender.Value, SideEffect, Receiver)(receiver,
			                                                           effect));
		return op;
	}
}
