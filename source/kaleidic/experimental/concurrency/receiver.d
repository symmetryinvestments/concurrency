module kaleidic.experimental.concurrency.receiver;

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
  import kaleidic.experimental.concurrency.stoptoken : NeverStopToken;
  return NeverStopToken();
}

struct NullReceiver(T) {
  void setDone() nothrow @safe @nogc {}
  void setError(Exception) nothrow @safe @nogc {}
  static if (is(T == void))
    void setValue() nothrow @safe @nogc {}
  else
    void setValue(T t) nothrow @safe @nogc {}
}

struct ThrowingNullReceiver(T) {
  void setDone() nothrow @safe @nogc {}
  void setError(Exception) nothrow @safe @nogc {}
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
