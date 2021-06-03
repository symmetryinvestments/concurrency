module concurrency.sender;

import concepts;
import std.traits : ReturnType;

// A Sender represents something that completes with either:
// 1. a value (which can be void)
// 2. completion, in response to cancellation
// 3. an Exception
//
// Many things can be represented as a Sender.
// Threads, Fibers, coroutines, etc. In general, any async operation.
//
// A Sender is lazy. Work it represents is only started when
// the sender is connected to a receiver and explicitly started.
//
// Senders and Receivers go hand in hand. Senders send a value,
// Receivers receive one.
//
// Senders are useful because many Tasks can be represented as them,
// and any operation on top of senders then works on any one of those
// Tasks.
//
// The most common operation is `sync_wait`. It blocks the current
// execution context to await the Sender.
//
// There are many others as well. Like `when_all`, `retry`, `when_any`,
// etc. These algorithms can be used on any sender.
//
// Cancellation happens through StopTokens. A Sender can ask a Receiver
// for a StopToken. Default is a NeverStopToken but Receiver's can
// customize this.
//
// The StopToken can be polled or a callback can be registered with one.
//
// Senders enforce Structured Concurrency because work cannot be
// started unless it is awaited.
//
// These concepts are heavily inspired by several C++ proposals
// starting with http://www.open-std.org/jtc1/sc22/wg21/docs/papers/2020/p0443r14.html

/// checks that T is a Sender
void checkSender(T)() @safe {
  T t = T.init;
  struct Receiver {
    static if (is(T.Value == void))
      void setValue() {}
    else
      void setValue(T.Value) {}
    void setDone() nothrow {}
    void setError(Exception e) nothrow {}
  }
  OpType!(T, Receiver) op = t.connect(Receiver.init);
}
enum isSender(T) = is(typeof(checkSender!T));

/// A Sender that sends a single value of type T
struct ValueSender(T) {
  static assert (models!(typeof(this), isSender));
  alias Value = T;
  static struct Op(Receiver) {
    Receiver receiver;
    static if (!is(T == void))
      T value;
    void start() @safe {
      import concurrency.receiver : setValueOrError;
      static if (!is(T == void))
        receiver.setValueOrError(value);
      else
        receiver.setValueOrError();
    }
  }
  static if (!is(T == void))
    T value;
  Op!Receiver connect(Receiver)(Receiver receiver) {
    static if (!is(T == void))
      return Op!(Receiver)(receiver, value);
    else
      return Op!(Receiver)(receiver);
  }
}

ValueSender!T just(T)(T t) {
  return ValueSender!T(t);
}

/// A polymorphic sender of type T
interface SenderObjectBase(T) {
  import concurrency.receiver;
  import concurrency.stoptoken;
  static assert (models!(typeof(this), isSender));
  alias Value = T;
  OperationObject connect(ReceiverObjectBase!(T) receiver) @safe;
  OperationObject connect(Receiver)(Receiver receiver) @safe {
    return connect(new class(receiver) ReceiverObjectBase!T {
      Receiver receiver;
      this(Receiver receiver) {
        this.receiver = receiver;
      }
      static if (is(T == void)) {
        void setValue() {
          receiver.setValueOrError();
        }
      } else {
        void setValue(T value) {
          receiver.setValueOrError(value);
        }
      }
      void setDone() nothrow {
        receiver.setDone();
      }
      void setError(Exception e) nothrow {
        receiver.setError(e);
      }
      StopTokenObject getStopToken() nothrow {
        return stopTokenObject(receiver.getStopToken());
      }
    });
  }
}

/// Type-erased operational state object
/// used in polymorphic senders
struct OperationObject {
  private void delegate() nothrow shared _start;
  void start() nothrow @trusted { _start(); }
}

interface OperationalStateBase {
  void start() @safe nothrow;
}

/// calls connect on the Sender but stores the OperationState on the heap
OperationalStateBase connectHeap(Sender, Receiver)(Sender sender, Receiver receiver) {
  alias State = typeof(sender.connect(receiver));
  return new class(sender, receiver) OperationalStateBase {
    State state;
    this(Sender sender, Receiver receiver) {
      state = sender.connect(receiver);
    }
    void start() @safe nothrow {
      state.start();
    }
  };
}

/// A class extending from SenderObjectBase that wraps any Sender
class SenderObjectImpl(Sender) : SenderObjectBase!(Sender.Value) {
  import concurrency.receiver : ReceiverObjectBase;
  static assert (models!(typeof(this), isSender));
  private Sender sender;
  this(Sender sender) {
    this.sender = sender;
  }
  OperationObject connect(ReceiverObjectBase!(Sender.Value) receiver) @trusted {
    auto state = sender.connectHeap(receiver);
    return OperationObject(cast(typeof(OperationObject._start))&state.start);
  }
  auto connect(Receiver)(Receiver receiver) {
    return sender.connect(receiver);
  }
}

/// Converts any Sender to a polymorphic SenderObject
auto toSenderObject(Sender)(Sender sender) {
  static assert(models!(Sender, isSender));
  static if (is(Sender : SenderObjectBase!(Sender.Value))) {
    return sender;
  } else
    return cast(SenderObjectBase!(Sender.Value))new SenderObjectImpl!(Sender)(sender);
}

/// A sender that always sets an error
struct ThrowingSender {
  alias Value = void;
  static struct Op(Receiver) {
    Receiver receiver;
    void start() {
      receiver.setError(new Exception("ThrowingSender"));
    }
  }
  auto connect(Receiver)(Receiver receiver) {
    return Op!Receiver(receiver);
  }
}

/// This tests whether a Sender, by itself, makes any calls to the
/// setError function.
/// If a Sender is connected to a Receiver that has a non-nothrow
/// setValue function, a Sender can still throw, but only Exceptions
/// throw from that Receiver's setValue function.
template canSenderThrow(Sender) {
  static assert (models!(Sender, isSender));
  struct NoErrorReceiver {
    void setDone() nothrow @safe @nogc {}
    static if (is(Sender.Value == void))
      void setValue() nothrow @safe @nogc {}
    else
      void setValue(Sender.Value t) nothrow @safe @nogc {}
  }
  enum canSenderThrow = !__traits(compiles, Sender.init.connect(NoErrorReceiver()));
}

static assert( canSenderThrow!ThrowingSender);
static assert(!canSenderThrow!(ValueSender!int));

/// A sender that always calls setDone
struct DoneSender {
  static assert (models!(typeof(this), isSender));
  alias Value = void;
  static struct DoneOp(Receiver) {
    Receiver receiver;
    void start() {
      receiver.setDone();
    }
  }
  auto connect(Receiver)(Receiver receiver) {
    return DoneOp!(Receiver)(receiver);
  }
}

/// A sender that always calls setValue with no args
struct VoidSender {
  static assert (models!(typeof(this), isSender));
  alias Value = void;
  struct VoidOp(Receiver) {
    Receiver receiver;
    void start() nothrow @safe {
      import concurrency.receiver : setValueOrError;
      receiver.setValueOrError();
    }
  }
  auto connect(Receiver)(Receiver receiver) {
    return VoidOp!Receiver(receiver);
  }
}

template OpType(Sender, Receiver) {
  import std.traits : ReturnType;
  import std.meta : staticMap;
  template GetOpType(alias connect) {
    static if (__traits(isTemplate, connect)) {
      alias GetOpType = ReturnType!(connect!Receiver);
    } else {
      alias GetOpType = ReturnType!(Sender.init.connect(Receiver.init));
    }
  }
  alias overloads = __traits(getOverloads, Sender, "connect", true);
  alias opTypes = staticMap!(GetOpType, overloads);
  alias OpType = opTypes[0];
}
