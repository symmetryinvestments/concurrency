module ut.concurrency.scheduler;

import concurrency.operations;
import concurrency.sender : DelaySender;
import concurrency;
import unit_threaded;
import concurrency.stoptoken;
import core.time : msecs;
import concurrency.scheduler;
import std.typecons : nullable;

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
