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
  @disable this(this);
  @disable this(ref return scope typeof(this) rhs);
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
    import std.stdio;
    debug writeln("enter fiber, ", cast(void*)fiber.continuation);
    if (auto throwable = fiber.call!(Fiber.Rethrow.no)) {
      debug writeln("fiber threw ", throwable);
      receiver.setError(throwable);
      return;
    }
    debug writeln("exit fiber");
    if (fiber.continuation !is null) {
      auto sender = cast(SenderObjectBase!void)fiber.continuation;
      fiber.continuation = null;
      try {
        auto op = sender.connectHeap(InnerFiberSchedulerReceiver!Receiver(fiber, &cycle, receiver));
        debug writeln("starting yielded sender");
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
    import concurrency : parentStopSource, CancelledException;

    parentStopSource = receiver.getStopToken().source;

    import std.stdio;
    try {
      debug writeln("FiberSender.run");
      receiver.setValue();
    } catch (CancelledException e) {
      debug writeln("FiberSender.run.cancelled");
      receiver.setDone();
    } catch (Exception e) {
      debug writeln("FiberSender.run.exception");
      receiver.setError(e);
    } catch (Throwable t) {
      debug writeln("FiberSender.run.throwable");
      receiver.setError(t.clone());
    }

    parentStopSource = null;
  }
}

struct InnerFiberSchedulerReceiver(Receiver) {
  import concurrency.receiver : ForwardExtensionPoints;
  import std.stdio;
  BaseFiber fiber;
  void delegate(BaseFiber, bool) nothrow @trusted cycle;
  Receiver receiver;
  void setDone() nothrow @safe {
    debug writeln("InnerFiberSchedulerReceiver.setDone");
    cycle(fiber, true);
  }
  void setError(Throwable e) nothrow @safe {
    debug writeln("InnerFiberSchedulerReceiver.setError");
    cycle(fiber, true);
  }
  void setValue() nothrow @safe {
    debug writeln("InnerFiberSchedulerReceiver.setValue");
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
  import std.stdio;

  auto fiber = BaseFiber.getThis();

  shared Result!(Sender.Value) local;
  debug writeln("Setup sender continuation");
  fiber.continuation = cast(Object)sender.onResult((Result!(Sender.Value) r) @safe shared { local = r; }).toSenderObject;
  debug writeln("Yield");
  yield();
  debug writeln("Resume");

  return cast()local;
}
