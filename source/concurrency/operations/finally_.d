module concurrency.operations.finally_;

import concurrency;
import concurrency.receiver;
import concurrency.sender;
import concurrency.stoptoken;
import concepts;
import std.traits;

auto finally_(Sender, Result)(Sender sender, Result result) {
    import std.traits : isCallable;
    return FinallySender!(Sender, Result)(sender, result);
}

private struct FinallyReceiver(Value, Result, Receiver) {
  Receiver receiver;
  Result result;
  private auto getResult() {
    static if (isCallable!Result)
      return result();
    else return result;
  }
  static if (is(Value == void))
    void setValue() @safe {
      receiver.setValue(getResult());
    }
  else
    void setValue(Value value) @safe {
      receiver.setValue(getResult());
    }
  void setDone() @safe nothrow {
    receiver.setDone();
  }
  void setError(Exception e) @safe nothrow {
    receiver.setValue(getResult());
  }
  mixin ForwardExtensionPoints!receiver;
}

struct FinallySender(Sender, Result) if (models!(Sender, isSender)) {
  static assert (models!(typeof(this), isSender));
  static if (isCallable!Result)
    alias Value = typeof(result());
  else
    alias Value = Result;
  Sender sender;
  Result result;
  auto connect(Receiver)(Receiver receiver) @safe {
    // ensure NRVO
    auto op = sender.connect(FinallyReceiver!(Sender.Value, Result, Receiver)(receiver, result));
    return op;
  }
}

