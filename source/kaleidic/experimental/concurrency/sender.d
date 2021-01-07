module kaleidic.experimental.concurrency.sender;

import concepts;

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
void checkSender(T)() {
  T t = T.init;
  static if (is(T.Value == void)) {
    struct Receiver {
      void setValue() {};
      void setDone() nothrow {};
      void setError(Exception) nothrow {};
    }
    t.connect(Receiver.init);
  } else {
    struct Receiver {
      void setValue(T.Value) {};
      void setDone() nothrow {};
      void setError(Exception) nothrow {};
    }
    t.connect(Receiver.init);
  }
}
enum isSender(T) = is(typeof(checkSender!T));

/// A Sender that sends a single value of type T
struct ValueSender(T) {
  static assert (models!(ValueSender!T, isSender));
  alias Value = T;
  static struct Op(Receiver) {
    Receiver receiver;
    T t;
    void start() {
      import kaleidic.experimental.concurrency.receiver : setValueOrError;
      receiver.setValueOrError(t);
    }
  }
  T t;
  Op!Receiver connect(Receiver)(Receiver r) {
    return Op!(Receiver)(r, t);
  }
}

/// A polymorphic sender of type T
interface SenderObjectBase(T) {
  static assert (models!(SenderObjectBase!T, isSender));
  alias Value = T;
  OperationObject connect(ReceiverObjectBase!(T) receiver);
}

/// A polymorphic receiver of type T
interface ReceiverObjectBase(T) {
  static assert (models!(ReceiverObjectBase!T, isReceiver));
  void setValue(T value = T.init);
  void setDone() nothrow;
  void setError(Exception) nothrow;
  StopTokenObject getStopToken() nothrow;
}

/// Type-erased operational state object
/// used in polymorphic senders
struct OperationObject {
  private void delegate() _start;
  void start() @trusted { _start(); }
}

/// Wraps a generic operation into an OperationObject
/// for polymorphic senders/receivers
OperationObject wrapOperation(alias fun, Args...)(Args args) {
  return OperationObject(closure(fun, args));
}

/// A class extending from SenderObjectBase that wraps any Sender
class SenderObjectImpl(Sender) : SenderObjectBase!(Sender.Value) {
  private Sender sender;
  this(Sender sender) {
    this.sender = sender;
  }
  OperationObject connect(ReceiverObjectBase!(Sender.Value) receiver) {
    auto state = sender.connect(receiver);
    return wrapOperation!(state => state.start(), state);
  }
  auto connect(Receiver)(Receiver receiver) {
    return sender.connect(receiver);
  }
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
