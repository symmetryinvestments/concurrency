module concurrency.operations.ignoreerror;

import concurrency;
import concurrency.receiver;
import concurrency.sender;
import concurrency.stoptoken;
import std.traits;

IESender!Sender ignoreError(Sender)(Sender sender) {
	return IESender!Sender(sender);
}

struct IESender(Sender) {
	alias Value = Sender.Value;
	Sender sender;
	auto connect(Receiver)(return Receiver receiver) @safe return scope {
		// ensure NRVO
		auto op = sender.connect(IEReceiver!(Sender.Value, Receiver)(receiver));
		return op;
	}
}

private struct IEReceiver(Value, Receiver) {
	import concurrency.receiver : setValueOrError;
	Receiver receiver;
	static if (is(Value == void))
		void setValue() @safe nothrow {
			receiver.setValueOrError();
		}

	else
		void setValue(Value value) @safe nothrow {
			receiver.setValueOrError(value);
		}

	void setDone() @safe nothrow {
		receiver.setDone();
	}

	void setError(Throwable e) @safe nothrow {
		receiver.setDone();
	}

	mixin ForwardExtensionPoints!receiver;
}
