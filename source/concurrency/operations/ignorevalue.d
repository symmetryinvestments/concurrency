module concurrency.operations.ignorevalue;

import concurrency;
import concurrency.receiver;
import concurrency.sender;
import concepts;

/// ignores the value and returns void
auto ignoreValue(Sender)(Sender sender) {
	return IgnoreValueSender!(Sender)(sender);
}

private struct IgnoreValueReceiver(Value, Receiver) {
	Receiver receiver;
	static if (is(Value == void))
		void setValue() @safe {
			receiver.setValue();
		}

	else
		void setValue(Value value) @safe {
			receiver.setValue();
		}

	void setDone() @safe nothrow {
		receiver.setDone();
	}

	void setError(Throwable t) @safe nothrow {
		receiver.setError(t);
	}

	mixin ForwardExtensionPoints!receiver;
}

struct IgnoreValueSender(Sender) if (models!(Sender, isSender)) {
	static assert(models!(typeof(this), isSender));
	alias Value = void;
	Sender sender;
	auto connect(Receiver)(return Receiver receiver) @safe return scope {
		// ensure NRVO
		auto op = sender.connect(
			IgnoreValueReceiver!(Sender.Value, Receiver)(receiver));
		return op;
	}
}
