module concurrency.operations.whenall;

import concurrency;
import concurrency.receiver;
import concurrency.sender;
import concurrency.stoptoken;
import concepts;
import std.traits;
import concurrency.utils : spin_yield, casWeak;

WhenAllSender!(Senders) whenAll(Senders...)(Senders senders) if (Senders.length > 1) {
  return WhenAllSender!(Senders)(senders);
}

private enum Flags : size_t {
  locked = 0x1,
  value_produced = 0x2,
  doneOrError_produced = 0x4
}

private enum Counter : size_t {
  tick = 0x8
}

private template WhenAllResult(Senders...) {
  import std.meta;
  import std.typecons;
  import mir.algebraic : Algebraic, Nullable;
  import concurrency.utils : NoVoid;
  template Cummulative(size_t count, Ts...) {
    static if (Ts.length > 0) {
      enum head = count + Ts[0];
      static if (Ts.length == 1)
        alias Cummulative = AliasSeq!(head);
      else static if (Ts.length > 1)
        alias Cummulative = AliasSeq!(head, Cummulative!(head, Ts[1..$]));
    } else {
      alias Cummulative = AliasSeq!();
    }
  }
  alias SenderValue(T) = T.Value;
  alias SenderValues = staticMap!(SenderValue, Senders);
  alias ValueTypes = Filter!(NoVoid, SenderValues);
  static if (ValueTypes.length > 1)
    alias Values = Tuple!(Filter!(NoVoid, SenderValues));
  else static if (ValueTypes.length == 1)
    alias Values = ValueTypes[0];
  alias Indexes = Cummulative!(0, staticMap!(NoVoid, SenderValues));

  static if (ValueTypes.length > 0) {
    struct WhenAllResult {
      Values values;
      void setValue(T)(T t, size_t index) {
        switch (index) {
          foreach(idx, I; Indexes) {
          case idx:
            static if (ValueTypes.length == 1)
              values = t;
            else static if (is(typeof(values[I-1]) == T))
              values[I-1] = t;
            return;
          }
        default: assert(false, "out of bounds");
        }
      }
    }
  } else {
    struct WhenAllResult {
    }
  }
}

private struct WhenAllOp(Receiver, Senders...) {
  import std.meta : staticMap;
  alias R = WhenAllResult!(Senders);
  alias ElementReceiver(Sender) = WhenAllReceiver!(Receiver, Sender.Value, R);
  alias ConnectResult(Sender) = OpType!(Sender, ElementReceiver!Sender);
  alias Ops = staticMap!(ConnectResult, Senders);
  Receiver receiver;
  WhenAllState!R state;
  Ops ops;
  @disable this(this);
  @disable this(ref return scope typeof(this) rhs);
  this(Receiver receiver, Senders senders) {
    this.receiver = receiver;
    state = new WhenAllState!R();
    foreach(i, Sender; Senders) {
      ops[i] = senders[i].connect(WhenAllReceiver!(Receiver, Sender.Value, WhenAllResult!(Senders))(receiver, state, i, Senders.length));
    }
  }
  void start() @trusted nothrow {
    import concurrency.stoptoken : StopSource;
    if (receiver.getStopToken().isStopRequested) {
      receiver.setDone();
      return;
    }
    state.cb = receiver.getStopToken().onStop(cast(void delegate() nothrow @safe shared)&state.stop); // butt ugly cast, but it won't take the second overload
    foreach(i, _; Senders) {
      ops[i].start();
    }
  }
}

import std.meta : allSatisfy, ApplyRight;

struct WhenAllSender(Senders...) if (allSatisfy!(ApplyRight!(models, isSender), Senders)) {
  alias Result = WhenAllResult!(Senders);
  static if (hasMember!(Result, "values"))
    alias Value = typeof(Result.values);
  else
    alias Value = void;
  Senders senders;
  auto connect(Receiver)(Receiver receiver) @safe {
    // ensure NRVO
    auto op = WhenAllOp!(Receiver, Senders)(receiver, senders);
    return op;
  }
}

private class WhenAllState(Value) : StopSource {
  import concurrency.bitfield;
  StopCallback cb;
  static if (is(typeof(Value.values)))
    Value value;
  Exception exception;
  shared SharedBitField!Flags bitfield;
}

private struct WhenAllReceiver(Receiver, InnerValue, Value) {
  import core.atomic : atomicOp, atomicLoad, MemoryOrder;
  Receiver receiver;
  WhenAllState!(Value) state;
  size_t senderIndex;
  size_t senderCount;
  auto getStopToken() {
    return StopToken(state);
  }
  private bool isValueProduced(size_t state) {
    return (state & Flags.value_produced) > 0;
  }
  private bool isDoneOrErrorProduced(size_t state) {
    return (state & Flags.doneOrError_produced) > 0;
  }
  private bool isLast(size_t state) {
    return (state >> 3) == senderCount;
  }
  static if (!is(InnerValue == void))
    void setValue(InnerValue value) @safe {
      with (state.bitfield.lock(Flags.value_produced, Counter.tick)) {
        state.value.setValue(value, senderIndex);
        release();
        process(newState);
      }
    }
  else
    void setValue() @safe {
      with (state.bitfield.update(Flags.value_produced, Counter.tick)) {
        process(newState);
      }
    }
  void setDone() @safe nothrow {
    with (state.bitfield.update(Flags.doneOrError_produced, Counter.tick)) {
      if (!isDoneOrErrorProduced(oldState))
        state.stop();
      process(newState);
    }
  }
  void setError(Exception exception) @safe nothrow {
    with (state.bitfield.lock(Flags.doneOrError_produced, Counter.tick)) {
      if (!isDoneOrErrorProduced(oldState)) {
        state.exception = exception;
        release(); // must release before calling .stop
        state.stop();
      } else
        release();
      process(newState);
    }
  }
  private void process(size_t newState) {
    if (!isLast(newState))
      return;

    state.cb.dispose();

    if (receiver.getStopToken().isStopRequested)
      receiver.setDone();
    else if (isDoneOrErrorProduced(newState)) {
      if (state.exception)
        receiver.setError(state.exception);
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
  mixin ForwardExtensionPoints!receiver;
}
