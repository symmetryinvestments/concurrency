module concurrency.signal;

import concurrency.stoptoken;

shared(StopSource) globalStopSource() @trusted {
  import core.atomic : atomicLoad, cas;

  if (globalSource.atomicLoad is null) {
    import concurrency.utils : dynamicLoad;
    auto ptr = getGlobalStopSourcePointer();

    if (auto source = (*ptr).atomicLoad) {
      globalSource = source;
      return globalSource;
    }

    auto tmp = new shared StopSource();
    if (ptr.cas(cast(shared StopSource)null, tmp)) {
      setupCtrlCHandler(tmp);
      globalSource = tmp;
    } else
      globalSource = (*ptr).atomicLoad;
  }
  return globalSource;
}

/// Returns true if first to set (otherwise it is ignored)
bool setGlobalStopSource(shared StopSource stopSource) @safe {
  import core.atomic : cas;
  auto ptr = getGlobalStopSourcePointer();
  if (!ptr.cas(cast(shared StopSource)null, stopSource))
    return false;
  globalSource = stopSource;
  return true;
}

/// Sets the stopSource to be called when receiving an interrupt
void setupCtrlCHandler(shared StopSource stopSource) @trusted {
  import core.sys.posix.signal;
  import core.atomic;

  if (stopSource is null)
    return;

  auto old = atomicExchange(&SignalHandler.signalStopSource, stopSource);
  if (old !is null)
    return;

  SignalHandler.setup();
  SignalHandler.launchHandlerThread();
  version (Windows) {
    import core.sys.windows.windows;
    SetConsoleCtrlHandler(&signalHandler, true);
  } else {
    static void handleSignal(int s) @trusted {
      import core.sys.posix.signal;
      sigaction_t old;
      sigset_t sigset;
      sigemptyset(&sigset);
      sigaction_t siginfo;
      siginfo.sa_handler = &signalHandler;
      siginfo.sa_mask = sigset;
      siginfo.sa_flags = SA_RESTART;
      sigaction(s, &siginfo, &old);
      // TODO: what to do with old?
    }

    handleSignal(SIGINT);
    handleSignal(SIGTERM);
  }
}

private static shared StopSource globalSource;

// we export this function so that dynamic libraries can load it to access
// the host's globalStopSource pointer.
// Otherwise they would access their own local instance.
// should not be called directly by usercode, instead use `globalStopSource`.
export extern(C) shared(StopSource*) concurrency_globalStopSourcePointer() @safe {
  return &globalSource;
}

private shared(StopSource*) getGlobalStopSourcePointer() @safe {
  import concurrency.utils : dynamicLoad;
  return dynamicLoad!concurrency_globalStopSourcePointer()();
}

struct SignalHandler {
  import core.atomic : atomicStore, atomicLoad, MemoryOrder, atomicExchange;
  import core.thread : Thread;
  static shared int lastSignal; // last signal received
  enum int ABORT = -1;
  version (Windows) {
    import core.sync.event : Event;
    private static shared Event event; // used to notify the dedicated thread to shutdown
    static void notify(int num) nothrow @nogc @trusted {
      lastSignal.atomicStore!(MemoryOrder.rel)(num);
      (cast()event).set();
    }
    private static int await() nothrow @nogc @trusted {
      (cast()event).wait();
      return lastSignal.atomicLoad!(MemoryOrder.acq)();
    }
    private static void setup() @trusted {
      (cast()event).initialize(false, false);
    }
  } else version (linux) {
    import core.sys.posix.unistd : write, read;
    private static shared int event; // eventfd to notify dedicated thread
    static void notify(int num) nothrow @nogc {
      lastSignal.atomicStore!(MemoryOrder.rel)(num);
      ulong b = 1;
      write(event, &b, typeof(b).sizeof);
    }
    private static int await() nothrow @nogc {
      ulong b;
      while(read(event, &b, typeof(b).sizeof) != typeof(b).sizeof) {}
      return lastSignal.atomicLoad!(MemoryOrder.acq)();
    }
    private static void setup() {
      import core.sys.linux.sys.eventfd;
      event = eventfd(0, EFD_CLOEXEC);
    }
  } else version (Posix) {
    import core.sys.posix.unistd : write, read, pipe;
    private static shared int[2] selfPipe; // self pipe to notify dedicated thread
    static void notify(int num) nothrow @nogc {
      lastSignal.atomicStore!(MemoryOrder.rel)(num);
      ulong b = 1;
      write(selfPipe[1], &b, typeof(b).sizeof);
    }
    private static int await() nothrow @nogc {
      ulong b;
      while(read(cast()selfPipe[0], &b, typeof(b).sizeof) != typeof(b).sizeof) {}
      return lastSignal.atomicLoad!(MemoryOrder.acq)();
    }
    private static void setup() {
      import std.exception : ErrnoException;
      if (pipe(cast(int[2])selfPipe) == -1)
        throw new ErrnoException("Failed to create self-pipe");
    }
  }
  private static void shutdown() {
    if (atomicLoad!(MemoryOrder.acq)(signalStopSource) !is null)
      SignalHandler.notify(ABORT);
  }
  private static shared StopSource signalStopSource;
  private static shared Thread handlerThread;
  private static void launchHandlerThread() {
    if (handlerThread.atomicLoad !is null)
      return;

    auto thread = new Thread((){
        for(;;) {
          if (SignalHandler.await() == ABORT) {
            return;
          }
          signalStopSource.stop();
        }
      });
    // This has to be a daemon thread otherwise the runtime will wait on it before calling the shared module destructor that stops it.
    thread.isDaemon = true;

    if (atomicExchange(&handlerThread, cast(shared)thread) !is null)
      return; // someone beat us to it

    thread.start();
  }
}

/// This is required to properly shutdown in the presence of sanitizers
shared static ~this() {
  import core.atomic : atomicExchange;
  import core.thread : Thread;
  SignalHandler.shutdown();
  if (auto thread = atomicExchange(&SignalHandler.handlerThread, null))
    (cast()thread).join();
}

version (Windows) {
  import core.sys.windows.windows;
  extern (Windows) static BOOL signalHandler(DWORD dwCtrlType) nothrow @system {
    import core.sys.posix.signal;
    if (dwCtrlType == CTRL_C_EVENT ||
        dwCtrlType == CTRL_BREAK_EVENT ||
        dwCtrlType == CTRL_CLOSE_EVENT ||
        dwCtrlType == CTRL_SHUTDOWN_EVENT) {
      SignalHandler.notify(SIGINT);
      return TRUE;
    }
    return FALSE;
  }
} else {
  extern (C) static void signalHandler(int i) nothrow @nogc {
    SignalHandler.notify(i);
  }
}
