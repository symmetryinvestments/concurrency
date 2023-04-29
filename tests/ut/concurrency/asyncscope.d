module ut.concurrency.asyncscope;

import concurrency.asyncscope;
import concurrency : syncWait;
import concurrency.sender : VoidSender, DoneSender, ThrowingSender;
import concurrency.stoptoken : StopToken;
import unit_threaded;

@("cleanup.empty")
@safe unittest {
  auto s = asyncScope();
  s.cleanup.syncWait.assumeOk;
  s.cleanup.syncWait.assumeOk; // test twice
}

@("cleanup.voidsender.single")
@safe unittest {
  auto s = asyncScope();
  s.spawn(VoidSender()).should == true;
  s.cleanup.syncWait.assumeOk;
  s.cleanup.syncWait.assumeOk; // test twice
}

@("cleanup.voidsender.triple")
@safe unittest {
  auto s = asyncScope();
  s.spawn(VoidSender()).should == true;
  s.spawn(VoidSender()).should == true;
  s.spawn(VoidSender()).should == true;
  s.cleanup.syncWait.assumeOk;
  s.cleanup.syncWait.assumeOk; // test twice
}

@("cleanup.waitingsender.single")
@safe unittest {
  auto s = asyncScope();
  s.spawn(waitingTask).should == true;
  s.cleanup.syncWait.assumeOk;
  s.cleanup.syncWait.assumeOk; // test twice
}

@("cleanup.waitingsender.triple")
@safe unittest {
  auto s = asyncScope();
  s.spawn(waitingTask).should == true;
  s.spawn(waitingTask).should == true;
  s.spawn(waitingTask).should == true;
  s.cleanup.syncWait.assumeOk;
  s.cleanup.syncWait.assumeOk; // test twice
}

@("spawn.stopped")
@safe unittest {
  auto s = asyncScope();
  s.cleanup.syncWait.assumeOk;
  s.spawn(VoidSender()).should == false;
}

@("spawn.error")
@safe unittest {
  auto s = asyncScope();
  s.spawn(ThrowingSender()).should == true;
  s.cleanup.syncWait.assumeOk.shouldThrow;
  s.cleanup.syncWait.assumeOk.shouldThrow; // test twice
}

@("spawn.reentry")
@safe unittest {
  import concurrency.sender : justFrom;
  auto s = asyncScope();
  s.spawn(justFrom(() shared { s.spawn(VoidSender()); })).should == true;
  s.cleanup.syncWait.assumeOk;
}

@("spawn.value.transform")
@safe unittest {
  import concurrency.sender : just;
  import concurrency.operations : then;
  auto s = asyncScope();
  s.spawn(just(42).then((int) {})).should == true;
  s.cleanup.syncWait.assumeOk;
  s.cleanup.syncWait.assumeOk; // test twice
}

@("cleanup.scoped")
@safe unittest {
  import concurrency.operations : onTermination;
  import core.atomic : atomicStore;
  shared bool p;
  {
    auto s = asyncScope();
    s.spawn(waitingTask().onTermination(() shared { p.atomicStore(true); }));
  }
  p.should == true;
}

@("cleanup.nested.struct")
@safe unittest {
  import concurrency.operations : onTermination;
  import core.atomic : atomicStore;
  shared bool p;
  static struct S {
    shared AsyncScope s;
  }
  {
    S s = S(asyncScope);
    s.s.spawn(waitingTask().onTermination(() shared { p.atomicStore(true); }));
  }
  p.should == true;
}

@("cleanup.nested.class")
@trusted unittest {
  import concurrency.operations : onTermination;
  import core.atomic : atomicStore;
  shared bool p;
  static class S {
    shared AsyncScope s;
    this() {
      s = asyncScope();
    }
  }
  auto s = new S();
  s.s.spawn(waitingTask().onTermination(() shared { p.atomicStore(true); }));
  destroy(s);
  p.should == true;
}

@("spawn.assert.thread")
@safe unittest {
  import concurrency.thread : ThreadSender;
  import concurrency.operations : then;
  auto fail = ThreadSender().then(() shared {
      assert(false, "bad things happen");
    });
  auto s = asyncScope();

  s.spawn(fail).should == true;
  s.cleanup.syncWait.shouldThrow!Throwable;
}

@("spawn.assert.inline")
@trusted unittest {
  import concurrency.thread : ThreadSender;
  import concurrency.sender : justFrom;

  auto fail = justFrom(() shared {
      assert(0, "bad things happen 2");
    });
  auto s = asyncScope();

  s.spawn(fail).shouldThrow!Throwable;
  s.cleanup.syncWait.shouldThrow!Throwable;
}

@("cleanup.assert.then")
@safe unittest {
  import concurrency.thread : ThreadSender;
  import concurrency.operations : then;
  auto s = asyncScope();

  s.cleanup.then(() shared { assert(false, "Ohh no!"); }).syncWait.shouldThrow!Throwable;
}

auto waitingTask() {
  import concurrency.thread : ThreadSender;
  import concurrency.operations : withStopToken;

  return ThreadSender().withStopToken((StopToken token) @trusted {
      import core.thread : Thread;
      while (!token.isStopRequested) { Thread.yield(); }
    });
}

@("withScheduler")
@safe unittest {
  import concurrency.sender : VoidSender;
  import concurrency.operations : withScheduler;
  import concurrency.scheduler : localThreadScheduler;
  auto s = asyncScope();

  s.spawn(VoidSender().withScheduler(localThreadScheduler));
  s.cleanup.syncWait.assumeOk;
}

@("onComplete.inline")
@safe unittest {
  auto s = asyncScope();

  s.stop();
  s.onComplete().syncWait.assumeOk;
}

@("onComplete.wait")
@safe unittest {
  import concurrency.thread : ThreadSender;
  import concurrency.stoptoken : StopSource;
  import concurrency.operations : then;

  auto source = new shared StopSource();
  auto s = asyncScope(source);

  s.spawn(ThreadSender().then(() shared @trusted {
        import core.thread : Thread;
        import core.time : msecs;
        Thread.sleep(10.msecs);
        source.stop();
      }));

  s.onComplete().syncWait.assumeOk;
}
