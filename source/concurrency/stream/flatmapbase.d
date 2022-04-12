module concurrency.stream.flatmapbase;

import concurrency.stream.stream;
import concurrency.sender : OpType, isSender;
import concurrency.receiver : ForwardExtensionPoints;
import concurrency.stoptoken : StopSource, StopToken;
import std.traits : ReturnType;
import concurrency.utils : isThreadSafeFunction;
import concepts;
import core.sync.semaphore : Semaphore;

enum OnOverlap {
  wait,
  latest
}

template FlatMapBaseStreamOp(Stream, Fun, OnOverlap overlap) {
  static assert(isThreadSafeFunction!Fun);
  alias Properties = StreamProperties!Stream;
  alias InnerSender = ReturnType!Fun;
  static assert(models!(InnerSender, isSender), "Fun must produce a Sender");
  alias DG = CollectDelegate!(InnerSender.Value);
  struct FlatMapBaseStreamOp(Receiver) {
    alias State = .State!(Properties.Sender.Value, InnerSender.Value, Receiver, overlap);
    alias Op = OpType!(Properties.Sender, StreamReceiver!State);
    alias InnerOp = OpType!(InnerSender, InnerSenderReceiver!State);
    Fun fun;
    Op op;
    InnerOp innerOp;
    State state;
    @disable this(ref return scope typeof(this) rhs);
    @disable this(this);
    this(Stream stream, Fun fun, return DG dg, return Receiver receiver) @trusted scope return {
      this.fun = fun;
      state = new State(dg, receiver);
      // TODO: would it be good to do the fun in a transform operation?
      op = stream.collect(cast(Properties.DG)&item).connect(StreamReceiver!State(state));
    }
    static if (is(Properties.ElementType == void))
      void item() {
        if (state.isStopRequested)
          return;
        state.onItem();
        with (state.bitfield.lock()) {
          if (isDoneOrErrorProduced(oldState)) {
            return;
          }
          auto sender = fun();
          release(Counter.tick); // release early
          runInnerSender(sender);
        }
      }
    else
      void item(Properties.ElementType t) {
        if (state.isStopRequested)
          return;
        state.onItem();
        with (state.bitfield.lock()) {
          if (isDoneOrErrorProduced(oldState)) {
            return;
          }
          auto sender = fun(t);
          release(Counter.tick); // release early
          runInnerSender(sender);
        }
      }
    private void runInnerSender(ref InnerSender sender) {
      innerOp = sender.connect(InnerSenderReceiver!(State)(state));
      innerOp.start();
    }
    void start() nothrow @safe scope {
      op.start();
    }
  }
}

private enum Flags : size_t {
  locked = 0x1,
  value_produced = 0x2,
  doneOrError_produced = 0x4
}

private enum Counter : size_t {
  tick = 0x8
}

private bool isLast(size_t state) @safe @nogc nothrow pure {
  return (state >> 3) == 2;
}

private bool isDoneOrErrorProduced(size_t state) @safe @nogc nothrow pure {
  return (state & Flags.doneOrError_produced) > 0;
}

final class State(TStreamSenderValue, TSenderValue, Receiver, OnOverlap overlap) : StopSource {
  import concurrency.bitfield;
  import concurrency.stoptoken;
  import std.exception : assumeWontThrow;
  alias DG = CollectDelegate!(SenderValue);
  alias StreamSenderValue = TStreamSenderValue;
  alias SenderValue = TSenderValue;
  alias onOverlap = overlap;
  DG dg;
  Receiver receiver;
  static if (!is(StreamSenderValue == void))
    StreamSenderValue value;
  Throwable throwable;
  Semaphore semaphore;
  StopCallback cb;
  static if (overlap == OnOverlap.latest)
    StopSource innerStopSource;
  shared SharedBitField!Flags bitfield;
  this(DG dg, Receiver receiver) {
    this.dg = dg;
    this.receiver = receiver;
    semaphore = new Semaphore(1);
    static if (overlap == OnOverlap.latest)
      innerStopSource = new StopSource();
    bitfield = SharedBitField!Flags(Counter.tick);
    cb = receiver.getStopToken.onStop(cast(void delegate() nothrow @safe shared)&stop);
  }
  override bool stop() nothrow @trusted {
    return (cast(shared)this).stop();
  }
  override bool stop() nothrow @trusted shared {
    static if (overlap == OnOverlap.latest) {
      auto r = super.stop();
      innerStopSource.stop();
      return r;
    } else {
      return super.stop();
    }
  }
  private void onItem() @trusted {
    static if (overlap == OnOverlap.latest) {
      innerStopSource.stop();
      semaphore.wait();
      innerStopSource.reset();
    } else {
      semaphore.wait();
    }
  }
  private void process(size_t newState) {
    cb.dispose();

    if (receiver.getStopToken().isStopRequested)
      receiver.setDone();
    else if (isDoneOrErrorProduced(newState)) {
      if (throwable)
        receiver.setError(throwable);
      else
        receiver.setDone();
    } else {
      import concurrency.receiver : setValueOrError;
      static if (is(typeof(Value.values)))
        receiver.setValueOrError(state.value.values);
      else
        receiver.setValueOrError();
    }
  }
  private StopToken getSenderStopToken() @safe nothrow {
    static if (overlap == OnOverlap.latest) {
      return StopToken(innerStopSource);
    } else {
      return StopToken(this);
    }
  }
}

struct StreamReceiver(State) {
  State state;
  static if (is(State.StreamSenderValue == void)) {
    void setValue() @safe {
      with (state.bitfield.update(Flags.value_produced, Counter.tick)) {
        if (isLast(newState))
          state.process(newState);
      }
    }
  } else {
    void setValue(State.StreamSenderValue value) @safe {
      with (state.bitfield.lock(Flags.value_produced, Counter.tick)) {
        bool last = isLast(newState);
        state.value = value;
        release();
        if (last)
          state.process(newState);
      }
    }
  }
  void setError(Throwable t) @safe nothrow {
    with (state.bitfield.lock(Flags.doneOrError_produced, Counter.tick)) {
      bool last = isLast(newState);
      if (!isDoneOrErrorProduced(oldState)) {
        state.throwable = t;
        release(); // must release before calling .stop
        state.stop();
      } else
        release();
      if (last)
        state.process(newState);
    }
  }
  void setDone() @safe nothrow {
    with (state.bitfield.update(Flags.doneOrError_produced, Counter.tick)) {
      bool last = isLast(newState);
      if (!isDoneOrErrorProduced(oldState))
        state.stop();
      if (last)
        state.process(newState);
    }
  }
  StopToken getStopToken() @safe nothrow {
    return StopToken(state);
  }
  private auto receiver() {
    return state.receiver;
  }
  mixin ForwardExtensionPoints!(receiver);
}

struct InnerSenderReceiver(State) {
  State state;
  static if (is(State.SenderValue == void)) {
    void setValue() @safe {
      state.dg();
      onSenderValue();
    }
  } else {
    void setValue(State.SenderValue value) @safe {
      state.dg(value);
      onSenderValue();
    }
  }
  void setError(Throwable t) @safe nothrow {
    with (state.bitfield.lock(Flags.doneOrError_produced, Counter.tick)) {
      bool last = isLast(newState);
      if (!isDoneOrErrorProduced(oldState)) {
        state.throwable = t;
        release(); // must release before calling .stop
        state.stop();
      } else
        release();
      if (last)
        state.process(newState);
      else
        notify();
    }
  }
  void setDone() @safe nothrow {
    static if (State.onOverlap == OnOverlap.latest) {
      if (!state.isStopRequested) {
        state.bitfield.add(Counter.tick);
        notify();
        return;
      }
    }
    with (state.bitfield.update(Flags.doneOrError_produced, Counter.tick)) {
      bool last = isLast(newState);
      if (!isDoneOrErrorProduced(oldState))
        state.stop();
      if (last)
        state.process(newState);
      else
        notify();
    }
  }
  auto getStopToken() @safe nothrow {
    return state.getSenderStopToken;
  }
  private auto receiver() {
    return state.receiver;
  }
  private void onSenderValue() @trusted {
    with (state.bitfield.update(0, Counter.tick)) {
      if (isLast(newState))
        state.process(newState);
      else
        notify();
    }
  }
  private void notify() @trusted {
    import std.exception : assumeWontThrow;
    state.semaphore.notify().assumeWontThrow;
  }
  mixin ForwardExtensionPoints!(receiver);
}
