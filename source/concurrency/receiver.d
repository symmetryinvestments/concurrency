module concurrency.receiver;

import concepts;

/// checks that T is a Receiver
void checkReceiver(T)() {
  T t = T.init;
  import std.traits;
  alias Params = Parameters!(T.setValue);
  static if (Params.length == 0)
    t.setValue();
  else
    t.setValue(Params[0].init);
  (() nothrow => t.setDone())();
  (() nothrow => t.setError(new Exception("test")))();
}

enum isReceiver(T) = is(typeof(checkReceiver!T));

auto getStopToken(Receiver)(Receiver r) nothrow @safe if (isReceiver!Receiver) {
  import concurrency.stoptoken : NeverStopToken;
  return NeverStopToken();
}

mixin template ForwardExtensionPoints(alias receiver) {
  auto getStopToken() nothrow @safe {
    return receiver.getStopToken();
  }
}

/// A polymorphic receiver of type T
interface ReceiverObjectBase(T) {
  import concurrency.stoptoken : StopTokenObject;
  static assert (models!(ReceiverObjectBase!T, isReceiver));
  static if (is(T == void))
    void setValue() @safe;
  else
    void setValue(T value = T.init) @safe;
  void setDone() nothrow @safe;
  void setError(Exception e) nothrow @safe;
  StopTokenObject getStopToken() nothrow @safe;
}

struct NullReceiver(T) {
  void setDone() nothrow @safe @nogc {}
  void setError(Exception e) nothrow @safe @nogc {}
  static if (is(T == void))
    void setValue() nothrow @safe @nogc {}
  else
    void setValue(T t) nothrow @safe @nogc {}
}

struct ThrowingNullReceiver(T) {
  void setDone() nothrow @safe @nogc {}
  void setError(Exception e) nothrow @safe @nogc {}
  static if (is(T == void))
    void setValue() @safe { throw new Exception("ThrowingNullReceiver"); }
  else
    void setValue(T t) @safe { throw new Exception("ThrowingNullReceiver"); }
}

void setValueOrError(Receiver)(auto ref Receiver receiver) {
  import std.traits;
  static if (hasFunctionAttributes!(receiver.setValue, "nothrow")) {
    receiver.setValue();
  } else {
    try {
      receiver.setValue();
    } catch (Exception e) {
      receiver.setError(e);
    }
  }
}

void setValueOrError(Receiver, T)(auto ref Receiver receiver, auto ref T value) {
  import std.traits;
  static if (hasFunctionAttributes!(receiver.setValue, "nothrow")) {
    receiver.setValue(value);
  } else {
    try {
      receiver.setValue(value);
    } catch (Exception e) {
      receiver.setError(e);
    }
  }
}
