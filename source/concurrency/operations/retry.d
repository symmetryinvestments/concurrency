module concurrency.operations.retry;

import concurrency;
import concurrency.receiver;
import concurrency.sender;
import concurrency.stoptoken;
import concepts;
import std.traits;

struct Times {
  int max = 5;
  int n = 0;
  bool failure(Exception e) @safe nothrow {
    n++;
    return n >= max;
  }
}

auto retry(Sender, Logic)(Sender sender, Logic logic) {
  return RetrySender!(Sender, Logic)(sender, logic);
}


private struct RetryReceiver(Receiver, Sender, Logic) {
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
  void setError(Exception e) @safe nothrow {
    if (logic.failure(e))
      receiver.setError(e);
    else {
      try {
        sender.connect(this).start();
      } catch (Exception e) {
        receiver.setError(e);
      }
    }
  }
  auto getStopToken() nothrow @safe {
    return receiver.getStopToken();
  }
}

private struct Op(Receiver, Sender, Logic) {
  Sender sender;
  RetryReceiver!(Receiver, Sender, Logic) receiver;
  void start() @safe nothrow {
    sender.connect(receiver).start();
  }
}

private struct RetrySender(Sender, Logic) {
  static assert(models!(typeof(this), isSender));
  alias Value = Sender.Value;
  Sender sender;
  Logic logic;
  auto connect(Receiver)(Receiver receiver) {
    return Op!(Receiver, Sender, Logic)(sender, RetryReceiver!(Receiver, Sender, Logic)(sender, receiver, logic));
  }
}
