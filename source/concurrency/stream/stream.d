module concurrency.stream.stream;

import concurrency.stoptoken;
import concurrency.receiver;
import concurrency.sender : isSender, OpType;
import concepts;
import std.traits : hasFunctionAttributes;

/// A Stream is anything that has a `.collect` function that accepts a callable and returns a Sender.
/// Once the Sender is connected and started the Stream will call the callable zero or more times before one of the three terminal functions of the Receiver is called.

template CollectDelegate(ElementType) {
  static if (is(ElementType == void)) {
    alias CollectDelegate = void delegate() @safe shared;
  } else {
    alias CollectDelegate = void delegate(ElementType) @safe shared;
  }
}

/// checks that T is a Stream
void checkStream(T)() {
  import std.traits : ReturnType;
  alias DG = CollectDelegate!(T.ElementType);
  static if (is(typeof(T.collect!DG)))
    alias Sender = ReturnType!(T.collect!(DG));
  else
    alias Sender = ReturnType!(T.collect);
  static assert (models!(Sender, isSender));
}
enum isStream(T) = is(typeof(checkStream!T));

/// A polymorphic stream with elements of type T
interface StreamObjectBase(T) {
  import concurrency.sender : SenderObjectBase;
  alias ElementType = T;
  static assert (models!(typeof(this), isStream));
  alias DG = CollectDelegate!(ElementType);

  SenderObjectBase!void collect(DG dg) @safe;
}

/// A class extending from StreamObjectBase that wraps any Stream
class StreamObjectImpl(Stream) : StreamObjectBase!(Stream.ElementType) if (models!(Stream, isStream)) {
  import concurrency.receiver : ReceiverObjectBase;
  static assert (models!(typeof(this), isStream));
  private Stream stream;
  this(Stream stream) {
    this.stream = stream;
  }
  alias DG = CollectDelegate!(Stream.ElementType);

  SenderObjectBase!void collect(DG dg) @safe {
    import concurrency.sender : toSenderObject;
    return stream.collect(dg).toSenderObject();
  }
}

/// Converts any Stream to a polymorphic StreamObject
StreamObjectBase!(Stream.ElementType) toStreamObject(Stream)(Stream stream) if (models!(Stream, isStream)) {
  return new StreamObjectImpl!(Stream)(stream);
}

template StreamProperties(Stream) {
  import std.traits : ReturnType;
  alias ElementType = Stream.ElementType;
  alias DG = CollectDelegate!(ElementType);
  alias Sender = ReturnType!(Stream.collect);
  alias Value = Sender.Value;
}

auto fromStreamOp(StreamElementType, SenderValue, alias Op, Args...)(Args args) {
  alias DG = CollectDelegate!(StreamElementType);
  static struct FromStreamSender {
    alias Value = SenderValue;
    Args args;
    DG dg;
    auto connect(Receiver)(return Receiver receiver) @safe scope return {
      // ensure NRVO
      auto op = Op!(Receiver)(args, dg, receiver);
      return op;
    }
  }
  static struct FromStream {
    static assert(models!(typeof(this), isStream));
    alias ElementType = StreamElementType;
    Args args;
    auto collect(DG dg) @safe {
      return FromStreamSender(args, dg);
    }
  }
  return FromStream(args);
}

template SchedulerType(Receiver) {
  import std.traits : ReturnType;
  alias SchedulerType = ReturnType!(Receiver.getScheduler);
}
