module concurrency.operations.retrywhen;

import concurrency;
import concurrency.operations.via;
import concurrency.receiver;
import concurrency.sender;
import concurrency.stoptoken;
import concepts;
import std.traits;

enum isRetryWhenLogic(T) = models!(typeof(T.init.failure(Exception.init)), isSender);

auto retryWhen(Sender, Logic)(Sender sender, Logic logic) if (isRetryWhenLogic!Logic) {
  return RetryWhenSender!(Sender, Logic)(sender, logic);
}

private struct TriggerReceiver(Sender, Receiver, Logic) {
  alias Value = void;
  private RetryWhenOp!(Sender, Receiver, Logic)* op;
  void setValue() @safe {
    op.sourceOp = op.sender.connect(SourceReceiver!(Sender, Receiver, Logic)(op));
    op.sourceOp.start();
  }
  void setDone() @safe nothrow {
    op.receiver.setDone();
  }
  void setError(Throwable t) @safe nothrow {
    op.receiver.setError(t);
  }
  private auto receiver() {
    return op.receiver;
  }
  mixin ForwardExtensionPoints!(receiver);
}

private struct SourceReceiver(Sender, Receiver, Logic) {
  alias Value = Sender.Value;
  private RetryWhenOp!(Sender, Receiver, Logic)* op;
  static if (is(Value == void)) {
    void setValue() @safe {
      op.receiver.setValueOrError();
    }
  } else {
    void setValue(Value value) @safe {
      op.receiver.setValueOrError(value);
    }
  }
  void setDone() @safe nothrow {
    op.receiver.setDone();
  }
  void setError(Throwable t) @trusted nothrow {
    if (auto ex = cast(Exception) t) {
      try {
        op.triggerOp = op.logic.failure(ex).connect(TriggerReceiver!(Sender, Receiver, Logic)(op));
        op.triggerOp.start();
      } catch (Throwable t2) {
        op.receiver.setError(t2);
      }
      return;
    }
    op.receiver.setError(t);
  }
  private auto receiver() {
    return op.receiver;
  }
  mixin ForwardExtensionPoints!(receiver);
}

private struct RetryWhenOp(Sender, Receiver, Logic) {
  import std.traits : ReturnType;
  alias SourceOp = OpType!(Sender, SourceReceiver!(Sender, Receiver, Logic));
  alias TriggerOp = OpType!(ReturnType!(Logic.failure), TriggerReceiver!(Sender, Receiver, Logic));
  Sender sender;
  Receiver receiver;
  Logic logic;
  // TODO: this could probably be a Variant to safe some space
  SourceOp sourceOp;
  TriggerOp triggerOp;
  @disable this(ref return scope typeof(this) rhs);
  @disable this(this);
  this(return Sender sender, Receiver receiver, Logic logic) @trusted scope {
    this.sender = sender;
    this.receiver = receiver;
    this.logic = logic;
    sourceOp = this.sender.connect(SourceReceiver!(Sender, Receiver, Logic)(&this));
  }
  void start() @trusted nothrow scope {
    sourceOp.start();
  }
}

struct RetryWhenSender(Sender, Logic) if (isRetryWhenLogic!Logic) {
  static assert(models!(typeof(this), isSender));
  alias Value = Sender.Value;
  Sender sender;
  Logic logic;
  auto connect(Receiver)(return Receiver receiver) @safe return scope {
    // ensure NRVO
    auto op = RetryWhenOp!(Sender, Receiver, Logic)(sender, receiver, logic);
    return op;
  }
}
