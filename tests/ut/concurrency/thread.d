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

  task.sync_wait().should == thisThreadID;
  scheduledTask.sync_wait().shouldNotEqual(thisThreadID);

  auto ts = whenAll(scheduledTask, scheduledTask).sync_wait();
  ts[0].shouldNotEqual(ts[1]);
}
