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
