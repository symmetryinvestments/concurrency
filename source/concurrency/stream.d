module concurrency.stream;

import concurrency.stoptoken;
import concurrency.receiver;
import concurrency.sender : isSender, OpType;
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
class StreamObjectImpl(Stream) : StreamObjectBase!(Stream.ElementType) if (models!(Stream, isStream)) {
  import concurrency.receiver : ReceiverObjectBase;
  static assert (models!(typeof(this), isStream));
  private Stream stream;
  this(Stream stream) {
    this.stream = stream;
  }
  alias DG = CollectDelegate!(Stream.ElementType);

  SenderObjectBase!void collect(DG dg) @safe {
    import concurrency.sender : toSenderObject;
    return stream.collect(dg).toSenderObject();
  }
}

/// Converts any Stream to a polymorphic StreamObject
StreamObjectBase!(Stream.ElementType) toStreamObject(Stream)(Stream stream) if (models!(Stream, isStream)) {
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
        @disable this(ref return scope typeof(this) rhs);
        @disable this(this);
        this(T t, DG dg, Receiver receiver) {
          this.t = t;
          this.dg = dg;
          this.receiver = receiver;
        }
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
        auto connect(Receiver)(Receiver receiver) @safe {
          return LoopOp!(Receiver)(t, dg, receiver);
        }
      }
      T t;
      auto collect(DG dg) @safe {
        return LoopSender(t, dg);
      }
    }
    return LoopStream(t);
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
auto take(Stream)(Stream stream, size_t n) if (models!(Stream, isStream)) {
  alias Properties = StreamProperties!Stream;
  static struct TakeReceiver(Receiver) {
    Receiver receiver;
    StopSource stopSource;
    static if (is(Properties.Sender.Value == void))
      void setValue() @safe { receiver.setValue(); }
    else
      void setValue(Properties.Sender.Value e) @safe { receiver.setValue(e); }
    void setDone() nothrow @safe {
      import concurrency.receiver : setValueOrError;
      static if (is(Properties.Sender.Value == void)) {
        if (stopSource.isStopRequested)
          receiver.setValueOrError();
        else
          receiver.setDone();
      } else
        receiver.setDone();
    }
    void setError(Exception e) nothrow @safe {
      receiver.setError(e);
    }
    mixin ForwardExtensionPoints!receiver;
  }
  static struct TakeOp(Receiver) {
    import concurrency.operations : withStopSource;
    import std.traits : ReturnType;
    alias SS = ReturnType!(withStopSource!(Properties.Sender));
    alias Op = OpType!(SS, TakeReceiver!Receiver);
    size_t n;
    Properties.DG dg;
    StopSource stopSource;
    Op op;
    @disable this(ref return scope typeof(this) rhs);
    @disable this(this);
    private this(Stream stream, size_t n, Properties.DG dg, Receiver receiver) @trusted {
      stopSource = new StopSource();
      this.dg = dg;
      this.n = n;
      op = stream.collect(cast(Properties.DG)&item).withStopSource(stopSource).connect(TakeReceiver!Receiver(receiver, stopSource));
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
    void start() nothrow @safe {
      op.start();
    }
  }
  import std.exception : enforce;
  enforce(n > 0, "cannot take 0");
  return fromStreamOp!(Properties.ElementType, Properties.Value, TakeOp)(stream, n);
}

auto transform(Stream, Fun)(Stream stream, Fun fun) if (models!(Stream, isStream)) {
  import std.traits : ReturnType;
  alias Properties = StreamProperties!Stream;
  alias DG = CollectDelegate!(ReturnType!Fun);
  static struct TransformStreamOp(Receiver) {
    alias Op = OpType!(Properties.Sender, Receiver);
    Fun fun;
    DG dg;
    Op op;
    @disable this(ref return scope typeof(this) rhs);
    @disable this(this);
    this(Stream stream, Fun fun, DG dg, Receiver receiver) @trusted {
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
    void start() nothrow @safe {
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
    static assert(models!(typeof(this), isStream));
    alias ElementType = StreamElementType;
    Args args;
    auto collect(DG dg) @safe {
      return FromStreamSender(args, dg);
    }
  }
  return FromStream(args);
}

/// Applies an accumulator to each value from the source
auto scan(Stream, ScanFn, Seed)(Stream stream, scope ScanFn scanFn, Seed seed) if (models!(Stream, isStream)) {
  import std.traits : ReturnType;
  alias Properties = StreamProperties!Stream;
  alias DG = CollectDelegate!(Seed);
  static struct ScanStreamOp(Receiver) {
    alias Op = OpType!(Properties.Sender, Receiver);
    ScanFn scanFn;
    Seed acc;
    DG dg;
    Op op;
    @disable this(ref return scope typeof(this) rhs);
    @disable this(this);
    this(Stream stream, ScanFn scanFn, Seed seed, DG dg, Receiver receiver) @trusted {
      this.scanFn = scanFn;
      this.acc = seed;
      this.dg = dg;
      op = stream.collect(cast(Properties.DG)&item).connect(receiver);
    }
    static if (is(Properties.ElementType == void))
      void item() {
        acc = scanFn(acc);
        dg(acc);
      }
    else
      void item(Properties.ElementType t) {
        acc = scanFn(acc, t);
        dg(acc);
      }
    void start() nothrow @safe {
      op.start();
    }
  }
  return fromStreamOp!(Seed, Properties.Value, ScanStreamOp)(stream, scanFn, seed);
}

/// Forwards the latest value from the base stream every time the trigger stream produces a value. If the base stream hasn't produces a (new) value the trigger is ignored
auto sample(StreamBase, StreamTrigger)(StreamBase base, StreamTrigger trigger) if (models!(StreamBase, isStream) && models!(StreamTrigger, isStream)) {
  import concurrency.operations.whileall;
  import concurrency.bitfield : SharedBitField;
  enum Flags : size_t {
    locked = 0x1,
    valid = 0x2
  }
  alias PropertiesBase = StreamProperties!StreamBase;
  alias PropertiesTrigger = StreamProperties!StreamTrigger;
  static assert(!is(PropertiesBase.ElementType == void), "No point in sampling a stream that procudes no values. Might as well use trigger directly");
  alias DG = PropertiesBase.DG;
  static struct SampleStreamOp(Receiver) {
    import std.traits : ReturnType;
    alias WhileAllSender = ReturnType!(whileAll!(PropertiesBase.Sender, PropertiesTrigger.Sender));
    alias Op = OpType!(WhileAllSender, Receiver);
    DG dg;
    Op op;
    PropertiesBase.ElementType element;
    shared SharedBitField!Flags state;
    shared size_t sampleState;
    @disable this(ref return scope inout typeof(this) rhs);
    @disable this(this);
    this(StreamBase base, StreamTrigger trigger, DG dg, Receiver receiver) @trusted {
      this.dg = dg;
      op = whileAll(base.collect(cast(PropertiesBase.DG)&item),
                    trigger.collect(cast(PropertiesTrigger.DG)&this.trigger)).connect(receiver);
    }
    void item(PropertiesBase.ElementType t) {
      import core.atomic : atomicOp;
      with(state.lock(Flags.valid)) {
        element = t;
      }
    }
    void trigger() {
      import core.atomic : atomicOp;
      with(state.lock()) {
        if (was(Flags.valid)) {
          auto localElement = element;
          release(Flags.valid);
          dg(localElement);
        }
      }
    }
    void start() {
      op.start();
    }
  }
  return fromStreamOp!(PropertiesBase.ElementType, PropertiesBase.Value, SampleStreamOp)(base, trigger);
}

auto via(Stream, Sender)(Stream stream, Sender sender) if (models!(Sender, isSender) && models!(Stream, isStream)) {
  alias Properties = StreamProperties!Stream;
  alias DG = Properties.DG;
  static struct ViaStreamOp(Receiver) {
    import std.traits : ReturnType;
    import concurrency.operations.via : senderVia = via;
    alias Op = OpType!(ReturnType!(senderVia!(Properties.Sender, Sender)), Receiver);
    Op op;
    @disable this(ref return scope typeof(this) rhs);
    @disable this(this);
    this(Stream stream, Sender sender, DG dg, Receiver receiver) {
      op = stream.collect(dg).senderVia(sender).connect(receiver);
    }
    void start() nothrow @safe {
      op.start();
    }
  }
  return fromStreamOp!(Properties.ElementType, Properties.Value, ViaStreamOp)(stream, sender);
}

auto doneStream() {
  alias DG = CollectDelegate!void;
  static struct DoneStreamOp(Receiver) {
    Receiver receiver;
    this(DG dg, Receiver receiver) {
      this.receiver = receiver;
    }
    void start() nothrow @safe {
      receiver.setDone();
    }
  }
  return fromStreamOp!(void, void, DoneStreamOp)();
}

auto errorStream(Exception e) {
  alias DG = CollectDelegate!void;
  static struct ErrorStreamOp(Receiver) {
    Exception e;
    Receiver receiver;
    this(Exception e, DG dg, Receiver receiver) {
      this.e = e;
      this.receiver = receiver;
    }
    void start() nothrow @safe {
      receiver.setError(e);
    }
  }
  return fromStreamOp!(void, void, ErrorStreamOp)(e);
}

/// A SharedStream is used for broadcasting values to zero or more receivers. Receivers can be added and removed at any time. The stream itself never completes, so receivers should themselves terminate their connection.
auto sharedStream(T)() {
  import concurrency.slist;
  alias DG = CollectDelegate!(T);
  return SharedStream!(T)(new shared SList!(SharedStream!(T).SubscriberDG));
}

shared struct SharedStream(T) {
  alias SubscriberDG = void delegate(T) nothrow @safe shared;
  import concurrency.slist;
  private {
    alias DG = CollectDelegate!T;
    static struct Op(Receiver) {
      shared SharedStream!T source;
      DG dg;
      Receiver receiver;
      StopCallback cb;
      void start() nothrow @trusted {
        auto stopToken = receiver.getStopToken();
        cb = stopToken.onStop(&(cast(shared)this).onStop);
        if (stopToken.isStopRequested) {
          cb.dispose();
          receiver.setDone();
        } else {
          source.add(&(cast(shared)this).onItem);
        }
      }
      void onStop() nothrow @safe shared {
        with(unshared) {
          source.remove(&this.onItem);
          receiver.setDone();
        }
      }
      void onItem(T element) nothrow @safe shared {
        with(unshared) {
          try {
            dg(element);
          } catch (Exception e) {
            source.remove(&this.onItem);
            cb.dispose();
            receiver.setError(e);
          }
        }
      }
      private auto ref unshared() nothrow @trusted shared {
        return cast()this;
      }
    }
    static struct SharedStreamSender {
      alias Value = void;
      shared SharedStream!T source;
      DG dg;
      auto connect(Receiver)(Receiver receiver) @safe {
        return Op!(Receiver)(source, dg, receiver);
      }
    }
    shared SList!SubscriberDG dgs;
  }
  this(shared SList!SubscriberDG dgs) {
    this.dgs = dgs;
  }
  void emit(T t) nothrow @trusted {
    foreach(dg; dgs[])
      dg(t);
  }
  private void remove(SubscriberDG dg) nothrow @trusted {
    dgs.remove(dg);
  }
  private void add(SubscriberDG dg) nothrow @trusted {
    dgs.pushBack(dg);
  }
  auto collect(DG dg) @safe {
    return SharedStreamSender(this, dg);
  }
}

