module concurrency.io.iouring;

version(linux):

import concurrency.data.queue.mpsc;
import concurrency.stoptoken;
import concurrency.receiver : setErrno, setValueOrError;
import during;
import core.stdc.errno : ECANCELED;

/// IOUring IO context. Used to schedule IO operations and supports Timers.
///
/// IOUring is only available on Linux. In most cases you don't use this context
/// directly, but instead use the IOContext defined in the `concurrency.io` module.
///
/// To create an IOUringContext use the static `construct` method, passing in the
/// size of the sqe and cqe buffers.
struct IOUringContext {
    import concurrency.scheduler : Timer, TimingWheels, TimerCommand;
    import core.time : msecs, Duration;
    import core.thread : ThreadID;
    import std.process : thisThreadID;
    import std.typecons : Nullable;

    private MPSCQueue!(Item) requests;
    private MPSCQueue!(Timer) timers;
    private Queue!(Item) pending;
    private ptrdiff_t totalSubmitted;
    private ptrdiff_t newlySubmitted;
    private Uring io;
    private ubyte[8] buffer;
    private int event;
    private TimingWheels wheels;
    private enum Duration tickSize = 1.msecs;
    private ThreadID threadId;
    // TODO: instead of using timers and timeout on the iouring_enter
    // we could also use IORING_OP_TIMEOUT
    // or even IORING_OP_LINK_TIMEOUT to link the timeout to the 
    // wakeup event
    private bool dirtyTimers;
    private long nextTimer;
    private shared bool needsWakeup;
    private this(uint size) @trusted {
        // TODO: look into `IORING_SETUP_SQPOLL` for fast submission
        import core.sys.linux.sys.eventfd;
        io.setup(size, 
            SetupFlags.SINGLE_ISSUER
            // | SetupFlags.DEFER_TASKRUN
            // | SetupFlags.COOP_TASKRUN
            // | SetupFlags.SQPOLL
            );
        event = eventfd(0, EFD_CLOEXEC);
        requests = new MPSCQueue!(Item);
        timers = new MPSCQueue!(Timer);
        wheels.initialize();
        threadId = thisThreadID;
    }

    static auto construct(uint size) @safe {
        return IOUringContext(size);
    }

    /// Returns a sender that when started drives the IOUringContext
    /// until the supplied sender completes.
    auto run(Sender)(Sender sender) @safe nothrow {
        return RunSender!(Sender)(&this, sender);
    }

    private void addTimer(ref Timer timer, Duration dur) @trusted shared {
        timer.scheduled_at = dur.split!"hnsecs".hnsecs;
        timer.command = TimerCommand.Register;
        timers.push(&timer);
        wakeup();
    }

    private void cancelTimer(ref Timer timer) @trusted shared {
        timer.command = TimerCommand.Cancel;
        timers.push(&timer);
        wakeup();
    }

    private ref assumeThreadSafe() @trusted nothrow shared {
        return cast()this;
    }
    // TODO: can this be make @safe?
    // otherwise it might have to be made @system perhaps?
    // we are taking a pointer to a ref item, which likely
    // sits on the stack.
    // logically however, all the lifetimes are correct though
    private bool push(ref Item item) @trusted nothrow shared {
        int __n = 0;
        int __no_new_submissions = 1;

        if (__n == __no_new_submissions) {
            CompletionEntry entry;
            entry.res = -ECANCELED;
            item.complete(entry);
            return false;
        } else {
            if (threadId == thisThreadID) {
                with (assumeThreadSafe) {
                    if (!io.full) {
                        submitItem(&item);
                        io.flush();
                        return true;
                    }
                }
            }

            requests.push(&item);
            return true;
        }
    }

    private void wakeup() @trusted nothrow shared {
        import core.sys.posix.unistd;
        import core.atomic : atomicLoad, MemoryOrder, cas;
        size_t wakeup = 1;
        if ((&needsWakeup).cas!(MemoryOrder.raw, MemoryOrder.raw)(true, false)) {
            core.sys.posix.unistd.write(event, &wakeup, wakeup.sizeof);
        }
    }

    private int run(scope shared StopToken stopToken) @safe nothrow {
        import core.atomic : atomicStore, MemoryOrder;

        assert(threadId == thisThreadID, "Thread that started IOUringContext must also drive it.");
        pending.append(requests.popAll());
        scheduleTimers();

        putEventFdChannel();
        while (!stopToken.isStopRequested() || !pending.empty() || !io.empty()) {
            putPending();

            int rc = submitAndWait();
            // TODO: return without completing all pending or completed requests
            // will result in blocked request. Instead we need to cancel all requests
            // until the stopToken is triggered.
            // Would it be possible to cancel the whole context in one go?
            if (rc < 0)
                return -rc;
            atomicStore!(MemoryOrder.raw)(needsWakeup, false);

            completeTimers();
            popCompleted();
            scheduleTimers();

            atomicStore!(MemoryOrder.raw)(needsWakeup, true);
            pending.append(requests.popAll());
        }

        return 0;
    }

    private void scheduleTimers() @safe nothrow {
        import std.datetime.systime : Clock;
        import core.time : hnsecs;
        import concurrency.scheduler : TimerTrigger;

        Queue!(Timer) items;
        items.append(timers.popAll());

        if (!items.empty)
            dirtyTimers = true;

        while (!items.empty) {
            auto timer = items.pop();

            if (timer.command == TimerCommand.Register) {
                auto real_now = Clock.currStdTime;
                auto tw_now = wheels.currStdTime(tickSize);
                auto delay = (real_now - tw_now).hnsecs;
                auto at = (timer.scheduled_at.hnsecs + delay) / tickSize;
                wheels.schedule(timer, at);
            } else {
                wheels.cancel(timer);
                timer.userdata(TimerTrigger.cancel);
            }
        }
    }

    private void completeTimers() @safe nothrow {
        import std.datetime.systime : Clock;
        import concurrency.scheduler : TimerTrigger;

        int incr = wheels.ticksToCatchUp(tickSize, Clock.currStdTime);
        if (incr > 0) {
            Timer* t;
            wheels.advance(incr, t);
            if (t !is null)
                dirtyTimers = true;
            while (t !is null) {
                auto next = t.next;
                t.userdata(TimerTrigger.trigger);
                t = next;
            }
        }
    }

    private Nullable!Duration timeUntilNextTimer() @safe nothrow {
		import std.datetime.systime : Clock;
		import core.time : hnsecs;

        long now = Clock.currStdTime;
        if (dirtyTimers) {
            dirtyTimers = false;
    		auto nextTriggerOpt = wheels.timeUntilNextEvent(tickSize, now);
            if (nextTriggerOpt.isNull) {
                nextTimer = 0;
                return typeof(return).init;
            }
            nextTimer = now + nextTriggerOpt.get.split!"hnsecs".hnsecs;
            return nextTriggerOpt;
        } else if (nextTimer != 0) {
            return typeof(return)((nextTimer - now).hnsecs);
        } else {
            return typeof(return).init;
        }
    }

    private int submitAndWait() @safe nothrow {
        import std.datetime.systime : Clock;

        auto nextTriggerOpt = timeUntilNextTimer();

        if (!nextTriggerOpt.isNull) {
            // next timer is in 0 msecs
            if (nextTriggerOpt.get <= 0.msecs) {
                // only submit any SubmissionEntries
                return io.submit();
            }

            // set io_uring timeout
            io_uring_getevents_arg arg;
            KernelTimespec timespec;

            auto parts = nextTriggerOpt.get().split!("seconds", "nsecs");
            timespec.tv_sec = parts.seconds;
            timespec.tv_nsec = parts.nsecs;
            arg.ts = cast(ulong)(cast(void*)&timespec);

            return io.submitAndWait(1, &arg);
        }

        return io.submitAndWait(1);
    }

    private void putEventFdChannel() @safe nothrow {
        io.putWith!((ref SubmissionEntry e, IOUringContext* context) {
            e.prepRead(context.event, context.buffer[0..8], 0);
        })(&this);
    }

    private void putPending() @safe nothrow {
        while (!pending.empty && !io.full()) {
            auto item = pending.pop();
            submitItem(item);
        }
    }

    private void submitItem(Item* item) @safe nothrow {
        SubmissionEntry entry;
        if (item.submit(entry)) {
            entry.setUserDataRaw(item);
            io.put(entry);
        }
    }

    private void popCompleted() @safe nothrow {
        // TODO: to reduce latency, would it help to run submit and complete in a loop?
        while (!io.empty()) {
            auto entry = io.front();
            auto item = entry.userDataAs!(Item*);
            if (item !is null)
                item.complete(entry);
            else
                putEventFdChannel();
            io.popFront();
        }
    }
}

/// very simple single linked list used for pending items in IOUringContext.
private struct Queue(Node) {
    import concurrency.data.queue.mpsc : Chain;
    Node* head, tail;

    bool empty() {
        return tail is null;
    }

    Node* pop() {
        auto res = tail;
        tail = tail.next;
        return res;
    }

    void append(Chain!(Node) chain) {
        if (empty) {
            head = chain.head;
            tail = chain.tail;
        } else {
            head.next = chain.tail;
            head = chain.head;
        }
    }
}

struct RunSender(Sender) {
    alias Value = Sender.Value;
    IOUringContext* context;
    Sender sender;
    auto connect(Receiver)(return Receiver receiver) @safe return scope {
        // ensure NRVO
        auto op = RunOp!(Sender, Receiver)(context, sender, receiver);
        return op;
    }
}

struct RunOp(Sender, Receiver) {
    import concurrency : Cancelled, justFrom, JustFromSender;
    import concurrency.sender : OpType;
    import concurrency.operations.dofinally;
    import concurrency.operations.whenall;
    import concurrency.operations.withscheduler;
    import concurrency.operations.withioscheduler;

    alias RunSender = JustFromSender!(void delegate() @trusted shared);
    alias SenderWithScheduler = WithSchedulerSender!(Sender, IOUringScheduler);
    alias SenderWithIOScheduler = WithIOSchedulerSender!(SenderWithScheduler, IOUringScheduler);
    alias ValueSender = DoFinallySender!(SenderWithIOScheduler, void delegate() @safe nothrow shared);
    alias CombinedSender = WhenAllSender!(ValueSender, RunSender);
    alias Op = OpType!(CombinedSender, Receiver);

    IOUringContext* context;
    shared StopSource stopSource;
    Op op;
    
    @disable
    this(ref return scope typeof(this) rhs);
    @disable
    this(this);

    this(IOUringContext* context, Sender sender, return Receiver receiver) @trusted return scope {
        this.context = context;
        shared IOUringContext* sharedContext = cast(shared)context;
        auto scheduler = IOUringScheduler(sharedContext);
        op = whenAll(
            sender.withScheduler(scheduler).withIOScheduler(scheduler).doFinally(() @safe nothrow shared {
                stopSource.stop();
                sharedContext.wakeup();
            }),
            justFrom(&(cast(shared)this).run),
        ).connect(receiver);
    }
    private void run() @trusted shared {
        with(cast()this) {
            import std.exception : ErrnoException;
            auto token = stopSource.token();
            auto res = context.run(token);
            if (res < 0)
                throw new ErrnoException("IOUring failed", -res);
        }
    }
    void start() @safe nothrow {
        op.start();
    }
}

struct Item {
    // TODO: we are storing 2 this pointers here
    bool delegate(ref SubmissionEntry sqe) @safe nothrow submit;
    void delegate(ref const CompletionEntry cqe) @safe nothrow complete;
    Item* next;
}

/// CancellableOperation forms the base of all iouring operations.
/// It provides IO submission and cancellation.
///
/// It is templated on the each Operation (read, write, open, etc.)
/// which only need to implement 2 methods, `submit` and `complete`.
/// Submit receives a SubmissionEntry directly from the IOUring
/// submission queue and is required to fill in that structure for
/// that specific IO operation, and complete handles the
/// CompletionEntry and is responsible for calling the appropriate
/// receiver completion method.
private struct CancellableOperation(Operation) {
    private shared(IOUringContext)* context;
    private Operation operation;
    private shared size_t ops;
    private shared StopCallback cb;
    private Item item;

    @disable
    this(ref return scope typeof(this) rhs);
    @disable
    this(this);

    @disable void opAssign(typeof(this) rhs) nothrow @safe @nogc;
    @disable void opAssign(ref typeof(this) rhs) nothrow @safe @nogc;

    this(shared IOUringContext* context, Operation operation) @safe {
        this.context = context;
        this.operation = operation;
    }

    void start() @trusted nothrow scope {
        item.submit = &submit;
        item.complete = &complete;
        if (context.push(item)) {
            context.wakeup();
        }
    }

    // TODO: shouldn't submit be shared?
    private bool submit(ref SubmissionEntry entry) @trusted nothrow {
        try {
            import core.atomic;
            ops.atomicFetchAdd!(MemoryOrder.raw)(1);
            auto stopToken = operation.receiver.getStopToken();
            cb.register(stopToken, &(cast(shared)this).onStop);

            operation.submit(entry);
            return true;
        } catch (Throwable e) {
            operation.receiver.setError(e);
            return false;
        }
    }

    private void complete(const ref CompletionEntry entry) @safe nothrow {
        import core.atomic;
        if (ops.atomicFetchSub!(MemoryOrder.raw)(1) != 1)
            return;

        cb.dispose();

        auto token = operation.receiver.getStopToken();
        if (entry.res == -ECANCELED || token.isStopRequested()) {
            operation.receiver.setDone();
        } else {
            operation.complete(entry);
        }
    }

    private void onStop() nothrow @safe shared {
        import core.atomic;
        size_t expected = 1;
        if (cas!(MemoryOrder.raw, MemoryOrder.raw)(&ops, expected, 2)) {
            // Note we reuse the original item since submit already happened
            // and the userData needs to be the same for the cancellation
            // anyway.
            with(assumeThreadSafe) {
                item.submit = &submitStop;
                if (this.context.push(item)) {
                    this.context.wakeup();
                }
            }
        }
    }

    private bool submitStop(ref SubmissionEntry entry) nothrow @safe {
        entry.prepCancel(item);
        return true;
    }

    private ref assumeThreadSafe() nothrow @trusted shared {
        return cast()this;
    }
}

private struct IOUringTimer {
    import concurrency.scheduler : Timer, TimingWheels, TimerCommand;
    import core.time : msecs, Duration;

    private shared IOUringContext* context;

    void addTimer(ref Timer timer, Duration dur) @safe {
        context.addTimer(timer, dur);
    }

    void cancelTimer(ref Timer timer) @safe {
        context.cancelTimer(timer);
    }
}

struct IOUringScheduler {
    import core.time : Duration;
    import std.socket : socket_t;
    shared (IOUringContext)* context;

    auto read(socket_t fd, ubyte[] buffer, long offset = 0) @safe nothrow @nogc {
        return ReadSender(context, fd, buffer, offset);
    }

    auto accept(socket_t fd) @safe nothrow @nogc {
        return AcceptSender(context, fd);
    }

    auto connect(socket_t fd, string address, ushort port) @safe nothrow @nogc {
        return ConnectSender(context, fd, address, port);
    }

    auto write(socket_t fd, const(ubyte)[] buffer, long offset = 0) @safe nothrow @nogc {
        return WriteSender(context, fd, buffer, offset);
    }

    auto close(socket_t fd) @safe nothrow @nogc {
        return CloseSender(context, fd);
    }

    auto schedule() @safe nothrow @nogc {
        import concurrency.scheduler : ScheduleAfterSender;
        import core.time : msecs;
        return ScheduleAfterSender!(IOUringTimer)(IOUringTimer(context), 0.msecs);
    }

    auto scheduleAfter(Duration duration) @safe nothrow @nogc {
        import concurrency.scheduler : ScheduleAfterSender;
        return ScheduleAfterSender!(IOUringTimer)(IOUringTimer(context), duration);
    }
}

struct ReadSender {
    import std.socket : socket_t;
    alias Value = ubyte[];
    shared IOUringContext* context;
    socket_t fd;
    ubyte[] buffer;
    long offset;
    auto connect(Receiver)(return Receiver receiver) @safe return scope {
        // ensure NRVO
        auto op = CancellableOperation!(ReadOperation!Receiver)(
            context,
            ReadOperation!(Receiver)(fd, buffer, offset, receiver)
        );
        return op;
    }
}

struct ReadOperation(Receiver) {
    import std.socket : socket_t;
    socket_t fd;
    ubyte[] buffer;
    long offset;
    Receiver receiver;
    void submit(ref SubmissionEntry entry) @safe nothrow {
        entry.prepRead(fd, buffer, offset);
    }
    void complete(const ref CompletionEntry entry) @safe nothrow {
        if (entry.res > 0) {
            receiver.setValueOrError(buffer[offset..entry.res]);
        } else if (entry.res == 0) {
            receiver.setDone();
        } else {
            receiver.setErrno("Read failed", -entry.res);
        }
    }
}

struct AcceptSender {
    import concurrency.ioscheduler : Client;
    import std.socket : socket_t;
    alias Value = Client;
    shared IOUringContext* context;
    socket_t fd;
    auto connect(Receiver)(return Receiver receiver) @safe return scope {
        // ensure NRVO
        auto op = CancellableOperation!(AcceptOperation!Receiver)(
            context,
            AcceptOperation!(Receiver)(fd, receiver)
        );
        return op;
    }
}

struct AcceptOperation(Receiver) {
    import core.sys.posix.sys.socket : sockaddr, socklen_t;
    import core.sys.posix.netinet.in_;
    import concurrency.ioscheduler : Client;
    import std.socket : socket_t;

    socket_t fd;
    Receiver receiver;
    sockaddr addr;
    socklen_t addrlen;
    void submit(ref SubmissionEntry entry) @safe nothrow {
        entry.prepAccept(fd, addr, addrlen);
    }
    void complete(const ref CompletionEntry entry) @safe nothrow {
        import std.socket : socket_t;
        if (entry.res >= 0) {
            receiver.setValueOrError(Client(cast(socket_t)entry.res, addr, addrlen));
        } else {
            receiver.setErrno("Accept failed", -entry.res);
        }
    }
}

struct ConnectSender {
    import std.socket : socket_t;
    alias Value = socket_t;
    shared IOUringContext* context;
    socket_t fd;
    string address;
    ushort port;
    auto connect(Receiver)(return Receiver receiver) @safe return scope {
        // ensure NRVO
        auto op = CancellableOperation!(ConnectOperation!Receiver)(
            context,
            ConnectOperation!(Receiver)(fd, address, port, receiver)
        );
        return op;
    }
}

struct ConnectOperation(Receiver) {
    import core.sys.posix.sys.socket;
    import std.socket : socket_t;
    version(Windows) {
        import core.sys.windows.windows;
    } else version(Posix) {
        import core.sys.posix.netinet.in_;
    }
    socket_t fd;
    Receiver receiver;
    sockaddr_in addr;
    this(socket_t fd, string address, ushort port, Receiver receiver) @trusted {
        this.fd = fd;
        this.receiver = receiver;
        addr.sin_family = AF_INET;
        addr.sin_port = htons(port);

        import std.string : toStringz;
        uint uiaddr = ntohl(inet_addr(address.toStringz()));
        if (INADDR_NONE == uiaddr) {
            throw new Exception(
                "bad listening host given, please use an IP address."
            );
        }

        addr.sin_addr.s_addr = htonl(uiaddr);
    }
    void submit(ref SubmissionEntry entry) @safe nothrow {
        entry.prepConnect(fd, addr);
    }
    void complete(const ref CompletionEntry entry) @safe nothrow {
        if (entry.res >= 0) {
            receiver.setValueOrError(cast(socket_t)entry.res);
        } else {
            receiver.setErrno("Connect failed", -entry.res);
        }
    }
}

struct WriteSender {
    import std.socket : socket_t;
    alias Value = int;
    shared IOUringContext* context;
    socket_t fd;
    const(ubyte)[] buffer;
    long offset;
    auto connect(Receiver)(return Receiver receiver) @safe return scope {
        // ensure NRVO
        auto op = CancellableOperation!(WriteOperation!Receiver)(
            context,
            WriteOperation!(Receiver)(fd, buffer, offset, receiver)
        );
        return op;
    }
}

struct WriteOperation(Receiver) {
    import std.socket : socket_t;
    socket_t fd;
    const(ubyte)[] buffer;
    long offset;
    Receiver receiver;
    void submit(ref SubmissionEntry entry) @safe nothrow {
        entry.prepWrite(fd, buffer, offset);
    }
    void complete(const ref CompletionEntry entry) @safe nothrow {
        if (entry.res > 0) {
            receiver.setValueOrError(entry.res);
        } else if (entry.res == 0) {
            receiver.setDone();
        } else {
            receiver.setErrno("Write failed", -entry.res);
        }
    }
}

struct CloseSender {
    import std.socket : socket_t;
    alias Value = void;
    shared IOUringContext* context;
    socket_t fd;
    auto connect(Receiver)(return Receiver receiver) @safe return scope {
        // ensure NRVO
        auto op = CancellableOperation!(CloseOperation!Receiver)(
            context,
            CloseOperation!(Receiver)(fd, receiver)
        );
        return op;
    }
}

struct CloseOperation(Receiver) {
    import std.socket : socket_t;
    socket_t fd;
    Receiver receiver;
    void submit(ref SubmissionEntry entry) @safe nothrow {
        entry.prepClose(fd);
    }
    void complete(const ref CompletionEntry entry) @safe nothrow {
        if (entry.res >= 0) {
            receiver.setValueOrError();
        } else {
            receiver.setErrno("Close failed", -entry.res);
        }
    }
}

struct NopSender {
    alias Value = int;
    shared IOUringContext* context;
    auto connect(Receiver)(return Receiver receiver) @safe return scope {
        // ensure NRVO
        auto op = CancellableOperation!(NopOperation!Receiver)(
            context,
            NopOperation!(Receiver)(receiver)
        );
        return op;
    }
}

struct NopOperation(Receiver) {
    Receiver receiver;
    void submit(ref SubmissionEntry entry) @safe nothrow {
        entry.prepNop();
    }
    void complete(const ref CompletionEntry entry) @safe nothrow {
        if (entry.res >= 0) {
            receiver.setValueOrError(entry.res);
        } else {
            receiver.setErrno("Nop failed", -entry.res);
        }
    }
}
