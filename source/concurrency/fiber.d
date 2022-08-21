module concurrency.fiber;

import concurrency.sender;
import concepts;
import core.thread.fiber;
import core.thread.fiber : Fiber;

alias Continuation = Object;

package(concurrency) abstract class BaseFiber : Fiber {
  private Continuation continuation;
  this(void delegate() dg, size_t sz, size_t guardPageSize) @trusted nothrow {
    super(dg, sz, guardPageSize);
  }
  static BaseFiber getThis() @trusted nothrow {
    import core.thread.fiber : Fiber;
    return cast(BaseFiber)Fiber.getThis();
  }
}

class OpFiber(Op) : BaseFiber {
  import core.memory : pageSize;

  private Op op;

  this(void delegate() shared @safe nothrow dg, size_t sz = pageSize * defaultStackPages, size_t guardPageSize = pageSize) @trusted nothrow {
    super(cast(void delegate())dg, sz, guardPageSize);
  }
}

struct FiberSender {
  static assert (models!(typeof(this), isSender));
  alias Value = void;
  auto connect(Receiver)(return Receiver receiver) @safe scope return {
    auto op = FiberSenderOp!(Receiver)(receiver);
    return op;
  }
}

struct FiberSenderOp(Receiver) {
  Receiver receiver;
  alias BaseSender = typeof(receiver.getScheduler().schedule());
  alias Op = OpType!(BaseSender, InnerFiberSchedulerReceiver!Receiver);
  void start() @trusted nothrow scope {
    auto fiber = new OpFiber!Op(cast(void delegate()shared nothrow @safe)&run);
    cycle(fiber, true);
  }
  private void schedule(OpFiber!Op fiber) @trusted nothrow {
    // TODO: why can't we store the Op here?
    fiber.op = receiver.getScheduler.schedule().connect(InnerFiberSchedulerReceiver!Receiver(fiber, &cycle, receiver));
    fiber.op.start();
  }
  private void cycle(BaseFiber f, bool inline_) @trusted nothrow {
    auto fiber = cast(OpFiber!Op)f;
    if (!inline_)
      return schedule(fiber);
    if (auto throwable = fiber.call!(Fiber.Rethrow.no)) {
      receiver.setError(throwable);
      return;
    }
    if (fiber.continuation !is null) {
      auto sender = cast(SenderObjectBase!void)fiber.continuation;
      fiber.continuation = null;
      try {
        auto op = sender.connectHeap(InnerFiberSchedulerReceiver!Receiver(fiber, &cycle, receiver));
        op.start();
      } catch (Throwable t) {
        receiver.setError(t);
        return;
      }
    } else if (fiber.state == Fiber.State.HOLD) {
      schedule(fiber);
    } else {
      // reuse it?
    }
  }
  private void run() nothrow @trusted {
    import concurrency.receiver : setValueOrError;
    import concurrency.error : clone;
    import concurrency : parentStopSource;

    parentStopSource = receiver.getStopToken().source;

    try {
      receiver.setValue();
    } catch (Exception e) {
      receiver.setError(e);
    } catch (Throwable t) {
      receiver.setError(t.clone());
    }

    parentStopSource = null;
  }
}

struct InnerFiberSchedulerReceiver(Receiver) {
  import concurrency.receiver : ForwardExtensionPoints;
  BaseFiber fiber;
  void delegate(BaseFiber, bool) nothrow @trusted cycle;
  Receiver receiver;
  void setDone() nothrow @safe {
    cycle(fiber, true);
  }
  void setError(Throwable e) nothrow @safe {
    cycle(fiber, true);
  }
  void setValue() nothrow @safe {
    cycle(fiber, true);
  }
  mixin ForwardExtensionPoints!receiver;
}

void yield() @trusted {
  import std.concurrency;
  std.concurrency.yield();
}

auto yield(Sender)(Sender sender) @trusted {
  import concurrency : Result;
  import concurrency.operations : onResult;
  import concurrency.sender : toSenderObject;

  auto fiber = BaseFiber.getThis();

  shared Result!(Sender.Value) local;
  fiber.continuation = cast(Object)sender.onResult((Result!(Sender.Value) r) @safe shared { local = r; }).toSenderObject;
  yield();

  static if (!is(Sender.Value == void))
    return local.value;
  else
    (cast()local).assumeOk;
}
