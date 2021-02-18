module concurrency.operations.withstoptoken;

import concurrency;
import concurrency.receiver;
import concurrency.sender;
import concurrency.stoptoken;
import concepts;
import std.traits;

auto withStopToken(Sender, Fun)(Sender sender, Fun fun) {
  return STSender!(Sender, Fun)(sender, fun);
}

private struct STReceiver(Receiver, Value, Fun) {
  Receiver receiver;
  Fun fun;
  static if (is(Value == void)) {
    void setValue() {
      static if (is(ReturnType!Fun == void)) {
        fun(receiver.getStopToken);
        receiver.setValueOrError();
      } else
        receiver.setValueOrError(fun(receiver.getStopToken));
    }
  } else {
    void setValue(Value value) {
      static if (is(ReturnType!Fun == void)) {
        fun(receiver.getStopToken, value);
        receiver.setValueOrError();
      } else
        receiver.setValueOrError(fun(receiver.getStopToken, value));
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

private struct Op(Receiver, Sender, Fun) {
  Sender sender;
  STReceiver!(Receiver, Sender.Value, Fun) receiver;
  void start() {
    sender.connect(receiver).start();
  }
}

private struct STSender(Sender, Fun) {
  static assert(models!(STSender, isSender));
  alias Value = ReturnType!fun;
  Sender sender;
  Fun fun;
  auto connect(Receiver)(Receiver receiver) {
    return Op!(Receiver, Sender, Fun)(sender, STReceiver!(Receiver, Sender.Value, Fun)(receiver, fun));
  }
}
