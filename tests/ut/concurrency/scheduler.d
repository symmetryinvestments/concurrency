module ut.concurrency.scheduler;

import concurrency.operations;
import concurrency.sender : DelaySender;
import concurrency;
import unit_threaded;
import concurrency.stoptoken;
import core.time : Duration, msecs, seconds;
import concurrency.scheduler;
import std.typecons : nullable;

private enum TimerAction { hold, trigger, cancel, triggerThenStop, stopThenTrigger, fail }

private class ScriptedTimers {
	TimerAction action;
	shared StopSource* source;
	Timer* timer;
	shared int adds, cancels;

	this(TimerAction action, shared StopSource* source) @safe {
		this.action = action;
		this.source = source;
	}

	void addTimer(ref Timer candidate) @trusted {
		import core.atomic : atomicOp;
		adds.atomicOp!"+="(1);
		timer = &candidate;
		final switch (action) {
			case TimerAction.hold: break;
			case TimerAction.trigger: candidate.userdata.callback(TimerTrigger.trigger); break;
			case TimerAction.cancel: candidate.userdata.callback(TimerTrigger.cancel); break;
			case TimerAction.triggerThenStop:
				candidate.userdata.callback(TimerTrigger.trigger);
				source.stop();
				break;
			case TimerAction.stopThenTrigger:
				source.stop();
				candidate.userdata.callback(TimerTrigger.trigger);
				break;
			case TimerAction.fail: throw new Exception("add failed");
		}
	}

	void cancelTimer(ref Timer candidate) @trusted {
		import core.atomic : atomicOp;
		assert(&candidate is timer);
		cancels.atomicOp!"+="(1);
	}

	void trigger() @trusted { timer.userdata.callback(TimerTrigger.trigger); }
	void acknowledgeCancel() @trusted { timer.userdata.callback(TimerTrigger.cancel); }
}

private class TerminalCounter {
	shared StopToken token;
	shared int values, dones, errors;

	this(shared StopToken token) @safe { this.token = token; }
	shared(StopToken) getStopToken() nothrow @safe { return token; }
	void setValue() @safe { import core.atomic : atomicOp; values.atomicOp!"+="(1); }
	void setDone() nothrow @safe { import core.atomic : atomicOp; dones.atomicOp!"+="(1); }
	void setError(Throwable) nothrow @safe { import core.atomic : atomicOp; errors.atomicOp!"+="(1); }
}

private class PairDone {
	import core.sync.event : Event;
	shared int count;
	Event event;
	this() @trusted shared { (cast() event).initialize(true, false); }
	void signal() @trusted shared { import core.atomic : atomicOp;
		if (count.atomicOp!"+="(1) == 2) (cast() event).setIfInitialized(); }
	bool wait(Duration timeout) @trusted shared { return (cast() event).wait(timeout); }
}

private auto scheduled(ref ScriptedTimers timers, ref TerminalCounter receiver,
	TimerAction action, shared StopSource* source) @safe {
	timers = new ScriptedTimers(action, source);
	receiver = new TerminalCounter(source.token);
	return SchedulerAdapter!ScriptedTimers(timers).scheduleAfter(1.msecs)
		.connect(receiver);
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

@("scheduleAfter.terminals") @safe
unittest {
	foreach (action; [TimerAction.trigger, TimerAction.cancel]) {
		auto source = new shared StopSource();
		ScriptedTimers timers;
		TerminalCounter receiver;
		auto op = scheduled(timers, receiver, action, source);
		op.start();
		timers.adds.should == 1;
		receiver.values.should == (action == TimerAction.trigger ? 1 : 0);
		receiver.dones.should == (action == TimerAction.cancel ? 1 : 0);
		receiver.errors.should == 0;
	}
}

@("scheduleAfter.already-stopped-and-add-error") @safe
unittest {
	auto stopped = new shared StopSource();
	stopped.stop.shouldBeTrue();
	ScriptedTimers timers;
	TerminalCounter receiver;
	auto op = scheduled(timers, receiver, TimerAction.hold, stopped);
	op.start();
	timers.adds.should == 0;
	receiver.values.should == 0;
	receiver.dones.should == 1;
	receiver.errors.should == 0;

	auto source = new shared StopSource();
	auto failing = scheduled(timers, receiver, TimerAction.fail, source);
	failing.start();
	timers.adds.should == 1;
	receiver.values.should == 0;
	receiver.dones.should == 0;
	receiver.errors.should == 1;
}

@("scheduleAfter.stop-races") @trusted
unittest {
	import core.thread : Thread;
	foreach (_; 0 .. 200) {
		auto source = new shared StopSource();
		ScriptedTimers timers;
		TerminalCounter receiver;
		auto op = scheduled(timers, receiver, TimerAction.hold, source);
		op.start();
		auto trigger = new Thread(() { timers.trigger(); });
		auto stop = new Thread(() { source.stop(); });
		trigger.start(); stop.start();
		trigger.join(); stop.join();
		if (timers.cancels)
			timers.acknowledgeCancel();
		(receiver.values + receiver.dones).should == 1;
		receiver.errors.should == 0;
		timers.cancels.should == receiver.dones;
	}
}

@("scheduleAfter.stop-before-setup") @safe
unittest {
	foreach (action; [TimerAction.triggerThenStop, TimerAction.stopThenTrigger]) {
		auto source = new shared StopSource();
		auto timers = new ScriptedTimers(action, source);
		auto receiver = new TerminalCounter(source.token);
		auto op = SchedulerAdapter!ScriptedTimers(timers).scheduleAfter(1.msecs)
			.connect(receiver);
		op.start();
		timers.cancels.should == 1;
		receiver.values.should == 0;
		receiver.dones.should == 0;
		timers.acknowledgeCancel();
		receiver.values.should == 0;
		receiver.dones.should == 1;
		receiver.errors.should == 0;
	}
}

@("scheduleAfter.manual-time.stop") @trusted
unittest {
	import core.thread : Thread;
	import core.stdc.stdio : fputs, stderr;
	import core.stdc.stdlib : abort;
	foreach (_; 0 .. 100) {
		auto source = new shared StopSource();
		auto worker = new shared ManualTimeWorker();
		auto receiver = new TerminalCounter(source.token);
		auto op = worker.getScheduler.scheduleAfter(1.msecs).connect(receiver);
		op.start();
		auto done = new shared PairDone();
		auto advance = new Thread(() { worker.advance(1.msecs); done.signal(); });
		auto stop = new Thread(() { source.stop(); done.signal(); });
		advance.isDaemon = true; stop.isDaemon = true;
		advance.start(); stop.start();
		if (!done.wait(2.seconds)) {
			fputs("ScheduleAfter ManualTime race timed out\n", stderr);
			abort();
		}
		advance.join(); stop.join();
		(receiver.values + receiver.dones).should == 1;
		receiver.errors.should == 0;
	}
}

@("scheduleAfter.local-thread.queued-add-stop") @safe
unittest {
	import concurrency.sender : delay, justFrom;
	shared source = StopSource();
	whenAll(justFrom(() shared => source.stop), delay(1.msecs))
		.syncWait(source).isCancelled.shouldBeTrue();
}

@("ManualTimeWorker") @safe
unittest {
	import core.atomic : atomicOp;

	shared int g, h;
	auto worker = new shared ManualTimeWorker();
	auto t1 = Timer(TimerData((TimerTrigger trigger) shared {
		g.atomicOp!"+="(1);
	}));
	worker.addTimer(t1, 10.msecs);
	auto t2 = Timer(TimerData((TimerTrigger trigger) shared {
		h.atomicOp!"+="(1);
	}));
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
	auto timer = Timer(TimerData((TimerTrigger trigger) shared {
		g.atomicOp!"+="(1 + (trigger == TimerTrigger.cancel));
	}));
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
