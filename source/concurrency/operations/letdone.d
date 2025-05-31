module concurrency.operations.letdone;

import concurrency.sender;
import concepts;
import concurrency.utils;

auto letDone(Sender, Fun)(Sender sender, Fun fun) {
   	import concurrency.utils;
	// static assert(isThreadSafeCallable!Fun);

    return LetDone!(Sender, Fun)(sender, fun);
}

struct LetDone(Sender, Fun) if (models!(Sender, isSender)) {
    import std.traits : ReturnType;
    alias FinalSender = ReturnType!(Fun);
    alias Value = FinalSender.Value;

    Sender sender;
    Fun fun;

    auto connect(Receiver)(return Receiver receiver) @safe return scope {
        // ensure NRVO
        auto op = LetDoneOp!(Sender, Fun, Receiver)(sender, fun, receiver);
        return op;
    }
}

struct LetDoneOp(Sender, Fun, Receiver) {
    import std.traits : ReturnType;
    import concurrency.sender : OpType;

    alias OpA = OpType!(Sender, LetDoneReceiver!(Sender.Value, Receiver));
    alias FinalSender = ReturnType!(Fun);
    alias OpB = OpType!(FinalSender, Receiver);

    static assert(is(Sender.Value == FinalSender.Value), "Both value types must be the same.");

    Fun fun;
    
    // LetDoneOp essentially has 2 states:
    // 1) executing the input Sender
    // 2) executing the Sender returned by Fun.
    //
    // The Senders each have an OperationalState, but only
    // one is used at a time.
    // Therefore we can put them inside a union and use a
    // discriminator to tell which is active. It is important
    // to manually destroy the correct OperationalState when this
    // object itself goes out of scope.
    //
    // To avoid storing yet another member we use the `fun` as
    // a discriminator. If it is `null` it means we are executing the
    // second Sender.
    // union {
        OpA opA;
        OpB opB;
    // }

    @disable
    this(ref return scope typeof(this) rhs);
    @disable
    this(this);


	@disable void opAssign(typeof(this) rhs) nothrow @safe @nogc;
	@disable void opAssign(ref typeof(this) rhs) nothrow @safe @nogc;

    this(return Sender sender, Fun fun, return Receiver receiver) @trusted return scope {
        this.fun = fun;
        opA = sender.connect(LetDoneReceiver!(Sender.Value, Receiver)(receiver, &next));
    }

    void start() @trusted nothrow scope {
        opA.start();
    }

    void next(Receiver receiver) @trusted nothrow {
        import concurrency.sender : emplaceOperationalState;
        try {
            auto sender = nextSender();
            opB.emplaceOperationalState(sender, receiver);
        } catch (Exception e) {
            receiver.setError(e);
            return;
        }
        opB.start();
    }
    private auto nextSender() @trusted {
        auto localFun = fun;
        fun = null;
        return localFun();
    }
}

struct LetDoneReceiver(Value, Receiver) {
    Receiver receiver;
    void delegate(Receiver) @trusted nothrow next;

    static if (is(Value == void)) {
        void setValue() @safe {
            receiver.setValue();
        }
    } else {
        void setValue(Value value) @safe {
            receiver.setValue(value.copyOrMove);
        }
    }

    void setDone() @safe nothrow {
        next(receiver);
    }

    void setError(Throwable e) @safe nothrow {
        receiver.setError(e);
    }

    import concurrency.receiver;
    mixin ForwardExtensionPoints!receiver;
}
