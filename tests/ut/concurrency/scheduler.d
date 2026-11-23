module ut.concurrency.scheduler;

import concurrency.operations;
import concurrency.sender : DelaySender;
import concurrency;
import unit_threaded;
import concurrency.stoptoken;
import core.time : msecs;
import concurrency.scheduler;
import std.typecons : nullable;
import core.sync.event : Event;
import core.thread : Thread;

private enum InlineTimerEvent {
	none,
	trigger,
	cancel,
}

private class TimerProbe {
	Timer* timer;
	InlineTimerEvent onAdd;
	Throwable addFailure;
	int addCalls;
	int cancelCalls;
	shared SetupGate setupGate;

	void addTimer(ref Timer timer) @trusted {
		this.timer = &timer;
		addCalls++;
		if (addFailure !is null)
			throw addFailure;
		if (setupGate !is null) {
			setupGate.enter();
			setupGate.waitRelease();
		}
		final switch (onAdd) {
			case InlineTimerEvent.none:
				break;
			case InlineTimerEvent.trigger:
				fire(TimerTrigger.trigger);
				break;
			case InlineTimerEvent.cancel:
				fire(TimerTrigger.cancel);
				break;
		}
	}

	void cancelTimer(ref Timer timer) @trusted {
		assert(&timer is this.timer);
		cancelCalls++;
	}

	void fire(TimerTrigger event) @trusted {
		assert(timer !is null);
		timer.userdata(event);
	}
}

private class SetupGate {
	Event entered, release;

	this() @trusted shared {
		(cast() entered).initialize(false, false);
		(cast() release).initialize(false, false);
	}

	void enter() @trusted shared {
		(cast() entered).setIfInitialized();
	}

	void waitEntered() @trusted shared {
		(cast() entered).wait();
	}

	void releaseSetup() @trusted shared {
		(cast() release).setIfInitialized();
	}

	void waitRelease() @trusted shared {
		(cast() release).wait();
	}
}

private class ContentionGate {
	Event triggerReady, cancelReady, release;

	this() @trusted shared {
		(cast() triggerReady).initialize(false, false);
		(cast() cancelReady).initialize(false, false);
		(cast() release).initialize(true, false);
	}

	void ready(TimerTrigger cause) @trusted shared {
		final switch (cause) {
			case TimerTrigger.trigger:
				(cast() triggerReady).setIfInitialized();
				break;
			case TimerTrigger.cancel:
				(cast() cancelReady).setIfInitialized();
				break;
		}
	}

	void waitReady() @trusted shared {
		(cast() triggerReady).wait();
		(cast() cancelReady).wait();
	}

	void releaseContenders() @trusted shared {
		(cast() release).setIfInitialized();
	}

	void waitRelease() @trusted shared {
		(cast() release).wait();
	}
}

private class ScheduleAfterEvents {
	int values;
	int dones;
	int errors;
	TimerTrigger terminal;
}

private struct ScheduleAfterReceiver {
	ScheduleAfterEvents events;
	shared StopToken token;

	void setValue() @safe {
		events.values++;
		events.terminal = TimerTrigger.trigger;
	}

	void setDone() @safe nothrow {
		events.dones++;
		events.terminal = TimerTrigger.cancel;
	}

	void setError(Throwable) @safe nothrow {
		events.errors++;
	}

	shared(StopToken) getStopToken() @safe nothrow {
		return token;
	}
}

private ScheduleAfterReceiver scheduleAfterReceiver(ScheduleAfterEvents events,
	return scope shared StopToken token = shared(StopToken).init) @safe {
	return ScheduleAfterReceiver(events, token);
}

private void checkTerminal(ScheduleAfterEvents events, int values, int dones,
	int errors) @safe {
	events.values.should == values;
	events.dones.should == dones;
	events.errors.should == errors;
}

private void checkContentionTerminal(ScheduleAfterEvents events) @safe {
	if (events.terminal == TimerTrigger.trigger)
		checkTerminal(events, 1, 0, 0);
	else
		checkTerminal(events, 0, 1, 0);
}

private Thread contender(TimerProbe worker, shared ContentionGate gate,
	TimerTrigger cause) @trusted {
	return new Thread({
		gate.ready(cause);
		gate.waitRelease();
		worker.fire(cause);
	}).start();
}

private void runContention(TimerProbe worker) @trusted {
	auto gate = new shared ContentionGate();
	auto trigger = contender(worker, gate, TimerTrigger.trigger);
	auto cancel = contender(worker, gate, TimerTrigger.cancel);
	gate.waitReady();
	gate.releaseContenders();
	trigger.join();
	cancel.join();
}

private Thread startOperation(T)(ref T operation) @trusted {
	return new Thread({ operation.start(); }).start();
}

@("scheduleAfter.assert-error") @trusted
unittest {
	import core.exception : AssertError;
	auto worker = new TimerProbe;
	worker.addFailure = new AssertError("timer assertion");
	auto events = new ScheduleAfterEvents;
	shared source = StopSource();
	auto operation = SchedulerAdapter!TimerProbe(worker).scheduleAfter(1.msecs)
		.connect(scheduleAfterReceiver(events, source.token));

	operation.start();

	checkTerminal(events, 0, 0, 1);
	source.assertNoCallbacks();
}

@("scheduleAfter") @safe
unittest {
	DelaySender(10.msecs).syncWait;
}

@("scheduleAfter.cancel") @safe
unittest {
	race(DelaySender(10.msecs), DelaySender(3.msecs)).syncWait;
}

@("scheduleAfter.stop-before-add") @safe
unittest {
	import concurrency.sender : delay, justFrom;
	shared source = StopSource();
	whenAll(justFrom(() shared => source.stop), delay(10.msecs))
		.syncWait(source);
}

@("scheduleAfter.inline-cancel-before-setup") @safe
unittest {
	auto worker = new TimerProbe;
	worker.onAdd = InlineTimerEvent.cancel;
	auto events = new ScheduleAfterEvents;
	shared source = StopSource();
	auto operation = SchedulerAdapter!TimerProbe(worker).scheduleAfter(1.msecs)
		.connect(scheduleAfterReceiver(events, source.token));

	operation.start();

	worker.addCalls.should == 1;
	checkTerminal(events, 0, 1, 0);
	source.assertNoCallbacks();
	source.stop();
	worker.fire(TimerTrigger.trigger);
	worker.fire(TimerTrigger.cancel);
	checkTerminal(events, 0, 1, 0);
}

@("scheduleAfter.duplicate-cancel") @safe
unittest {
	auto worker = new TimerProbe;
	auto events = new ScheduleAfterEvents;
	shared source = StopSource();
	auto operation = SchedulerAdapter!TimerProbe(worker).scheduleAfter(1.msecs)
		.connect(scheduleAfterReceiver(events, source.token));

	operation.start();
	worker.fire(TimerTrigger.cancel);
	worker.fire(TimerTrigger.cancel);

	checkTerminal(events, 0, 1, 0);
	source.assertNoCallbacks();
}

@("scheduleAfter.trigger-cancel-contention-before-setup") @trusted
unittest {
	auto worker = new TimerProbe;
	auto events = new ScheduleAfterEvents;
	shared source = StopSource();
	auto setup = new shared SetupGate();
	worker.setupGate = setup;
	auto operation = SchedulerAdapter!TimerProbe(worker).scheduleAfter(1.msecs)
		.connect(scheduleAfterReceiver(events, source.token));
	auto starter = startOperation(operation);
	setup.waitEntered();

	runContention(worker);
	checkTerminal(events, 0, 0, 0);

	setup.releaseSetup();
	starter.join();
	checkContentionTerminal(events);
	source.assertNoCallbacks();
	worker.fire(TimerTrigger.trigger);
	worker.fire(TimerTrigger.cancel);
	checkContentionTerminal(events);
}

@("scheduleAfter.trigger-cancel-contention-after-setup") @safe
unittest {
	auto worker = new TimerProbe;
	auto events = new ScheduleAfterEvents;
	shared source = StopSource();
	auto operation = SchedulerAdapter!TimerProbe(worker).scheduleAfter(1.msecs)
		.connect(scheduleAfterReceiver(events, source.token));

	operation.start();
	runContention(worker);

	checkContentionTerminal(events);
	source.assertNoCallbacks();
	worker.fire(TimerTrigger.trigger);
	worker.fire(TimerTrigger.cancel);
	checkContentionTerminal(events);
}

@("scheduleAfter.stop-during-setup") @trusted
unittest {
	auto worker = new TimerProbe;
	auto events = new ScheduleAfterEvents;
	shared source = StopSource();
	auto setup = new shared SetupGate();
	worker.setupGate = setup;
	auto operation = SchedulerAdapter!TimerProbe(worker).scheduleAfter(1.msecs)
		.connect(scheduleAfterReceiver(events, source.token));
	auto starter = startOperation(operation);
	setup.waitEntered();

	source.stop();
	checkTerminal(events, 0, 0, 0);
	setup.releaseSetup();
	starter.join();

	checkTerminal(events, 0, 1, 0);
	worker.cancelCalls.should == 1;
	source.assertNoCallbacks();
	worker.fire(TimerTrigger.trigger);
	worker.fire(TimerTrigger.cancel);
	checkTerminal(events, 0, 1, 0);
}

@("scheduleAfter.normal-trigger") @safe
unittest {
	foreach (inline; [false, true]) {
		auto worker = new TimerProbe;
		worker.onAdd = inline ? InlineTimerEvent.trigger : InlineTimerEvent.none;
		auto events = new ScheduleAfterEvents;
		shared source = StopSource();
		auto operation = SchedulerAdapter!TimerProbe(worker).scheduleAfter(1.msecs)
			.connect(scheduleAfterReceiver(events, source.token));

		operation.start();
		if (!inline)
			worker.fire(TimerTrigger.trigger);

		checkTerminal(events, 1, 0, 0);
		source.assertNoCallbacks();
	}
}

@("scheduleAfter.timer-callback-survives-facade-destruction") @trusted
unittest {
	auto worker = new TimerProbe;
	auto events = new ScheduleAfterEvents;
	shared source = StopSource();

	auto facade = SchedulerAdapter!TimerProbe(worker);
	auto operation = facade.scheduleAfter(1.msecs)
		.connect(scheduleAfterReceiver(events, source.token));
	operation.start();
	facade = SchedulerAdapter!TimerProbe.init;
	worker.fire(TimerTrigger.trigger);

	checkTerminal(events, 1, 0, 0);
	source.assertNoCallbacks();
}

@("ManualTimeWorker") @safe
unittest {
	import core.atomic : atomicOp;

	shared int g, h;
	auto worker = new shared ManualTimeWorker();
	auto t1 = Timer((TimerTrigger trigger) shared {
		g.atomicOp!"+="(1);
	});
	worker.addTimer(t1, 10.msecs);
	auto t2 = Timer((TimerTrigger trigger) shared {
		h.atomicOp!"+="(1);
	});
	worker.addTimer(t2, 5.msecs);

	worker.timeUntilNextEvent().should == 5.msecs.nullable;
	g.should == 0;
	h.should == 0;

	worker.advance(4.msecs);
	worker.timeUntilNextEvent().should == 1.msecs.nullable;
	h.should == 0;
	g.should == 0;

	worker.advance(1.msecs);
	worker.timeUntilNextEvent().should == 5.msecs.nullable;
	h.should == 1;
	g.should == 0;

	worker.advance(5.msecs);
	h.should == 1;
	g.should == 1;
	worker.timeUntilNextEvent().isNull.should == true;
}

@("ManualTimeWorker.cancel") @safe
unittest {
	import core.atomic : atomicOp;

	shared int g;
	auto worker = new shared ManualTimeWorker();
	auto timer = Timer((TimerTrigger trigger) shared {
		g.atomicOp!"+="(1 + (trigger == TimerTrigger.cancel));
	});
	worker.addTimer(timer, 10.msecs);
	worker.timeUntilNextEvent().should == 10.msecs.nullable;
	g.should == 0;

	worker.advance(4.msecs);
	worker.timeUntilNextEvent().should == 6.msecs.nullable;
	g.should == 0;

	worker.cancelTimer(timer);
	worker.timeUntilNextEvent().isNull.should == true;
	g.should == 2;
}

@("ManualTimeWorker.error") @safe
unittest {
	import core.time;
	import concurrency.operations : withScheduler, whenAll;
	import concurrency.sender : justFrom;

	shared int p = 0;
	import concurrency.scheduler : ManualTimeWorker;

	auto worker = new shared ManualTimeWorker();

	auto sender = DelaySender(10.msecs).withScheduler(worker.getScheduler);

	auto driver = justFrom(() shared {
		worker.advance(7.msecs);
		throw new Exception("halt");
	});

	whenAll(sender, driver).syncWait.assumeOk.shouldThrowWithMessage("halt");
}

@("toSenderObject.Schedule") @safe
unittest {
	import concurrency.sender : toSenderObject;
	Schedule().toSenderObject.syncWait.assumeOk;
}
