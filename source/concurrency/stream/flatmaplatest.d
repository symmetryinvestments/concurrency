module concurrency.stream.flatmaplatest;

import concurrency.stream.stream;
import concurrency.sender : OpType, isSender;
import concurrency.receiver : ForwardExtensionPoints;
import concurrency.stoptoken : StopSource;
import std.traits : ReturnType;
import concurrency.utils : isThreadSafeFunction;
import concepts;
import core.sync.semaphore : Semaphore;

auto flatMapLatest(Stream, Fun)(Stream stream, Fun fun) if (models!(Stream, isStream)) {
  static assert(isThreadSafeFunction!Fun);
  alias Properties = StreamProperties!Stream;
  return fromStreamOp!(ReturnType!Fun.Value, Properties.Value, FlatMapLatestStreamOp!(Stream, Fun))(stream, fun);
}

template FlatMapLatestStreamOp(Stream, Fun) {
  static assert(isThreadSafeFunction!Fun);
  alias Properties = StreamProperties!Stream;
  alias InnerSender = ReturnType!Fun;
  static assert(models!(InnerSender, isSender), "Fun must produce a Sender");
  alias DG = CollectDelegate!(InnerSender.Value);
  struct FlatMapLatestStreamOp(Receiver) {
    alias State = .State!(Properties.Sender.Value, InnerSender.Value, Receiver);
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
        state.innerStopSource.stop();
        state.semaphore.wait();
        state.innerStopSource.reset();
        with (state.bitfield.lock()) {
          if (state.isDoneOrErrorProduced(oldState)) {
            return;
          }
          release(Counter.tick); // release early
          auto sender = fun();
          runInnerSender(sender);
        }
      }
    else
      void item(Properties.ElementType t) {
        if (state.isStopRequested)
          return;
        state.innerStopSource.stop();
        state.semaphore.wait();
        state.innerStopSource.reset();
        with (state.bitfield.lock()) {
          if (state.isDoneOrErrorProduced(oldState)) {
            return;
          }
          release(Counter.tick); // release early
          auto sender = fun(t);
          runInnerSender(sender);
        }
      }
    private void runInnerSender(ref InnerSender sender) {
      innerOp = sender.connect(InnerSenderReceiver!(State)(state));
      innerOp.start();
    }
    void start() nothrow @safe {
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

final class State(TStreamSenderValue, TSenderValue, Receiver) : StopSource {
  import concurrency.bitfield;
  import concurrency.stoptoken;
  import std.exception : assumeWontThrow;
  alias DG = CollectDelegate!(SenderValue);
  alias StreamSenderValue = TStreamSenderValue;
  alias SenderValue = TSenderValue;
  DG dg;
  Receiver receiver;
  static if (!is(StreamSenderValue == void))
    StreamSenderValue value;
  Throwable throwable;
  Semaphore semaphore;
  StopCallback cb;
  StopSource innerStopSource;
  shared SharedBitField!Flags bitfield;
  this(DG dg, Receiver receiver) {
    this.dg = dg;
    this.receiver = receiver;
    semaphore = new Semaphore(1);
    innerStopSource = new StopSource();
    bitfield = SharedBitField!Flags(Counter.tick);
    cb = receiver.getStopToken.onStop(cast(void delegate() nothrow @safe shared)&stop);
  }
  override bool stop() nothrow @trusted {
    return (cast(shared)this).stop();
  }
  override bool stop() nothrow @trusted shared {
    auto r = super.stop();
    innerStopSource.stop();
    return r;
  }
  private bool isLast(size_t state) {
    return (state >> 3) == 2;
  }
  private bool isDoneOrErrorProduced(size_t state) {
    return (state & Flags.doneOrError_produced) > 0;
  }
  private auto getStopToken() @safe nothrow {
    return StopToken(this);
  }
  void onStreamDone() @safe nothrow {
    with (bitfield.update(Flags.doneOrError_produced, Counter.tick)) {
      bool last = isLast(newState);
      if (!isDoneOrErrorProduced(oldState))
        stop();
      if (last)
        process(newState);
    }
  }
  void onStreamError(Throwable t) @safe nothrow {
    with (bitfield.lock(Flags.doneOrError_produced, Counter.tick)) {
      bool last = isLast(newState);
      if (!isDoneOrErrorProduced(oldState)) {
        throwable = t;
        release(); // must release before calling .stop
        stop();
      } else
        release();
      if (last)
        process(newState);
    }
  }
  static if (!is(StreamSenderValue == void)) {
    void onStreamValue(StreamSenderValue v) {
      with (bitfield.lock(Flags.value_produced, Counter.tick)) {
        bool last = isLast(newState);
        value = v;
        release();
        if (last)
          process(newState);
      }
    }
  } else {
    void onStreamValue() @safe {
      with (bitfield.update(Flags.value_produced, Counter.tick)) {
        if (isLast(newState))
          process(newState);
      }
    }
  }
  void onSenderDone() @trusted nothrow {
    if (!isStopRequested) {
      bitfield.add(Counter.tick);
      semaphore.notify().assumeWontThrow;
      return;
    }
    with (bitfield.update(Flags.doneOrError_produced, Counter.tick)) {
      bool last = isLast(newState);
      if (!isDoneOrErrorProduced(oldState))
        stop();
      if (last)
        process(newState);
      else
        semaphore.notify().assumeWontThrow;
    }
  }
  void onSenderError(Throwable t) @trusted nothrow {
    with (bitfield.lock(Flags.doneOrError_produced, Counter.tick)) {
      bool last = isLast(newState);
      if (!isDoneOrErrorProduced(oldState)) {
        throwable = t;
        release(); // must release before calling .stop
        stop();
      } else
        release();
      if (last)
        process(newState);
      else
        semaphore.notify().assumeWontThrow;
    }
  }
  void onSenderValue() @trusted {
    with (bitfield.update(0, Counter.tick)) {
      if (isLast(newState))
        process(newState);
      else {
        semaphore.notify().assumeWontThrow;
      }
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
}

struct StreamReceiver(State) {
  State state;
  static if (is(State.StreamSenderValue == void)) {
    void setValue() @safe {
      state.onStreamValue();
    }
  } else {
    void setValue(State.StreamSenderValue value) @safe {
      state.onStreamValue(value);
    }
  }
  void setError(Throwable t) @safe nothrow {
    state.onStreamError(t);
  }
  void setDone() @safe nothrow {
    state.onStreamDone();
  }
  auto getStopToken() @safe nothrow {
    return state.getStopToken;
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
      state.onSenderValue();
    }
  } else {
    void setValue(State.SenderValue value) @safe {
      state.dg(value);
      state.onSenderValue();
    }
  }
  void setError(Throwable t) @safe nothrow {
    state.onSenderError(t);
  }
  void setDone() @safe nothrow {
    state.onSenderDone();
  }
  auto getStopToken() @safe nothrow {
    import concurrency.stoptoken;
    return StopToken(state.innerStopSource);
  }
  private auto receiver() {
    return state.receiver;
  }
  mixin ForwardExtensionPoints!(receiver);
}
