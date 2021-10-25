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
  alias Value = Sender.Value;
  auto result = syncWait(sender, (()@trusted=>cast()stopSource)());
  static if (is(Value == void)) {
    return result.match!((Cancelled c) => false,
                         (Exception e) { throw e; },
                         (typeof(null)) => true);
  } else {
    return result.match!((Cancelled c) { throw new Exception("Cancelled"); },
                         (Exception e) { throw e; },
                         (ref t) => t);
  }
}

deprecated("Use syncWait instead")
auto sync_wait(Sender)(auto scope ref Sender sender) {
  alias Value = Sender.Value;
  auto result = syncWait(sender);
  static if (is(Value == void)) {
    return result.match!((Cancelled c) => false,
                         (Exception e) { throw e; },
                         (typeof(null)) => true);
  } else {
    return result.match!((Cancelled c) { throw new Exception("Cancelled"); },
                         (Exception e) { throw e; },
                         (ref t) => t);
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

void setTopLevelStopSource(shared StopSource stopSource) @trusted {
  import std.exception : enforce;
  enforce(parentStopSource is null);
  parentStopSource = cast()stopSource;
}

package(concurrency) static StopSource parentStopSource;

/// Start the Sender and waits until it completes, cancels, or has an error.
auto syncWait(Sender, StopSource)(auto ref Sender sender, StopSource stopSource) {
  return syncWaitImpl(sender, (()@trusted=>cast()stopSource)());
}

auto syncWait(Sender)(auto scope ref Sender sender) {
  import concurrency.signal : globalStopSource;
  auto childStopSource = new shared StopSource();
  StopToken parentStopToken = parentStopSource ? StopToken(parentStopSource) : StopToken(globalStopSource);

  StopCallback cb = parentStopToken.onStop(() shared { childStopSource.stop(); });
  auto result = syncWaitImpl(sender, (()@trusted=>cast()childStopSource)());
  // detach stopSource
  cb.dispose();
  return result;
}

private Result!(Sender.Value) syncWaitImpl(Sender)(auto scope ref Sender sender, StopSource stopSource) @safe {
  import mir.algebraic : Algebraic, Nullable;
  static assert(models!(Sender, isSender));
  import concurrency.signal;
  import core.sys.posix.signal : SIGTERM, SIGINT;

  alias Value = Sender.Value;
  alias Receiver = SyncWaitReceiver2!(Value);

  /// TODO: not fiber safe
  auto old = parentStopSource;
  parentStopSource = stopSource;

  auto state = Receiver.State(stopSource);
  Receiver receiver = (()@trusted => Receiver(&state))();
  auto op = sender.connect(receiver);
  op.start();

  state.worker.start();

  parentStopSource = old;

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
