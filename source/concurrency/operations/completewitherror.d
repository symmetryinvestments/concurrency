module concurrency.operations.completewitherror;

import concurrency;
import concurrency.receiver;
import concurrency.sender;
import concepts;
import std.traits;

auto completeWithError(Sender)(Sender sender, Throwable t) {
	return CompleteWithErrorSender!(Sender)(sender, t);
}

template isA(T) if (is(T == class)) {
	bool isA(P)(auto ref P p) if (is(P == class)) {
		return cast(T) p !is null;
	}
}

template isNotA(T) if (is(T == class)) {
	bool isNotA(P)(auto ref P p) {
		return !p.isA!T;
	}
}

private struct CompleteWithErrorReceiver(Receiver) {
	Receiver receiver;
	Throwable error;
	void setValue() nothrow @safe {
		receiver.setError(error);
	}

	void setValue(T)(auto ref T t) nothrow @safe {
		receiver.setError(error);
	}

	void setDone() nothrow @safe {
		receiver.setError(error);
	}

	void setError(Throwable e) nothrow @safe {
		if (error.isA!Exception && e.isNotA!Exception) {
			// if e is a throwable and t just a regular exception, forward throwable
			receiver.setError(e);
			return;
		}

		receiver.setError(error);
	}

	mixin ForwardExtensionPoints!receiver;
}

struct CompleteWithErrorSender(Sender) if (models!(Sender, isSender)) {
	static assert(models!(typeof(this), isSender));
	alias Value = Sender.Value;
	Sender sender;
	Throwable t;
	auto connect(Receiver)(return Receiver receiver) @safe return scope {
		/// ensure NRVO
		auto op =
			sender.connect(CompleteWithErrorReceiver!(Receiver)(receiver, t));
		return op;
	}
}
