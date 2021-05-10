module concurrency.thread;

import concurrency.executor;
import concurrency.scheduler;
import concurrency.sender;
import concepts;

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
  import std.concurrency : Tid, thisTid, send, receive;
  private {
    Tid tid;
    shared int counter;
  }

  this(LocalThreadExecutor e) @safe {
    this.tid = e.tid;
  }

  this(this) @disable;

  void start() @trusted {
    assert(isInContext); // start can only be called on the thread
    bool running = true;
    while (running) {
      VoidFunction vFunc = null;
      VoidDelegate vDel = null;
      receive((VoidFunction fn) => vFunc = fn,
              (VoidDelegate dg) => vDel = dg,
              (bool _){running = false;});
      /// work has to be run outside of receive (else the lock inside receive will be kept and then we cannot have work push new work)
      if (vFunc !is null) {
        vFunc();
      }
      if (vDel !is null) {
        vDel();
      }
    }
    // TODO: do we want to drain all VoidFunction/VoidDelegates here?
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

  static Semaphore semaphore;
  if (semaphore is null)
    semaphore = new Semaphore();
  auto localSemaphore = semaphore;

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
  Context c = Context(work, args, localSemaphore);
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

@models!(ThreadSender, isSender)
struct ThreadSender {
  alias Value = void;
  private struct Op(Receiver) {
    private Receiver receiver;
    void start() @trusted nothrow {
      import concurrency.utils : closure;
      import concurrency.receiver : setValueOrError;
      executeInNewThread(closure((Receiver receiver) @safe {
            (() @trusted {try {
                receiver.setValueOrError();
              } catch (Throwable t) {
                import std.stdio;
                stderr.writeln(t);
                assert(0);
              }
            })();
          }, receiver));
    }
  }
  auto connect(Receiver)(Receiver receiver) {
    return Op!(Receiver)(receiver);
  }
}

@models!(ThreadScheduler, isScheduler)
struct ThreadScheduler {
  auto schedule() { return ThreadSender(); }
}
