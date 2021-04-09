module concurrency.timer;

import concurrency.stoptoken;
import core.time : Duration;

// Determine if we are running on a Darwin platform
version (OSX) {
  version = Darwin;
} else version (iOS) {
  version = Darwin;
} else version (TVOS) {
  version = Darwin;
} else version (WatchOS) {
  version = Darwin;
}

// Determine posix implementation
version(Darwin) {
  version = kqueue;
}

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
    } else version (kqueue) {
      import core.atomic : atomicLoad, MemoryOrder;
      import core.stdc.errno : errno, EINTR;
      import core.stdc.stdio : perror;
      import core.stdc.stdint : uintptr_t;
      import core.sys.posix.sys.time: timespec;
      import std.datetime.stopwatch : AutoStart, StopWatch;
      import std.exception : ErrnoException;

      version(Darwin) {
        import core.sys.darwin.sys.event;
      }

      shared bool shared_stopped = false;

      // Start the timer now so we count the overhead of setting up the kqueue
      auto sw = StopWatch(AutoStart.yes);

      // Create a new kqueue object which is referenced by a file descriptor
      shared immutable(int) kq_fd = kqueue();
      if (kq_fd == -1) {
        throw new ErrnoException("kqueue failed");
      }

      // Close the file descriptor and release the kqueue on exit. The file descriptor is shared
      // with the callback which runs asynchronously to this thread. The ordering of the resource
      // cleanup must correctly sequence by first detaching the callback and only then closing the
      // file descriptor after the access hazard has been discharged!
      scope(exit) {
        import core.sys.posix.unistd : close;
        if(close(kq_fd) == -1) {
          perror("closing kqueue file descriptor");
        }
      }

      // Kqueue user events use an integer to identify many distinct events on
      // the same queue.
      enum uintptr_t STOP_EVENT_IDENTIFIER = 0;

      // Configure the user event filter on the queue to wait for the
      // callback's trigger
      kevent_t event;
      EV_SET(&event, STOP_EVENT_IDENTIFIER, EVFILT_USER, EV_ADD | EV_ONESHOT, 0, 0, null);
      if(kevent(kq_fd, &event, 1, null, 0, null) == -1) {
        throw new ErrnoException("kevent failed while registering user event filter");
      }

      // Adding the callback sequences the initialization of shared_stopped and kq_fd in whatever thread
      // picks up the callback
      auto cb = stopToken.onStop(() shared @trusted {
        import core.atomic : atomicStore;
        atomicStore!(MemoryOrder.rel)(shared_stopped, true);

        // Trigger the user event with the registered identifier
        kevent_t trigger;
        EV_SET(&trigger, STOP_EVENT_IDENTIFIER, EVFILT_USER, 0, NOTE_TRIGGER, 0, null);
        if(kevent(kq_fd, &trigger, 1, null, 0, null) == -1) {
          perror("kevent failed while triggering user event");
        }
      });

      // Detaches the callback from the start token so that no other threads will have access to the
      // file descriptor for the kqueue. This must sequence before the kqueue file descriptor is
      // closure.
      scope(failure) {
        cb.dispose();
      }

      for(Duration elapsed = sw.peek(); elapsed < dur; elapsed = sw.peek) {
        const time_to_wait = timespec((dur - elapsed).split!("seconds", "nsecs").tupleof);

        // Block up until the remaining wait duration for an event corresponding to the trigger from
        // the callback
        const ev_count = kevent(kq_fd, null, 0, &event, 1, &time_to_wait);

        enum string kevent_wait_failure = "kevent failed while waiting for user event";

        if(ev_count == -1) {
          if(errno == EINTR) {
            continue;
          }

          throw new ErrnoException(kevent_wait_failure);
        }

        if(ev_count == 0) {
          continue;
        }

        // Check for out-of-band error return in the event stream
        if(event.flags & EV_ERROR) {
          // The event data contains the error code
          immutable(int) error_code = cast(int) event.data;

          if(error_code == EINTR) {
            continue;
          }

          throw new ErrnoException(kevent_wait_failure, error_code);
        }

        if((event.flags & EVFILT_USER) && (event.ident == STOP_EVENT_IDENTIFIER)) {
          break;
        }
      }

      // Dispose of the callback before sequencing load of shared_stopped
      cb.dispose();

      return atomicLoad!(MemoryOrder.acq)(shared_stopped);
    } else version (linux) {
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
