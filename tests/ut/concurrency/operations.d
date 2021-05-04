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
import std.typecons;

/// Used to test that Senders keep the operational state alive until one receiver's terminal is called
struct OutOfBandValueSender(T) {
  alias Value = T;
  T t;
  struct Op(Receiver) {
    Receiver receiver;
    T t;
    void run() {
      receiver.setValue(t);
    }
    void start() {
      auto t = new Thread(&this.run).start();
    }
  }
  auto connect(Receiver)(Receiver receiver) {
    return Op!(Receiver)(receiver, t);
  }
}

@("ignoreErrors.sync_wait.value")
@safe unittest {
  bool delegate() shared dg = () shared { throw new Exception("Exceptions are rethrown"); };
  ThreadSender()
    .then(dg)
    .ignoreError()
    .sync_wait()
    .shouldThrowWithMessage("Canceled");
}

@("oob")
unittest {
  auto oob = OutOfBandValueSender!int(43);
  oob.sync_wait().should == 43;
}

@("race")
unittest {
  race(ValueSender!int(4), ValueSender!int(5)).sync_wait.should == 4;
  auto fastThread = ThreadSender().then(() shared => 1);
  auto slowThread = ThreadSender().then(() shared { Thread.sleep(50.msecs); return 2; });
  race(fastThread, slowThread).sync_wait.should == 1;
  race(slowThread, fastThread).sync_wait.should == 1;
}

@("race.oob")
unittest {
  auto oob = OutOfBandValueSender!int(43);
  auto value = ValueSender!int(11);
  race(oob, value).sync_wait().should == 11;
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

@("whenAll")
unittest {
  whenAll(ValueSender!int(1), ValueSender!int(2)).sync_wait.should == tuple(1,2);
  whenAll(ValueSender!int(1), ValueSender!int(2), ValueSender!int(3)).sync_wait.should == tuple(1,2,3);
  whenAll(VoidSender(), ValueSender!int(2)).sync_wait.should == 2;
  whenAll(ValueSender!int(1), VoidSender()).sync_wait.should == 1;
  whenAll(VoidSender(), VoidSender()).sync_wait.should == true;
  whenAll(ValueSender!int(1), ThrowingSender()).sync_wait.shouldThrow;
  whenAll(ThrowingSender(), ValueSender!int(1)).sync_wait.shouldThrow;
  whenAll(ValueSender!int(1), DoneSender()).sync_wait.shouldThrowWithMessage("Canceled");
  whenAll(DoneSender(), ValueSender!int(1)).sync_wait.shouldThrowWithMessage("Canceled");
  whenAll(DoneSender(), ThrowingSender()).sync_wait.shouldThrowWithMessage("ThrowingSender");
  whenAll(ThrowingSender(), DoneSender()).sync_wait.shouldThrowWithMessage("ThrowingSender");

}

@("whenAll.cancel")
unittest {
  auto waiting = ThreadSender().withStopToken((StopToken token){
      while (!token.isStopRequested) { Thread.yield(); }
    });
  whenAll(waiting, DoneSender()).sync_wait.should == false;
  whenAll(ThrowingSender(), waiting).sync_wait.shouldThrow;
  whenAll(waiting, ThrowingSender()).sync_wait.shouldThrow;
  auto waitingInt = ThreadSender().withStopToken((StopToken token){
      while (!token.isStopRequested) { Thread.yield(); }
      return 42;
    });
  whenAll(waitingInt, DoneSender()).sync_wait.shouldThrowWithMessage("Canceled");
  whenAll(ThrowingSender(), waitingInt).sync_wait.shouldThrow;
  whenAll(waitingInt, ThrowingSender()).sync_wait.shouldThrow;
}

@("retry")
unittest {
  ValueSender!int(5).retry(Times(5)).sync_wait.should == 5;
  int t = 3;
  int n = 0;
  struct Sender {
    alias Value = void;
    static struct Op(Receiver) {
      Receiver receiver;
      bool fail;
      void start() nothrow {
        if (fail)
          receiver.setError(new Exception("Fail fail fail"));
        else
          receiver.setValue();
      }
    }
    auto connect(Receiver)(Receiver receiver) {
      return Op!(Receiver)(receiver, n++ < t);
    }
  }
  Sender().retry(Times(5)).sync_wait.should == true;
  n.should == 4;
  n = 0;

  Sender().retry(Times(2)).sync_wait.shouldThrowWithMessage("Fail fail fail");
  n.should == 2;
  shared int p = 0;
  ThreadSender().then(()shared { import core.atomic; p.atomicOp!("+=")(1); throw new Exception("Failed"); }).retry(Times(5)).sync_wait.shouldThrowWithMessage("Failed");
  p.should == 5;
}

@("whenAll.oob")
unittest {
  auto oob = OutOfBandValueSender!int(43);
  auto value = ValueSender!int(11);
  whenAll(oob, value).sync_wait().should == tuple(43, 11);
}
