module concurrency.stream.tolist;

import concurrency.stream.stream;
import concurrency.sender : OpType;
import concepts;

/// toList collects all the stream's values and emits the array as a Sender
auto toList(Stream)(Stream stream) if (models!(Stream, isStream)) {
  alias Properties = StreamProperties!Stream;
  static assert(is(Properties.Value == void), "sender must produce void for toList to work");
  return ToListSender!Stream(stream);
}

struct ToListSender(Stream) {
  alias Properties = StreamProperties!Stream;
  alias Value = Properties.ElementType[];
  Stream stream;
  auto connect(Receiver)(return Receiver receiver) @safe return scope {
    // ensure NRVO
    auto op = ToListOp!(Stream, Receiver)(stream, receiver);
    return op;
  }
}

struct ToListOp(Stream, Receiver) {
  alias Properties = StreamProperties!Stream;
  alias State = ToListState!(Receiver, Properties.ElementType);
  State state;
  alias Op = OpType!(Properties.Sender, ToListReceiver!(State));
  Op op;
  @disable this(this);
  @disable this(ref return scope typeof(this) rhs);
  this(Stream stream, return Receiver receiver) @trusted return scope {
    state.receiver = receiver;
    op = stream.collect(cast(Properties.DG)&item).connect(ToListReceiver!(State)(&state));
  }
  void item(Properties.ElementType t) {
    state.arr ~= t;
  }
  void start() nothrow @safe {
    op.start();
  }
}

struct ToListState(Receiver, ElementType) {
  Receiver receiver;
  ElementType[] arr;
}

struct ToListReceiver(State) {
  State* state;
  void setValue() @safe {
    state.receiver.setValue(state.arr);
  }
  void setDone() @safe nothrow {
    state.receiver.setDone();
  }
  void setError(Throwable t) nothrow @safe {
    state.receiver.setError(t);
  }
  auto getStopToken() nothrow @safe {
    return state.receiver.getStopToken();
  }
  auto getScheduler() nothrow @safe {
    return state.receiver.getScheduler();
  }
}
