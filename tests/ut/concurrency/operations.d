module ut.concurrency.operations;

import concurrency;
import concurrency.sender;
import concurrency.thread;
import concurrency.operations;
import concurrency.receiver;
import concurrency.stoptoken;
import concurrency.nursery;
import unit_threaded;
import core.time;
import core.thread;

@("ignoreErrors.sync_wait.value")
@safe unittest {
  bool delegate() shared dg = () shared { throw new Exception("Exceptions are rethrown"); };
  ThreadSender()
    .then(dg)
    .ignoreError()
    .sync_wait()
    .shouldThrowWithMessage("Canceled");
}

@("race")
unittest {
  race(ValueSender!int(4), ValueSender!int(5)).sync_wait.should == 4;
  auto fastThread = ThreadSender().then(() shared => 1);
  auto slowThread = ThreadSender().then(() shared { Thread.sleep(50.msecs); return 2; });
  race(fastThread, slowThread).sync_wait.should == 1;
  race(slowThread, fastThread).sync_wait.should == 1;
}

@("race.exception.single")
unittest {
  race(ThrowingSender(), ValueSender!int(5)).sync_wait.should == 5;
  race(ThrowingSender(), ThrowingSender()).sync_wait.shouldThrow();
}

@("race.exception.double")
unittest {
  auto slow = ThreadSender().then(() shared { Thread.sleep(50.msecs); throw new Exception("Slow"); });
  auto fast = ThreadSender().then(() shared { throw new Exception("Fast"); });
  race(slow, fast).sync_wait.shouldThrowWithMessage("Fast");
}

@("race.cancel-other")
unittest {
  auto waiting = ThreadSender().withStopToken((StopToken token){
      while (!token.isStopRequested) { Thread.yield(); }
    });
  race(waiting, ValueSender!int(88)).sync_wait.get.should == 88;
}

@("race.cancel")
unittest {
  auto waiting = ThreadSender().withStopToken((StopToken token){
      while (!token.isStopRequested) { Thread.yield(); }
    });
  auto nursery = new shared Nursery();
  nursery.run(race(waiting, waiting));
  nursery.run(ThreadSender().then(() shared { Thread.sleep(50.msecs); nursery.stop(); }));
  nursery.sync_wait().should == false;
}

@("via")
unittest {
  import std.typecons : tuple;
  ValueSender!int(3).via(ValueSender!int(6)).sync_wait().should == tuple(6,3);
  ValueSender!int(5).via(VoidSender()).sync_wait().should == 5;
  VoidSender().via(ValueSender!int(4)).sync_wait().should == 4;
}

@("then.value")
@safe unittest {
  ValueSender!int(3).then((int i) shared => i*3).sync_wait().shouldEqual(9);
}

@("finally")
unittest {
  ValueSender!int(1).finally_(() => 4).sync_wait().should == 4;
  ValueSender!int(2).finally_(3).sync_wait().should == 3;
  ThrowingSender().finally_(3).sync_wait().should == 3;
  ThrowingSender().finally_(() => 4).sync_wait().should == 4;
  ThrowingSender().finally_(3).sync_wait().should == 3;
  DoneSender().finally_(() => 4).sync_wait().shouldThrowWithMessage("Canceled");
  DoneSender().finally_(3).sync_wait().shouldThrowWithMessage("Canceled");
}
