module ut.concurrency.thread;

import concurrency;
import concurrency.sender;
import concurrency.thread;
import concurrency.operations;
import concurrency.receiver;
import unit_threaded;
import core.atomic : atomicOp;
import mir.algebraic: value = assumeOk;

@("stdTaskPool")
@safe unittest {
  import std.process : thisThreadID;
  static auto fun() @trusted {
    import core.thread : Thread;
    import core.time : msecs;
    Thread.sleep(10.msecs);
    return thisThreadID;
  }
  auto pool = stdTaskPool(2);

  auto task = justFrom(&fun);
  auto scheduledTask = task.on(pool.getScheduler);

  task.syncWait.value.should == thisThreadID;
  scheduledTask.syncWait.value.shouldNotEqual(thisThreadID);

  auto ts = whenAll(scheduledTask, scheduledTask).syncWait.value;
  ts[0].shouldNotEqual(ts[1]);
}

@("stdTaskPool.scope")
@safe unittest {
  void disappearScheduler(StdTaskPoolProtoScheduler p) @safe;
  void disappearSender(Sender)(Sender s) @safe;

  auto pool = stdTaskPool(2);

  auto scheduledTask = VoidSender().on(pool.getScheduler);

  // ensure we can't leak the scheduler
  static assert(!__traits(compiles, disappearScheduler(pool.getScheduler)));

  // ensure we can't leak a sender that scheduled on the scoped pool
  static assert(!__traits(compiles, disappearSender(scheduledTask)));
}

@("stdTaskPool.assert")
@system unittest {
  import std.exception : assertThrown;
  import core.exception : AssertError;
  auto pool = stdTaskPool(2);
  just(42).then((int i) => assert(i == 99, "i must be 99")).via(pool.getScheduler.schedule()).syncWait.assertThrown!(AssertError)("i must be 99");
}

@("ThreadSender.assert")
@system unittest {
  import std.exception : assertThrown;
  import core.exception : AssertError;
  just(42).then((int i) => assert(i == 99, "i must be 99")).via(ThreadSender()).syncWait.assertThrown!(AssertError)("i must be 99");
}

@("localThreadWorker.assert")
@system unittest {
  import std.exception : assertThrown;
  import core.exception : AssertError;
  just(42).then((int i) => assert(i == 99, "i must be 99")).syncWait.assertThrown!(AssertError)("i must be 99");
}

@("ThreadSender.whenAll.assert")
@system unittest {
  import std.exception : assertThrown;
  import core.time : msecs;
  import core.exception : AssertError;
  auto fail = just(42).then((int i) => assert(i == 99, "i must be 99")).via(ThreadSender());
  auto slow = delay(100.msecs);
  whenAll(fail,slow).syncWait.assertThrown!(AssertError)("i must be 99");
}
