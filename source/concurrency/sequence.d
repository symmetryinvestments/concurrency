module concurrency.sequence;

template NextSenderType(Sender, Receiver) {
    import std.traits : ReturnType;
    alias NextSenderType = ReturnType!(Receiver.setNext!(Sender));
}

auto sequence(Range)(Range range) {
    return RangeSequence!(Range)(range);
}

struct RangeSequence(Range) {
    alias Value = void;
    import std.range : ElementType;
    alias Element = ElementType!Range;
    Range range;
    auto connect(Receiver)(return Receiver receiver) @safe return scope {
        auto op = RangeSequenceOp!(Range, Receiver)(range, receiver);
        return op;
    }
}

struct RangeSequenceOp(Range, Receiver) {
    import concurrency.sender : OpType, JustFromSender, justFrom, ValueSender, just;
    import concurrency.operations : on;
    import std.range : ElementType, empty, front;

    Range range;
    Receiver receiver;

    alias ItemSender = typeof(just(range.front).on(scheduler));
    alias NextSender = NextSenderType!(ItemSender, Receiver);
    alias Op = OpType!(NextSender, RangeSequenceNextReceiver!(Range, Receiver));
    Op op;
    
    TrampolineScheduler scheduler;
    @disable this(ref return scope typeof(this) rhs);
    @disable this(this);

    @disable void opAssign(typeof(this) rhs) nothrow @safe @nogc;
    @disable void opAssign(ref typeof(this) rhs) nothrow @safe @nogc;

    this(Range range, Receiver receiver) {
        this.range = range;
        this.receiver = receiver;
    }
    void start() @safe scope nothrow {
        next();
    }
    private void next() @trusted scope nothrow {
        import std.range : empty, front;
        import concurrency.operations : on;
        import concurrency.sender : emplaceOperationalState;
        try {
            if (range.empty)
                receiver.setValue();
            else {
                auto recv = RangeSequenceNextReceiver!(Range, Receiver)(this);
                op.emplaceOperationalState(receiver
                    .setNext(just(range.front).on(scheduler)),
                    recv);
                op.start();
            }
        } catch (Exception e) {
            receiver.setError(e);
        }
    }
}

void setValueUnlessStopped(Receiver)(ref Receiver r) {
    if (r.getStopToken().isStopRequested)
        r.setDone();
    else
        r.setValue();
}

struct RangeSequenceNextReceiver(Range, Receiver) {
    RangeSequenceOp!(Range, Receiver)* op;
    this (ref RangeSequenceOp!(Range, Receiver) op) {
        this.op = &op;
    }
    void setValue() nothrow @safe {
        try {
            import std.range : popFront;
            op.range.popFront();
            op.next();
        } catch (Exception e) {
            op.receiver.setError(e);
        }
    }
    void setDone() nothrow @safe {
        op.receiver.setValueUnlessStopped();
    }
    void setError(Throwable t) nothrow @safe {
        op.receiver.setError(t);
    }
    auto getStopToken() nothrow @safe {
        return op.receiver.getStopToken();
    }
    auto getScheduler() nothrow @safe {
        return op.receiver.getScheduler();
    }
}

auto collect(Sequence, Fun)(Sequence s, Fun fun) {
    return SequenceCollect!(Sequence, Fun)(s, fun);
}

struct SequenceCollect(Sequence, Fun) {
    alias Value = void;
    Sequence s;
    Fun fun;
    auto connect(Receiver)(return Receiver receiver) @safe return scope {
        auto op = s.connect(SequenceCollectReceiver!(Fun, Receiver)(fun, receiver));
        return op;
    }  
}

struct SequenceCollectReceiver(Fun, Receiver) {
    Fun fun;
    Receiver receiver;
    auto setNext(Sender)(Sender sender) {
        import concurrency.operations : then;
        return sender.then(fun);
    }
    auto setDone() @safe nothrow {
        receiver.setDone();
    }
    auto setValue() {
        receiver.setValue();
    }
    auto setError(Throwable t) nothrow @safe {
        receiver.setError(t);
    }
    auto getStopToken() nothrow @safe {
        return receiver.getStopToken();
    }
    auto getScheduler() nothrow @safe {
        return receiver.getScheduler();
    }
}

auto toList(Sequence)(Sequence s) {
    return SequenceToList!(Sequence)(s);
}

struct SequenceToList(Sequence) {
    static if (is(Sequence.Element == void)) {
        alias Value = void;
    } else {
        alias Value = Sequence.Element[];
    }
    Sequence s;
    auto connect(Receiver)(return Receiver receiver) @safe return scope {
        auto op = SequenceToListOp!(Sequence, Receiver)(s, receiver);
        return op;
    }
}

struct SequenceToListOp(Sequence, Receiver){
    Sequence s;
    SequenceToListState!(Sequence.Element, Receiver) state;
    import concurrency.sender : OpType;
    alias Op = OpType!(Sequence, SequenceToListReceiver!(Sequence.Element, Receiver));
    Op op;
    @disable this(ref return scope typeof(this) rhs);
    @disable this(this);

    @disable void opAssign(typeof(this) rhs) nothrow @safe @nogc;
    @disable void opAssign(ref typeof(this) rhs) nothrow @safe @nogc;

    this(Sequence s, Receiver r) @safe scope {
        this.s = s;
        state.receiver = r;
        op = s.connect(SequenceToListReceiver!(Sequence.Element, Receiver)(state));
    }
    void start() @safe scope nothrow {
        op.start();
    }
}

struct SequenceToListState(Element, Receiver) {
    Receiver receiver;
    static if (!is(Element == void)) {
        Element[] list;
    }
}

struct SequenceToListReceiver(Element, Receiver) {
    SequenceToListState!(Element, Receiver)* op;
    this (ref SequenceToListState!(Element, Receiver) op) {
        this.op = &op;
    }
    auto setNext(Sender)(Sender sender) {
        import concurrency.operations : then;

        static if (is(Element == void)) {
            return sender.then(() @safe shared {});
        } else {
            return sender.then((Sender.Value v) @safe shared { op.list ~= v; });
        }
    }
    auto setValue() nothrow @safe {
        static if (is(Element == void)) {
            op.receiver.setValue();
        } else {
            op.receiver.setValue(op.list);
        }
    }
    auto setDone() nothrow @safe {
        op.receiver.setDone();
    }
    auto setError(Throwable t) nothrow @safe {
        op.receiver.setError(t);
    }
    auto receiver() nothrow @safe {
        return &op.receiver;
    }
    import concurrency.receiver : ForwardExtensionPoints;
    mixin ForwardExtensionPoints!receiver;
}

struct TrampolineState {
    static TrampolineState* current;
    
    static auto construct() nothrow @trusted {
        auto state = TrampolineState();
        current = &state;
        return state;
    }

    ~this() nothrow @safe {
        current = null;
    }

    void drain() nothrow @safe {
        while(head !is null) {
            auto op = head;
            head = head.next;
            depth = 1;
            op.exec();
        }
    }

    size_t depth = 1;
    TrampolinePendingItem* head;
}

struct TrampolineScheduler {
    size_t maxDepth = 16;
    auto schedule() @safe nothrow {
        return TrampolineSender(maxDepth);
    }
}

struct TrampolineSender {
    alias Value = void;
    size_t maxDepth = 16;
    auto connect(Receiver)(return Receiver receiver) @safe return scope {
        auto op = TrampolineOp!(Receiver)(maxDepth, receiver);
        return op;
    }
}

struct TrampolinePendingItem {
    void delegate() nothrow @safe exec;
    TrampolinePendingItem* next;
}

struct TrampolineOp(Receiver) {
    size_t maxDepth;
    Receiver receiver;
    TrampolinePendingItem base;

    @disable this(ref return scope typeof(this) rhs);
    @disable this(this);

    @disable void opAssign(typeof(this) rhs) nothrow @safe @nogc;
    @disable void opAssign(ref typeof(this) rhs) nothrow @safe @nogc;

    void start() @trusted scope nothrow {
        auto current = TrampolineState.current;
        if (current is null) {
            auto state = TrampolineState.construct();
            execute();
            state.drain();
        } else if (current.depth < maxDepth) {
            ++current.depth;
            execute();
        } else {
            // Exceeded recursion limit.
            base.exec = &this.execute;
            base.next = current.head;
            current.head = &base;
        }
    }
    void execute() nothrow @safe {
        if (receiver.getStopToken().isStopRequested()) {
            receiver.setDone();
        } else {
            receiver.setValue();
        }
    }
}

struct SequenceNextTransformer(Fun) {
    Fun f;
    auto setNext(Sender)(Sender s) {
        import concurrency.operations : then;
        return s.then(f);
    }
}

auto transform(Sequence, Fun)(Sequence s, Fun f) {
    import concurrency.operations : then;
    return s.nextTransform(SequenceNextTransformer!(Fun)(f));
}

auto nextTransform(Sequence, NextTransformer)(Sequence s, NextTransformer t) {
    return SequenceNextTransform!(Sequence, NextTransformer)(s, t);
}

struct SequenceNextTransform(Sequence, NextTransformer) {
    import concurrency.sender : VoidSender;
    import concurrency : just;
    alias Value = void;
    static if (is(Sequence.Element == void)) {
        alias Element = typeof(t.setNext(VoidSender())).Value;
    } else {
        alias Element = typeof(t.setNext(just(Sequence.Element.init))).Value;
    }
    Sequence s;
    NextTransformer t;
    auto connect(Receiver)(return Receiver receiver) @safe return scope {
        auto op = s.connect(SequenceNextTransformReceiver!(NextTransformer, Receiver)(t, receiver));
        return op;
    }
}

struct SequenceNextTransformReceiver(NextTransformer, Receiver) {
    NextTransformer t;
    Receiver receiver;
    auto setNext(Sender)(Sender sender) nothrow @safe {
        return receiver.setNext(t.setNext(sender));
    }
    auto setValue() nothrow @safe {
        receiver.setValue();
    }
    auto setDone() nothrow @safe {
        receiver.setDone();
    }
    auto setError(Throwable t) nothrow @safe {
        receiver.setError(t);
    }
    import concurrency.receiver : ForwardExtensionPoints;
    mixin ForwardExtensionPoints!receiver;
}

auto filter(Sequence, Fun)(Sequence s, Fun f) {
    return SequenceFilter!(Sequence, Fun)(s, f);
}

struct SequenceFilter(Sequence, Fun) {
    import std.traits : ReturnType;
    alias Value = void;
    alias Element = Sequence.Element;
    Sequence s;
    Fun f;
    auto connect(Receiver)(return Receiver receiver) @safe return scope {
        auto op = s.connect(SequenceFilterReceiver!(Fun, Receiver)(f, receiver));
        return op;
    }
}

struct SequenceFilterReceiver(Fun, Receiver) {
    Fun fun;
    Receiver receiver;
    auto setNext(Sender)(Sender sender) {
        return SequenceFilterNextSender!(Sender, Fun, Receiver)(sender, fun, receiver);
    }
    auto setValue() {
        receiver.setValue();
    }
    auto setDone() nothrow @safe {
        receiver.setDone();
    }
    auto setError(Throwable t) nothrow @safe {
        receiver.setError(t);
    }
    import concurrency.receiver : ForwardExtensionPoints;
    mixin ForwardExtensionPoints!receiver;
}

struct SequenceFilterNextSender(Sender, Fun, NextReceiver) {
    alias Value = Sender.Value;
    Sender sender;
    Fun fun;
    NextReceiver nextReceiver;
    auto connect(Receiver)(return Receiver receiver) @safe return scope {
        auto op = SequenceFilterNextOp!(Sender, Fun, NextReceiver, Receiver)(sender, fun, nextReceiver, receiver);
        return op;
    }
}

struct SequenceFilterNextOp(Sender, Fun, NextReceiver, Receiver) {
    import concurrency.sender : OpType;

    alias Op = OpType!(Sender, SequenceFilterNextReceiver!(Sender.Value, Fun, NextReceiver, Receiver));
    Op op;
    SequenceFilterNextState!(Fun, NextReceiver, Receiver) state;
    this(Sender sender, Fun fun, NextReceiver nextReceiver, Receiver receiver) @trusted {
        state = SequenceFilterNextState!(Fun, NextReceiver, Receiver)(fun, nextReceiver, receiver);
        op = sender.connect(SequenceFilterNextReceiver!(Sender.Value, Fun, NextReceiver, Receiver)(&state));
    }
    @disable this(ref return scope typeof(this) rhs);
    @disable this(this);

    @disable void opAssign(typeof(this) rhs) nothrow @safe @nogc;
    @disable void opAssign(ref typeof(this) rhs) nothrow @safe @nogc;

    void start() @trusted scope nothrow {
        op.start();
    }
}

struct SequenceFilterNextState(Fun, NextReceiver, Receiver) {
    Fun fun;
    NextReceiver nextReceiver;
    Receiver receiver;
}

struct SequenceFilterNextReceiver(Value, Fun, NextReceiver, Receiver) {
    SequenceFilterNextState!(Fun, NextReceiver, Receiver)* state;

    auto setValue(Value value) {
        import concurrency : just;
        import concurrency : connectHeap;
        if (state.fun(value)) {
            auto sender = state.nextReceiver.setNext(just(value));
            // TODO: put state in SequenceFilterNextOp
            sender.connectHeap(state.receiver).start();
        } else {
            state.receiver.setValue();
        }
    }
    auto setError(Throwable t) nothrow @safe {
        state.nextReceiver.setError(t);
    }
    auto setDone() nothrow @safe {
        state.nextReceiver.setDone();
    }
    auto receiver() nothrow @safe {
        return &state.nextReceiver;
    }
    import concurrency.receiver : ForwardExtensionPoints;
    mixin ForwardExtensionPoints!receiver;
}

auto take(Sequence)(Sequence s, size_t n) {
    return SequenceTake!(Sequence)(s, n);
}

struct SequenceTake(Sequence) {
    import std.traits : ReturnType;
    alias Value = void;
    alias Element = Sequence.Element;
    Sequence s;
    size_t n;
    auto connect(Receiver)(return Receiver receiver) @safe return scope {
        auto op = SequenceTakeOp!(Sequence, Receiver)(s, receiver, n);
        return op;
    }
}

struct SequenceTakeOp(Sequence, Receiver) {
    import concurrency.sender : OpType;

    alias Op = OpType!(Sequence, SequenceTakeReceiver!Receiver);
    Op op;
    SequenceTakeState!(Receiver) state;

    @disable this(ref return scope typeof(this) rhs);
    @disable this(this);

    @disable void opAssign(typeof(this) rhs) nothrow @safe @nogc;
    @disable void opAssign(ref typeof(this) rhs) nothrow @safe @nogc;

    this(Sequence s, Receiver r, size_t n) @trusted return scope {
        state = SequenceTakeState!(Receiver)(r, n);
        op = s.connect(SequenceTakeReceiver!(Receiver)(&state));
    }
    void start() @safe nothrow {
        op.start();
    }
}

struct SequenceTakeState(Receiver) {
    Receiver receiver;
    size_t n;
}

struct SequenceTakeReceiver(Receiver) {
    SequenceTakeState!(Receiver)* state;
    auto setNext(Sender)(Sender sender) {
        import concurrency.operations : then;
        import concurrency : Result, Cancelled, Completed;

        static if (is(Sender.Value == void)) {
            return state.receiver.setNext(sender.then(() @safe shared {
                if (state.n == 0)
                    return Result!(Sender.Value)(Cancelled());
                else {
                    state.n--;
                    return Result!(Sender.Value)(Completed());
                }
            }));
        } else {
            return state.receiver.setNext(sender.then((Sender.Value v) @safe shared {
                if (state.n == 0)
                    return Result!(Sender.Value)(Cancelled());
                else {
                    state.n--;
                    return Result!(Sender.Value)(v);
                }
            }));
        }
    }
    auto setValue() {
        receiver.setValue();
    }
    auto setDone() nothrow @safe {
        receiver.setDone();
    }
    auto setError(Throwable t) nothrow @safe {
        receiver.setError(t);
    }
    auto receiver() nothrow @safe {
        return &state.receiver;
    }
    import concurrency.receiver : ForwardExtensionPoints;
    mixin ForwardExtensionPoints!receiver;
}


auto deferSequence(Fun)(Fun f) {
    import concurrency.utils : isThreadSafeCallable;
    static assert(isThreadSafeCallable!Fun);

    return SequenceDefer!(Fun)(f);
}

struct SequenceDefer(Fun) {
    import std.traits : ReturnType;
    alias Value = void;
    alias Element = ReturnType!(Fun).Value;
    Fun f;
    auto connect(Receiver)(return Receiver receiver) @safe return scope {
        auto op = SequenceDeferOp!(Fun, Receiver)(f, receiver);
        return op;
    }
}

struct SequenceDeferOp(Fun, Receiver) {
    import concurrency.sender : OpType;
    import concurrency.operations : on;

    alias ItemSender = typeof(fun().on(scheduler));
    alias NextSender = NextSenderType!(ItemSender, Receiver);
    alias Op = OpType!(NextSender, SequenceDeferReceiver!(Fun, Receiver));

    Fun fun;
    Receiver receiver;
    TrampolineScheduler scheduler;
    Op op;

    @disable this(ref return scope typeof(this) rhs);
    @disable this(this);

    @disable void opAssign(typeof(this) rhs) nothrow @safe @nogc;
    @disable void opAssign(ref typeof(this) rhs) nothrow @safe @nogc;

    void start() @safe nothrow {
        next();
    }
    void next() @trusted scope nothrow {
        import concurrency.sender : emplaceOperationalState;
        op.emplaceOperationalState(receiver.setNext(fun().on(scheduler)),
            SequenceDeferReceiver!(Fun, Receiver)(&this));
        op.start();
    }
}

struct SequenceDeferReceiver(Fun, Receiver) {
    SequenceDeferOp!(Fun, Receiver)* op;
    auto setValue() nothrow @safe {
        op.next();
    }
    auto setDone() nothrow @safe {
        op.receiver.setValueUnlessStopped();
    }
    auto setError(Throwable t) nothrow @safe {
        op.receiver.setError(t);
    }
    auto getStopToken() nothrow @trusted {
        return op.receiver.getStopToken();
    }
    auto getScheduler() nothrow @safe {
        return op.receiver.getScheduler();
    }
    // TODO: probably should start with an Env
    // might also use that to get Async into the Scheduler
}

import core.time : Duration;
auto interval(Duration duration, bool emitAtStart) {
    static struct S {
        Duration duration;
        bool emitAtStart;
        this(Duration duration, bool emitAtStart) shared @safe nothrow {
            this.duration = duration;
            this.emitAtStart = emitAtStart;
        }
        auto opCall() @safe shared {
            import core.time : seconds;
            import concurrency.scheduler : ScheduleAfter;

            if (emitAtStart) {
                emitAtStart = false;
                return ScheduleAfter(0.seconds);
            }
            return ScheduleAfter(duration);
        }
    }
    return deferSequence(shared S(duration, emitAtStart));
}

/// checks that T is a Sequence
void checkSequence(T)() @safe {
    import concurrency.scheduler : SchedulerObjectBase;
    import concurrency.stoptoken : StopToken;
    T t = T.init;
    struct Scheduler {
        import core.time : Duration;
        import concurrency : VoidSender;
        auto schedule() @safe {
            return VoidSender();
        }

        auto scheduleAfter(Duration) @safe {
            return VoidSender();
        }
    }

    static struct Receiver {
        int* i; // force it scope
        static if (is(T.Value == void))
            void setValue() @safe {}

        else
            void setValue(T.Value) @safe {}

        auto setNext(Sender)(Sender s) @safe nothrow {
            return s;
        }

        void setDone() @safe nothrow {}

        void setError(Throwable e) @safe nothrow {}

        shared(StopToken) getStopToken() @safe nothrow {
            return shared(StopToken).init;
        }

        Scheduler getScheduler() @safe nothrow {
            return Scheduler.init;
        }
    }

    import concurrency : OpType, isValidOp;

    scope receiver = Receiver.init;
    OpType!(T, Receiver) op = t.connect(receiver);
    static if (!isValidOp!(T, Receiver))
        pragma(msg, "Warning: ", T,
               "'s operation state is not returned via the stack");
}

enum isSequence(T) = is(typeof(checkSequence!T));

private struct FlattenSenderSequenceTransformer {
    auto setNext(Sender)(Sender s) {
        return s.flatten;
    }
}
auto flatten(SenderOrSequence)(SenderOrSequence s) {
    import concurrency : isSender;
    static if (isSender!(SenderOrSequence)) {
        alias Sender = SenderOrSequence;
        static if (isSender!(Sender.Value)) {
            // Sender of Sender
            return FlattenSenderSender!(Sender)(s);
        } else static if (isSequence!(Sender.Value)) {
            // Sender of Sequence
            return FlattenSenderSequence!(Sender)(s);
        } else static assert(0, "Must be a sender/sequence of sender(s)/sequence(s)");
    } else static if (isSequence!(SenderOrSequence)) {
        alias Sequence = SenderOrSequence;
        static if (isSender!(Sequence.Element)) {
            // Sequence of Senders
            return s.nextTransform(FlattenSenderSequenceTransformer());
        } else static if (isSequence!(Sequence.Element)) {
            // Sequence of Sequences
            return FlattenSequence!(Sequence)(s);
        } else 
            static assert(0, "Must be a sender/sequence of sender(s)/sequence(s)");
    } else 
        static assert(0, "Must be a sender/sequence of sender(s)/sequence(s)");
}

struct FlattenSenderSequence(Sender) {
    alias Value = Sender.Value.Value;
    alias Element = Sender.Value.Element;
    Sender s;
    auto connect(Receiver)(return Receiver receiver) @safe return scope {
        auto op = FlattenSenderSenderOp!(Sender, Receiver)(s, receiver);
        return op;
    }
}

struct FlattenSenderSender(Sender) {
    alias Value = Sender.Value.Value;
    Sender s;
    auto connect(Receiver)(return Receiver receiver) @safe return scope {
        auto op = FlattenSenderSenderOp!(Sender, Receiver)(s, receiver);
        return op;
    }
}

struct FlattenSenderSenderOp(Sender, Receiver) {
    import concurrency.sender : OpType;

    Receiver receiver;
    // TODO: can put these 2 ops in the same memory location to save space
    alias Op = OpType!(Sender, FlattenSenderReceiver!(Sender, Receiver));
    alias Op2 = OpType!(Sender.Value, Receiver);
    Op op;
    Op2 op2;
    @disable this(ref return scope typeof(this) rhs);
    @disable this(this);

    @disable void opAssign(typeof(this) rhs) nothrow @safe @nogc;
    @disable void opAssign(ref typeof(this) rhs) nothrow @safe @nogc;

    this(Sender sender, Receiver receiver) scope {
        this.receiver = receiver;
        op = sender.connect(FlattenSenderReceiver!(Sender, Receiver)(this));
    }
    void start() nothrow {
        op.start();
    }
}

struct FlattenSenderReceiver(Sender, Receiver) {
    FlattenSenderSenderOp!(Sender, Receiver)* op;
    this(ref FlattenSenderSenderOp!(Sender, Receiver) op) {
        this.op = &op;
    }
    auto setValue(Sender.Value s) @trusted nothrow {
        try {
            import concurrency.sender : emplaceOperationalState;
            op.op2.emplaceOperationalState(s, op.receiver);
            op.op2.start();
        } catch (Exception e) {
            op.receiver.setError(e);
        }
    }
    auto setDone() nothrow @safe {
        op.receiver.setDone();
    }
    auto setError(Throwable t) nothrow @safe {
        op.receiver.setError(t);
    }
    auto getStopToken() nothrow @trusted {
        return op.receiver.getStopToken();
    }
    auto getScheduler() nothrow @safe {
        return op.receiver.getScheduler();
    }
}

struct FlattenSequence(Sequence) {
    alias Value = Sequence.Value;
    alias Element = Sequence.Element.Element;
    Sequence s;
    auto connect(Receiver)(return Receiver receiver) @safe return scope {
        auto op = FlattenSequenceOp!(Sequence, Receiver)(s, receiver);
        return op;
    }
}

struct FlattenSequenceOp(Sequence, Receiver) {
    import concurrency.sender : OpType;

    Receiver receiver;
    alias Op = OpType!(Sequence, FlattenSequenceReceiver!(Sequence, Receiver));
    Op op;
    @disable this(ref return scope typeof(this) rhs);
    @disable this(this);

    @disable void opAssign(typeof(this) rhs) nothrow @safe @nogc;
    @disable void opAssign(ref typeof(this) rhs) nothrow @safe @nogc;

    this(Sequence sequence, Receiver receiver) @safe scope {
        this.receiver = receiver;
        op = sequence.connect(FlattenSequenceReceiver!(Sequence, Receiver)(this));
    }
    void start() @safe scope nothrow {
        op.start();
    }
}

private struct FlattenSequenceTranformer(Receiver) {
    Receiver* receiver;
    this(ref Receiver receiver) @trusted return scope {
        this.receiver = &receiver;
    }
    auto setNext(Sender)(Sender s) @safe nothrow {
        return receiver.setNext(s);
    }
}

struct FlattenSequenceReceiver(Sequence, Receiver) {
    FlattenSequenceOp!(Sequence, Receiver)* op;
    this(ref FlattenSequenceOp!(Sequence, Receiver) op) {
        this.op = &op;
    }
    auto setNext(Sender)(Sender sender) @trusted nothrow return scope {
        auto transformer = FlattenSequenceTranformer!(Receiver)(op.receiver);
        return nextTransform(sender.flatten, transformer).collect((){});
    }
    auto setValue() @safe nothrow {
        op.receiver.setValue();
    }
    auto setDone() nothrow @safe {
        op.receiver.setDone();
    }
    auto setError(Throwable t) nothrow @safe {
        op.receiver.setError(t);
    }
    auto getStopToken() nothrow @trusted {
        return op.receiver.getStopToken();
    }
    auto getScheduler() nothrow @safe {
        return op.receiver.getScheduler();
    }
}

auto flatMap(Sequence, Fun)(Sequence s, Fun f) {
    // TOD: probably flatMap is just .then(f).flatten()
    return FlatMapSequence!(Sequence, Fun)(s, f);
}

struct FlatMapSequence(Sequence, Fun) {
    import std.traits : ReturnType;

    alias Value = void;
    alias Element = ReturnType!(Fun).Value;
    Sequence s;
    Fun f;
    auto connect(Receiver)(return Receiver receiver) @safe return scope {
        auto op = FlatMapSequenceOp!(Sequence, Fun, Receiver)(s, f, receiver);
        return op;
    }
}

struct FlatMapSequenceOp(Sequence, Fun, Receiver) {
    import concurrency.sender : OpType;

    alias Op = OpType!(Sequence, FlatMapSequenceReceiver!(Sequence, Fun, Receiver));
    Fun fun;
    Receiver receiver;
    Op op;

    @disable this(ref return scope typeof(this) rhs);
    @disable this(this);

    @disable void opAssign(typeof(this) rhs) nothrow @safe @nogc;
    @disable void opAssign(ref typeof(this) rhs) nothrow @safe @nogc;

    this(Sequence sequence, Fun fun, Receiver receiver) {
        this.fun = fun;
        this.receiver = receiver;
        op = sequence.connect(FlatMapSequenceReceiver!(Sequence, Fun, Receiver)(this));
    }
    void start() nothrow {
        op.start();
    }
}

struct FlatMapSequenceReceiver(Sequence, Fun, Receiver) {
    FlatMapSequenceOp!(Sequence, Fun, Receiver)* op;
    this(ref FlatMapSequenceOp!(Sequence, Fun, Receiver) op) {
        this.op = &op;
    }
    auto setNext(Sender)(Sender sender) {
        import concurrency.operations : then;
        return op.receiver.setNext(sender.then(op.fun).flatten);
    }
    auto setValue() {
        op.receiver.setValue();
    }
    auto setDone() nothrow @safe {
        op.receiver.setDone();
    }
    auto setError(Throwable t) nothrow @safe {
        op.receiver.setError(t);
    }
    auto getStopToken() nothrow @trusted {
        return op.receiver.getStopToken();
    }
    auto getScheduler() nothrow @safe {
        return op.receiver.getScheduler();
    }
}

struct ScanSequenceTransformer(Fun, Seed) {
    Fun fun;
    Seed seed;
    auto setNext(Sender)(Sender sender) {
        import concurrency.operations : then;
        static if (is(Sender.Value == void)) {
            return sender.then(() @safe shared {
                seed = fun(seed);
                return seed;
            });
        } else {
            return sender.then((Sender.Value value) @safe shared {
                seed = fun(value, seed);
                return seed;
            });
        }
    }
}

auto scan(Sequence, Fun, Seed)(Sequence s, Fun fun, Seed seed) {
    auto transformer = ScanSequenceTransformer!(Fun, Seed)(fun, seed);
    return s.nextTransform(transformer);
}

auto iotaSequence(T)(T start, T end) {
    import std.range : iota;

    return iota(start, end).sequence();
}

auto filterMap(Sequence, Fun)(Sequence s, Fun f) {
    return FilterMapSequence!(Sequence, Fun)(s, f);
}

import std.typecons : Nullable;
alias NullabledType(P : Nullable!T, T) = T;

struct FilterMapSequence(Sequence, Fun) {
    import std.traits : ReturnType;
    alias Value = void;
    alias FunReturn = ReturnType!Fun;
    static if (is(FunReturn == void)) {
        alias Element = void;
    } else {
        alias Element = NullabledType!(ReturnType!(Fun));
    }
    Sequence s;
    Fun f;
    auto connect(Receiver)(return Receiver receiver) @safe return scope {
        auto op = s.connect(FilterMapSequenceReceiver!(Fun, Receiver)(f, receiver));
        return op;
    }
}

struct FilterMapSequenceReceiver(Fun, Receiver) {
    Fun fun;
    Receiver receiver;
    auto setNext(Sender)(Sender sender) {
        return FilterMapSequenceNextSender!(Sender, Fun, Receiver)(sender, fun, receiver);
    }
    auto setValue() {
        receiver.setValue();
    }
    auto setDone() nothrow @safe {
        receiver.setDone();
    }
    auto setError(Throwable t) nothrow @safe {
        receiver.setError(t);
    }
    import concurrency.receiver : ForwardExtensionPoints;
    mixin ForwardExtensionPoints!receiver;
}

struct FilterMapSequenceNextSender(Sender, Fun, NextReceiver) {
    alias Value = Sender.Value;
    Sender sender;
    Fun fun;
    NextReceiver nextReceiver;
    auto connect(Receiver)(return Receiver receiver) @safe return scope {
        auto op = FilterMapSequenceNextOp!(Sender, Fun, NextReceiver, Receiver)(sender, fun, nextReceiver, receiver);
        return op;
    }
}

struct FilterMapSequenceNextOp(Sender, Fun, NextReceiver, Receiver) {
    import concurrency.sender : OpType;

    alias Op = OpType!(Sender, FilterMapSequenceNextReceiver!(Sender.Value, Fun, NextReceiver, Receiver));
    Op op;
    FilterMapSequenceNextState!(Fun, NextReceiver, Receiver) state;
    this(Sender sender, Fun fun, NextReceiver nextReceiver, Receiver receiver) @trusted {
        state = FilterMapSequenceNextState!(Fun, NextReceiver, Receiver)(fun, nextReceiver, receiver);
        op = sender.connect(FilterMapSequenceNextReceiver!(Sender.Value, Fun, NextReceiver, Receiver)(&state));
    }
    @disable this(ref return scope typeof(this) rhs);
    @disable this(this);

    @disable void opAssign(typeof(this) rhs) nothrow @safe @nogc;
    @disable void opAssign(ref typeof(this) rhs) nothrow @safe @nogc;

    void start() @trusted scope nothrow {
        op.start();
    }
}

struct FilterMapSequenceNextState(Fun, NextReceiver, Receiver) {
    Fun fun;
    NextReceiver nextReceiver;
    Receiver receiver;
}

struct FilterMapSequenceNextReceiver(Value, Fun, NextReceiver, Receiver) {
    FilterMapSequenceNextState!(Fun, NextReceiver, Receiver)* state;

    static if (is(Value == void)) {
        auto setValue() {
            import concurrency : just;
            import concurrency : connectHeap;
            auto result = state.fun();
            if (result.isNone) {
                state.receiver.setValue();
            } else {
                auto sender = state.nextReceiver.setNext(just(result.getSome));
                // TODO: put state in FilterMapSequenceNextOp
                sender.connectHeap(state.receiver).start();
            }
        }
    } else {
        auto setValue(Value value) {
            import concurrency : just;
            import concurrency : connectHeap;
            auto result = state.fun(value);
            if (result.isNone) {
                state.receiver.setValue();
            } else {
                auto sender = state.nextReceiver.setNext(just(result.getSome));
                // TODO: put state in FilterMapSequenceNextOp
                sender.connectHeap(state.receiver).start();
            }
        }
    }
    auto setError(Throwable t) nothrow @safe {
        state.nextReceiver.setError(t);
    }
    auto setDone() nothrow @safe {
        state.nextReceiver.setDone();
    }
    auto receiver() nothrow @safe {
        return &state.nextReceiver;
    }
    import concurrency.receiver : ForwardExtensionPoints;
    mixin ForwardExtensionPoints!receiver;
}

private bool isNone(T)(ref const T t) {
    return t.isNull();
}

private auto getSome(T)(ref T t) {
    return t.get();
}

auto proxyNext(Sequence, Receiver)(Sequence sequence, Receiver receiver) {
    return ProxyNextSequence!(Sequence, Receiver)(sequence, receiver);
}

struct ProxyNextSequence(Sequence, NextReceiver) {
    alias Value = Sequence.Value;

    Sequence sequence;
    NextReceiver nextReceiver;

    auto connect(Receiver)(return Receiver receiver) @safe return scope {
        // ensure NRVO
        auto op = sequence.connect(ProxyNextReceiver!(NextReceiver, Receiver)(nextReceiver, receiver));
        return op;
    }
}

struct ProxyNextReceiver(NextReceiver, Receiver) {
    NextReceiver nextReceiver;
    Receiver receiver;

    auto setNext(Sender)(Sender sender) {
        return nextReceiver.setNext(sender);
    }
    auto setValue() {
        receiver.setValue();
    }
    auto setDone() nothrow @safe {
        receiver.setDone();
    }
    auto setError(Throwable t) nothrow @safe {
        receiver.setError(t);
    }
    import concurrency.receiver : ForwardExtensionPoints;
    mixin ForwardExtensionPoints!receiver;
}

auto sample(BaseSequence, TriggerSequence)(BaseSequence base, TriggerSequence trigger) {
    return SampleSequence!(BaseSequence, TriggerSequence)(base, trigger);
}

struct SampleSequence(BaseSequence, TriggerSequence) {
    alias Value = void;
    alias Element = BaseSequence.Element;

    BaseSequence base;
    TriggerSequence trigger;

    auto connect(Receiver)(return Receiver receiver) @safe return scope {
        // ensure NRVO
        auto op = SampleSequenceOp!(BaseSequence, TriggerSequence, Receiver)(base, trigger, receiver);
        return op;
    }
}

struct SampleSequenceOp(BaseSequence, TriggerSequence, Receiver) {
	import concurrency.bitfield : SharedBitField;
	import concurrency.sender : OpType;
    import concurrency.operations : RaceSender;

    import std.typecons : Nullable;
	enum Flags : size_t {
		locked = 0x1,
		valid = 0x2
	}
	shared SharedBitField!Flags state;
    alias Element = BaseSequence.Element;
	Element item;
    alias RaceAllSender = RaceSender!(
        SequenceCollect!(BaseSequence, void delegate(Element) shared @safe nothrow @nogc),
        ProxyNextSequence!(FilterMapSequence!(TriggerSequence, Nullable!Element delegate() shared @safe nothrow @nogc), Receiver)
        );
    alias Op = OpType!(RaceAllSender, Receiver);

    Op op;

    @disable this(ref return scope typeof(this) rhs);
    @disable this(this);

    @disable void opAssign(typeof(this) rhs) nothrow @safe @nogc;
    @disable void opAssign(ref typeof(this) rhs) nothrow @safe @nogc;

    this(BaseSequence base, TriggerSequence trigger, return Receiver receiver) @trusted return scope {
        import concurrency.operations : raceAll;
        op = raceAll(
            base.collect(&(cast(shared)this).produced),
            trigger.filterMap(&(cast(shared)this).triggered).proxyNext(receiver)
        ).connect(receiver);
    }

    void start() {
        op.start();
    }

    private void produced(Element item) shared @safe nothrow @nogc {
        with (state.lock(Flags.valid)) {
            this.item = item;
        }
    }

    private Nullable!Element triggered() shared @safe nothrow @nogc{
        with (state.lock()) {
            if (was(Flags.valid)) {
                auto localElement = item;
                release(Flags.valid);
                return Nullable!Element(localElement);
            }
            return Nullable!Element.init;
        }
    }
}

auto slide(Sequence)(Sequence sequence, long window, long step = 1) {
    static assert(!is(Sequence.Element == void), "Sequence passed to slide must produce elements.");
    
	import std.exception : enforce;
	enforce(window > 0, "window must be greater than 0.");
	enforce(step > 0, "step must be greated than 0.");

    return SlideSequence!(Sequence)(sequence, window, step);
}

struct SlideSequence(Sequence) {
    alias Value = void;
    alias Element = Sequence.Element[];

    Sequence sequence;
    long window, step;

    auto connect(Receiver)(return Receiver receiver) @safe return scope {
        auto op = SlideSequenceOp!(Sequence, Receiver)(sequence, window, step, receiver);
        return op;
    }
}

struct SlideSequenceOp(Sequence, Receiver) {
    import concurrency.sender : OpType;
    alias Element = Sequence.Element;

    alias Op = OpType!(FilterMapSequence!(Sequence, Nullable!(Element[]) delegate(Sequence.Element) @safe pure nothrow), Receiver);

    long step, pos;
    Element[] arr;
    Op op;

    @disable this(ref return scope typeof(this) rhs);
    @disable this(this);

    @disable void opAssign(typeof(this) rhs) nothrow @safe @nogc;
    @disable void opAssign(ref typeof(this) rhs) nothrow @safe @nogc;
        
    this(Sequence sequence, long window, long step, return Receiver receiver) @trusted return scope {
        arr.length = window;
        this.step = step;
        op = sequence.filterMap(&this.onNext).connect(receiver);
    }

    void start() scope {
        op.start();
    }

    Nullable!(Element[]) onNext(Sequence.Element element) @safe {
        import std.algorithm : moveAll;
        if (pos < 0) {
            pos++;
            return Nullable!(Element[]).init;
        }

        if (pos+1 > arr.length) {
            if (step < arr.length) {
                moveAll(arr[step .. $], arr[0 .. $ - step]);
                pos -= step;
            } else {
                pos = (cast(long)arr.length) - step;
                if (pos < 0) {
                    pos++;
                    return Nullable!(Element[]).init;
                }
            }
        }

        arr[pos] = element;
        pos++;

        if (pos == arr.length) {
            return Nullable!(Element[])(arr.dup);
        } else {
            return Nullable!(Element[]).init;
        }
    }
}

// cron - create a sequence like interval but using cron spec

// flatmap{latest,concat} - create a sequence that flattens

// throttling ?

// merge ?

// interval - emits items on interval

// share - creates a shared sequence that allows hot plugging receivers, like a broadcast

// while/until - stops the stream 
