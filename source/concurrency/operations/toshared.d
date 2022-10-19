module concurrency.operations.toshared;

import concurrency.receiver;
import concurrency.sender;
import concurrency.stoptoken;
import concurrency.scheduler : NullScheduler;
import concepts;
import std.traits;
import mir.algebraic : Algebraic, Nullable, match;

/// Wraps a Sender in a SharedSender. A SharedSender allows many receivers to connect to the same underlying Sender, forwarding the same termination call to each receiver.
/// The underlying Sender is connected and started only once. It can be explicitely `reset` so that it connects and starts the underlying Sender the next time it started. Calling `reset` when the underlying Sender hasn't completed is a no-op.
/// When the last receiver triggers its stoptoken while the underlying Sender is still running, the latter will be cancelled and one termination function of the former will be called after the latter is completed. (This is to ensure structured concurrency, otherwise tasks could be left running without anyone awaiting them).
/// If an receiver is connected after the underlying Sender has already been completed, that receiver will have one of its termination functions called immediately.
/// This operation is useful when you have multiple tasks that all depend on one shared task. It allows you to write the shared task as a regular Sender and simply apply a `.toShared`.
auto toShared(Sender, Scheduler)(Sender sender, Scheduler scheduler) {
  return new SharedSender!(Sender, Scheduler, ResetLogic.keepLatest)(sender, scheduler);
}

auto toShared(Sender)(Sender sender) {
  return new SharedSender!(Sender, NullScheduler, ResetLogic.keepLatest)(sender, NullScheduler());
}

enum ResetLogic {
  keepLatest,
  alwaysReset
}

class SharedSender(Sender, Scheduler, ResetLogic resetLogic) if (models!(Sender, isSender)) {
  import std.traits : ReturnType;
  static assert(models!(typeof(this), isSender));
  alias Props = Properties!(Sender);
  alias Value = Props.Value;
  alias InternalValue = Props.InternalValue;
  private {
    Sender sender;
    Scheduler scheduler;
    SharedSenderState!(Sender) state;
    void add(Props.DG dg) @safe nothrow {
      with(state.counter.lock(0, Flags.tick)) {
        if (was(Flags.completed)) {
          InternalValue value = state.inst.value.get;
          release(Flags.tick); // release early
          dg(value);
        } else {
          if ((oldState >> 2) == 0) {
            auto localState = new SharedSenderInstStateImpl!(Sender, Scheduler, resetLogic)();
            this.state.inst = localState;
            release(); // release early
            localState.dgs.pushBack(dg);
            try {
              localState.op = sender.connect(SharedSenderReceiver!(Sender, Scheduler, resetLogic)(&state, scheduler));
            } catch (Exception e) {
              state.process!(resetLogic)(InternalValue(e));
            }
            localState.op.start();
          } else {
            auto localState = state.inst;
            localState.dgs.pushBack(dg);
          }
        }
      }
    }
    /// returns false if it is the last
    bool remove(Props.DG dg) @safe nothrow {
      with (state.counter.lock(0, 0, Flags.tick)) {
        if (was(Flags.completed)) {
          release(0-Flags.tick); // release early
          return true;
        }
        if ((newState >> 2) == 0) {
          auto localStopSource = state.inst;
          release(); // release early
          localStopSource.stop();
          return false;
        } else {
          auto localReceiver = state.inst;
          release(); // release early
          localReceiver.dgs.remove(dg);
          return true;
        }
      }
    }
  }
  bool isCompleted() @trusted {
    import core.atomic : MemoryOrder;
    return (state.counter.load!(MemoryOrder.acq) & Flags.completed) > 0;
  }
  void reset() @trusted {
    with (state.counter.lock()) {
      if (was(Flags.completed))
        release(Flags.completed);
    }
  }
  this(Sender sender, Scheduler scheduler) {
    this.sender = sender;
    this.scheduler = scheduler;
  }
  auto connect(Receiver)(return Receiver receiver) @safe scope return {
    // ensure NRVO
    auto op = SharedSenderOp!(Sender, Scheduler, resetLogic, Receiver)(this, receiver);
    return op;
  }
}

private enum Flags {
  locked = 0x1,
  completed = 0x2,
  tick = 0x4
}

private struct Done{}

private struct ValueRep{}

private template Properties(Sender) {
  alias Value = Sender.Value;
  static if (!is(Value == void))
    alias ValueRep = Value;
  else
    alias ValueRep = .ValueRep;
  alias InternalValue = Algebraic!(Throwable, ValueRep, Done);
  alias DG = void delegate(InternalValue) nothrow @safe shared;
}

private struct SharedSenderOp(Sender, Scheduler, ResetLogic resetLogic, Receiver) {
  alias Props = Properties!(Sender);
  SharedSender!(Sender, Scheduler, resetLogic) parent;
  Receiver receiver;
  StopCallback cb;
  @disable this(ref return scope typeof(this) rhs);
  @disable this(this);
  void start() nothrow @trusted scope {
    parent.add(&(cast(shared)this).onValue);
    cb = receiver.getStopToken.onStop(&(cast(shared)this).onStop);
  }
  void onStop() nothrow @trusted shared {
    with(unshared) {
      /// If this is the last one connected, remove will return false,
      /// stop the underlying sender and we will receive the setDone via
      /// the onValue.
      /// This is to ensure we always await the underlying sender for
      /// completion.
      if (parent.remove(&(cast(shared)this).onValue))
        receiver.setDone();
    }
  }
  void onValue(Props.InternalValue value) nothrow @safe shared {
    with(unshared) {
      value.match!((Props.ValueRep v){
          try {
            static if (is(Props.Value == void))
              receiver.setValue();
            else
              receiver.setValue(v);
          } catch (Exception e) {
            /// TODO: dispose needs to be called in all cases, except
            /// this onValue can sometimes be called immediately,
            /// leaving no room to set cb.dispose...
            cb.dispose();
            receiver.setError(e);
          }
        }, (Throwable e){
          receiver.setError(e);
        }, (Done d){
          receiver.setDone();
        });
    }
  }
  private auto ref unshared() @trusted nothrow shared {
    return cast()this;
  }
}

private struct SharedSenderReceiver(Sender, Scheduler, ResetLogic resetLogic) {
  alias InternalValue = Properties!(Sender).InternalValue;
  alias ValueRep = Properties!(Sender).ValueRep;
  SharedSenderState!(Sender)* state;
  Scheduler scheduler;
  static if (is(Sender.Value == void))
    void setValue() @safe {
      process(InternalValue(ValueRep()));
    }
  else
    void setValue(ValueRep v) @safe {
      process(InternalValue(v));
    }
  void setDone() @safe nothrow {
    process(InternalValue(Done()));
  }
  void setError(Throwable e) @safe nothrow {
    process(InternalValue(e));
  }
  private void process(InternalValue v) @safe {
    state.process!(resetLogic)(v);
  }
  StopToken getStopToken() @trusted nothrow {
    return StopToken(state.inst);
  }
  Scheduler getScheduler() @safe nothrow scope {
    return scheduler;
  }
}

private struct SharedSenderState(Sender) {
  import concurrency.bitfield;

  alias Props = Properties!(Sender);

  SharedSenderInstState!(Sender) inst;
  SharedBitField!Flags counter;
}

private template process(ResetLogic resetLogic) {
  void process(State, InternalValue)(State state, InternalValue value) @safe {
    state.inst.value = value;
    static if (resetLogic == ResetLogic.alwaysReset) {
      size_t updateFlag = 0;
    } else {
      size_t updateFlag = Flags.completed;
    }
    with(state.counter.lock(updateFlag)) {
      auto localState = state.inst;
      InternalValue v = localState.value.get;
      release(oldState & (~0x3)); // release early and remove all ticks
      if (localState.isStopRequested)
        v = Done();
      foreach(dg; localState.dgs[])
        dg(v);
    }
  }
}

private class SharedSenderInstState(Sender) : StopSource {
  import concurrency.slist;
  import std.traits : ReturnType;
  alias Props = Properties!(Sender);
  shared SList!(Props.DG) dgs;
  Nullable!(Props.InternalValue) value;
  this() {
    this.dgs = new shared SList!(Props.DG);
  }
}

/// NOTE: this is a super class to break a dependency cycle of SharedSenderReceiver on itself (which it technically doesn't have but is probably too complex for the compiler)
private class SharedSenderInstStateImpl(Sender, Scheduler, ResetLogic resetLogic) : SharedSenderInstState!(Sender) {
  alias Op = OpType!(Sender, SharedSenderReceiver!(Sender, Scheduler, resetLogic));
  Op op;
}
