module concurrency.operations.ignoreerror;

import concurrency;
import concurrency.receiver;
import concurrency.sender;
import concurrency.stoptoken;
import concepts;
import std.traits;

IESender!Sender ignoreError(Sender)(Sender sender) {
  return IESender!Sender(sender);
}

private struct IESender(Sender) {
  static assert(models!(typeof(this), isSender));
  alias Value = Sender.Value;
  Sender sender;
  auto connect(Receiver)(Receiver receiver) {
    return sender.connect(IEReceiver!(Sender.Value,Receiver)(receiver));
  }
}

private struct IEReceiver(Value, Receiver) {
  import concurrency.receiver : setValueOrError;
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
  mixin ForwardExtensionPoints!receiver;
}
