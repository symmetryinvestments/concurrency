module ut.concurrency.thread;

import concurrency;
import concurrency.sender;
import concurrency.thread;
import concurrency.operations;
import concurrency.receiver;
import unit_threaded;
import core.atomic : atomicOp;

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
