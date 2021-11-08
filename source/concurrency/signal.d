module concurrency.signal;

import concurrency.stoptoken;

shared(StopSource) globalStopSource() @trusted {
  import core.atomic : atomicLoad;
  static StopSource localSource; // can't be shared else it is global
  if (localSource !is null)
    return cast(shared)localSource;

  if (globalSource.atomicLoad is null) {
    auto tmp = new shared StopSource();
    if (setGlobalStopSource(tmp)) {
      setupCtrlCHandler(tmp);
    }
  }
  localSource = cast()globalSource;
  return cast(shared)localSource;
}

/// Returns true if first to set (otherwise it is ignored)
bool setGlobalStopSource(shared StopSource stopSource) @safe {
  import core.atomic : atomicExchange;
  return atomicExchange(&globalSource, stopSource) is null;
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
    static int await() nothrow @nogc @trusted {
      (cast()event).wait();
      return lastSignal.atomicLoad!(MemoryOrder.acq)();
    }
    static void setup() @trusted {
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
    static int await() nothrow @nogc {
      ulong b;
      while(read(event, &b, typeof(b).sizeof) != typeof(b).sizeof) {}
      return lastSignal.atomicLoad!(MemoryOrder.acq)();
    }
    static void setup() {
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
    static int await() nothrow @nogc {
      ulong b;
      while(read(cast()selfPipe[0], &b, typeof(b).sizeof) != typeof(b).sizeof) {}
      return lastSignal.atomicLoad!(MemoryOrder.acq)();
    }
    static void setup() {
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
  static void launchHandlerThread() {
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
