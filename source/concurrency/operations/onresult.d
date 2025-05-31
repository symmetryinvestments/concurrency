module concurrency.operations.onresult;

import concurrency;
import concurrency.receiver;
import concurrency.sender;
import concurrency.stoptoken;
import concurrency.utils;

/// runs a side-effect whenever the underlying sender completes with value or cancellation
auto onResult(Sender, SideEffect)(Sender sender, SideEffect effect) {
	import concurrency.utils : isThreadSafeFunction;
	static assert(isThreadSafeFunction!SideEffect);
	return OnResultSender!(Sender, SideEffect)(sender, effect);
}

alias tee = onResult;

private struct OnResultReceiver(Value, SideEffect, Receiver) {
	Receiver receiver;
	SideEffect sideEffect;
	static if (is(Value == void))
		void setValue() @safe {
			sideEffect(Result!void());
			receiver.setValue();
		}

	else
		void setValue(Value value) @safe {
			sideEffect(Result!(Value)(value));
			receiver.setValue(value.copyOrMove);
		}

	void setDone() @trusted nothrow {
		try {
			sideEffect(Result!(Value)(Cancelled()));
		} catch (Throwable t) {
			return receiver.setError(t);
		}

		receiver.setDone();
	}

	void setError(Throwable e) @trusted nothrow {
		if (auto ex = cast(Exception) e) {
			try {
				sideEffect(Result!(Value)(ex));
			} catch (Exception e2) {
				return receiver.setError(() @trusted {
					return Throwable.chainTogether(e2, e);
				}());
			} catch (Throwable t) {
				return receiver.setError(t);
			}
		}

		receiver.setError(e);
	}

	mixin ForwardExtensionPoints!receiver;
}

struct OnResultSender(Sender, SideEffect) {
	alias Value = Sender.Value;
	Sender sender;
	SideEffect effect;
	auto connect(Receiver)(return Receiver receiver) @safe return scope {
		// ensure NRVO
		auto op = sender.connect(OnResultReceiver!(Sender.Value, SideEffect,
		                                           Receiver)(receiver, effect));
		return op;
	}
}
