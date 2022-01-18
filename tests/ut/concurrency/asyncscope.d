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

auto waitingTask() {
  import concurrency.thread : ThreadSender;
  import concurrency.operations : withStopToken;

  return ThreadSender().withStopToken((StopToken token) @trusted {
      import core.thread : Thread;
      while (!token.isStopRequested) { Thread.yield(); }
    });
}
