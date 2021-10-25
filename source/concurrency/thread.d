module concurrency.thread;

import concurrency.executor;
import concurrency.scheduler;
import concurrency.sender;
import concepts;
import core.sync.semaphore : Semaphore;

LocalThreadExecutor getLocalThreadExecutor() @safe {
  static LocalThreadExecutor localThreadExecutor;
  if (localThreadExecutor is null)
    localThreadExecutor = new LocalThreadExecutor();
  return localThreadExecutor;
}

class LocalThreadExecutor : Executor {
  import core.atomic : atomicOp, atomicStore, atomicLoad, cas;
  import std.concurrency : Tid, thisTid, send, receive;
  private {
    Tid tid;
  }

  this() @safe {
    tid = thisTid;
  }

  void execute(VoidDelegate dg) @trusted {
    version (unittest) {
      // NOTE: We must call the delegate on the current thread instead of going to the main one
      // the reason is that there is no nursery running on the main one because we are running unit tests
      // when SIL becomes multithreaded we can revisit this
      dg();
    } else {
      if (isInContext)
        dg();
      else
        (cast() tid).send(dg);
    }
  }

  void execute(VoidFunction fn) @trusted {
    version (unittest) {
      fn();
    } else {
      if (isInContext)
        fn();
      else
        (cast() tid).send(fn);
    }
  }

  bool isInContext() @trusted {
    return thisTid == cast()tid;
  }
}

package struct LocalThreadWorker {
  import core.time : Duration, msecs, hnsecs;
  import std.concurrency : Tid, thisTid, send, receive, receiveTimeout;
  import concurrency.scheduler : Timer, TimerTrigger, TimerDelegate;

  static struct AddTimer {
    Timer timer;
    Duration dur;
  }
  static struct RemoveTimer {
    Timer timer;
  }

  private {
    Tid tid;
    shared int counter;
    shared ulong nextTimerId;
  }

  this(LocalThreadExecutor e) @safe {
    this.tid = e.tid;
  }

  this(Tid tid) @safe {
    this.tid = tid;
  }

  void start() @trusted {
    assert(isInContext); // start can only be called on the thread
    import concurrency.timingwheels;
    import std.datetime.systime : Clock;
    TimingWheels!Timer wheels;
    auto ticks = 1.msecs; // represents the granularity
    wheels.init();
    bool running = true;
    auto addTimerHandler = (AddTimer cmd) scope {
      auto real_now = Clock.currStdTime;
      auto tw_now = wheels.currStdTime(ticks);
      auto delay = (real_now - tw_now).hnsecs;
      auto at = (cmd.dur + delay)/ticks;
      wheels.schedule(cmd.timer, at);
    };
    auto removeTimerHandler = (RemoveTimer cmd) scope {
      wheels.cancel(cmd.timer);
      cmd.timer.dg(TimerTrigger.cancel);
    };
    while (running) {
      VoidFunction vFunc = null;
      VoidDelegate vDel = null;
      import std.meta : AliasSeq;
      alias handlers = AliasSeq!((VoidFunction fn) => vFunc = fn,
                                 (VoidDelegate dg) => vDel = dg,
                                 addTimerHandler,
                                 removeTimerHandler,
                                 (bool _){running = false;}
                                 );
      auto nextTrigger = wheels.timeUntilNextEvent(ticks, Clock.currStdTime);
      bool handleIt = false;
      if (nextTrigger.isNull()) {
        receive(handlers);
        goto handleIt;
      } else {
        if (nextTrigger.get > 0.msecs) {
          if (receiveTimeout(nextTrigger.get, handlers)) {
            goto handleIt;
          }
        }
        int advance = wheels.ticksToCatchUp(ticks, Clock.currStdTime);
        if (advance > 0) {
          auto wr = wheels.advance(advance);
          foreach(t; wr.timers) {
            t.dg(TimerTrigger.trigger);
          }
        }
        continue;
      }
    handleIt:
      if (vFunc !is null) {
        vFunc();
      }
      if (vDel !is null) {
        vDel();
      }
    }
    version (unittest) {
      import std.variant : Variant;
      import core.time : seconds;
      while(receiveTimeout(seconds(-1),(Variant v){
            import std.stdio;
            writeln("Got unwanted message ", v);
            assert(0);
          })) {}
    }
  }

  void schedule(VoidDelegate dg) {
    tid.send(dg);
  }

  Timer addTimer(TimerDelegate dg, Duration dur) @trusted {
    import core.atomic : atomicOp;
    ulong id = nextTimerId.atomicOp!("+=")(1);
    Timer timer = Timer(dg, id);
    tid.send(AddTimer(timer, dur));
    return timer;
  }

  void cancelTimer(Timer timer) @trusted {
    tid.send(RemoveTimer(timer));
  }

  void stop() nothrow @trusted {
    try {
      (cast()tid).send(false);
    } catch (Exception e) {
      assert(false, e.msg);
    }
  }

  bool isInContext() @trusted {
    return thisTid == cast()tid;
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
  import std.concurrency;
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
  auto getScheduler() scope @safe {
    return StdTaskPoolProtoScheduler(pool);
  }
  auto getScheduler() scope @trusted shared {
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
