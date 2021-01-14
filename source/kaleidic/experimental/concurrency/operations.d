module experimental.concurrency.operations;

import experimental.concurrency;
import experimental.concurrency.receiver;

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

auto withStopToken(Sender, Fun)(Sender sender, Fun fun) {
  import std.traits;
  static struct STReceiver(Receiver) {
    Receiver receiver;
    Fun fun;
    static if (is(Sender.Value == void)) {
      void setValue() {
        static if (is(ReturnType!Fun == void)) {
          fun(receiver.getStopToken);
          receiver.setValue();
        } else
          receiver.setValue(fun(receiver.getStopToken));
      }
    } else {
      void setValue(Sender.Value value) {
        static if (is(ReturnType!Fun == void)) {
          fun(receiver.getStopToken, value);
          receiver.setValue();
        } else
          receiver.setValue(fun(receiver.getStopToken, value));
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
    STReceiver!Receiver receiver;
    void start() {
      sender.connect(receiver).start();
    }
  }
  static struct STSender {
    import std.traits : ReturnType;
    alias Value = ReturnType!fun;
    Sender sender;
    Fun fun;
    auto connect(Receiver)(Receiver receiver) {
      return Op!Receiver(sender, STReceiver!Receiver(receiver, fun));
    }
  }
  return STSender(sender, fun);
}
