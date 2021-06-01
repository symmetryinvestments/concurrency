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
        // TODO: we connect on the heap here but we can probably do something smart...
        // Maybe we can store the new Op in the RetryOp struct
        // From what I gathered that is what libunifex does
        sender.connectHeap(this).start();
      } catch (Exception e) {
        receiver.setError(e);
      }
    }
  }
  auto getStopToken() nothrow @safe {
    return receiver.getStopToken();
  }
}

private struct RetryOp(Receiver, Sender, Logic) {
  alias Op = OpType!(Sender, RetryReceiver!(Receiver, Sender, Logic));
  Op op;
  this(Sender sender, RetryReceiver!(Receiver, Sender, Logic) receiver) {
    op = sender.connect(receiver);
  }
  void start() @safe nothrow {
    op.start();
  }
}

struct RetrySender(Sender, Logic) if (models!(Sender, isSender)) {
  static assert(models!(typeof(this), isSender));
  alias Value = Sender.Value;
  Sender sender;
  Logic logic;
  auto connect(Receiver)(Receiver receiver) {
    return RetryOp!(Receiver, Sender, Logic)(sender, RetryReceiver!(Receiver, Sender, Logic)(sender, receiver, logic));
  }
}
