module ut.concurrency.sender;

import concurrency;
import concurrency.sender;
import concurrency.thread;
import concurrency.operations;
import concurrency.receiver;
import unit_threaded;
import core.atomic : atomicOp;

@("sync_wait.value")
@safe unittest {
  ValueSender!(int)(5).sync_wait().shouldEqual(5);
}

@("value.start.attributes.1")
@safe nothrow @nogc unittest {
  ValueSender!(int)(5).connect(NullReceiver!int()).start();
}

@("value.start.attributes.2")
@safe nothrow unittest {
  ValueSender!(int)(5).connect(ThrowingNullReceiver!int()).start();
}

@("value.void")
@safe unittest {
  ValueSender!void().sync_wait().should == true;
}

@("sync_wait.thread")
@safe unittest {
  ThreadSender().sync_wait().shouldEqual(true);
}

@("sync_wait.thread.then.value")
@safe unittest {
  ThreadSender().then(() shared => 2*3).sync_wait().shouldEqual(6);
}

@("sync_wait.thread.then.exception")
@safe unittest {
  bool delegate() @safe shared dg = () shared { throw new Exception("Exceptions are rethrown"); };
  ThreadSender()
    .then(dg)
    .sync_wait()
    .shouldThrow();
}

@("toSenderObject.value")
@safe unittest {
  ValueSender!(int)(4).toSenderObject.sync_wait().shouldEqual(4);
}

@("toSenderObject.thread")
@safe unittest {
  ThreadSender().then(() shared => 2*3+1).toSenderObject.sync_wait().shouldEqual(7);
}

@("via.threadsender.error")
@safe unittest {
  ThrowingSender().via(ThreadSender()).sync_wait().shouldThrow();
}

@("toShared.basic")
@safe unittest {
  import std.typecons : tuple;

  shared int g;

  auto s = just(1)
    .then((int i) @trusted shared { return g.atomicOp!"+="(1); })
    .toShared();

  whenAll(s, s).sync_wait.should == tuple(1,1);
  race(s, s).sync_wait.should == 1;
  s.sync_wait.should == 1;
  s.sync_wait.should == 1;

  s.reset();
  s.sync_wait.should == 2;
  s.sync_wait.should == 2;
  whenAll(s, s).sync_wait.should == tuple(2,2);
  race(s, s).sync_wait.should == 2;
}

@("toShared.via.thread")
@safe unittest {
  import concurrency.operations.toshared;

  shared int g;

  auto s = just(1)
    .then((int i) @trusted shared { return g.atomicOp!"+="(1); })
    .via(ThreadSender())
    .toShared();

  race(s, s).sync_wait.should == 1;
  s.reset();
  race(s, s).sync_wait.should == 2;
}

@("toShared.error")
@safe unittest {
  shared int g;

  auto s = VoidSender()
    .then(() @trusted shared { g.atomicOp!"+="(1); throw new Exception("Error"); })
    .toShared();

  s.sync_wait().shouldThrowWithMessage("Error");
  g.should == 1;
  s.sync_wait().shouldThrowWithMessage("Error");
  g.should == 1;

  race(s, s).sync_wait.shouldThrowWithMessage("Error");
  g.should == 1;

  s.reset();
  s.sync_wait.shouldThrowWithMessage("Error");
  g.should == 2;
}

@("toShared.done")
@safe unittest {
  shared int g;

  auto s = DoneSender()
    .via(VoidSender()
         .then(() @trusted shared { g.atomicOp!"+="(1); }))
    .toShared();

  s.sync_wait().should == false;
  g.should == 1;
  s.sync_wait().should == false;
  g.should == 1;

  race(s, s).sync_wait.should == false;
  g.should == 1;

  s.reset();
  s.sync_wait.should == false;
  g.should == 2;
}

@("toShared.stop")
@safe unittest {
  import concurrency.stoptoken;
  import core.atomic : atomicStore, atomicLoad;
  shared bool g;

  auto waiting = ThreadSender().withStopToken((StopToken token) @trusted {
      while (!token.isStopRequested) { }
      g.atomicStore(true);
    });
  auto source = new StopSource();
  auto stopper = just(source).then((StopSource source) shared { source.stop(); });

  whenAll(waiting.toShared().withStopSource(source), stopper).sync_wait().should == false;

  g.atomicLoad.should == true;
}

@("toShared.scheduler")
@safe unittest {
  import core.time : msecs;
  // by default toShared doesn't support scheduling
  static assert(!__traits(compiles, { DelaySender(1.msecs).toShared().sync_wait().should == true; }));
  // have to pass scheduler explicitly
  import concurrency.scheduler : localThreadScheduler;
  DelaySender(1.msecs).toShared(localThreadScheduler).sync_wait().should == true;
}

@("nvro")
@safe unittest {
  static struct Op(Receiver) {
    Receiver receiver;
    void* atConstructor;
    @disable this(ref return scope typeof(this) rhs);
    this(Receiver receiver) @trusted {
      this.receiver = receiver;
      atConstructor = cast(void*)&this;
    }
    void start() @trusted nothrow {
      void* atStart = cast(void*)&this;
      receiver.setValue(atConstructor == atStart);
    }
  }
  static struct NRVOSender {
    alias Value = bool;
    auto connect(Receiver)(Receiver receiver) @safe {
      // ensure NRVO
      auto op = Op!Receiver(receiver);
      return op;
    }
  }
  NRVOSender().sync_wait().should == true;
  NRVOSender().via(ThreadSender()).sync_wait().should == true;
  whenAll(NRVOSender(),VoidSender()).sync_wait.should == true;
  whenAll(VoidSender(),NRVOSender()).sync_wait.should == true;
  race(NRVOSender(),NRVOSender()).sync_wait.should == true;
}

@("justFrom")
@safe unittest {
  justFrom(() shared =>42).sync_wait.should == 42;
}

@("delay")
@safe unittest {
  import core.time : msecs;

  race(delay(2.msecs).then(() shared => 2),
       delay(1.msecs).then(() shared => 1)).sync_wait.should == 1;
}
