module concurrency.operations.retrywhen;

import concurrency;
import concurrency.operations.via;
import concurrency.receiver;
import concurrency.sender;
import concurrency.stoptoken;
import concepts;
import std.traits;

version(unittest) {
  struct Wait {
    import core.time : Duration;
    Duration dur;
    int max = 5;
    int n = 0;
    auto failure(Exception e) @safe {
      n++;
      if (n >= max)
        throw e;
      return delay(dur);
    }
  }
}

enum isRetryWhenLogic(T) = models!(typeof(T.init.failure(Exception.init)), isSender);

auto retryWhen(Sender, Logic)(Sender sender, Logic logic) {
  return RetryWhenSender!(Sender, Logic)(sender, logic);
}

private class RetryWhenExceptionWrapper : Exception {
  this(Throwable t) @safe nothrow {
    super("Wrapper");
    next = t;
  }
}

private struct RetryWhenExceptionWrapperReceiver(Receiver, Value) {
  private {
    Receiver receiver;
  }
  static if (is(Value == void)) {
    void setValue() @safe {
      receiver.setValue();
    }
  } else {
    void setValue(Value value) @safe {
      receiver.setValue(value);
    }
  }
  void setDone() @safe nothrow {
    receiver.setDone();
  }
  void setError(Throwable t) @safe nothrow {
    receiver.setError(new RetryWhenExceptionWrapper(t));
  }
  mixin ForwardExtensionPoints!receiver;
}

private struct RetryWhenExceptionWrapperSender(Sender) {
  static assert(models!(typeof(this), isSender));
  alias Value = Sender.Value;
  Sender sender;
  auto connect(Receiver)(return Receiver receiver) @safe scope return {
    // ensure NRVO
    auto op = sender.connect(RetryWhenExceptionWrapperReceiver!(Receiver, Value)(receiver));
    return op;
  }
}

private struct RetryWhenReceiver(Receiver, Sender, Logic) {
  private {
    Sender sender;
    Receiver receiver;
    Logic logic;
    alias Value = Sender.Value;
  }
  static if (is(Value == void)) {
    void setValue() @safe {
      receiver.setValueOrError();
    }
  } else {
    void setValue(Value value) @safe {
      receiver.setValueOrError(value);
    }
  }
  void setDone() @safe nothrow {
    receiver.setDone();
  }
  void setError(Throwable t) @safe nothrow {
    auto w = cast(RetryWhenExceptionWrapper) t;
    if (w) {
      receiver.setError(w.next);
      return;
    }
    auto e = cast(Exception) t;
    if (!e) {
      receiver.setError(e);
      return;
    }
    try {
      auto s = logic.failure(e);
      // TODO: we connect on the heap here but we can probably do something smart...
      // Maybe we can store the new Op in the RetryWhenOp struct
      // From what I gathered that is what libunifex does
      sender.via(RetryWhenExceptionWrapperSender!(typeof(s))(s)).connectHeap(this).start();
    } catch (Exception e) {
      receiver.setError(e);
    }
  }
  mixin ForwardExtensionPoints!receiver;
}

private struct RetryWhenOp(Receiver, Sender, Logic) {
  alias Op = OpType!(Sender, RetryWhenReceiver!(Receiver, Sender, Logic));
  Op op;
  @disable this(ref return scope typeof(this) rhs);
  @disable this(this);
  this(Sender sender, return RetryWhenReceiver!(Receiver, Sender, Logic) receiver) @trusted scope {
    op = sender.connect(receiver);
  }
  void start() @trusted nothrow scope {
    op.start();
  }
}

struct RetryWhenSender(Sender, Logic) if (models!(Sender, isSender) && models!(Logic, isRetryWhenLogic)) {
  static assert(models!(typeof(this), isSender));
  alias Value = Sender.Value;
  Sender sender;
  Logic logic;
  auto connect(Receiver)(return Receiver receiver) @safe scope return {
    // ensure NRVO
    auto op = RetryWhenOp!(Receiver, Sender, Logic)(sender, RetryWhenReceiver!(Receiver, Sender, Logic)(sender, receiver, logic));
    return op;
  }
}
