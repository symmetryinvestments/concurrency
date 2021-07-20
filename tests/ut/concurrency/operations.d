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
  T value;
  struct Op(Receiver) {
    Receiver receiver;
    T value;
    void run() {
      receiver.setValue(value);
    }
    void start() @trusted scope {
      auto value = new Thread(&this.run).start();
    }
  }
  auto connect(Receiver)(return Receiver receiver) @safe scope return {
    // ensure NRVO
    auto op = Op!(Receiver)(receiver, value);
    return op;
  }
}

@("ignoreErrors.syncWait.value")
@safe unittest {
  bool delegate() @safe shared dg = () shared { throw new Exception("Exceptions are rethrown"); };
  ThreadSender()
    .then(dg)
    .ignoreError()
    .syncWait.isCancelled.should == true;
}

@("oob")
unittest {
  auto oob = OutOfBandValueSender!int(43);
  oob.syncWait.value.should == 43;
}

@("race")
unittest {
  race(ValueSender!int(4), ValueSender!int(5)).syncWait.value.should == 4;
  auto fastThread = ThreadSender().then(() shared => 1);
  auto slowThread = ThreadSender().then(() shared @trusted { Thread.sleep(50.msecs); return 2; });
  race(fastThread, slowThread).syncWait.value.should == 1;
  race(slowThread, fastThread).syncWait.value.should == 1;
}

@("race.multiple")
unittest {
  race(ValueSender!int(4), ValueSender!int(5), ValueSender!int(6)).syncWait.value.should == 4;
}

@("race.oob")
unittest {
  auto oob = OutOfBandValueSender!int(43);
  auto value = ValueSender!int(11);
  race(oob, value).syncWait.value.should == 11;
}

@("race.exception.single")
unittest {
  race(ThrowingSender(), ValueSender!int(5)).syncWait.value.should == 5;
  race(ThrowingSender(), ThrowingSender()).syncWait.assumeOk.shouldThrow();
}

@("race.exception.double")
unittest {
  auto slow = ThreadSender().then(() shared @trusted { Thread.sleep(50.msecs); throw new Exception("Slow"); });
  auto fast = ThreadSender().then(() shared { throw new Exception("Fast"); });
  race(slow, fast).syncWait.assumeOk.shouldThrowWithMessage("Fast");
}

@("race.cancel-other")
unittest {
  auto waiting = ThreadSender().withStopToken((StopToken token) @trusted {
      while (!token.isStopRequested) { Thread.yield(); }
    });
  race(waiting, ValueSender!int(88)).syncWait.value.get.should == 88;
}

@("race.cancel")
unittest {
  auto waiting = ThreadSender().withStopToken((StopToken token) @trusted {
      while (!token.isStopRequested) { Thread.yield(); }
    });
  auto nursery = new shared Nursery();
  nursery.run(race(waiting, waiting));
  nursery.run(ThreadSender().then(() @trusted shared { Thread.sleep(50.msecs); nursery.stop(); }));
  nursery.syncWait.isCancelled.should == true;
}

@("via")
unittest {
  import std.typecons : tuple;
  ValueSender!int(3).via(ValueSender!int(6)).syncWait.value.should == tuple(6,3);
  ValueSender!int(5).via(VoidSender()).syncWait.value.should == 5;
  VoidSender().via(ValueSender!int(4)).syncWait.value.should == 4;
}

@("then.value.delegate")
@safe unittest {
  ValueSender!int(3).then((int i) shared => i*3).syncWait.value.shouldEqual(9);
}

@("then.value.function")
@safe unittest {
  ValueSender!int(3).then((int i) => i*3).syncWait.value.shouldEqual(9);
}

@("then.oob")
@safe unittest {
  OutOfBandValueSender!int(46).then((int i) shared => i*3).syncWait.value.shouldEqual(138);
}

@("finally")
unittest {
  ValueSender!int(1).finally_(() => 4).syncWait.value.should == 4;
  ValueSender!int(2).finally_(3).syncWait.value.should == 3;
  ThrowingSender().finally_(3).syncWait.value.should == 3;
  ThrowingSender().finally_(() => 4).syncWait.value.should == 4;
  ThrowingSender().finally_(3).syncWait.value.should == 3;
  DoneSender().finally_(() => 4).syncWait.isCancelled.should == true;
  DoneSender().finally_(3).syncWait.isCancelled.should == true;
}

@("whenAll")
unittest {
  whenAll(ValueSender!int(1), ValueSender!int(2)).syncWait.value.should == tuple(1,2);
  whenAll(ValueSender!int(1), ValueSender!int(2), ValueSender!int(3)).syncWait.value.should == tuple(1,2,3);
  whenAll(VoidSender(), ValueSender!int(2)).syncWait.value.should == 2;
  whenAll(ValueSender!int(1), VoidSender()).syncWait.value.should == 1;
  whenAll(VoidSender(), VoidSender()).syncWait.isOk.should == true;
  whenAll(ValueSender!int(1), ThrowingSender()).syncWait.assumeOk.shouldThrowWithMessage("ThrowingSender");
  whenAll(ThrowingSender(), ValueSender!int(1)).syncWait.assumeOk.shouldThrowWithMessage("ThrowingSender");
  whenAll(ValueSender!int(1), DoneSender()).syncWait.isCancelled.should == true;
  whenAll(DoneSender(), ValueSender!int(1)).syncWait.isCancelled.should == true;
  whenAll(DoneSender(), ThrowingSender()).syncWait.isCancelled.should == true;
  whenAll(ThrowingSender(), DoneSender()).syncWait.assumeOk.shouldThrowWithMessage("ThrowingSender");

}

@("whenAll.cancel")
unittest {
  auto waiting = ThreadSender().withStopToken((StopToken token) @trusted {
      while (!token.isStopRequested) { Thread.yield(); }
    });
  whenAll(waiting, DoneSender()).syncWait.isCancelled.should == true;
  whenAll(ThrowingSender(), waiting).syncWait.assumeOk.shouldThrow;
  whenAll(waiting, ThrowingSender()).syncWait.assumeOk.shouldThrow;
  auto waitingInt = ThreadSender().withStopToken((StopToken token) @trusted {
      while (!token.isStopRequested) { Thread.yield(); }
      return 42;
    });
  whenAll(waitingInt, DoneSender()).syncWait.isCancelled.should == true;
  whenAll(ThrowingSender(), waitingInt).syncWait.assumeOk.shouldThrow;
  whenAll(waitingInt, ThrowingSender()).syncWait.assumeOk.shouldThrow;
}

@("whenAll.stop")
unittest {
  auto waiting = ThreadSender().withStopToken((StopToken token) @trusted {
      while (!token.isStopRequested) { Thread.yield(); }
    });
  auto source = new StopSource();
  auto stopper = just(source).then((StopSource source) shared => source.stop());
  whenAll(waiting, stopper).withStopSource(source).syncWait.isCancelled.should == true;
}

@("retry")
unittest {
  ValueSender!int(5).retry(Times(5)).syncWait.value.should == 5;
  int t = 3;
  int n = 0;
  struct Sender {
    alias Value = void;
    static struct Op(Receiver) {
      Receiver receiver;
      bool fail;
      void start() @safe nothrow {
        if (fail)
          receiver.setError(new Exception("Fail fail fail"));
        else
          receiver.setValue();
      }
    }
    auto connect(Receiver)(return Receiver receiver) @safe scope return {
      // ensure NRVO
      auto op = Op!(Receiver)(receiver, n++ < t);
      return op;
    }
  }
  Sender().retry(Times(5)).syncWait.isOk.should == true;
  n.should == 4;
  n = 0;

  Sender().retry(Times(2)).syncWait.assumeOk.shouldThrowWithMessage("Fail fail fail");
  n.should == 2;
  shared int p = 0;
  ThreadSender().then(()shared { import core.atomic; p.atomicOp!("+=")(1); throw new Exception("Failed"); }).retry(Times(5)).syncWait.assumeOk.shouldThrowWithMessage("Failed");
  p.should == 5;
}

@("whenAll.oob")
unittest {
  auto oob = OutOfBandValueSender!int(43);
  auto value = ValueSender!int(11);
  whenAll(oob, value).syncWait.value.should == tuple(43, 11);
}

@("withStopToken.oob")
unittest {
  auto oob = OutOfBandValueSender!int(44);
  oob.withStopToken((StopToken stopToken, int t) => t).syncWait.value.should == 44;
}

@("withStopSource.oob")
unittest {
  auto oob = OutOfBandValueSender!int(45);
  oob.withStopSource(new StopSource()).syncWait.value.should == 45;
}

@("value.withstoptoken.via.thread")
@safe unittest {
  ValueSender!int(4).withStopToken((StopToken s, int i) { throw new Exception("Badness");}).via(ThreadSender()).syncWait.assumeOk.shouldThrowWithMessage("Badness");
}

@("completewithcancellation")
@safe unittest {
  ValueSender!void().completeWithCancellation.syncWait.isCancelled.should == true;
}

@("raceAll")
@safe unittest {
  auto waiting = ThreadSender().withStopToken((StopToken token) @trusted {
      while (!token.isStopRequested) { Thread.yield(); }
    });
  raceAll(waiting, DoneSender()).syncWait.isOk.should == true;
  raceAll(waiting, just(42)).syncWait.value.should == 42;
  raceAll(waiting, ThrowingSender()).syncWait.isOk.should == true;
}

@("on.ManualTimeWorker")
@safe unittest {
  import concurrency.scheduler : ManualTimeWorker;

  auto worker = new shared ManualTimeWorker();
  auto driver = just(worker).then((shared ManualTimeWorker worker) shared {
      worker.timeUntilNextEvent().should == 10.msecs;
      worker.advance(5.msecs);
      worker.timeUntilNextEvent().should == 5.msecs;
      worker.advance(5.msecs);
      worker.timeUntilNextEvent().should == null;
    });
  auto timer = DelaySender(10.msecs).withScheduler(worker.getScheduler);

  whenAll(timer, driver).syncWait().isOk.should == true;
}

@("on.ManualTimeWorker.cancel")
@safe unittest {
  import concurrency.scheduler : ManualTimeWorker;

  auto worker = new shared ManualTimeWorker();
  auto source = new StopSource();
  auto driver = just(source).then((StopSource source) shared {
      worker.timeUntilNextEvent().should == 10.msecs;
      source.stop();
      worker.timeUntilNextEvent().should == null;
    });
  auto timer = DelaySender(10.msecs).withScheduler(worker.getScheduler);

  whenAll(timer, driver).syncWait(source).isCancelled.should == true;
}

@("then.stack.no-leak")
@safe unittest {
  struct S {
    void fun(int i) shared {
    }
  }
  shared S s;
  // its perfectly ok to point to a function on the stack
  auto sender = just(42).then(&s.fun);

  sender.syncWait();

  void disappearSender(Sender)(Sender s) @safe;
  // but the sender can't leak now
  static assert(!__traits(compiles, disappearSender(sender)));
}
