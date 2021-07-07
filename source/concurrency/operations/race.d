module concurrency.operations.race;

import concurrency;
import concurrency.receiver;
import concurrency.sender;
import concurrency.stoptoken;
import concurrency.utils : spin_yield, casWeak;
import concepts;
import std.traits;

/// Runs both Senders and propagates the value of whoever completes first
/// if both error out the first exception is propagated,
/// uses mir.algebraic if the Sender value types differ
RaceSender!(Senders) race(Senders...)(Senders senders) {
  return RaceSender!(Senders)(senders, false);
}

private template Result(Senders...) {
  import concurrency.utils : NoVoid;
  import mir.algebraic : Algebraic, Nullable;
  import std.meta : staticMap, Filter, NoDuplicates;
  alias getValue(Sender) = Sender.Value;
  alias SenderValues = staticMap!(getValue, Senders);
  alias NoVoidValueTypes = Filter!(NoVoid, SenderValues);
  enum HasVoid = SenderValues.length != NoVoidValueTypes.length;
  alias ValueTypes = NoDuplicates!(NoVoidValueTypes);

  static if (ValueTypes.length == 0)
    alias Result = void;
  else static if (ValueTypes.length == 1)
    static if (HasVoid)
      alias Result = Nullable!(ValueTypes[0]);
    else
      alias Result = ValueTypes[0];
  else {
    alias Result = Algebraic!(ValueTypes);
  }
}

private struct RaceOp(Receiver, Senders...) {
  import std.meta : staticMap;
  alias R = Result!(Senders);
  alias ElementReceiver(Sender) = RaceReceiver!(Receiver, Sender.Value, R);
  alias ConnectResult(Sender) = OpType!(Sender, ElementReceiver!Sender);
  alias Ops = staticMap!(ConnectResult, Senders);
  Receiver receiver;
  State!R state;
  Ops ops;
  @disable this(this);
  @disable this(ref return scope typeof(this) rhs);
  this(Receiver receiver, return Senders senders, bool noDropouts) @trusted scope {
    this.receiver = receiver;
    state = new State!(R)(noDropouts);
    foreach(i, Sender; Senders) {
      ops[i] = senders[i].connect(ElementReceiver!(Sender)(receiver, state, Senders.length));
    }
  }
  void start() @trusted nothrow scope {
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

struct RaceSender(Senders...) if (allSatisfy!(ApplyRight!(models, isSender), Senders)) {
  static assert(models!(typeof(this), isSender));
  alias Value = Result!(Senders);
  Senders senders;
  bool noDropouts; // if true then we fail the moment one contender does, otherwise we keep running until one finishes
  auto connect(Receiver)(return Receiver receiver) @safe scope return {
    // ensure NRVO
    auto op = RaceOp!(Receiver, Senders)(receiver, senders, noDropouts);
    return op;
  }
}

private class State(Value) : StopSource {
  import concurrency.bitfield;
  StopCallback cb;
  static if (!is(Value == void))
    Value value;
  Exception exception;
  shared SharedBitField!Flags bitfield;
  bool noDropouts;
  this(bool noDropouts) {
    this.noDropouts = noDropouts;
  }
}

private enum Flags : size_t {
  locked = 0x1,
  value_produced = 0x2,
  doneOrError_produced = 0x4
}

private enum Counter : size_t {
  tick = 0x8,
  mask = ~0x7
}

private struct RaceReceiver(Receiver, InnerValue, Value) {
  import core.atomic : atomicOp, atomicLoad, MemoryOrder;
  Receiver receiver;
  State!(Value) state;
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
    void setValue(InnerValue value) @safe nothrow {
      with (state.bitfield.lock(Flags.value_produced, Counter.tick)) {
        if (!isValueProduced(oldState)) {
          static if (is(InnerValue == Value))
            state.value = value;
          else
            state.value = Value(value);
          release(); // must release before calling .stop
          state.stop();
        } else
          release();

        process(newState);
      }
    }
  else
    void setValue() @safe nothrow {
      with (state.bitfield.update(Flags.value_produced, Counter.tick)) {
        if (!isValueProduced(oldState)) {
          state.stop();
        }
        process(newState);
      }
    }
  void setDone() @safe nothrow {
    with (state.bitfield.update(Flags.doneOrError_produced, Counter.tick)) {
      if (state.noDropouts && !isDoneOrErrorProduced(oldState)) {
        state.stop();
      }
      process(newState);
    }
  }
  void setError(Exception exception) @safe nothrow {
    with (state.bitfield.lock(Flags.doneOrError_produced, Counter.tick)) {
      if (!isDoneOrErrorProduced(oldState)) {
        state.exception = exception;
        if (state.noDropouts) {
          release(); // release before stop
          state.stop();
        }
      }
      release();
      process(newState);
    }
  }
  private void process(size_t newState) {
    import concurrency.receiver : setValueOrError;

    if (!isLast(newState))
      return;

    state.cb.dispose();
    if (receiver.getStopToken().isStopRequested)
      receiver.setDone();
    else if (isValueProduced(newState)) {
      static if (is(Value == void))
        receiver.setValueOrError();
      else
        receiver.setValueOrError(state.value);
    } else if (state.exception)
      receiver.setError(state.exception);
    else
      receiver.setDone();
  }
  mixin ForwardExtensionPoints!receiver;
}
