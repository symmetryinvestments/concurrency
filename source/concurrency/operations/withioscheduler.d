module concurrency.operations.withioscheduler;

import concurrency;
import concurrency.receiver;
import concurrency.sender;
import concurrency.stoptoken;
import concurrency.utils;
import concepts;
import std.traits;

auto withIOScheduler(Sender, IOScheduler)(Sender sender, IOScheduler ioScheduler) {
	return WithIOSchedulerSender!(Sender, IOScheduler)(sender, ioScheduler);
}

private struct WithIOSchedulerReceiver(Receiver, Value, IOScheduler) {
	Receiver receiver;
	IOScheduler ioScheduler;
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

	auto getIOScheduler() @safe nothrow {
		return ioScheduler;
	}

	mixin ForwardExtensionPoints!receiver;
}

struct WithIOSchedulerSender(Sender, IOScheduler) { //if (models!(Sender, isSender)) {
	alias Value = Sender.Value;
	Sender sender;
	IOScheduler ioScheduler;
	auto connect(Receiver)(return Receiver receiver) @safe return scope {
		alias R = WithIOSchedulerReceiver!(Receiver, Sender.Value, IOScheduler);
		// ensure NRVO
		auto op = sender.connect(R(receiver, ioScheduler));
		return op;
	}
}
