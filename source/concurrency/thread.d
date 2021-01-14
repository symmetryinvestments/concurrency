module concurrency.thread;

import concurrency.executor;
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
    shared bool running;
    shared int counter;
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

  void start() @trusted {
    if (atomicOp!"+="(counter, 1) < 1)
      return;
    assert(isInContext); // start can only be called on the thread
    atomicStore(running, true);
    while (atomicLoad(running)) {
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
    if (atomicLoad(counter) > 0) {
      atomicStore(running, true);
    }
  }

  void stop() nothrow @trusted {
    try {
      atomicOp!"-="(counter, 1);
      if (cas(&running, true, false)) {
        (cast()tid).send(false);
      }
    } catch (Exception e) {
      assert(false, e.msg);
    }
  }

  bool isInContext() @trusted {
    return thisTid == cast()tid;
  }
}

void executeInNewThread(VoidFunction fn) @system {
  import concurrency.utils : closure;
  import core.thread : Thread, thread_detachThis;
  version (Posix) import core.sys.posix.pthread : pthread_detach, pthread_self;

  new Thread(cast(void delegate())closure((VoidFunction fn) {
        fn(); //thread_detachThis(); NOTE: see git.symmetry.dev/SIL/plugins/alpha/web/-/issues/3
        version (Posix)
          pthread_detach(pthread_self);
      }, fn)).start();
}

void executeInNewThread(VoidDelegate fn) @system {
  import concurrency.utils : closure;
  import core.thread : Thread, thread_detachThis;
  version (Posix) import core.sys.posix.pthread : pthread_detach, pthread_self;
  new Thread(cast(void delegate())closure((VoidDelegate fn) {
        fn(); //thread_detachThis(); NOTE: see git.symmetry.dev/SIL/plugins/alpha/web/-/issues/3
        version (Posix)
          pthread_detach(pthread_self);
      }, fn)).start();
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
  static if (is(RT == void)) {
    executor.execute(cast(VoidDelegate)() { work(args); localSemaphore.notify(); });
    semaphore.wait();
  } else {
    RT result;
    executor.execute(cast(VoidDelegate)() { result = work(args); localSemaphore.notify(); });
    semaphore.wait();
    return result;
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
    void start() @trusted {
      import concurrency.utils : closure;
      import concurrency.receiver : setValueOrError;
      executeInNewThread(closure((Receiver receiver) shared @safe {
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
