module concurrency.operations.withstopsource;

import concurrency;
import concurrency.receiver;
import concurrency.sender;
import concurrency.stoptoken;
import concepts;
import std.traits;

template withStopSource(Sender) {
  auto withStopSource(Sender sender, StopSource stopSource) {
    return SSSender!(Sender)(sender, stopSource);
  }
  auto withStopSource(Sender sender, shared StopSource stopSource) @trusted {
    return SSSender!(Sender)(sender, cast()stopSource);
  }
}

private struct SSReceiver(Receiver, Value) {
  private {
    Receiver receiver;
    StopSource stopSource;
    StopSource combinedSource;
    StopCallback[2] cbs;
  }
  static if (is(Value == void)) {
    void setValue() @safe {
      resetStopCallback();
      receiver.setValueOrError();
    }
  } else {
    void setValue(Value value) @safe {
      resetStopCallback();
      receiver.setValueOrError(value);
    }
  }
  void setDone() @safe nothrow {
    resetStopCallback();
    receiver.setDone();
  }
  // TODO: would be good if we only emit this function in the Sender actually could call it
  void setError(Exception e) @safe nothrow {
    resetStopCallback();
    receiver.setError(e);
  }
  auto getStopToken() nothrow @trusted {
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

struct SSSender(Sender) if (models!(Sender, isSender)) {
  static assert(models!(typeof(this), isSender));
  alias Value = Sender.Value;
  Sender sender;
  StopSource stopSource;
  auto connect(Receiver)(Receiver receiver) @safe {
    alias R = SSReceiver!(Receiver, Sender.Value);
    return sender.connect(R(receiver, stopSource));
  }
}
