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
    this(Range range, Receiver receiver) {
        this.range = range;
        this.receiver = receiver;
    }
    void start() {
        next();
    }
    private void next() @trusted nothrow {
        import std.range : empty, front;
        import concurrency.operations : on;
        try {
        if (range.empty)
            receiver.setValue();
        else {
            op = receiver
                .setNext(just(range.front).on(scheduler))
                .connect(RangeSequenceNextReceiver!(Range, Receiver)(this));
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
    // auto receiver() nothrow @safe {
    //     return &op.receiver;
    // }
    // import concurrency.receiver : ForwardExtensionPoints;
    // mixin ForwardExtensionPoints!receiver;
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
    import concurrency.receiver : ForwardExtensionPoints;
    mixin ForwardExtensionPoints!receiver;
}

auto toList(Sequence)(Sequence s) {
    return SequenceToList!(Sequence)(s);
}

struct SequenceToList(Sequence) {
    alias Value = Sequence.Element[];
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
    this(Sequence s, Receiver r) {
        this.s = s;
        state.receiver = r;
    }
    void start() @safe scope {
        auto op = s.connect(SequenceToListReceiver!(Sequence.Element, Receiver)(state));
        op.start();
    }
}

struct SequenceToListState(Element, Receiver) {
    Receiver receiver;
    Element[] list;
}

struct SequenceToListReceiver(Element, Receiver) {
    SequenceToListState!(Element, Receiver)* op;
    this (ref SequenceToListState!(Element, Receiver) op) {
        this.op = &op;
    }
    auto setNext(Sender)(Sender sender) {
        import concurrency.operations : then;

        return sender.then((Sender.Value v) @safe shared { op.list ~= v; });
    }
    auto setValue() {
        op.receiver.setValue(op.list);
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
    void start() @trusted scope {
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

auto transform(Sequence, Fun)(Sequence s, Fun f) {
    return SequenceTransform!(Sequence, Fun)(s, f);
}

struct SequenceTransform(Sequence, Fun) {
    import std.traits : ReturnType;
    alias Value = void;
    alias Element = ReturnType!(Fun);
    Sequence s;
    Fun f;
    auto connect(Receiver)(return Receiver receiver) @safe return scope {
        auto op = s.connect(SequenceTransformReceiver!(Fun, Receiver)(f, receiver));
        return op;
    }
}

struct SequenceTransformReceiver(Fun, Receiver) {
    Fun fun;
    Receiver receiver;
    auto setNext(Sender)(Sender sender) {
        import concurrency.operations : then;
        return receiver.setNext(sender.then(fun));
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
    Sender sender;
    SequenceFilterNextState!(Fun, NextReceiver, Receiver) state;
    import concurrency.sender : OpType;

    alias Op = OpType!(Sender, SequenceFilterNextReceiver!(Sender.Value, Fun, NextReceiver, Receiver));
    Op op;
    this(Sender sender, Fun fun, NextReceiver nextReceiver, Receiver receiver) {
        this.sender = sender;
        state = SequenceFilterNextState!(Fun, NextReceiver, Receiver)(fun, nextReceiver, receiver);
    }
    @disable this(ref return scope typeof(this) rhs);
    @disable this(this);
    void start() @trusted scope {
        op = sender.connect(SequenceFilterNextReceiver!(Sender.Value, Fun, NextReceiver, Receiver)(&state));
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
        import std.stdio;
        if (state.fun(value)) {
            auto sender = state.nextReceiver.setNext(just(value));
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
