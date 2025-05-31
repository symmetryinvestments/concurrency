module concurrency.operations.stopon;

import concurrency;
import concurrency.receiver;
import concurrency.sender;
import concurrency.stoptoken;
import concurrency.utils;
import std.traits;

auto stopOn(Sender)(Sender sender, shared StopToken stopToken) {
	return StopOn!(Sender)(sender, stopToken);
}

private struct StopOnReceiver(Receiver, Value) {
	private {
		Receiver receiver;
		shared StopToken stopToken;
	}

	static if (is(Value == void)) {
		void setValue() @safe {
			receiver.setValue();
		}
	} else {
		void setValue(Value value) @safe {
			receiver.setValue(value.copyOrMove);
		}
	}

	void setDone() @safe nothrow {
		receiver.setDone();
	}

	void setError(Throwable e) @safe nothrow {
		receiver.setError(e);
	}

	auto getStopToken() nothrow @safe {
		return stopToken;
	}

	mixin ForwardExtensionPoints!receiver;
}

struct StopOn(Sender) {
	alias Value = Sender.Value;
	Sender sender;
	shared StopToken stopToken;
	auto connect(Receiver)(return Receiver receiver) @safe return scope {
		alias R = StopOnReceiver!(Receiver, Sender.Value);
		// ensure NRVO
		auto op = sender.connect(R(receiver, stopToken));
		return op;
	}
}
