module concurrency.operations.toshared;

import concurrency;
import concurrency.receiver;
import concurrency.sender;
import concurrency.stoptoken;
import concepts;
import std.traits;
import mir.algebraic : Algebraic, Nullable, match;

/// Wraps a Sender in a SharedSender. A SharedSender allows many receivers to connect to the same underlying Sender, forwarding the same termination call to each receiver.
/// The underlying Sender is connected and started only once. It can be explicitely `reset` so that it connects and starts the underlying Sender the next time it started. Calling `reset` when the underlying Sender hasn't completed is a no-op.
/// When the last receiver triggers its stoptoken while the underlying Sender is still running, the latter will be cancelled and one termination function of the former will be called after the latter is completed. (This is to ensure structured concurrency, otherwise tasks could be left running without anyone awaiting them).
/// If an receiver is connected after the underlying Sender has already been completed, that receiver will have one of its termination functions called immediately.
/// This operation is useful when you have multiple tasks that all depend on one shared task. It allows you to write the shared task as a regular Sender and simply apply a `.toShared`.
auto toShared(Sender, Scheduler)(Sender sender, Scheduler scheduler) {
  return new SharedSender!(Sender, Scheduler)(sender, scheduler);
}

auto toShared(Sender)(Sender sender) {
  return new SharedSender!(Sender, NullScheduler)(sender, NullScheduler());
}

private struct NullScheduler {}
private struct Done{}
private struct ValueRep{}

class SharedSender(Sender, Scheduler) if (models!(Sender, isSender)) {
  import std.traits : ReturnType;
  import concurrency.slist;
  import concurrency.bitfield;
  static assert(models!(typeof(this), isSender));
  alias Value = Sender.Value;
  static if (!is(Value == void))
    alias ValueRep = Value;
  alias InternalValue = Algebraic!(Exception, ValueRep, Done);
  alias DG = void delegate(InternalValue) nothrow @safe shared;
  static struct SharedSenderOp(Receiver) {
    SharedSender parent;
    Receiver receiver;
    StopCallback cb;
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
    void onValue(InternalValue value) nothrow @safe shared {
      with(unshared) {
        value.match!((ValueRep v){
            try {
              static if (is(Value == void))
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
          }, (Exception e){
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
  static class SharedSenderState : StopSource {
    import std.traits : ReturnType;
    alias Op = OpType!(Sender, SharedSenderReceiver);
    SharedSender parent;
    shared SList!DG dgs;
    Nullable!InternalValue value;
    Op op;
    this(SharedSender parent) {
      this.dgs = new shared SList!DG;
      this.parent = parent;
    }
  }
  static struct SharedSenderReceiver {
    SharedSenderState state;
    Scheduler scheduler;
    static if (is(Sender.Value == void))
      void setValue() @safe {
        state.value = InternalValue(ValueRep());
        process();
      }
    else
      void setValue(ValueRep v) @safe {
        state.value = InternalValue(v);
        process();
      }
    void setDone() @safe nothrow {
      state.value = InternalValue(Done());
      process();
    }
    void setError(Exception e) @safe nothrow {
      state.value = InternalValue(e);
      process();
    }
    private void process() @trusted {
      state.parent.process();
    }
    StopToken getStopToken() @safe nothrow {
      return StopToken(state);
    }
    Scheduler getScheduler() @safe nothrow scope {
      return scheduler;
    }
  }
  private {
    Sender sender;
    Scheduler scheduler;
    SharedSenderState state;
    enum Flags {
      locked = 0x1,
      completed = 0x2,
      tick = 0x4
    }
    SharedBitField!Flags counter;
    void add(DG dg) @safe nothrow {
      with(counter.lock(0, Flags.tick)) {
        if (was(Flags.completed)) {
          InternalValue value = state.value.get;
          release(Flags.tick); // release early
          dg(value);
        } else {
          if ((oldState >> 2) == 0) {
            auto localState = new SharedSenderState(this);
            this.state = localState;
            release(); // release early
            localState.dgs.pushBack(dg);
            try {
              localState.op = sender.connect(SharedSenderReceiver(localState, scheduler));
            } catch (Exception e) {
              state.value = InternalValue(e);
              process();
            }
            localState.op.start();
          } else {
            auto localState = state;
            release(); // release early
            localState.dgs.pushBack(dg);
          }
        }
      }
    }
    /// returns false if it is the last
    bool remove(DG dg) @safe nothrow {
      with (counter.lock(0, 0, Flags.tick)) {
        if (was(Flags.completed)) {
          release(0-Flags.tick); // release early
          return true;
        }
        if ((newState >> 2) == 0) {
          auto localStopSource = state;
          release(); // release early
          localStopSource.stop();
          return false;
        } else {
          auto localReceiver = state;
          release(); // release early
          localReceiver.dgs.remove(dg);
          return true;
        }
      }
    }
  }
  private void process() {
    with(counter.lock(Flags.completed)) {
      auto localState = state;
      release(oldState & (~0x3)); // release early and remove all ticks
      InternalValue v = localState.value.get;
      if (localState.isStopRequested)
        v = Done();
      foreach(dg; localState.dgs[])
        dg(v);
    }
  }
  bool isCompleted() @trusted {
    import core.atomic : MemoryOrder;
    return (counter.load!(MemoryOrder.acq) & Flags.completed) > 0;
  }
  void reset() @trusted {
    with (counter.lock()) {
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
    auto op = SharedSenderOp!Receiver(this, receiver);
    return op;
  }
}
