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
RaceSender!(SenderA, SenderB) race(SenderA, SenderB)(SenderA senderA, SenderB senderB) {
  return RaceSender!(SenderA, SenderB)(senderA, senderB);
}

private template Result(SenderA, SenderB) {
  import mir.algebraic : Algebraic, Nullable;
  static if (is(SenderA.Value == void) && is(SenderB.Value == void))
    alias Result = void;
  else static if (is(SenderA.Value == void))
    alias Result = Nullable!(SenderB.Value);
  else static if (is(SenderB.Value == void))
    alias Result = Nullable!(SenderA.Value);
  else static if (is(SenderA.Value == SenderB.Value))
    alias Result = SenderA.Value;
  else
    alias Result = Algebraic!(SenderA.Value, SenderB.Value);
}

private struct RaceOp(Receiver, SenderA, SenderB) {
  import std.traits : ReturnType;
  alias ElementReceiver(Sender) = RaceReceiver!(Receiver, Sender.Value, R);
  alias R = Result!(SenderA, SenderB);
  alias OpA = ReturnType!(SenderA.connect!(ElementReceiver!SenderA));
  alias OpB = ReturnType!(SenderB.connect!(ElementReceiver!SenderB));
  Receiver receiver;
  State!R state;
  OpA opA;
  OpB opB;
  this(Receiver receiver, SenderA senderA, SenderB senderB) {
    this.receiver = receiver;
    state = new State!(R)();
    opA = senderA.connect(RaceReceiver!(Receiver, SenderA.Value, R)(receiver, state, 2));
    opB = senderB.connect(RaceReceiver!(Receiver, SenderB.Value, R)(receiver, state, 2));
  }
  void start() @trusted {
    import concurrency.stoptoken : StopSource;
    if (receiver.getStopToken().isStopRequested) {
      receiver.setDone();
      return;
    }
    state.cb = receiver.getStopToken().onStop(cast(void delegate() nothrow @safe shared)&state.stop); // butt ugly cast, but it won't take the second overload
    opA.start();
    opB.start();
  }
}

private struct RaceSender(SenderA, SenderB) {
  alias Value = Result!(SenderA, SenderB);
  SenderA senderA;
  SenderB senderB;
  auto connect(Receiver)(Receiver receiver) {
    return RaceOp!(Receiver, SenderA, SenderB)(receiver, senderA, senderB);
  }
}

private class State(Value) : StopSource {
  StopCallback cb;
  static if (!is(Value == void))
    Value value;
  Exception exception;
  shared size_t racestate;
}

private enum Flags : size_t {
  locked = 0x1,
  value_produced = 0x2,
  exception_produced = 0x4
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
  private void setReceiverValue() nothrow {
    import concurrency.receiver : setValueOrError;
    static if (is(Value == void))
      receiver.setValueOrError();
    else
      receiver.setValueOrError(state.value);
  }
  private auto update(size_t transition) nothrow {
    import std.typecons : tuple;
    size_t oldState, newState;
    do {
      goto load_state;
      do {
        spin_yield();
      load_state:
        oldState = state.racestate.atomicLoad!(MemoryOrder.acq);
      } while (isLocked(oldState));
      newState = (oldState + Counter.tick) | transition;
    } while (!casWeak!(MemoryOrder.acq, MemoryOrder.acq)(&state.racestate, oldState, newState));
    return tuple!("old", "new_")(oldState, newState);
  }
  private bool isValueProduced(size_t state) {
    return (state & Flags.value_produced) > 0;
  }
  private bool isExceptionProduced(size_t state) {
    return (state & Flags.exception_produced) > 0;
  }
  private bool isLocked(size_t state) {
    return (state & Flags.locked) > 0;
  }
  private bool isLast(size_t state) {
    return (state >> 3) == senderCount;
  }
  static if (!is(InnerValue == void))
    void setValue(InnerValue value) {
      auto transition = update(Flags.value_produced | Flags.locked);
      if (!isValueProduced(transition.old)) {
        state.value = Value(value);
        state.racestate.atomicOp!"-="(Flags.locked); // need to unlock before stop
        state.stop();
      } else
        state.racestate.atomicOp!"-="(Flags.locked);

      if (isLast(transition.new_)) {
        state.cb.dispose();
        if (receiver.getStopToken().isStopRequested())
          receiver.setDone();
        else
          setReceiverValue();
      }
    }
  else
    void setValue() {
      auto transition = update(Flags.value_produced);
      if (!isValueProduced(transition.old)) {
        state.stop();
      }
      if (isLast(transition.new_)) {
        state.cb.dispose();
        if (receiver.getStopToken().isStopRequested())
          receiver.setDone();
        else
          setReceiverValue();
      }
    }
  void setDone() {
    auto transition = update(0);
    if (isLast(transition.new_)) {
      state.cb.dispose();
      if (receiver.getStopToken().isStopRequested())
        receiver.setDone();
      else if (isValueProduced(transition.new_))
        setReceiverValue();
      else if (isExceptionProduced(transition.new_))
        receiver.setError(state.exception);
      else
        receiver.setDone();
    }
  }
  void setError(Exception exception) {
    auto transition = update(Flags.exception_produced | Flags.locked);
    if (!isExceptionProduced(transition.old)) {
      state.exception = exception;
    }
    state.racestate.atomicOp!"-="(Flags.locked);

    if (isLast(transition.new_)) {
      state.cb.dispose();
      if (receiver.getStopToken().isStopRequested())
        receiver.setDone();
      else if (isValueProduced(transition.new_))
        setReceiverValue();
      else
        receiver.setError(state.exception);
    }
  }
}
