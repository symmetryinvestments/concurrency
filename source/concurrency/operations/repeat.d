module concurrency.operations.repeat;

import concurrency;
import concurrency.receiver;
import concurrency.sender;
import concurrency.stoptoken;
import concepts;
import std.traits;

auto repeat(Sender)(Sender sender) {
  static assert(is(Sender.Value : void), "Can only repeat effectful Senders.");
  return RepeatSender!(Sender)(sender);
}

private struct RepeatReceiver(Receiver) {
  private Receiver receiver;
  private void delegate() @safe nothrow scope reset;
  void setValue() @safe {
    reset();
  }
  void setDone() @safe nothrow {
    receiver.setDone();
  }
  void setError(Throwable e) @safe nothrow {
    receiver.setError(e);
  }
  mixin ForwardExtensionPoints!receiver;
}

private struct RepeatOp(Receiver, Sender) {
  alias Op = OpType!(Sender, RepeatReceiver!(Receiver));
  Sender sender;
  Receiver receiver;
  Op op;
  @disable this(ref return scope typeof(this) rhs);
  @disable this(this);
  this(Sender sender, Receiver receiver) @trusted scope {
    this.sender = sender;
    this.receiver = receiver;
  }
  void start() @trusted nothrow scope {
    op = sender.connect(RepeatReceiver!(Receiver)(receiver, &start));
    op.start();
  }
}

struct RepeatSender(Sender) if (models!(Sender, isSender)) {
  static assert(models!(typeof(this), isSender));
  alias Value = Sender.Value;
  Sender sender;
  auto connect(Receiver)(return Receiver receiver) @safe scope return {
    // ensure NRVO
    auto op = RepeatOp!(Receiver, Sender)(sender, receiver);
    return op;
  }
}
