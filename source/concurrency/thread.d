module concurrency.thread;

import concurrency.executor;
import concurrency.scheduler;
import concurrency.sender;
import concepts;
import core.sync.semaphore : Semaphore;
import mir.algebraic;
import concurrency.scheduler : Timer;
import core.time : Duration;
import concurrency.data.queue.waitable;
import concurrency.data.queue.mpsc;

// we export the getLocalThreadExecutor function so that dynamic libraries
// can load it to access the host's localThreadExecutor TLS instance.
// Otherwise they would access their own local instance.
// should not be called directly by usercode, call `silThreadExecutor` instead.
export extern(C) LocalThreadExecutor concurrency_getLocalThreadExecutor() @safe {
  static LocalThreadExecutor localThreadExecutor;
  if (localThreadExecutor is null) {
    localThreadExecutor = new LocalThreadExecutor();
  }

  return localThreadExecutor;
}

LocalThreadExecutor getLocalThreadExecutor() @trusted {
  import concurrency.utils : dynamicLoad;
  static LocalThreadExecutor localThreadExecutor;
  if (localThreadExecutor is null) {
    localThreadExecutor = dynamicLoad!concurrency_getLocalThreadExecutor()();
  }
  return localThreadExecutor;
}

private struct AddTimer {
  Timer timer;
  Duration dur;
}

private struct RemoveTimer {
  Timer timer;
}

private struct Noop {}

private alias WorkItem = Variant!(typeof(null), VoidDelegate, VoidFunction, AddTimer, RemoveTimer, Noop); // null signifies end

private struct WorkNode {
  WorkItem payload;
  shared WorkNode* next;
}

private alias WorkQueue = WaitableQueue!(MPSCQueue!WorkNode);

class LocalThreadExecutor : Executor {
  import core.atomic : atomicOp, atomicStore, atomicLoad, cas;
  import core.thread : ThreadID;
  import std.process : thisThreadID;
  import concurrency.scheduler : Timer;
  import concurrency.timingwheels;

  static struct Node {
    VoidDelegate dg;
    Node* next;
  }
  private {
    ThreadID threadId;
    WorkQueue queue;
    TimingWheels!Timer wheels;
    shared ulong nextTimerId;
  }

  this() @safe {
    threadId = thisThreadID;
    queue = new WorkQueue;
  }

  void execute(VoidDelegate dg) @trusted {
    if (isInContext)
      dg();
    else
      queue.push(new WorkNode(WorkItem(dg)));
  }

  void execute(VoidFunction fn) @trusted {
    if (isInContext)
      fn();
    else
      queue.push(new WorkNode(WorkItem(fn)));
  }

  bool isInContext() @trusted {
    return thisThreadID == threadId;
  }
}

package struct LocalThreadWorker {
  import core.time : Duration, msecs, hnsecs;
  import concurrency.scheduler : Timer, TimerTrigger, TimerDelegate;

  private {
    LocalThreadExecutor executor;
  }

  this(LocalThreadExecutor e) @safe {
    executor = e;
  }

  private bool removeTimer(RemoveTimer cmd) {
    auto removed = executor.wheels.cancel(cmd.timer);
    cmd.timer.dg(TimerTrigger.cancel);
    return removed;
  }

  void start() @trusted {
    assert(isInContext); // start can only be called on the thread
    import std.datetime.systime : Clock;
    import std.array : Appender;
    Appender!(Timer[]) expiredTimers;
    auto ticks = 1.msecs; // represents the granularity
    executor.wheels.reset();
    executor.wheels.init();
    bool running = true;
    while (running) {
      import std.meta : AliasSeq;
      alias handlers = AliasSeq!((typeof(null)){running = false;},
                                 (RemoveTimer cmd) => removeTimer(cmd),
                                 (AddTimer cmd) {
                                   auto real_now = Clock.currStdTime;
                                   auto tw_now = executor.wheels.currStdTime(ticks);
                                   auto delay = (real_now - tw_now).hnsecs;
                                   auto at = (cmd.dur + delay)/ticks;
                                   executor.wheels.schedule(cmd.timer, at);
                                 },
                                 (VoidFunction fn) => fn(),
                                 (VoidDelegate dg) => dg(),
                                 (Noop){}
                                 );
      auto nextTrigger = executor.wheels.timeUntilNextEvent(ticks, Clock.currStdTime);
      bool handleIt = false;
      if (nextTrigger.isNull()) {
        auto work = executor.queue.pop();
        if (work is null)
          continue;
        work.payload.match!(handlers);
      } else {
        if (nextTrigger.get > 0.msecs) {
          auto work = executor.queue.pop(nextTrigger.get);
          if (work !is null) {

            work.payload.match!(handlers);
            continue;
          }
        }
        int advance = executor.wheels.ticksToCatchUp(ticks, Clock.currStdTime);
        if (advance > 0) {
          import std.range : retro;
          executor.wheels.advance(advance, expiredTimers);
          // NOTE timingwheels keeps the timers in reverse order, so we iterate in reverse
          foreach(t; expiredTimers.data.retro) {
            t.dg(TimerTrigger.trigger);
          }
          expiredTimers.shrinkTo(0);
        }
      }
    }
    version (unittest) {
      if (!executor.queue.empty) {
        auto work = executor.queue.pop();
        import std.stdio;
        writeln("Got unwanted message ", work);
        assert(0);
      }
      assert(executor.wheels.totalTimers == 0, "Still timers left");
    }
  }

  void schedule(VoidDelegate dg) {
    executor.queue.push(new WorkNode(WorkItem(dg)));
  }

  Timer addTimer(TimerDelegate dg, Duration dur) @trusted {
    import core.atomic : atomicOp;
    ulong id = executor.nextTimerId.atomicOp!("+=")(1);
    Timer timer = Timer(dg, id);
    executor.queue.push(new WorkNode(WorkItem(AddTimer(timer, dur))));
    return timer;
  }

  void cancelTimer(Timer timer) @trusted {
    import std.algorithm : find;

    auto cmd = RemoveTimer(timer);
    if (isInContext) {
      if (removeTimer(cmd))
        return;
      // if the timer is still in the queue, rewrite the queue node to a Noop
      auto nodes = executor.queue[].find!((node) {
          if (!node.payload._is!AddTimer)
            return false;
          return node.payload.get!AddTimer.timer.id == timer.id;
        });

      if (!nodes.empty) {
        nodes.front.payload = WorkItem(Noop());
      }
    } else
      executor.queue.push(new WorkNode(WorkItem(RemoveTimer(timer))));
  }

  void stop() nothrow @trusted {
    try {
      executor.queue.push(new WorkNode(WorkItem(null)));
    } catch (Exception e) {
      assert(false, e.msg);
    }
  }

  bool isInContext() @trusted {
    return executor.isInContext;
  }
}

private Semaphore localSemaphore() {
  static Semaphore semaphore;
  if (semaphore is null)
    semaphore = new Semaphore();
  return semaphore;
}

package void executeInNewThread(VoidFunction fn) @system nothrow {
  import concurrency.utils : closure;
  import core.thread : Thread, thread_detachThis, thread_detachInstance;
  version (Posix) import core.sys.posix.pthread : pthread_detach, pthread_self;

  auto t = new Thread(cast(void delegate())closure((VoidFunction fn) @trusted {
        fn();
        version (Posix)
          pthread_detach(pthread_self); //NOTE: see git.symmetry.dev/SIL/plugins/alpha/web/-/issues/3
      }, fn)).start();
  try {
    /*
      the isDaemon is really only a protecting against a race condition in druntime,
      which is only introduced because I am detaching the thread, which I need to do
      if I don't want to leak memory.

      If the isDaemon fails because the Thread is gone (unlikely) than it can't
      trigger unwanted behavior the isDaemon is preventing in the first place.

      So it is fine if the exception is ignored.
     */
    t.isDaemon = true; // is needed because of pthread_detach (otherwise there is a race between druntime joining and the thread exiting)
  } catch (Exception e) {}
}

package void executeInNewThread(VoidDelegate fn) @system nothrow {
  import concurrency.utils : closure;
  import core.thread : Thread, thread_detachThis, thread_detachInstance;
  version (Posix) import core.sys.posix.pthread : pthread_detach, pthread_self;

  auto t = new Thread(cast(void delegate())closure((VoidDelegate fn) @trusted {
        fn();
        version (Posix)
          pthread_detach(pthread_self); //NOTE: see git.symmetry.dev/SIL/plugins/alpha/web/-/issues/3
      }, fn)).start();
  try {
    /*
      the isDaemon is really only a protecting against a race condition in druntime,
      which is only introduced because I am detaching the thread, which I need to do
      if I don't want to leak memory.

      If the isDaemon fails because the Thread is gone (unlikely) then it can't
      trigger unwanted behavior the isDaemon is preventing in the first place.

      So it is fine if the exception is ignored.
    */
    t.isDaemon = true; // is needed because of pthread_detach (otherwise there is a race between druntime joining and the thread exiting)
  } catch (Exception e) {}
}

class ThreadExecutor : Executor {
  void execute(VoidFunction fn) @trusted {
    executeInNewThread(fn);
  }
  void execute(VoidDelegate fn) @trusted {
    executeInNewThread(fn);
  }
  bool isInContext() @safe { return false; }
}

auto executeAndWait(Executor, Work, Args...)(Executor executor, Work work, Args args) {
  import core.sync.semaphore;
  import std.traits;

  if (executor.isInContext)
    return work(args);

  Semaphore semaphore = localSemaphore();

  alias RT = ReturnType!Work;
  struct Context {
    Work work;
    Args args;
    Semaphore semaphore;
    static if (is(RT == void)) {
      void run() {
        work(args);
        semaphore.notify();
      }
    } else {
      RT result;
      void run() {
        result = work(args);
        semaphore.notify();
      }
    }
  }
  Context c = Context(work, args, semaphore);
  executor.execute(cast(VoidDelegate)&c.run);
  semaphore.wait();
  static if (!is(RT == void)) {
    return c.result;
  }
}

shared static this() {
  import concurrency.utils : resetScheduler;

  resetScheduler();
}

struct ThreadSender {
  static assert (models!(typeof(this), isSender));
  alias Value = void;
  static struct Op(Receiver) {
    private Receiver receiver;
    @disable this(ref return scope typeof(this) rhs);
    @disable this(this);
    this(Receiver receiver) {
      this.receiver = receiver;
    }
    void start() @trusted nothrow scope {
      executeInNewThread(cast(VoidDelegate)&run);
    }
    void run() @trusted {
      import concurrency.receiver : setValueOrError;
      import concurrency.error : clone;
      import concurrency : parentStopSource;

      parentStopSource = receiver.getStopToken().source;

      try {
        receiver.setValue();
      } catch (Exception e) {
        receiver.setError(e);
      } catch (Throwable t) {
        receiver.setError(t.clone());
      }

      parentStopSource = null;
    }
  }
  auto connect(Receiver)(return Receiver receiver) @safe scope return {
    // ensure NRVO
    auto op = Op!(Receiver)(receiver);
    return op;
  }
}

struct StdTaskPool {
  import std.parallelism : Task, TaskPool;
  TaskPool pool;
  @disable this(ref return scope typeof(this) rhs);
  @disable this(this);
  this(TaskPool pool) @trusted scope shared {
    this.pool = cast(shared)pool;
  }
  ~this() nothrow @trusted scope {
    try {
      pool.finish(true);
    } catch (Exception e) {
      // can't really happen
      assert(0);
    }
  }
  auto getScheduler() return @safe {
    return StdTaskPoolProtoScheduler(pool);
  }
  auto getScheduler() return @trusted shared {
    return StdTaskPoolProtoScheduler(cast()pool);
  }
}

shared(StdTaskPool) stdTaskPool(size_t nWorkers = 0) @safe {
  import std.parallelism : TaskPool;
  return shared StdTaskPool(new TaskPool(nWorkers));
}

struct StdTaskPoolProtoScheduler {
  import std.parallelism : TaskPool;
  TaskPool pool;
  auto schedule() {
    return TaskPoolSender(pool);
  }
  auto withBaseScheduler(Scheduler)(Scheduler scheduler) {
    return StdTaskPoolScheduler!(Scheduler)(pool, scheduler);
  }
}

private struct StdTaskPoolScheduler(Scheduler) {
  import std.parallelism : TaskPool;
  import core.time : Duration;
  TaskPool pool;
  Scheduler scheduler;
  auto schedule() {
    return TaskPoolSender(pool);
  }
  auto scheduleAfter(Duration run) {
    import concurrency.operations : via;
    return schedule().via(scheduler.scheduleAfter(run));
  }
}

private struct TaskPoolSender {
  import std.parallelism : Task, TaskPool, scopedTask, task;
  import std.traits : ReturnType;
  import concurrency.error : clone;
  alias Value = void;
  TaskPool pool;
  static struct Op(Receiver) {
    static void setValue(Receiver receiver) @trusted nothrow {
      import concurrency : parentStopSource;
      parentStopSource = receiver.getStopToken().source;
      try {
        receiver.setValue();
      } catch (Exception e) {
        receiver.setError(e);
      } catch (Throwable t) {
        receiver.setError(t.clone);
      }
      parentStopSource = null;
    }
    TaskPool pool;
    alias TaskType = typeof(task!setValue(Receiver.init));
    TaskType myTask;
    @disable this(ref return scope typeof(this) rhs);
    @disable this(this);
    this(Receiver receiver, TaskPool pool) @safe return scope {
      myTask = task!(setValue)(receiver);
      this.pool = pool;
    }
    void start() @trusted nothrow scope {
      try {
        pool.put(myTask);
      } catch (Exception e) {
        myTask.args[0].setError(e);
      }
    }
  }
  auto connect(Receiver)(return Receiver receiver) @safe scope return {
    // ensure NRVO
    auto op = Op!(Receiver)(receiver, pool);
    return op;
  }
}
