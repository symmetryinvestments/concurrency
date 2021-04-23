module concurrency.operations.then;

import concurrency;
import concurrency.receiver;
import concurrency.sender;
import concurrency.stoptoken;
import concepts;
import std.traits;

auto then(Sender, Fun)(Sender sender, Fun fun) {
  static assert (hasFunctionAttributes!(Fun, "shared"), "Function must be shared");

  return ThenSender!(Sender, Fun)(sender, fun);
}

private struct ThenReceiver(Receiver, Value, Fun) {
  Receiver receiver;
  Fun fun;
  static if (is(Value == void)) {
    void setValue() {
      static if (is(ReturnType!Fun == void)) {
        fun();
        receiver.setValue();
      } else
        receiver.setValue(fun());
    }
  } else {
    void setValue(Value value) {
      static if (is(ReturnType!Fun == void)) {
        fun(value);
        receiver.setValue();
      } else
        receiver.setValue(fun(value));
    }
  }
  void setDone() nothrow {
    receiver.setDone();
  }
  void setError(Exception e) nothrow {
    receiver.setError(e);
  }
  auto getStopToken() {
    return receiver.getStopToken();
  }
}

private struct Op(Sender, Receiver, Fun) {
  Sender sender;
  ThenReceiver!(Receiver, Sender.Value, Fun) receiver;
  void start() nothrow {
    sender.connect(receiver).start();
  }
}

private struct ThenSender(Sender, Fun) {
  import std.traits : ReturnType;
  static assert(models!(ThenSender, isSender));
  alias Value = ReturnType!fun;
  Sender sender;
  Fun fun;
  auto connect(Receiver)(Receiver receiver) {
    return Op!(Sender, Receiver, Fun)(sender, ThenReceiver!(Receiver, Sender.Value, Fun)(receiver, fun));
  }
}
