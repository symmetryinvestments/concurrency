module ut.concurrency.sender;

import concurrency;
import concurrency.sender;
import concurrency.thread;
import concurrency.operations;
import concurrency.receiver;
import unit_threaded;
import core.atomic : atomicOp;
import mir.algebraic: value = assumeOk, assumeOk, match;

@("syncWait.value")
@safe unittest {
  ValueSender!(int)(5).syncWait.value.shouldEqual(5);
  whenAll(just(5), ThrowingSender()).syncWait.value.shouldThrow();
  whenAll(just(5), DoneSender()).syncWait.value.shouldThrow();
}

@("syncWait.assumeOk")
@safe unittest {
  ThrowingSender().syncWait.assumeOk.shouldThrow();
  DoneSender().syncWait.assumeOk.shouldThrow();
  ErrorSender(new Exception("Failure")).syncWait.assumeOk.shouldThrow();
}

@("syncWait.match")
@safe unittest {
  ValueSender!(int)(5).syncWait.match!((int i) => true, "false").should == true;
}

@("syncWait.match.void")
@safe unittest {
  VoidSender().syncWait.match!(() => true, "false").should == true;
}

@("syncWait.nested.basic")
@safe unittest {
  import concurrency.stoptoken;
  auto source = new shared StopSource();

  justFrom(() shared {
      VoidSender().withStopToken((StopToken token){
          source.stop();
          token.isStopRequested.should == true;
        }).syncWait().isCancelled.should == true;
    }).syncWait(source).isCancelled.should == true;
}

@("syncWait.nested.thread")
@safe unittest {
  import concurrency.stoptoken;
  auto source = new shared StopSource();

  justFrom(() shared {
      VoidSender().withStopToken((StopToken token){
          source.stop();
          token.isStopRequested.should == true;
        }).syncWait().isCancelled.should == true;
    }).via(ThreadSender()).syncWait(source).isCancelled.should == true;
}

@("syncWait.nested.threadpool")
@safe unittest {
  import concurrency.stoptoken;
  auto source = new shared StopSource();

  auto pool = stdTaskPool(2);

  justFrom(() shared {
      VoidSender().withStopToken((StopToken token){
          source.stop();
          token.isStopRequested.should == true;
        }).syncWait().isCancelled.should == true;
    }).via(pool.getScheduler().schedule()).syncWait(source).isCancelled.should == true;
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
  ValueSender!void().syncWait().assumeOk;
}

@("syncWait.thread")
@safe unittest {
  ThreadSender().syncWait.assumeOk;
}

@("syncWait.thread.then.value")
@safe unittest {
  ThreadSender().then(() shared => 2*3).syncWait.value.shouldEqual(6);
}

@("syncWait.thread.then.exception")
@safe unittest {
  bool delegate() @safe shared dg = () shared { throw new Exception("Exceptions are forwarded"); };
  ThreadSender()
    .then(dg)
    .syncWait()
    .isError.should == true;
}

@("toSenderObject.value")
@safe unittest {
  ValueSender!(int)(4).toSenderObject.syncWait.value.shouldEqual(4);
}

@("toSenderObject.thread")
@safe unittest {
  ThreadSender().then(() shared => 2*3+1).toSenderObject.syncWait.value.shouldEqual(7);
}

@("via.threadsender.error")
@safe unittest {
  ThrowingSender().via(ThreadSender()).syncWait().isError.should == true;
}

@("toShared.basic")
@safe unittest {
  import std.typecons : tuple;

  shared int g;

  auto s = just(1)
    .then((int i) @trusted shared { return g.atomicOp!"+="(1); })
    .toShared();

  whenAll(s, s).syncWait.value.should == tuple(1,1);
  race(s, s).syncWait.value.should == 1;
  s.syncWait.value.should == 1;
  s.syncWait.value.should == 1;

  s.reset();
  s.syncWait.value.should == 2;
  s.syncWait.value.should == 2;
  whenAll(s, s).syncWait.value.should == tuple(2,2);
  race(s, s).syncWait.value.should == 2;
}

@("toShared.via.thread")
@safe unittest {
  import concurrency.operations.toshared;

  shared int g;

  auto s = just(1)
    .then((int i) @trusted shared { return g.atomicOp!"+="(1); })
    .via(ThreadSender())
    .toShared();

  s.syncWait.value.should == 1;
  s.syncWait.value.should == 1;

  s.reset();
  s.syncWait.value.should == 2;
  s.syncWait.value.should == 2;
}

@("toShared.error")
@safe unittest {
  shared int g;

  auto s = VoidSender()
    .then(() @trusted shared { g.atomicOp!"+="(1); throw new Exception("Error"); })
    .toShared();

  s.syncWait.assumeOk.shouldThrowWithMessage("Error");
  g.should == 1;
  s.syncWait.assumeOk.shouldThrowWithMessage("Error");
  g.should == 1;

  race(s, s).syncWait.assumeOk.shouldThrowWithMessage("Error");
  g.should == 1;

  s.reset();
  s.syncWait.assumeOk.shouldThrowWithMessage("Error");
  g.should == 2;
}

@("toShared.done")
@safe unittest {
  shared int g;

  auto s = DoneSender()
    .via(VoidSender()
         .then(() @trusted shared { g.atomicOp!"+="(1); }))
    .toShared();

  s.syncWait.isCancelled.should == true;
  g.should == 1;
  s.syncWait.isCancelled.should == true;
  g.should == 1;

  race(s, s).syncWait.isCancelled.should == true;
  g.should == 1;

  s.reset();
  s.syncWait.isCancelled.should == true;
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

  whenAll(waiting.toShared().withStopSource(source), stopper).syncWait.isCancelled.should == true;

  g.atomicLoad.should == true;
}

@("toShared.scheduler")
@safe unittest {
  import core.time : msecs;
  // by default toShared doesn't support scheduling
  static assert(!__traits(compiles, { DelaySender(1.msecs).toShared().syncWait().assumeOk; }));
  // have to pass scheduler explicitly
  import concurrency.scheduler : localThreadScheduler;
  DelaySender(1.msecs).toShared(localThreadScheduler).syncWait().assumeOk;
}

@("toShared.nursery")
@safe unittest {
  /// just see if we can instantiate
  import concurrency.nursery;
  import concurrency.scheduler;
  auto n = new shared Nursery();
  auto s = n.toShared(localThreadScheduler());
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
    auto connect(Receiver)(return Receiver receiver) @safe scope return {
      // ensure NRVO
      auto op = Op!Receiver(receiver);
      return op;
    }
  }
  NRVOSender().syncWait().assumeOk;
  NRVOSender().via(ThreadSender()).syncWait().assumeOk;
  whenAll(NRVOSender(),VoidSender()).syncWait.assumeOk;
  whenAll(VoidSender(),NRVOSender()).syncWait.assumeOk;
  race(NRVOSender(),NRVOSender()).syncWait.assumeOk;
}

@("justFrom")
@safe unittest {
  justFrom(() shared =>42).syncWait.value.should == 42;
}

@("justFrom.exception")
@safe unittest {
  justFrom(() shared { throw new Exception("failure"); }).syncWait.isError.should == true;
}

@("delay")
@safe unittest {
  import core.time : msecs;

  race(delay(20.msecs).then(() shared => 2),
       delay(1.msecs).then(() shared => 1)).syncWait.value.should == 1;
}

@("promise.basic")
@safe unittest {
  auto prom = promise!int;
  auto cont = prom.sender.then((int i) => i * 2);
  auto runner = justFrom(() shared => cast(void)prom.fulfill(72));

  whenAll(cont, runner).syncWait.value.should == 144;
}

@("promise.double")
@safe unittest {
  import std.typecons : tuple;
  auto prom = promise!int;
  auto cont = prom.sender.then((int i) => i * 2);
  auto runner = justFrom(() shared => cast(void)prom.fulfill(72));

  whenAll(cont, cont, runner).syncWait.value.should == tuple(144, 144);
}

@("promise.scheduler")
@safe unittest {
  import std.typecons : tuple;
  auto prom = promise!int;
  auto pool = stdTaskPool(2);

  auto cont = prom.sender.forwardOn(pool.getScheduler).then((int i) => i * 2);
  auto runner = justFrom(() shared => cast(void)prom.fulfill(72)).via(ThreadSender());

  whenAll(cont, cont, runner).syncWait.value.should == tuple(144, 144);
}

@("promise.then.exception.inline")
@safe unittest {
  auto prom = promise!int;
  auto cont = prom.sender.then((int i) { throw new Exception("nope"); });
  prom.fulfill(33);
  cont.syncWait().assumeOk.shouldThrowWithMessage("nope");
}

@("promise.then.exception.thread")
@safe unittest {
  auto prom = promise!int;
  auto cont = prom.sender.then((int i) { throw new Exception("nope"); });
  auto runner = justFrom(() shared => cast(void)prom.fulfill(72)).via(ThreadSender());
  whenAll(cont, runner).syncWait().assumeOk.shouldThrowWithMessage("nope");
}

@("just.tuple")
@safe unittest {
  import std.typecons : tuple;
  import concurrency.stoptoken;
  just(14, 52).syncWait.value.should == tuple(14, 52);
  just(14, 53).then((int a, int b) => a*b).syncWait.value.should == 742;
  just(14, 54).withStopToken((StopToken s, int a, int b) => a*b).syncWait.value.should == 756;
}
