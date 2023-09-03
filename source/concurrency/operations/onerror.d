module concurrency.operations.onerror;

import concurrency;
import concurrency.receiver;
import concurrency.sender;
import concurrency.stoptoken;
import concepts;

/// runs a side-effect whenever the underlying sender errors
auto onError(Sender, SideEffect)(Sender sender, SideEffect effect) {
	import concurrency.utils : isThreadSafeFunction;
	alias T = Exception;
	static assert(isThreadSafeFunction!SideEffect);
	return OnErrorSender!(Sender, SideEffect)(sender, effect);
}

private struct OnErrorReceiver(Value, SideEffect, Receiver) {
	Receiver receiver;
	SideEffect sideEffect;
	static if (is(Value == void))
		void setValue() @safe {
			receiver.setValue();
		}

	else
		void setValue(Value value) @safe {
			receiver.setValue(value);
		}

	void setDone() @safe nothrow {
		receiver.setDone();
	}

	void setError(Throwable t) @safe nothrow {
		if (auto e = cast(Exception) t) {
			try
				sideEffect(e);
			catch (Exception e2) {
				receiver.setError(() @trusted {
					return Throwable.chainTogether(e2, e);
				}());
				return;
			}
		}

		receiver.setError(t);
	}

	mixin ForwardExtensionPoints!receiver;
}

struct OnErrorSender(Sender, SideEffect) if (models!(Sender, isSender)) {
	static assert(models!(typeof(this), isSender));
	alias Value = Sender.Value;
	Sender sender;
	SideEffect effect;
	auto connect(Receiver)(return Receiver receiver) @safe return scope {
		// ensure NRVO
		auto op = sender.connect(OnErrorReceiver!(Sender.Value, SideEffect,
		                                          Receiver)(receiver, effect));
		return op;
	}
}
