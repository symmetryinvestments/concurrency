module concurrency.stream;

import concurrency.stoptoken;
import concurrency.receiver;
public import concurrency.stream.stream;
public import concurrency.stream.filter;
public import concurrency.stream.take;
public import concurrency.stream.transform;
public import concurrency.stream.scan;
public import concurrency.stream.sample;
public import concurrency.stream.tolist;
public import concurrency.stream.slide;
public import concurrency.stream.throttling;
public import concurrency.stream.cycle;
public import concurrency.stream.flatmapconcat;
import concurrency.sender : isSender, OpType;
import concepts;
import std.traits : hasFunctionAttributes;

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

auto intervalStream(Duration duration, bool emitAtStart = false) {
  alias DG = CollectDelegate!(void);
  static struct ItemReceiver(Op) {
    Op* op;
    void setValue() @safe {
      if (op.receiver.getStopToken.isStopRequested) {
        op.receiver.setDone();
        return;
      }
      try {
        op.dg();
        if (op.receiver.getStopToken.isStopRequested) {
          op.receiver.setDone();
          return;
        }
        op.load();
      } catch (Exception e) {
        op.receiver.setError(e);
      }
    }
    void setDone() @safe nothrow {
      op.receiver.setDone();
    }
    void setError(Throwable t) @safe nothrow {
      op.receiver.setError(t);
    }
    auto getStopToken() @safe {
      return op.receiver.getStopToken();
    }
    auto getScheduler() @safe {
      return op.receiver.getScheduler();
    }
  }
  static struct Op(Receiver) {
    import std.traits : ReturnType;
    Duration duration;
    DG dg;
    Receiver receiver;
    alias SchedulerAfterSender = ReturnType!(SchedulerType!(Receiver).scheduleAfter);
    alias Op = OpType!(SchedulerAfterSender, ItemReceiver!(typeof(this)));
    Op op;
    bool emitAtStart;
    @disable this(this);
    @disable this(ref return scope typeof(this) rhs);
    this(Duration duration, DG dg, Receiver receiver, bool emitAtStart) {
      this.duration = duration;
      this.dg = dg;
      this.receiver = receiver;
      this.emitAtStart = emitAtStart;
    }
    void start() @trusted nothrow {
      try {
        if (emitAtStart) {
          emitAtStart = false;
          dg();
          if (receiver.getStopToken.isStopRequested) {
            receiver.setDone();
            return;
          }
        }
        load();
      } catch (Exception e) {
        receiver.setError(e);
      }
    }
    private void load() @trusted nothrow {
      try {
        op = receiver.getScheduler().scheduleAfter(duration).connect(ItemReceiver!(typeof(this))(&this));
        op.start();
      } catch (Exception e) {
        receiver.setError(e);
      }
    }
  }
  static struct Sender {
    alias Value = void;
    Duration duration;
    DG dg;
    bool emitAtStart;
    auto connect(Receiver)(return Receiver receiver) @safe scope return {
      // ensure NRVO
      auto op = Op!(Receiver)(duration, dg, receiver, emitAtStart);
      return op;
    }
  }
  static struct IntervalStream {
    alias ElementType = void;
    Duration duration;
    bool emitAtStart = false;
    auto collect(DG dg) @safe {
      return Sender(duration, dg, emitAtStart);
    }
  }
  return IntervalStream(duration, emitAtStart);
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
    @disable this(ref return scope typeof(this) rhs);
    @disable this(this);
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
    @disable this(ref return scope typeof(this) rhs);
    @disable this(this);
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
  alias ElementType = T;
  alias SubscriberDG = void delegate(T) nothrow @safe shared;
  import concurrency.slist;
  private {
    alias DG = CollectDelegate!T;
    static struct Op(Receiver) {
      shared SharedStream!T source;
      DG dg;
      Receiver receiver;
      StopCallback cb;
      @disable this(ref return scope typeof(this) rhs);
      @disable this(this);
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
      auto connect(Receiver)(return Receiver receiver) @safe scope return {
        // ensure NRVO
        auto op = Op!(Receiver)(source, dg, receiver);
        return op;
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
