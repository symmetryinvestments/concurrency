module concurrency.operations.forwardon;

// whenever the underlying Sender completes the forwardon forwards the completion on a specific scheduler

import concurrency;
import concurrency.receiver;
import concurrency.sender;
import concurrency.stoptoken;
import concepts;

auto forwardOn(Sender, Scheduler)(Sender sender, Scheduler scheduler) {
  return ForwardOnSender!(Sender, Scheduler)(sender, scheduler);
}

private struct ForwardOnReceiver(Receiver, Value, Scheduler) {
  import concurrency.operations : via;
  Receiver receiver;
  Scheduler scheduler;
  static if (is(Value == void)) {
    void setValue() @safe {
      VoidSender().via(scheduler.schedule()).connectHeap(receiver).start();
    }
  } else {
    void setValue(Value value) @safe {
      just(value).via(scheduler.schedule()).connectHeap(receiver).start();
    }
  }
  void setDone() @safe nothrow {
    DoneSender().via(scheduler.schedule()).connectHeap(receiver).start();
  }
  void setError(Exception e) @safe nothrow {
    ErrorSender(e).via(scheduler.schedule()).connectHeap(receiver).start();
  }
  mixin ForwardExtensionPoints!receiver;
}

struct ForwardOnSender(Sender, Scheduler) if (models!(Sender, isSender)) {
  import std.traits : ReturnType;
  static assert(models!(typeof(this), isSender));
  alias Value = Sender.Value;
  Sender sender;
  Scheduler scheduler;
  auto connect(Receiver)(return Receiver receiver) @safe scope return {
    alias R = ForwardOnReceiver!(Receiver, Sender.Value, Scheduler);
    // ensure NRVO
    auto op = sender.connect(R(receiver, scheduler));
    return op;
  }
}
