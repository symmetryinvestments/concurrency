module concurrency.operations.letvalue;

auto letValue(Sender, Fun)(Sender sender, Fun fun) {
   	import concurrency.utils;
	static assert(isThreadSafeCallable!Fun);

    return LetValue!(Sender, Fun)(sender, fun);
}

struct LetValue(Sender, Fun) {
    import std.traits : ReturnType;
    alias FinalSender = ReturnType!(Fun);
    alias Value = FinalSender.Value;

    Sender sender;
    Fun fun;

    auto connect(Receiver)(return Receiver receiver) @safe return scope {
        // ensure NRVO
        auto op = LetValueOp!(Sender, Fun, Receiver)(sender, fun, receiver);
        return op;
    }
}

struct LetValueOp(Sender, Fun, Receiver) {
    import std.traits : ReturnType;
    import concurrency.sender : OpType;

    alias OpA = OpType!(Sender, LetValueReceiver!(Sender.Value, Receiver));
    alias FinalSender = ReturnType!(Fun);
    alias OpB = OpType!(FinalSender, Receiver);

    Fun fun;
    
    // LetValueOp essentially has 2 states:
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
    union {
        OpA opA;
        OpB opB;
    }
    static if (!is(Sender.Value == void)) {
        Sender.Value value;
    }

    this(Sender sender, Fun fun, return Receiver receiver) @trusted scope {
        this.fun = fun;
        opA = sender.connect(LetValueReceiver!(Sender.Value, Receiver)(receiver, &next));
    }

    ~this() @trusted {
        if (fun is null)
            opB.destroy();
        else
            opA.destroy();
    }

    void start() @trusted nothrow scope {
        opA.start();
    }

    static if (is(Sender.Value == void)) {
        void next(Receiver receiver) @trusted nothrow {
            try {
                opB = nextSender().connect(receiver);
            } catch (Exception e) {
                receiver.setError(e);
                return;
            }
            opB.start();
        }
        private auto nextSender() @trusted {
            auto localFun = fun;
            opA.destroy();
            fun = null;
            return localFun();
        }
    } else {
        void next(Sender.Value value, Receiver receiver) @trusted nothrow {
            this.value = value;
            try {
                opB = nextSender(this.value).connect(receiver);
            } catch (Exception e) {
                receiver.setError(e);
                return;
            }
            opB.start();
        }
        private auto nextSender(Sender.Value value) @trusted {
            auto localFun = fun;
            opA.destroy();
            fun = null;
            return localFun(value);
        }
    }

}

struct LetValueReceiver(Value, Receiver) {
    Receiver receiver;

    static if (is(Value == void)) {
        void delegate(Receiver) @trusted nothrow next;
        void setValue() @safe nothrow {
            next(receiver);
        }
    } else {
        void delegate(Value, Receiver) @trusted nothrow next;
        void setValue(Value value) @safe nothrow {
            next(value, receiver);
        }
    }

    void setDone() @safe nothrow {
        receiver.setDone();
    }

    void setError(Throwable e) @safe nothrow {
        receiver.setError(e);
    }

    import concurrency.receiver;
    mixin ForwardExtensionPoints!receiver;
}
