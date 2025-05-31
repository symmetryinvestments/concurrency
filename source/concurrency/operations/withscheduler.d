module concurrency.operations.withscheduler;

import concurrency;
import concurrency.receiver;
import concurrency.sender;
import concurrency.stoptoken;
import concurrency.utils;
import concepts;
import std.traits;

auto withScheduler(Sender, Scheduler)(Sender sender, Scheduler scheduler) {
	return WithSchedulerSender!(Sender, Scheduler)(sender, scheduler);
}

private struct WithSchedulerReceiver(Receiver, Value, Scheduler) {
	Receiver receiver;
	Scheduler scheduler;
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

	auto getScheduler() @safe nothrow {
		import concurrency.scheduler : withBaseScheduler;
		return scheduler.withBaseScheduler(receiver.getScheduler);
	}

	mixin ForwardExtensionPoints!receiver;
}

struct WithSchedulerSender(Sender, Scheduler) { //if (models!(Sender, isSender)) {
	alias Value = Sender.Value;
	Sender sender;
	Scheduler scheduler;
	auto connect(Receiver)(return Receiver receiver) @safe return scope {
		alias R = WithSchedulerReceiver!(Receiver, Sender.Value, Scheduler);
		// ensure NRVO
		auto op = sender.connect(R(receiver, scheduler));
		return op;
	}
}
