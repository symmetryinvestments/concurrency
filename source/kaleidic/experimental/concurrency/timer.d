module kaleidic.experimental.concurrency.timer;

import kaleidic.experimental.concurrency.stoptoken;
import core.time : Duration;

/// waits for dur and returns true
/// or false when stoptoken is triggered
bool wait(StopToken stopToken, Duration dur) nothrow @trusted {
  // this is a optimisation,
  // it will still work if a stop is triggered before the
  // onStop handler is set
  if (stopToken.isStopRequested)
    return false;

  try {
    version (Windows) {
      import core.sync.mutex : Mutex;
      import core.sync.condition : Condition;
      import kaleidic.lang.types : Variable;

      auto m = new Mutex();
      auto cond = new Condition(m);
      auto cb = stopToken.onStop(cast(void delegate() shared nothrow @safe)() nothrow @trusted {
          m.lock_nothrow();
          scope (exit)
            m.unlock_nothrow();
          try {
            cond.notify();
          }
          catch (Exception e) {
            assert(false, e.msg);
          }
        });
      scope (exit)
        cb.dispose();

      /// wait returns true if notified, we want to return false in that case as it signifies cancellation
      m.lock_nothrow();
      scope(exit) m.unlock_nothrow();
      return !cond.wait(dur);
    } else version (Posix) {
      import core.sys.linux.timerfd;
      import core.sys.linux.sys.eventfd;
      import core.sys.posix.sys.select;
      import std.exception : ErrnoException;
      import core.sys.posix.unistd;
      import core.stdc.errno;

      shared int stopfd = eventfd(0, EFD_CLOEXEC);
      if (stopfd == -1)
        throw new ErrnoException("eventfd failed");

      auto cb = stopToken.onStop(() shared @trusted {
          ulong b = 1;
          write(stopfd, &b, typeof(b).sizeof);
        });
      scope (exit) {
        cb.dispose();
        close(stopfd);
      }

      auto when = dur.split!("seconds", "usecs");
      fd_set read_fds;
      FD_ZERO(&read_fds);
      FD_SET(stopfd, &read_fds);
      timeval tv;
      tv.tv_sec = when.seconds;
      tv.tv_usec = when.usecs;
    retry:
      const ret = select(stopfd + 1, &read_fds, null, null, &tv);
      if (ret == 0) {
        return true;
      } else if (ret == -1) {
        if (errno == EINTR || errno == EAGAIN)
          goto retry;
        throw new Exception("wtf select");
      } else {
        return false;
      }
    }
  } catch (Exception e) {
    assert(false, e.msg);
  }
}
