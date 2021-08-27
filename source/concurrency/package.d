module concurrency;

import concurrency.stoptoken;
import concurrency.sender;
import concurrency.thread;
import concepts;

bool isMainThread() @trusted {
  import core.thread : Thread;
  return Thread.getThis().isMainThread();
}

package struct SyncWaitReceiver2(Value) {
  static struct State {
    LocalThreadWorker worker;
    bool canceled;
    static if (!is(Value == void))
      Value result;
    Throwable throwable;
    StopSource stopSource;

    this(StopSource stopSource) {
      this.stopSource = stopSource;
      worker = LocalThreadWorker(getLocalThreadExecutor());
    }

    void handleSignal(int signal) {
      stopSource.stop();
    }
  }
  State* state;
  void setDone() nothrow @safe {
    state.canceled = true;
    state.worker.stop();
  }

  void setError(Throwable e) nothrow @safe {
    state.throwable = e;
    state.worker.stop();
  }
  static if (is(Value == void))
    void setValue() nothrow @safe {
      state.worker.stop();
    }
  else
    void setValue(Value value) nothrow @safe {
      state.result = value;
      state.worker.stop();
    }
  auto getStopToken() nothrow @safe @nogc {
    return StopToken(state.stopSource);
  }
  auto getScheduler() nothrow @safe {
    import concurrency.scheduler : SchedulerAdapter;
    return SchedulerAdapter!(LocalThreadWorker*)(&state.worker);
  }
}

deprecated("Use syncWait instead")
auto sync_wait(Sender, StopSource)(auto ref Sender sender, StopSource stopSource) {
  return sync_wait_impl(sender, (()@trusted=>cast()stopSource)());
}

deprecated("Use syncWait instead")
auto sync_wait(Sender)(auto scope ref Sender sender) {
  return sync_wait_impl(sender);
}

auto sync_wait_impl(Sender)(auto scope ref Sender sender, StopSource stopSource = null) @safe {
  static assert(models!(Sender, isSender));
  import concurrency.signal;
  import core.sys.posix.signal : SIGTERM, SIGINT;

  alias Value = Sender.Value;
  alias Receiver = SyncWaitReceiver2!(Value);

  auto state = Receiver.State(stopSource is null ? new StopSource() : stopSource);
  Receiver receiver = (()@trusted => Receiver(&state))();
  SignalHandler signalHandler;

  if (stopSource is null) {
    /// TODO: not so sure about this
    if (isMainThread) {
      (()@trusted => signalHandler.setup(&state.handleSignal))();
      signalHandler.on(SIGINT);
      signalHandler.on(SIGTERM);
    }
  }

  auto op = sender.connect(receiver);
  op.start();

  state.worker.start();

  if (isMainThread)
    signalHandler.teardown();

  /// if exception, rethrow
  if (state.throwable !is null)
    throw state.throwable;

  /// if no value, return true if not canceled
  static if (is(Value == void))
    return !state.canceled;
  else {
    if (state.canceled)
      throw new Exception("Canceled");

    return state.result;
  }
}

struct Cancelled {}
static immutable cancelledException = new Exception("Cancelled");

struct Result(T) {
  import mir.algebraic : Algebraic, Nullable;
  static struct Value(T) {
    static if (!is(T == void))
      T value;
  }
  static if (is(T == void))
    Nullable!(Cancelled, Exception) result;
  else
    Algebraic!(Value!T, Cancelled, Exception) result;

  static if (!is(T == void))
    this(T v) {
      result = Value!T(v);
    }
  this(Cancelled c) {
    result = c;
  }
  this(Exception e) {
    result = e;
  }

  bool isCancelled() {
    return result._is!Cancelled;
  }
  bool isError() {
    return result._is!Exception;
  }
  bool isOk() {
    static if (is(T == void))
      return result.isNull;
    else
      return result._is!(Value!T);
  }
  static if (!is(T == void))
    T value() {
      if (isCancelled)
        throw cancelledException;
      if (isError)
        throw error;
      return result.get!(Value!T).value;
    }
  Exception error() {
    return result.get!(Exception);
  }
  void assumeOk() {
    import mir.algebraic : match;
    static if (is(T == void))
      result.match!((typeof(null)){},(Exception e){throw e;},(Cancelled c){throw cancelledException;});
    else
      result.match!((Exception e){throw e;},(Cancelled c){throw cancelledException;},(ref t){});
  }
}

/// matches over the result of syncWait
template match(Handlers...) {
  // has to be separate because of dual-context limitation
  auto match(T)(Result!T r) {
    import mir.algebraic : match;
    static if (is(T == void))
      return r.result.match!(Handlers);
    else
      return r.result.match!((Result!(T).Value!(T) v) => v.value, (ref t) => t).match!(Handlers);
  }
}

/// Start the Sender and waits until it completes, cancels, or has an error.
auto syncWait(Sender, StopSource)(auto ref Sender sender, StopSource stopSource) {
  return syncWaitImpl(sender, (()@trusted=>cast()stopSource)());
}

auto syncWait(Sender)(auto scope ref Sender sender) {
  return syncWaitImpl(sender);
}

Result!(Sender.Value) syncWaitImpl(Sender)(auto scope ref Sender sender, StopSource stopSource = null) @safe {
  import mir.algebraic : Algebraic, Nullable;
  static assert(models!(Sender, isSender));
  import concurrency.signal;
  import core.sys.posix.signal : SIGTERM, SIGINT;

  alias Value = Sender.Value;
  alias Receiver = SyncWaitReceiver2!(Value);

  auto state = Receiver.State(stopSource is null ? new StopSource() : stopSource);
  // Receiver receiver = (()@trusted => Receiver(&state))();
  Receiver receiver = (()@trusted => Receiver(&state))();
  SignalHandler signalHandler;

  if (stopSource is null) {
    /// TODO: not so sure about this
    if (isMainThread) {
      (()@trusted => signalHandler.setup(&state.handleSignal))();
      signalHandler.on(SIGINT);
      signalHandler.on(SIGTERM);
    }
  }

  auto op = sender.connect(receiver);
  op.start();

  state.worker.start();

  if (isMainThread)
    signalHandler.teardown();

  if (state.canceled)
    return Result!Value(Cancelled());

  if (auto t = cast(Error)state.throwable)
    throw t;

  if (state.throwable !is null) {
    if (auto e = cast(Exception)state.throwable)
      return Result!Value(e);
    assert(false, "Can only rethrow Exceptions");
  }
  static if (is(Value == void))
    return Result!Value();
  else
    return Result!Value(state.result);
}
