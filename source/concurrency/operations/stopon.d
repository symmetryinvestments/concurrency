module concurrency.operations.stopon;

import concurrency;
import concurrency.receiver;
import concurrency.sender;
import concurrency.stoptoken;
import concepts;
import std.traits;

auto stopOn(Sender)(Sender sender, StopToken stopToken) {
  return StopOn!(Sender)(sender, stopToken);
}

private struct StopOnReceiver(Receiver, Value) {
  private {
    Receiver receiver;
    StopToken stopToken;
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
  void setError(Exception e) @safe nothrow {
    receiver.setError(e);
  }
  auto getStopToken() nothrow @trusted {
    return stopToken;
  }
  mixin ForwardExtensionPoints!receiver;
}

struct StopOn(Sender) if (models!(Sender, isSender)) {
  static assert(models!(typeof(this), isSender));
  alias Value = Sender.Value;
  Sender sender;
  StopToken stopToken;
  auto connect(Receiver)(return Receiver receiver) @safe scope return {
    alias R = StopOnReceiver!(Receiver, Sender.Value);
    // ensure NRVO
    auto op = sender.connect(R(receiver, stopToken));
    return op;
  }
}
