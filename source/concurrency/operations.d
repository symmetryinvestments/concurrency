module concurrency.operations;

import concurrency;
import concurrency.receiver;
import concurrency.sender;
import concurrency.stoptoken;
import concepts;
import std.traits;

auto then(Sender, Fun)(Sender sender, Fun fun) {
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
    import concurrency.sender;
    static assert(models!(ThenSender, isSender));
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
  static struct STReceiver(Receiver) {
    Receiver receiver;
    Fun fun;
    static if (is(Sender.Value == void)) {
      void setValue() {
        static if (is(ReturnType!Fun == void)) {
          fun(receiver.getStopToken);
          receiver.setValueOrError();
        } else
          receiver.setValueOrError(fun(receiver.getStopToken));
      }
    } else {
      void setValue(Sender.Value value) {
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
  static struct Op(Receiver) {
    Sender sender;
    STReceiver!Receiver receiver;
    void start() {
      sender.connect(receiver).start();
    }
  }
  static struct STSender {
    static assert(models!(STSender, isSender));
    alias Value = ReturnType!fun;
    Sender sender;
    Fun fun;
    auto connect(Receiver)(Receiver receiver) {
      return Op!Receiver(sender, STReceiver!Receiver(receiver, fun));
    }
  }
  return STSender(sender, fun);
}

auto withStopSource(Sender)(Sender sender, StopSource stopSource) {
  static struct SSReceiver(Receiver) {
    private {
      Receiver receiver;
      StopSource stopSource;
      StopSource combinedSource;
      StopCallback[2] cbs;
    }
    static if (is(Sender.Value == void)) {
      void setValue() {
        resetStopCallback();
        receiver.setValueOrError();
      }
    } else {
      void setValue(Sender.Value value) {
        resetStopCallback();
        receiver.setValueOrError(value);
      }
    }
    void setDone() nothrow {
      resetStopCallback();
      receiver.setDone();
    }
    // TODO: would be good if we only emit this function in the Sender actually could call it
    void setError(Exception e) nothrow {
      resetStopCallback();
      receiver.setError(e);
    }
    auto getStopToken() {
      import core.atomic;
      if (this.combinedSource is null) {
        auto local = new StopSource();
        auto sharedStopSource = cast(shared)local;
        StopSource emptyStopSource = null;
        if (cas(&this.combinedSource, emptyStopSource, local)) {
          cbs[0] = receiver.getStopToken().onStop(() shared => cast(void)sharedStopSource.stop());
          cbs[1] = StopToken(stopSource).onStop(() shared => cast(void)sharedStopSource.stop());
          if (atomicLoad(this.combinedSource) is null) {
            cbs[0].dispose();
            cbs[1].dispose();
          }
        } else {
          cbs[0].dispose();
          cbs[1].dispose();
        }
      }
      return StopToken(combinedSource);
    }
    private void resetStopCallback() {
      import core.atomic;
      if (atomicExchange(&this.combinedSource, cast(StopSource)null)) {
        if (cbs[0]) cbs[0].dispose();
        if (cbs[1]) cbs[1].dispose();
      }
    }
  }
  static struct Op(Receiver) {
    Sender sender;
    SSReceiver!Receiver receiver;
    void start() {
      sender.connect(receiver).start();
    }
  }
  static struct SSSender {
    static assert(models!(SSSender, isSender));
    alias Value = Sender.Value;
    Sender sender;
    StopSource stopSource;
    auto connect(Receiver)(Receiver receiver) {
      return Op!Receiver(sender, SSReceiver!Receiver(receiver, stopSource));
    }
  }
  return SSSender(sender, stopSource);
}

auto ignoreError(Sender)(Sender sender) {
  import concurrency.receiver : setValueOrError;
  struct IEReceiver(Value, Receiver) {
    Receiver receiver;
    static if (is(Value == void))
      void setValue() {
        receiver.setValueOrError();
      }
    else
      void setValue(Value value) {
        receiver.setValueOrError(value);
      }
    void setDone() {
      receiver.setDone();
    }
    void setError(Exception e) {
      receiver.setDone();
    }
    auto getStopToken() {
      return receiver.getStopToken();
    }
  }
  struct IESender {
    Sender sender;
    alias Value = Sender.Value;
    auto connect(Receiver)(Receiver receiver) {
      return sender.connect(IEReceiver!(Sender.Value,Receiver)(receiver));
    }
  }
  return IESender(sender);
}
