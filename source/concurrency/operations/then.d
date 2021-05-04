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

private struct ThenSender(Sender, Fun) {
  import std.traits : ReturnType;
  static assert(models!(typeof(this), isSender));
  alias Value = ReturnType!fun;
  Sender sender;
  Fun fun;
  auto connect(Receiver)(Receiver receiver) {
    alias R = ThenReceiver!(Receiver, Sender.Value, Fun);
    return sender.connect(R(receiver, fun));
  }
}
