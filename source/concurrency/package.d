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
}

auto sync_wait(Sender)(auto ref Sender sender, StopSource stopSource = null) {
  static assert(models!(Sender, isSender));
  import concurrency.signal;
  import core.sys.posix.signal : SIGTERM, SIGINT;

  alias Value = Sender.Value;
  enum NoThrow = !canSenderThrow!(Sender);

  alias Receiver = SyncWaitReceiver2!(Value, NoThrow);

  auto state = Receiver.State(stopSource is null ? new StopSource() : stopSource);
  Receiver receiver = Receiver(&state);
  SignalHandler signalHandler;

  if (stopSource is null) {
    /// TODO: not so sure about this
    if (isMainThread) {
      (()@trusted => signalHandler.setup(&state.handleSignal))();
      signalHandler.on(SIGINT);
      signalHandler.on(SIGTERM);
    }
  }

  /// we allow passing a scoped receiver because we know this sender will terminate before this function ends
  auto op = (()@trusted => sender.connect(receiver))();
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
