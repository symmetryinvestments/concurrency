module kaleidic.experimental.concurrency.operations;

import kaleidic.experimental.concurrency;
import kaleidic.experimental.concurrency.receiver;

auto then(Sender, Fun)(Sender sender, Fun fun) {
  import std.traits;
  static assert (hasFunctionAttributes!(Fun, "shared"), "Function must be shared");

  static struct ThenReceiver(Receiver) {
    Receiver receiver;
    Fun fun;
    static if (is(Sender.Value == void)) {
      void setValue() {
        static if (is(ReturnType!Fun == void)) {
          fun();
          receiver.setValue();
        } else
          receiver.setValue(fun());
      }
    } else {
      void setValue(Sender.Value value) {
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
  static struct Op(Receiver) {
    Sender sender;
    ThenReceiver!Receiver receiver;
    void start() {
      sender.connect(receiver).start();
    }
  }
  static struct ThenSender {
    import std.traits : ReturnType;
    alias Value = ReturnType!fun;
    Sender sender;
    Fun fun;
    auto connect(Receiver)(Receiver receiver) {
      return Op!Receiver(sender, ThenReceiver!Receiver(receiver, fun));
    }
  }
  return ThenSender(sender, fun);
}
