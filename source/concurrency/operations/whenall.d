module concurrency.operations.whenall;

import concurrency;
import concurrency.receiver;
import concurrency.sender;
import concurrency.stoptoken;
import concepts;
import std.traits;
import concurrency.utils : spin_yield, casWeak;

WhenAllSender!(Senders) whenAll(Senders...)(Senders senders) if (Senders.length > 1){
  return WhenAllSender!(Senders)(senders);
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
  Receiver receiver;
  Senders senders;
  void start() @trusted {
    import concurrency.stoptoken : StopSource;
    if (receiver.getStopToken().isStopRequested) {
      receiver.setDone();
      return;
    }
    auto state = new WhenAllState!(WhenAllResult!(Senders))();
    state.cb = receiver.getStopToken().onStop(cast(void delegate() nothrow @safe shared)&state.stop); // butt ugly cast, but it won't take the second overload
    foreach(i, Sender; Senders) {
      senders[i].connect(WhenAllReceiver!(Receiver, Sender.Value, WhenAllResult!(Senders))(receiver, state, i, Senders.length)).start();
    }
  }
}

private struct WhenAllSender(Senders...) {
  alias Result = WhenAllResult!(Senders);
  static if (hasMember!(Result, "values"))
    alias Value = typeof(Result.values);
  else
    alias Value = void;
  Senders senders;
  auto connect(Receiver)(Receiver receiver) {
    return WhenAllOp!(Receiver, Senders)(receiver, senders);
  }
}

private class WhenAllState(Value) : StopSource {
  StopCallback cb;
  static if (is(typeof(Value.values)))
    Value value;
  Exception exception;
  shared size_t racestate;
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
  private void setReceiverValue() nothrow {
    import concurrency.receiver : setValueOrError;
    static if (is(typeof(Value.values)))
      receiver.setValueOrError(state.value.values);
    else
      receiver.setValueOrError();
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
      auto transition = update(Flags.value_produced);
      state.value.setValue(value, senderIndex);

      if (isLast(transition.new_)) {
        state.cb.dispose();
        if (receiver.getStopToken().isStopRequested())
          receiver.setDone();
        else if (isExceptionProduced(transition.new_))
          receiver.setError(state.exception);
        else if (state.isStopRequested())
          receiver.setDone();
        else
          setReceiverValue();
      }
    }
  else
    void setValue() {
      auto transition = update(Flags.value_produced);

      if (isLast(transition.new_)) {
        state.cb.dispose();

        if (receiver.getStopToken().isStopRequested())
          receiver.setDone();
        else if (isExceptionProduced(transition.new_))
          receiver.setError(state.exception);
        else if (state.isStopRequested())
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
      else if (isExceptionProduced(transition.new_))
        receiver.setError(state.exception);
      else
        receiver.setDone();
    } else
      state.stop();
  }
  void setError(Exception exception) {
    auto transition = update(Flags.exception_produced | Flags.locked);
    if (!isExceptionProduced(transition.old)) {
      state.exception = exception;
      state.racestate.atomicOp!"-="(Flags.locked); // need to unlock before stop
      state.stop();
    } else
      state.racestate.atomicOp!"-="(Flags.locked);

    if (isLast(transition.new_)) {
      state.cb.dispose();
      if (receiver.getStopToken().isStopRequested())
        receiver.setDone();
      else
        receiver.setError(state.exception);
    }
  }
}
