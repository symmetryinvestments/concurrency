module concurrency.operations.withstoptoken;

import concurrency;
import concurrency.receiver;
import concurrency.sender;
import concurrency.stoptoken;
import concepts;
import std.traits;
import concurrency.utils : isThreadSafeFunction;

deprecated("function passed is not shared @safe delegate or @safe function.")
auto withStopToken(Sender, Fun)(Sender sender, Fun fun) if (!isThreadSafeFunction!Fun) {
  return STSender!(Sender, Fun)(sender, fun);
 }

auto withStopToken(Sender, Fun)(Sender sender, Fun fun) if (isThreadSafeFunction!Fun) {
  return STSender!(Sender, Fun)(sender, fun);
}

private struct STReceiver(Receiver, Value, Fun) {
  Receiver receiver;
  Fun fun;
  this(return scope Receiver receiver, return Fun fun) @safe return scope {
    this.receiver = receiver;
    this.fun = fun;
  }
  static if (is(Value == void)) {
    void setValue() @safe {
      static if (is(ReturnType!Fun == void)) {
        fun(receiver.getStopToken);
        if (receiver.getStopToken.isStopRequested)
          receiver.setDone();
        else
          receiver.setValueOrError();
      } else
        receiver.setValueOrError(fun(receiver.getStopToken));
    }
  } else {
    import std.typecons : isTuple;
    enum isExpandable = isTuple!Value && __traits(compiles, {fun(StopToken.init, Value.init.expand);});
    void setValue(Value value) @safe {
      static if (is(ReturnType!Fun == void)) {
        static if (isExpandable)
          fun(receiver.getStopToken, value.expand);
        else
          fun(receiver.getStopToken, value);
        if (receiver.getStopToken.isStopRequested)
          receiver.setDone();
        else
          receiver.setValueOrError();
      } else {
        static if (isExpandable)
          auto r = fun(receiver.getStopToken, value.expand);
        else
          auto r = fun(receiver.getStopToken, value);
        receiver.setValueOrError(r);
      }
    }
  }
  void setDone() nothrow @safe {
    receiver.setDone();
  }
  void setError(Throwable e) nothrow @safe {
    receiver.setError(e);
  }
  mixin ForwardExtensionPoints!receiver;
}

struct STSender(Sender, Fun) if (models!(Sender, isSender)) {
  static assert(models!(typeof(this), isSender));
  alias Value = ReturnType!fun;
  Sender sender;
  Fun fun;
  auto connect(Receiver)(return Receiver receiver) @safe return scope {
    alias R = STReceiver!(Receiver, Sender.Value, Fun);
    // ensure NRVO
    auto op = sender.connect(R(receiver, fun));
    return op;
  }
}
