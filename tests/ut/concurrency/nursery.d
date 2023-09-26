module ut.concurrency.nursery;

import concurrency;
import concurrency.sender;
import concurrency.thread;
import concurrency.operations;
import concurrency.nursery;
import concurrency.stoptoken;
import unit_threaded;

@("run.stopped") @safe
unittest {
	auto nursery = new shared Nursery();
	nursery.stop();
	nursery.syncWait().isCancelled.should == true;
}

@("run.empty") @safe
unittest {
	auto nursery = new shared Nursery();
	auto stop = justFrom(() shared => nursery.stop());
	whenAll(nursery, stop).syncWait().isCancelled.should == true;
}

@("run.value") @safe
unittest {
	auto nursery = new shared Nursery();
	nursery.run(ValueSender!(int)(5));
	nursery.syncWait.assumeOk;
	nursery.getStopToken().isStopRequested().shouldBeFalse();
}

@("run.exception") @safe
unittest {
	auto nursery = new shared Nursery();
	nursery.run(ThrowingSender());
	nursery.syncWait.assumeOk.shouldThrow();
	nursery.getStopToken().isStopRequested().shouldBeTrue();
}

@("run.value.then") @safe
unittest {
	auto nursery = new shared Nursery();
	shared(int) global;
	nursery.run(ValueSender!(int)(5).then((int c) shared => global = c));
	global.shouldEqual(0);
	nursery.syncWait.assumeOk;
	global.shouldEqual(5);
}

@("run.thread.run") @safe
unittest {
	auto nursery = new shared Nursery();
	shared(int) global;
	nursery.run(ThreadSender().then(() @safe shared {
		nursery.run(ValueSender!(int)(5).then((int c) @safe shared {
			global = c;
		}));
	}));
	global.shouldEqual(0);
	nursery.syncWait.assumeOk;
	global.shouldEqual(5);
	nursery.getStopToken().isStopRequested().shouldBeFalse();
}

@("run.thread.stop.internal") @safe
unittest {
	auto nursery = new shared Nursery();
	nursery.run(ThreadSender().then(() @safe shared => nursery.stop()));
	nursery.syncWait.isCancelled.should == true;
	nursery.getStopToken().isStopRequested().shouldBeTrue();
}

@("run.thread.stop.external") @safe
unittest {
	auto nursery = new shared Nursery();
	shared stopSource = StopSource(); 
	nursery.run(ThreadSender().then(() @safe shared => stopSource.stop()));
	nursery.syncWait(stopSource).isCancelled.should == true;
	nursery.getStopToken().isStopRequested().shouldBeTrue();
	stopSource.isStopRequested().shouldBeTrue();
}

@("run.thread.stop.internal.sibling") @safe
unittest {
	import core.thread : Thread;
	auto nursery = new shared Nursery();
	auto thread1 = ThreadSender().then(() @trusted shared {
		auto token = nursery.getStopToken();
		while (!token.isStopRequested())
			Thread.yield();
	});
	auto thread2 = ThreadSender().then(() @safe shared => nursery.stop());
	nursery.run(thread1);
	nursery.run(thread2);
	nursery.syncWait.isCancelled.should == true;
	nursery.getStopToken().isStopRequested().shouldBeTrue();
}

@("run.nested") @safe
unittest {
	auto nursery1 = new shared Nursery();
	auto nursery2 = new shared Nursery();
	shared(int) global;
	nursery1.run(nursery2);
	nursery2.run(ValueSender!(int)(99).then((int c) shared => global = c));
	global.shouldEqual(0);
	nursery1.syncWait.assumeOk;
	global.shouldEqual(99);
	nursery1.getStopToken().isStopRequested().shouldBeFalse();
	nursery2.getStopToken().isStopRequested().shouldBeFalse();
}

@("run.error") @safe
unittest {
	import core.thread : Thread;
	auto nursery = new shared Nursery();
	auto thread1 = ThreadSender().then(() @trusted shared {
		auto token = nursery.getStopToken();
		while (!token.isStopRequested())
			Thread.yield();
	});
	auto thread2 =
		ThreadSender().withStopToken((shared StopToken token) @trusted shared {
			while (!token.isStopRequested())
				Thread.yield();
		});
	auto thread3 = ThreadSender().then(() @safe shared {
		throw new Exception("Error should stop everyone");
	});
	nursery.run(thread1);
	nursery.run(thread2);
	nursery.run(thread3);
	nursery.getStopToken().isStopRequested().shouldBeFalse();
	nursery.syncWait.assumeOk.shouldThrow();
	nursery.getStopToken().isStopRequested().shouldBeTrue();
}

@("withStopSource.1") @safe
unittest {
	import core.thread : Thread;
	shared StopSource stopSource;
	auto nursery = new shared Nursery();

	auto thread1 =
		ThreadSender().withStopToken((shared StopToken stopToken) @trusted shared {
			while (!stopToken.isStopRequested)
				Thread.yield();
		}).withStopSource(stopSource);

	// stop via the source
	auto stopper = justFrom(() shared => stopSource.stop());

	nursery.run(thread1);
	nursery.run(stopper);

	nursery.syncWait.assumeOk;
}

@("withStopSource.2") @safe
unittest {
	import core.thread : Thread;
	shared StopSource stopSource;
	auto nursery = new shared Nursery();

	auto thread1 =
		ThreadSender().withStopToken((shared StopToken stopToken) @trusted shared {
			while (!stopToken.isStopRequested)
				Thread.yield();
		}).withStopSource(stopSource);

	// stop via the nursery
	auto stopper = justFrom(() shared => nursery.stop());

	nursery.run(thread1);
	nursery.run(stopper);

	nursery.syncWait.isCancelled.should == true;
}
