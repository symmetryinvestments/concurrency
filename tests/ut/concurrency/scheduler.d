module ut.concurrency.scheduler;

import concurrency.operations;
import concurrency.sender : DelaySender;
import concurrency;
import unit_threaded;
import concurrency.stoptoken;
import core.time : msecs;
import concurrency.scheduler;

@("scheduleAfter")
@safe unittest {
  DelaySender(10.msecs).syncWait;
}

@("scheduleAfter.cancel")
@safe unittest {
  race(DelaySender(10.msecs), DelaySender(3.msecs)).syncWait;
}

@("ManualTimeWorker")
@safe unittest {
  import core.atomic : atomicOp;

  shared int g, h;
  auto worker = new shared ManualTimeWorker();
  worker.addTimer((TimerTrigger trigger) shared { g.atomicOp!"+="(1); }, 10.msecs);
  worker.addTimer((TimerTrigger trigger) shared { h.atomicOp!"+="(1); }, 5.msecs);

  worker.timeUntilNextEvent().should == 5.msecs;
  g.should == 0;
  h.should == 0;

  worker.advance(4.msecs);
  worker.timeUntilNextEvent().should == 1.msecs;
  h.should == 0;
  g.should == 0;

  worker.advance(1.msecs);
  worker.timeUntilNextEvent().should == 5.msecs;
  h.should == 1;
  g.should == 0;

  worker.advance(5.msecs);
  h.should == 1;
  g.should == 1;
  worker.timeUntilNextEvent().should == null;
}

@("ManualTimeWorker.cancel")
@safe unittest {
  import core.atomic : atomicOp;

  shared int g;
  auto worker = new shared ManualTimeWorker();
  auto timer = worker.addTimer((TimerTrigger trigger) shared { g.atomicOp!"+="(1 + (trigger == TimerTrigger.cancel)); }, 10.msecs);
  worker.timeUntilNextEvent().should == 10.msecs;
  g.should == 0;

  worker.advance(4.msecs);
  worker.timeUntilNextEvent().should == 6.msecs;
  g.should == 0;

  worker.cancelTimer(timer);
  worker.timeUntilNextEvent().should == null;
  g.should == 2;
}

@("ManualTimeWorker.error")
@safe unittest {
  import core.time;
  import concurrency.operations : withScheduler, whenAll;
  import concurrency.sender : justFrom;

  shared int p = 0;
  import concurrency.scheduler : ManualTimeWorker;

  auto worker = new shared ManualTimeWorker();

  auto sender = DelaySender(10.msecs)
    .withScheduler(worker.getScheduler);

  auto driver = justFrom(() shared {
      worker.advance(7.msecs);
      throw new Exception("halt");
    });

  whenAll(sender, driver).syncWait.assumeOk.shouldThrowWithMessage("halt");
}

@("toSenderObject.Schedule")
@safe unittest {
  import concurrency.sender : toSenderObject;
  Schedule().toSenderObject.syncWait.assumeOk;
}
