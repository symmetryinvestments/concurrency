module concurrency.operations.completewithcancellation;

import concurrency;
import concurrency.receiver;
import concurrency.sender;
import concepts;
import std.traits;

auto completeWithCancellation(Sender)(Sender sender) {
	return CompleteWithCancellationSender!(Sender)(sender);
}

private struct CompleteWithCancellationReceiver(Receiver) {
	Receiver receiver;
	void setValue() nothrow @safe {
		receiver.setDone();
	}

	void setDone() nothrow @safe {
		receiver.setDone();
	}

	void setError(Throwable e) nothrow @safe {
		receiver.setError(e);
	}

	mixin ForwardExtensionPoints!receiver;
}

struct CompleteWithCancellationSender(Sender) if (models!(Sender, isSender)) {
	static assert(
		is(Sender.Value == void),
		"Sender must produce void to be able to complete with cancellation."
	);
	alias Value = void;
	Sender sender;
	auto connect(Receiver)(return Receiver receiver) @safe return scope {
		/// ensure NRVO
		auto op = sender
			.connect(CompleteWithCancellationReceiver!(Receiver)(receiver));
		return op;
	}
}
