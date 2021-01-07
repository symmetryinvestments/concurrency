module kaleidic.experimental.concurrency.signal;

struct SignalHandler {
  private __gshared void delegate(int) callback = null;
  private void delegate(int) oldCallback;
  extern (C) static void intr(int i) nothrow @nogc {
    if (callback is null)
      return;
    // TODO: this cast is a bit sketchy
    (cast(void delegate(int) nothrow @nogc) callback)(i);
  }

  version (Posix) {
    import core.sys.posix.signal;
    private sigaction_t[int] previous;
  } else version (Windows) {
    alias Fun = extern (C) void function(int) nothrow @nogc @system;
    private Fun[int] previous;
  } else static assert("Platform not supported");

  void setup(void delegate(int) cb) @trusted {
    oldCallback = callback;
    callback = cb;
  }

  void on(int s) @trusted {
    version (Posix) {
      import core.sys.posix.signal;

      sigaction_t old;
      sigset_t sigset;
      sigemptyset(&sigset);
      sigaction_t siginfo;
      siginfo.sa_handler = &intr;
      siginfo.sa_mask = sigset;
      siginfo.sa_flags = SA_RESTART;
      sigaction(s, &siginfo, &old);
    } else {
      import core.stdc.signal;
      Fun old = signal(s, &intr);
    }
    previous[s] = old;
  }

  void forward(int sig) @trusted {
    foreach(s, old; previous) {
      if (s != sig)
        continue;
      version (Posix) {
        if (old.sa_handler)
          old.sa_handler(s);
      }
      else if (old)
        old(s);
    }
  }

  void teardown() nothrow @trusted {
    callback = oldCallback;
    try {
    foreach(s, old; previous) {
      version (Posix) {
        sigaction(s, &old, null);
      } else {
        import core.stdc.signal;
        signal(s, old);
      }
    }
    } catch (Exception e) {}
  }
}
