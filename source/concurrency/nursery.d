module concurrency.nursery;

import concurrency.stoptoken : StopSource, StopToken, StopCallback, onStop;
import concurrency.thread : LocalThreadExecutor;
import concurrency.receiver : getStopToken;
import concurrency.scheduler : SchedulerObjectBase;
import std.typecons : Nullable;

/// A Nursery is a place for senders to be ran in, while being a Sender itself.
/// Stopping the Nursery cancels all senders.
/// When any Sender completes with an Error all Senders are canceled as well.
/// Cancellation is signaled with a StopToken.
/// Senders themselves bare the responsibility to respond to stop requests.
/// When cancellation happens all Senders are waited on for completion.
/// Senders can be added to the Nursery at any time.
/// Senders are only started when the Nursery itself is being awaited on.
class Nursery : StopSource {
  import concurrency.sender : isSender, OperationalStateBase;
  import core.sync.mutex : Mutex;

  alias Value = void;
  private {
    Node[] operations;
    struct Node {
      OperationalStateBase state;
      void start() @safe nothrow {
        state.start();
      }
      size_t id;
    }
    Mutex mutex;
    shared size_t busy = 0;
    shared size_t counter = 0;
    Exception exception; // first exception from sender, if any
    ReceiverObject receiver;
    StopCallback stopCallback;
    Nursery assumeThreadSafe() @trusted shared nothrow {
      return cast(Nursery)this;
    }
  }

  this() @safe shared {
    import concurrency.utils : resetScheduler;
    resetScheduler();
    with(assumeThreadSafe) mutex = new Mutex();
  }

  StopToken getStopToken() nothrow @trusted shared {
    return StopToken(cast(Nursery)this);
  }

  private auto getScheduler() nothrow @trusted shared {
    return (cast()receiver).getScheduler();
  }

  private void setError(Exception e, size_t id) nothrow @safe shared {
    import core.atomic : cas;
    with(assumeThreadSafe) cas(&exception, cast(Exception)null, e); // store exception if not already
    done(id);
    stop();
  }

  private void done(size_t id) nothrow @trusted shared {
    import std.algorithm : countUntil, remove;
    import core.atomic : atomicOp;

    with (assumeThreadSafe) {
      mutex.lock_nothrow();
      auto idx = operations.countUntil!(o => o.id == id);
      if (idx != -1)
        operations = operations.remove(idx);
      bool isDone = atomicOp!"-="(busy,1) == 0;
      auto localReceiver = receiver;
      auto localException = exception;
      if (isDone) {
        exception = null;
        receiver = null;
        stopCallback.dispose();
        stopCallback = null;
      }
      mutex.unlock_nothrow();

      if (isDone && localReceiver !is null) {
        if (localException !is null) {
          localReceiver.setError(localException);
        } else if (isStopRequested()) {
          localReceiver.setDone();
        } else {
          try {
            localReceiver.setValue();
          } catch (Exception e) {
            localReceiver.setError(e);
          }
        }
      }
    }
  }

  void run(Sender)(Nullable!Sender sender) shared if (isSender!Sender) {
    if (!sender.isNull)
      run(sender.get());
  }

  void run(Sender)(Sender sender) shared @trusted if (isSender!Sender) {
    import std.typecons : Nullable;
    import core.atomic : atomicOp;
    import concurrency.sender : connectHeap;

    static if (is(Sender == class) || is(Sender == interface))
      if (sender is null)
        return;

    size_t id = atomicOp!"+="(counter, 1);
    auto op = sender.connectHeap(NurseryReceiver!(Sender.Value)(this, id));

    mutex.lock_nothrow();
    operations ~= cast(shared) Node(op, id);
    atomicOp!"+="(busy, 1);
    bool hasStarted = this.receiver !is null;
    mutex.unlock_nothrow();

    if (hasStarted)
      op.start();
  }

  auto connect(Receiver)(Receiver receiver) @trusted {
    return (cast(shared)this).connect(receiver);
  }

  auto connect(Receiver)(Receiver receiver) shared {
    final class ReceiverImpl : ReceiverObject {
      Receiver receiver;
      this(Receiver receiver) { this.receiver = receiver; }
      void setValue() @safe { receiver.setValue(); }
      void setDone() nothrow @safe { receiver.setDone(); }
      void setError(Exception e) nothrow @safe { receiver.setError(e); }
      SchedulerObjectBase getScheduler() nothrow @safe {
        import concurrency.scheduler : toSchedulerObject;
        return receiver.getScheduler().toSchedulerObject();
      }
    }
    static struct Op {
      shared Nursery nursery;
      StopCallback cb;
      ReceiverObject receiver;
      @disable this(ref return scope typeof(this) rhs);
      @disable this(this);
      this(shared Nursery n, StopCallback cb, ReceiverObject r) {
        nursery = n;
        this.cb = cb;
        receiver = r;
      }
      void start() nothrow {
        nursery.setReceiver(receiver, cb);
      }
    }
    auto stopToken = receiver.getStopToken();
    auto cb = stopToken.onStop(() shared nothrow @trusted => cast(void)this.stop());
    return Op(this, cb, new ReceiverImpl(receiver));
  }

  private void setReceiver(ReceiverObject r, StopCallback cb) nothrow @safe shared {
    with(assumeThreadSafe) {
      mutex.lock_nothrow();
      assert(this.receiver is null, "Cannot await a nursery twice.");
      receiver = r;
      stopCallback = cb;
      auto ops = operations.dup();
      mutex.unlock_nothrow();

      // start all work
      foreach(op; ops)
        op.start();
    }
  }
}

private interface ReceiverObject {
  void setValue() @safe;
  void setDone() nothrow @safe;
  void setError(Exception e) nothrow @safe;
  SchedulerObjectBase getScheduler() nothrow @safe;
}

private struct NurseryReceiver(Value) {
  shared Nursery nursery;
  size_t id;
  this(shared Nursery nursery, size_t id) {
    this.nursery = nursery;
    this.id = id;
  }

  static if (is(Value == void)) {
    void setValue() shared @safe {
      (cast() this).setDone();
    }
    void setValue() @safe {
      (cast() this).setDone();
    }
  } else {
    void setValue(Value val) shared @trusted {
      (cast() this).setDone();
    }
    void setValue(Value val) @safe {
      nursery.done(id);
    }
  }

  void setDone() nothrow @safe {
    nursery.done(id);
  }

  void setError(Exception e) nothrow @safe {
    nursery.setError(e, id);
  }

  auto getStopToken() @safe {
    return nursery.getStopToken();
  }

  auto getScheduler() @safe {
    return nursery.getScheduler();
  }
}
