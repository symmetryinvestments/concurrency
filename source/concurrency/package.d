module concurrency;

import concurrency.stoptoken;
import concurrency.sender;
import concurrency.thread;
import concepts;

bool isMainThread() @trusted {
  import core.thread : Thread;
  return Thread.getThis().isMainThread();
}

private struct SyncWaitReceiver(Value, bool isNoThrow) {
  LocalThreadWorker* worker;
  bool* canceled;
  static if (!is(Value == void))
    Value* result;
  static if (!isNoThrow)
    Exception* exception;
  StopSource stopSource;
  void setDone() nothrow @safe {
    (*canceled) = true;
    worker.stop();
  }
  static if (!isNoThrow)
    void setError(Exception e) nothrow @safe {
      (*exception) = e;
      worker.stop();
    }
  static if (is(Value == void))
    void setValue() nothrow @safe {
      worker.stop();
    }
  else
    void setValue(Value value) nothrow @safe {
      (*result) = value;
      worker.stop();
    }
  auto getStopToken() nothrow @safe @nogc {
    return StopToken(stopSource);
  }
}

auto sync_wait(Sender)(auto ref Sender sender, StopSource stopSource = null) {
  static assert(models!(Sender, isSender));
  import concurrency.signal;
  import core.sys.posix.signal : SIGTERM, SIGINT;

  alias Value = Sender.Value;

  enum NoThrow = !canSenderThrow!(Sender);
  static if (!NoThrow)
    Exception exception;
  SignalHandler signalHandler;
  bool canceled;
  static if (!is(Value == void))
    Value result;

  auto localThreadExecutor = getLocalThreadExecutor();
  import std.stdio;
  if (stopSource is null) {
    stopSource = new StopSource();
    /// TODO: not so sure about this
    if (isMainThread) {
      signalHandler.setup((int signal) => cast(void)stopSource.stop());
      signalHandler.on(SIGINT);
      signalHandler.on(SIGTERM);
    }
  }
  auto worker = LocalThreadWorker(localThreadExecutor);

  alias Receiver = SyncWaitReceiver!(Value, NoThrow);

  static if (!is(Value == void)) {
    static if (!NoThrow)
      auto receiver = Receiver(&worker, &canceled, &result, &exception, stopSource);
    else
      auto receiver = Receiver(&worker, &canceled, &result, stopSource);
  } else {
    static if (!NoThrow)
      auto receiver = Receiver(&worker, &canceled, &exception, stopSource);
    else
      auto receiver = Receiver(&worker, &canceled, stopSource);
  }

  /// we allow passing a scoped receiver because we know this sender will terminate before this function ends
  (()@trusted => sender.connect(receiver).start())();

  worker.start();

  if (isMainThread)
    signalHandler.teardown();

  /// if exception, rethrow
  static if (!NoThrow)
    if (exception !is null)
      throw exception;

  /// if no value, return true if not canceled
  static if (is(Value == void))
    return !canceled;
  else {
    if (canceled)
      throw new Exception("Canceled");

    return result;
  }
}
