module concurrency.asyncscope;

import concurrency.stoptoken;

enum Flag {
  locked = 0,
  stopped = 1,
  tick = 2
}

auto asyncScope() @safe {
  // ensure NRVO
  auto as = shared AsyncScope(new shared StopSource());
  return as;
}

struct AsyncScope {
private:
  import concurrency.bitfield : SharedBitField;
  import concurrency.sender : Promise;

  shared SharedBitField!Flag flag;
  shared Promise!void completion;
  shared StopSource stopSource;
  Throwable throwable;
  shared StopCallback cb;

  void forward() @trusted nothrow shared {
    import core.atomic : atomicLoad;
    auto t = throwable.atomicLoad();
    if (t !is null)
      completion.error(cast(Throwable)t);
    else
      completion.fulfill();
  }

  void complete() @safe nothrow shared {
    auto newState = flag.sub(Flag.tick);
    if (newState == 1) {
      forward();
    }
  }

  void setError(Throwable t) @trusted nothrow shared {
    import core.atomic : cas;
    cas(&throwable, cast(shared Throwable)null, cast(shared)t);
    stop();
    complete();
  }
public:
  @disable this(ref return scope typeof(this) rhs);
  @disable this(this);
  @disable this();

  ~this() @safe shared {
    import concurrency : syncWait;
    import core.atomic : atomicLoad;
    auto t = throwable.atomicLoad();
    if (t !is null && (cast(shared(Exception))t) is null)
      return;
    if (!completion.isCompleted)
      cleanup.syncWait();
  }

  this(shared StopSource stopSource) @trusted shared {
    completion = new shared Promise!void;
    this.stopSource = stopSource;
    cb = cast(shared)this.stopSource.onStop(() @safe shared nothrow => cast(void)this.stop());
  }

  auto cleanup() @safe shared {
    stop();
    return completion.sender();
  }

  bool stop() nothrow @trusted {
    return (cast(shared)this).stop();
  }

  bool stop() nothrow @trusted shared {
    cb.dispose();
    import core.atomic : MemoryOrder;
    if ((flag.load!(MemoryOrder.acq) & Flag.stopped) > 0)
      return false;

    auto newState = flag.add(Flag.stopped);
    if (newState == 1) {
      forward();
    }
    return stopSource.stop();
  }

  bool spawn(Sender)(Sender s) shared @trusted {
    import concurrency.sender : connectHeap;
    with (flag.update(0, Flag.tick)) {
      if ((oldState & Flag.stopped) == 1) {
        complete();
        return false;
      }
      try {
        s.connectHeap(AsyncScopeReceiver(&this)).start();
      } catch (Throwable t) {
        // we are required to catch the throwable here, otherwise
        // the destructor will wait infinitely for something that
        // no longer runs
        // by calling setError we ensure the internal state is correct
        setError(t);
        throw t;
      }
      return true;
    }
  }
}

struct AsyncScopeReceiver {
  private shared AsyncScope* s;
  void setValue() nothrow @safe {
    s.complete();
  }
  void setDone() nothrow @safe {
    s.complete();
  }
  void setError(Throwable t) nothrow @safe {
    s.setError(t);
  }
  auto getStopToken() nothrow @safe {
    import concurrency.stoptoken : StopToken;
    return StopToken(s.stopSource);
  }
  auto getScheduler() nothrow @safe {
    return NullScheduler();
  }
}

struct NullScheduler {}
