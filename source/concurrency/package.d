module concurrency;

import concurrency.stoptoken;
import concurrency.sender;
import concurrency.thread;
import concepts;

bool isMainThread() @trusted {
  import core.thread : Thread;
  return Thread.getThis().isMainThread();
}

package struct SyncWaitReceiver2(Value, bool isNoThrow) {
  static struct State {
    LocalThreadWorker worker;
    bool canceled;
    static if (!is(Value == void))
      Value result;
    static if (!isNoThrow)
      Exception exception;
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

  static if (!isNoThrow)
    void setError(Exception e) nothrow @safe {
      state.exception = e;
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
  enum NoThrow = !canSenderThrow!(Sender);

  alias Receiver = SyncWaitReceiver2!(Value, NoThrow);

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
  static if (!NoThrow)
    if (state.exception !is null)
      throw state.exception;

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

struct Result(T) {
  import mir.algebraic : Algebraic, match;
  static struct Value(T) {
    static if (!is(T == void))
      T value;
  }
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
    return result._is!(Value!T);
  }
  static if (!is(T == void))
    T value() {
      return result.get!(Value!T).value;
    }
  Exception error() {
    return result.get!(Exception);
  }
  void assumeOk() {
    result.match!((Exception e){ throw e;},(ref t){});
  }
}

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
  enum NoThrow = !canSenderThrow!(Sender);

  alias Receiver = SyncWaitReceiver2!(Value, NoThrow);

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

  static if (!NoThrow)
    if (state.exception !is null)
      return Result!Value(state.exception);

  static if (is(Value == void))
    return Result!Value();
  else
    return Result!Value(state.result);
}
