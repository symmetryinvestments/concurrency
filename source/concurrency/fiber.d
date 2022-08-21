module concurrency.fiber;

import concurrency.sender;
import concepts;
import core.thread.fiber;
import core.thread.fiber : Fiber;

class CancelledException : Exception {
	this(string file = __FILE__, size_t line = __LINE__, Throwable next = null) @nogc @safe pure nothrow {
		super("Cancelled", file, line, next);
	}
}

package(concurrency) class BaseFiber : Fiber {
	import concurrency.receiver : ReceiverObjectBase;
    import core.memory : pageSize;

    private ReceiverObjectBase!void erasedReceiver;
    private void delegate() @safe nothrow startSender;
    private Throwable nextError;

    this(void delegate() shared @safe nothrow dg, size_t sz = pageSize * defaultStackPages, size_t guardPageSize = pageSize) @trusted nothrow {
        super(cast(void delegate())dg, sz, guardPageSize);
    }
    static BaseFiber getThis() @trusted nothrow {
        import core.thread.fiber : Fiber;
        return cast(BaseFiber)Fiber.getThis();
    }
}

auto fiber(Fun)(Fun fun) {
    import concurrency.operations : then;
    return FiberSender().then(fun);
}

struct FiberSender {
    static assert (models!(typeof(this), isSender));
    alias Value = void;
    auto connect(Receiver)(return Receiver receiver) @safe return scope {
        auto op = FiberSenderOp!(Receiver)(receiver);
        return op;
    }
}

struct FiberSenderOp(Receiver) {
	import concurrency.receiver : ReceiverObjectBase;

    Receiver receiver;
    alias BaseSender = typeof(receiver.getScheduler().schedule());
    alias Op = OpType!(BaseSender, FiberContinuationReceiver!Receiver);

    @disable this(this);
    @disable this(ref return scope typeof(this) rhs);

	@disable void opAssign(typeof(this) rhs) nothrow @safe @nogc;
	@disable void opAssign(ref typeof(this) rhs) nothrow @safe @nogc;

    Op op;

    void start() @trusted nothrow scope {
        auto fiber = new BaseFiber(cast(void delegate()shared nothrow @safe)&run);
        fiber.erasedReceiver = FiberContinuationReceiver!Receiver(fiber, &cycle, receiver).toReceiverObject!void;
        cycle(fiber, true);
    }
    private void schedule(BaseFiber fiber) @trusted nothrow {
        import concurrency.sender : emplaceOperationalState;
        try {
            op.emplaceOperationalState(
                receiver.getScheduler.schedule(),
                FiberContinuationReceiver!Receiver(fiber, &cycle, receiver)
            );
            op.start();
        } catch (Exception e) {
            receiver.setError(e);
        }
    }
    private void cycle(BaseFiber fiber, bool inline_) @trusted nothrow {
        if (auto throwable = fiber.call!(Fiber.Rethrow.no)) {
            receiver.setError(throwable);
            return;
        }

        if (fiber.startSender !is null) {
            auto start = fiber.startSender;
            fiber.startSender = null;
            try {
                start();
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

        try {
            receiver.setValue();
        } catch (CancelledException e) {
            receiver.setDone();
        } catch (Exception e) {
            receiver.setError(e);
        } catch (Throwable t) {
            receiver.setError(t.clone());
        }
    }
}

// Receiver used to continue the Fiber after yielding on a Sender.
// TODO: this receiver could directly be a ReceiverObjectBase
struct FiberContinuationReceiver(Receiver) {
    import concurrency.receiver : ForwardExtensionPoints;
    BaseFiber fiber;
    void delegate(BaseFiber, bool) nothrow @trusted cycle;
    Receiver receiver;
    void setDone() nothrow @safe {
        cycle(fiber, true);
    }
    void setError(Throwable e) nothrow @safe {
        fiber.nextError = e;
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

auto yield(Sender)(return Sender sender) @trusted {
    import concurrency : Result;
    import concurrency.operations : onResult, then, ignoreValue;
    import concurrency.sender : toSenderObject;
    import concurrency.receiver : ReceiverObjectBase;

    auto fiber = BaseFiber.getThis();

    YieldResult!(Sender.Value) local;
    void store(Result!(Sender.Value) r) @trusted {
        local = YieldResult!(Sender.Value)(r);
    }

    auto base = sender
        .onResult(cast(void delegate(Result!(Sender.Value)) @safe shared)&store)
        .ignoreValue();

    alias Op = OpType!(typeof(base), ReceiverObjectBase!void);
    Op op = base.connect(fiber.erasedReceiver);
    fiber.startSender = &op.start;

    yield();


    // The last remaining allocations are around the SchedulerObject returning SenderObjectBase



    if (fiber.nextError) {
        auto error = fiber.nextError;
        fiber.nextError = null;
        throw error;
    }

    return local.value;
}

import core.attribute : mustuse;
struct YieldResult(T) {
    import concurrency.syncwait : Completed, Cancelled, Result, isA, match;
    import std.sumtype;

    static if (is(T == void)) {
        alias Value = Completed;
    } else {
        alias Value = T;
    }

	alias V = SumType!(Value, Exception);

    private V result;

    this(Result!(T) other) {
        static if (is(T == void))
            alias valueHandler = (Completed c) => V(c);
        else
            alias valueHandler = (T t) => V(t);
        
        result = other.match!(
            valueHandler,
            (Cancelled c) => V(new CancelledException()),
            (Exception e) => V(e),
        );
    }

    auto value() @trusted scope {
        static if (is(T == void))
            alias valueHandler = (Completed c) {};
        else
            alias valueHandler = (T t) => t;

        return std.sumtype.match!(valueHandler, function T(Exception e) @trusted {
            throw e;
        })(result);
    }
}
