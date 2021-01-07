module kaleidic.experimental.concurrency;

import kaleidic.experimental.concurrency.stoptoken;
import kaleidic.experimental.concurrency.sender;
import concepts;

bool isMainThread() @trusted {
  import core.thread : Thread;
  return Thread.getThis().isMainThread();
}

auto sync_wait(Sender)(auto ref Sender sender, StopSource stopSource = null) {
  static assert(models!(Sender, isSender));
  import kaleidic.experimental.concurrency.signal;
  import kaleidic.experimental.concurrency.thread;
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

  static struct Receiver {
    LocalThreadExecutor localThreadExecutor;
    bool* canceled;
    static if (!is(Value == void))
      Value* result;
    static if (!NoThrow)
      Exception* exception;
    StopSource stopSource;
    void setDone() nothrow @safe {
      (*canceled) = true;
      localThreadExecutor.stop();
    }
    static if (!NoThrow)
      void setError(Exception e) nothrow @safe {
        (*exception) = e;
        localThreadExecutor.stop();
      }
    static if (is(Value == void))
      void setValue() nothrow @safe {
        localThreadExecutor.stop();
      }
    else
      void setValue(Value value) nothrow @safe {
        (*result) = value;
        localThreadExecutor.stop();
      }
    auto getStopToken() nothrow @safe @nogc {
      return StopToken(stopSource);
    }
  }

  static if (!is(Value == void)) {
    static if (!NoThrow)
      auto receiver = Receiver(localThreadExecutor, &canceled, &result, &exception, stopSource);
    else
      auto receiver = Receiver(localThreadExecutor, &canceled, &result, stopSource);
  } else {
    static if (!NoThrow)
      auto receiver = Receiver(localThreadExecutor, &canceled, &exception, stopSource);
    else
      auto receiver = Receiver(localThreadExecutor, &canceled, stopSource);
  }

  /// we allow passing a scoped receiver because we know this sender will terminate before this function ends
  (()@trusted => sender.connect(receiver).start())();

  localThreadExecutor.start(); /// this blocks until one of the setXxx function on the receiver is called

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
