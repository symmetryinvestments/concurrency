module concurrency.operations.then;

import concurrency;
import concurrency.receiver;
import concurrency.sender;
import concurrency.stoptoken;
import concepts;

auto then(Sender, Fun)(Sender sender, Fun fun) {
  import std.traits : hasFunctionAttributes, isFunction, isFunctionPointer;
  static assert (isFunction!Fun || isFunctionPointer!Fun || hasFunctionAttributes!(Fun, "shared"), "Function must be shared");

  return ThenSender!(Sender, Fun)(sender, fun);
}

private struct ThenReceiver(Receiver, Value, Fun) {
  import std.traits : ReturnType;
  Receiver receiver;
  Fun fun;
  static if (is(Value == void)) {
    void setValue() @safe {
      static if (is(ReturnType!Fun == void)) {
        fun();
        receiver.setValue();
      } else
        receiver.setValue(fun());
    }
  } else {
    import std.typecons : isTuple;
    enum isExpandable = isTuple!Value && __traits(compiles, {fun(Value.init.expand);});
    void setValue(Value value) @safe {
      static if (is(ReturnType!Fun == void)) {
        static if (isExpandable)
          fun(value.expand);
        else
          fun(value);
        receiver.setValue();
      } else {
        static if (isExpandable)
          auto r = fun(value.expand);
        else
          auto r = fun(value);
        receiver.setValue(r);
      }
    }
  }
  void setDone() @safe nothrow {
    receiver.setDone();
  }
  void setError(Exception e) @safe nothrow {
    receiver.setError(e);
  }
  mixin ForwardExtensionPoints!receiver;
}

struct ThenSender(Sender, Fun) if (models!(Sender, isSender)) {
  import std.traits : ReturnType;
  static assert(models!(typeof(this), isSender));
  alias Value = ReturnType!fun;
  Sender sender;
  Fun fun;
  auto connect(Receiver)(return Receiver receiver) @safe scope return {
    alias R = ThenReceiver!(Receiver, Sender.Value, Fun);
    // ensure NRVO
    auto op = sender.connect(R(receiver, fun));
    return op;
  }
}
