module concurrency.stream;

import concurrency.stoptoken;
import concurrency.receiver;
import concurrency.sender : isSender;
import concepts;
import std.traits : hasFunctionAttributes;

/// A Stream is anything that has a `.collect` function that accepts a callable and returns a Sender.
/// Once the Sender is connected and started the Stream will call the callable zero or more times before one of the three terminal functions of the Receiver is called.

template CollectDelegate(ElementType) {
  static if (is(ElementType == void)) {
    alias CollectDelegate = void delegate() @safe shared;
  } else {
    alias CollectDelegate = void delegate(ElementType) @safe shared;
  }
}

/// checks that T is a Stream
void checkStream(T)() {
  import std.traits : ReturnType;
  alias DG = CollectDelegate!(T.ElementType);
  static if (is(typeof(T.collect!DG)))
    alias Sender = ReturnType!(T.collect!(DG));
  else
    alias Sender = ReturnType!(T.collect);
  static assert (models!(Sender, isSender));
}
enum isStream(T) = is(typeof(checkStream!T));

/// A polymorphic stream with elements of type T
interface StreamObjectBase(T) {
  import concurrency.sender : SenderObjectBase;
  alias ElementType = T;
  static assert (models!(typeof(this), isStream));
  alias DG = CollectDelegate!(ElementType);

  SenderObjectBase!void collect(DG dg) @safe;
}

/// A class extending from StreamObjectBase that wraps any Stream
class StreamObjectImpl(Stream) : StreamObjectBase!(Stream.ElementType) {
  import concurrency.receiver : ReceiverObjectBase;
  static assert (models!(typeof(this), isStream));
  private Stream stream;
  this(Stream stream) {
    this.stream = stream;
  }
  alias DG = CollectDelegate!(Stream.ElementType);

  SenderObjectBase!void collect(DG dg) {
    import concurrency.sender : toSenderObject;
    return stream.collect(dg).toSenderObject();
  }
}

/// Converts any Stream to a polymorphic StreamObject
StreamObjectBase!(Stream.ElementType) toStreamObject(Stream)(Stream stream) {
  static assert(models!(Stream, isStream));
  return new StreamObjectImpl!(Stream)(stream);
}

/*
  catch?
  combineLatest
  count
  debounce
  distinctUntilChanged
  drop
  dropWhile
  filter
  first
  firstOrNull
  flatMapConcat
  flatMapLatest
  flatMapMerge
  fold
  map
  mapLatest
  merge
  onEach
  onEmpty
  onStart
  onSubscription
  reduce (fold with no seed)
  retry
  retryWhen
  runningReduce
  sample
  scan (like runningReduce but with initial value)
  take
  takeWhile
  toList
  transform
  transformLatest
  zip
*/

/// Helper to construct a Stream, useful if the Stream you are modeling has a blocking loop
template loopStream(E) {
  alias DG = CollectDelegate!(E);
  auto loopStream(T)(T t) {
    static struct LoopStream {
      static assert(models!(typeof(this), isStream));
      alias ElementType = E;
      static struct LoopOp(Receiver) {
        T t;
        DG dg;
        Receiver receiver;
        void start() @safe nothrow {
          try {
            t.loop(dg, receiver.getStopToken);
          } catch (Exception e) {
            receiver.setError(e);
          }
          if (receiver.getStopToken().isStopRequested)
            receiver.setDone();
          else
            receiver.setValueOrError();
        }
      }
      static struct LoopSender {
        alias Value = void;
        T t;
        DG dg;
        auto connect(Receiver)(Receiver receiver) {
          return LoopOp!(Receiver)(t, dg, receiver);
        }
      }
      T t;
      auto collect(DG dg) {
        return LoopSender(t, dg);
      }
    }
    return LoopStream(t);
  }
}

/// Helper to construct a Stream, useful if the Stream you are modeling has an external source that should be started/stopped
template startStopStream(E) {
  alias DG = CollectDelegate!(E);
  auto startStopStream(T)(T t) {
    static struct StartStopStream {
      static assert(models!(typeof(this), isStream));
      alias ElementType = E;
      static struct StartStopOp(Receiver) {
        T t;
        DG dg;
        Receiver receiver;
        StopCallback cb;
        void start() @trusted nothrow {
          t.start(&emit, receiver.getStopToken);
          cb = receiver.getStopToken.onStop(&(cast(shared)this).stop);
        }
        void emit(ElementType element) nothrow {
          try {
            dg(element);
          } catch (Exception e) {
            cb.dispose();
            try { t.stop(); } catch (Exception e2) {}
            receiver.setError(e);
          }
        }
        void stop() shared @trusted nothrow {
          try {
            (cast()t).stop();
          } catch (Exception e) {}
          (cast()receiver).setDone();
        }
      }
      static struct StartStopSender {
        alias Value = void;
        T t;
        DG dg;
        auto connect(Receiver)(Receiver receiver) {
          return StartStopOp!(Receiver)(t, dg, receiver);
        }
      }
      T t;
      auto collect(DG dg) {
        return StartStopSender(t, dg);
      }
    }
    return StartStopStream(t);
  }
}

/// Stream that emit the same value until cancelled
auto infiniteStream(T)(T t) {
  alias DG = CollectDelegate!(T);
  struct Loop {
    T val;
    void loop(StopToken)(DG emit, StopToken stopToken) {
      while(!stopToken.isStopRequested)
        emit(val);
    }
  }
  return Loop(t).loopStream!T;
}

/// Stream that emits from start..end or until cancelled
auto iotaStream(T)(T start, T end) {
  alias DG = CollectDelegate!(T);
  struct Loop {
    T b,e;
    void loop(StopToken)(DG emit, StopToken stopToken) {
      foreach(i; b..e) {
        emit(i);
        if (stopToken.isStopRequested)
          break;
      }
    }
  }
  return Loop(start, end).loopStream!T;
}

/// Stream that emits each value from the array or until cancelled
auto arrayStream(T)(T[] arr) {
  alias DG = CollectDelegate!(T);
  struct Loop {
    T[] arr;
    void loop(StopToken)(DG emit, StopToken stopToken) @safe {
      foreach(item; arr) {
        emit(item);
        if (stopToken.isStopRequested)
          break;
      }
    }
  }
  return Loop(arr).loopStream!T;
}

import core.time : Duration;

/// Stream that emits after each duration or until cancelled
auto intervalStream(Duration duration) {
  alias DG = CollectDelegate!(void);
  static struct Loop {
    Duration duration;
    void loop(StopToken)(DG emit, StopToken stopToken) @trusted {

      if (stopToken.isStopRequested)
        return;

      // TODO: waiting should really be a feature of the scheduler, because it depends on if we are in a thread, fiber, coroutine or an eventloop
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

        m.lock_nothrow();
        scope(exit) m.unlock_nothrow();
        while (!cond.wait(duration)) {
          m.unlock_nothrow();
          emit();
          m.lock_nothrow();
        }
        receiver.setDone();
      } else version (linux) {
        import core.sys.linux.timerfd;
        import core.sys.linux.sys.eventfd;
        import core.sys.posix.sys.select;
        import std.exception : ErrnoException;
        import core.sys.posix.unistd;
        import core.stdc.errno;

        shared int stopfd = eventfd(0, EFD_CLOEXEC);
        if (stopfd == -1)
          throw new ErrnoException("eventfd failed");

        auto stopCb = stopToken.onStop(() shared @trusted {
            ulong b = 1;
            write(stopfd, &b, typeof(b).sizeof);
          });
        scope (exit) {
          stopCb.dispose();
          close(stopfd);
        }

      auto when = duration.split!("seconds", "usecs");
      while(!stopToken.isStopRequested) {
        fd_set read_fds;
        FD_ZERO(&read_fds);
        FD_SET(stopfd, &read_fds);
        timeval tv;
        tv.tv_sec = when.seconds;
        tv.tv_usec = when.usecs;
      retry:
        const ret = select(stopfd + 1, &read_fds, null, null, &tv);
        if (ret == 0) {
          emit();
        } else if (ret == -1) {
          if (errno == EINTR || errno == EAGAIN)
            goto retry;
          throw new Exception("wtf select");
        } else {
          return;
        }
      }
    } else static assert(0, "not supported");
    }
  }
  return Loop(duration).loopStream!void;
}

template StreamProperties(Stream) {
  import std.traits : ReturnType;
  alias ElementType = Stream.ElementType;
  alias DG = CollectDelegate!(ElementType);
  alias Sender = ReturnType!(Stream.collect);
  alias Value = Sender.Value;
}

/// takes the first n values from a stream or until cancelled
auto take(Stream)(Stream stream, size_t n) {
  static assert(models!(Stream, isStream));
  alias Properties = StreamProperties!Stream;
  static struct TakeOp(Receiver) {
    import concurrency.operations : withStopSource;
    import std.traits : ReturnType;
    alias SS = ReturnType!(withStopSource!(Properties.Sender));
    alias Op = ReturnType!(SS.connect!Receiver);
    size_t n;
    Properties.DG dg;
    StopSource stopSource;
    Op op;
    private this(Stream stream, size_t n, Properties.DG dg, Receiver receiver) @trusted {
      stopSource = new StopSource();
      this.dg = dg;
      this.n = n;
      op = stream.collect(cast(Properties.DG)&item).withStopSource(stopSource).connect(receiver);
    }
    static if (is(Properties.ElementType == void)) {
      private void item() {
        dg();
        /// TODO: this implies the stream will only call emit from a single execution context, we might need to enforce that
        n--;
        if (n == 0)
          stopSource.stop();
      }
    } else {
      private void item(Properties.ElementType t) {
        dg(t);
        n--;
        if (n == 0)
          stopSource.stop();
      }
    }
    void start() {
      op.start();
    }
  }
  import std.exception : enforce;
  enforce(n > 0, "cannot take 0");
  return fromStreamOp!(Properties.ElementType, Properties.Value, TakeOp)(stream, n);
}

auto transform(Stream, Fun)(Stream stream, Fun fun) {
  alias Properties = StreamProperties!Stream;
  import std.traits : ReturnType;
  static struct TransformStreamOp(Receiver) {
    alias Op = ReturnType!(Properties.Sender.connect!Receiver);
    Fun fun;
    Properties.DG dg;
    Op op;
    this(Stream stream, Fun fun, Properties.DG dg, Receiver receiver) @trusted {
      this.fun = fun;
      this.dg = dg;
      op = stream.collect(cast(Properties.DG)&item).connect(receiver);
    }
    static if (is(Properties.ElementType == void))
      void item() {
        dg(fun());
      }
    else
      void item(Properties.ElementType t) {
        dg(fun(t));
      }
    void start() {
      op.start();
    }
  }
  return fromStreamOp!(ReturnType!Fun, Properties.Value, TransformStreamOp)(stream, fun);
}

auto fromStreamOp(StreamElementType, SenderValue, alias Op, Args...)(Args args) {
  alias DG = CollectDelegate!(StreamElementType);
  struct FromStreamSender {
    alias Value = SenderValue;
    Args args;
    DG dg;
    auto connect(Receiver)(Receiver receiver) @safe {
      return Op!(Receiver)(args, dg, receiver);
    }
  }
  struct FromStream {
    alias ElementType = StreamElementType;
    Args args;
    auto collect(DG dg) {
      return FromStreamSender(args, dg);
    }
  }
  return FromStream(args);
}
