/**
 * Simple idiomatic dlang wrapper around linux io_uring
 * (see: https://kernel.dk/io_uring.pdf) asynchronous API.
 */
module during;

version(linux):

public import during.io_uring;
import during.openat2;

import core.atomic : MemoryOrder;
debug import core.stdc.stdio;
import core.stdc.stdlib;
import core.sys.linux.epoll;
import core.sys.linux.errno;
import core.sys.linux.sched;
import core.sys.linux.sys.mman;
import core.sys.linux.unistd;
import core.sys.posix.fcntl;
import core.sys.posix.signal;
import core.sys.posix.sys.socket;
import core.sys.posix.sys.types;
import core.sys.posix.sys.uio;
import std.algorithm.comparison : among;
import std.traits : Unqual;

nothrow @nogc:

/**
 * Setup new instance of io_uring into provided `Uring` structure.
 *
 * Params:
 *     uring = `Uring` structure to be initialized (must not be already initialized)
 *     entries = Number of entries to initialize uring with
 *     flags = `SetupFlags` to use to initialize uring.
 *
 * Returns: On succes it returns 0, `-errno` otherwise.
 */
int setup(ref Uring uring, uint entries = 128, SetupFlags flags = SetupFlags.NONE) @safe
{
    SetupParameters params;
    params.flags = flags;
    return setup(uring, entries, params);
}

/**
 * Setup new instance of io_uring into provided `Uring` structure.
 *
 * Params:
 *     uring = `Uring` structure to be initialized (must not be already initialized)
 *     entries = Number of entries to initialize uring with
 *     params = `SetupParameters` to use to initialize uring.
 *
 * Returns: On succes it returns 0, `-errno` otherwise.
 */
int setup(ref Uring uring, uint entries, ref const SetupParameters params) @safe
{
    assert(uring.payload is null, "Uring is already initialized");
    uring.payload = () @trusted { return cast(UringDesc*)calloc(1, UringDesc.sizeof); }();
    if (uring.payload is null) return -errno;

    uring.payload.params = params;
    uring.payload.refs = 1;
    auto r = io_uring_setup(entries, uring.payload.params);
    if (r < 0) return -errno;

    uring.payload.fd = r;

    r = uring.payload.mapRings();
    if (r < 0)
    {
        dispose(uring);
        return r;
    }

    // debug printf("uring(%d): setup\n", uring.payload.fd);

    return 0;
}

/**
 * Simplified wrapper around `io_uring_probe` that is used to check what io_uring operations current
 * kernel is actually supporting.
 */
struct Probe
{
    static assert (Operation.max < 64, "Needs to be adjusted");
    private
    {
        io_uring_probe probe;
        io_uring_probe_op[64] ops;
        int err;
    }

    const @safe pure nothrow @nogc:

    /// Is operation supported?
    bool isSupported(Operation op)
    in (op <= Operation.max, "Invalid operation")
    {
        if (op > probe.last_op) return false;
        assert(ops[op].op == op, "Operations differs");
        return (ops[op].flags & IO_URING_OP_SUPPORTED) != 0;
    }

    /// Error code when we fail to get `Probe`.
    @property int error() { return err; }

    /// `true` if probe was sucesfully retrieved.
    T opCast(T)() if (is(T == bool)) { return err == 0; }
}

/// Probes supported operations on a temporary created uring instance
Probe probe() @safe nothrow @nogc
{
    Uring io;
    immutable ret = io.setup(2);
    if (ret < 0) {
        Probe res;
        res.err = ret;
        return res;
    }

    return io.probe();
}

/**
 * Main entry point to work with io_uring.
 *
 * It hides `SubmissionQueue` and `CompletionQueue` behind standard range interface.
 * We put in `SubmissionEntry` entries and take out `CompletionEntry` entries.
 *
 * Use predefined `prepXX` methods to fill required fields of `SubmissionEntry` before `put` or during `putWith`.
 *
 * Note: `prepXX` functions doesn't touch previous entry state, just fills in operation properties. This is because for
 * less error prone interface it is cleared automatically when prepared using `putWith`. So when using on own `SubmissionEntry`
 * (outside submission queue), that would be added to the submission queue using `put`, be sure its cleared if it's
 * reused for multiple operations.
 */
struct Uring
{
    nothrow @nogc:

    private UringDesc* payload;

    /// Copy constructor
    this(ref return scope Uring rhs) @safe pure
    {
        assert(rhs.payload !is null, "rhs payload is null");
        // debug printf("uring(%d): copy\n", rhs.payload.fd);
        this.payload = rhs.payload;
        this.payload.refs++;
    }

    /// Destructor
    ~this() @safe
    {
        dispose(this);
    }

    /// Probes supported operations
    Probe probe() @safe
    in (payload !is null, "Uring hasn't been initialized yet")
    {
        Probe res;
        immutable ret = () @trusted { return io_uring_register(
            payload.fd,
            RegisterOpCode.REGISTER_PROBE,
            cast(void*)&res.probe, res.ops.length
        ); }();
        if (ret < 0) res.err = ret;
        return res;
    }

    /// Native io_uring file descriptor
    int fd() const @safe pure
    in (payload !is null, "Uring hasn't been initialized yet")
    {
        return payload.fd;
    }

    /// io_uring parameters
    SetupParameters params() const @safe pure return
    in (payload !is null, "Uring hasn't been initialized yet")
    {
        return payload.params;
    }

    /// Check if there is some `CompletionEntry` to process.
    bool empty() const @safe pure
    in (payload !is null, "Uring hasn't been initialized yet")
    {
        return payload.cq.empty;
    }

    /// Check if there is space for another `SubmissionEntry` to submit.
    bool full() const @safe pure
    in (payload !is null, "Uring hasn't been initialized yet")
    {
        return payload.sq.full;
    }

    /// Available space in submission queue before it becomes full
    size_t capacity() const @safe pure
    in (payload !is null, "Uring hasn't been initialized yet")
    {
        return payload.sq.capacity;
    }

    /// Number of entries in completion queue
    size_t length() const @safe pure
    in (payload !is null, "Uring hasn't been initialized yet")
    {
        return payload.cq.length;
    }

    /// Get first `CompletionEntry` from cq ring
    ref CompletionEntry front() @safe pure return
    in (payload !is null, "Uring hasn't been initialized yet")
    {
        return payload.cq.front;
    }

    /// Move to next `CompletionEntry`
    void popFront() @safe pure
    in (payload !is null, "Uring hasn't been initialized yet")
    {
        return payload.cq.popFront;
    }

    /**
     * Adds new entry to the `SubmissionQueue`.
     *
     * Note that this just adds entry to the queue and doesn't advance the tail
     * marker kernel sees. For that `finishSq()` is needed to be called next.
     *
     * Also note that to actually enter new entries to kernel,
     * it's needed to call `submit()`.
     *
     * Params:
     *     FN    = Function to fill next entry in queue by `ref` (should be faster).
     *             It is expected to be in a form of `void function(ARGS)(ref SubmissionEntry, auto ref ARGS)`.
     *             Note that in this case queue entry is cleaned first before function is called.
     *     entry = Custom built `SubmissionEntry` to be posted as is.
     *             Note that in this case it is copied whole over one in the `SubmissionQueue`.
     *     args  = Optional arguments passed to the function
     *
     * Returns: reference to `Uring` structure so it's possible to chain multiple commands.
     */
    ref Uring put()(auto ref SubmissionEntry entry) @safe pure return
    in (payload !is null, "Uring hasn't been initialized yet")
    {
        payload.sq.put(entry);
        return this;
    }

    /// ditto
    ref Uring putWith(alias FN, ARGS...)(auto ref ARGS args) return
    in (payload !is null, "Uring hasn't been initialized yet")
    {
        import std.functional : forward;
        payload.sq.putWith!FN(forward!args);
        return this;
    }

    /**
     * Similar to `put(SubmissionEntry)` but in this case we can provide our custom type (args) to be filled
     * to next `SubmissionEntry` in queue.
     *
     * Fields in the provided type must use the same names as in `SubmissionEntry` to be automagically copied.
     *
     * Params:
     *   op = Custom operation definition.
     * Returns:
     */
    ref Uring put(OP)(auto ref OP op) return
        if (!is(OP == SubmissionEntry))
    in (payload !is null, "Uring hasn't been initialized yet")
    {
        payload.sq.put(op);
        return this;
    }

    /**
     * Advances the userspace submision queue and returns last `SubmissionEntry`.
     */
    ref SubmissionEntry next()() @safe pure
    in (payload !is null, "Uring hasn't been initialized yet")
    {
        return payload.sq.next();
    }

    /**
     * If completion queue is full, the new event maybe dropped.
     * This value records number of dropped events.
     */
    uint overflow() const @safe pure
    in (payload !is null, "Uring hasn't been initialized yet")
    {
        return payload.cq.overflow;
    }

    /// Counter of invalid submissions (out-of-bound index in submission array)
    uint dropped() const @safe pure
    in (payload !is null, "Uring hasn't been initialized yet")
    {
        return payload.sq.dropped;
    }

    /**
     * Submits qued `SubmissionEntry` to be processed by kernel.
     *
     * Params:
     *     want  = number of `CompletionEntries` to wait for.
     *             If 0, this just submits queued entries and returns.
     *             If > 0, it blocks until at least wanted number of entries were completed.
     *     sig   = See io_uring_enter(2) man page
     *
     * Returns: Number of submitted entries on success, `-errno` on error
     */
    int submit(S)(uint want, const scope S* args)
        if (is(S == sigset_t) || is(S == io_uring_getevents_arg))
    in (payload !is null, "Uring hasn't been initialized yet")
    {
        if (_expect(want > 0, false)) return submitAndWait(want, args);
        return submit(args);
    }

    /// ditto
    int submit(uint want) @safe
    {
        pragma(inline, true)
        if (_expect(want > 0, true)) return submitAndWait(want, cast(sigset_t*)null);
        return submit(cast(sigset_t*)null);
    }

    /// ditto
    int submit(S)(const scope S* args) @trusted
        if (is(S == sigset_t) || is(S == io_uring_getevents_arg))
    in (payload !is null, "Uring hasn't been initialized yet")
    {
        immutable len = cast(int)payload.sq.length;
        if (_expect(len > 0, true)) // anything to submit?
        {
            payload.sq.flushTail(); // advance queue index

            EnterFlags flags;
            if (payload.params.flags & SetupFlags.SQPOLL)
            {
                if (_expect(payload.sq.flags & SubmissionQueueFlags.NEED_WAKEUP, false))
                    flags |= EnterFlags.SQ_WAKEUP;
                else return len; // fast poll
            }
            static if (is(S == io_uring_getevents_arg))
                flags |= EnterFlags.EXT_ARG;
            immutable r = io_uring_enter(payload.fd, len, 0, flags, args);
            if (_expect(r < 0, false)) return -errno;
            return r;
        }
        return 0;
    }

    /// ditto
    int submit() @safe
    {
        pragma(inline, true)
        return submit(cast(sigset_t*)null);
    }

    /**
     * Flushes submission queue index to the kernel.
     * Doesn't call any syscall, it just advances the SQE queue for kernel.
     * This can be used with `IORING_SETUP_SQPOLL` when kernel polls the submission queue.
     */
    void flush() @safe
    {
        payload.sq.flushTail(); // advance queue index
    }

    /**
     * Simmilar to `submit` but with this method we just wait for required number
     * of `CompletionEntries`.
     *
     * Returns: `0` on success, `-errno` on error
     */
    int wait(S)(uint want = 1, const scope S* args = null) @trusted
        if (is(S == sigset_t) || is(S == io_uring_getevents_arg))
    in (payload !is null, "Uring hasn't been initialized yet")
    in (want > 0, "Invalid want value")
    {
        pragma(inline);
        if (payload.cq.length >= want) return 0; // we don't need to syscall
        EnterFlags flags = EnterFlags.GETEVENTS;
        static if (is(S == io_uring_getevents_arg))
            flags |= EnterFlags.EXT_ARG;
        immutable r = io_uring_enter(payload.fd, 0, want, flags, args);
        if (_expect(r < 0, false)) return -errno;
        return 0;
    }

    /// ditto
    int wait(uint want = 1)
    {
        pragma(inline, true)
        return wait(want, cast(sigset_t*)null);
    }

    /**
     * Special case of a `submit` that can be used when we know beforehead that we want to wait for
     * some amount of CQEs.
     */
    int submitAndWait(S)(uint want, const scope S* args) @trusted
        if (is(S == sigset_t) || is(S == io_uring_getevents_arg))
    in (payload !is null, "Uring hasn't been initialized yet")
    in (want > 0, "Invalid want value")
    {
        immutable len = cast(int)payload.sq.length;
        if (_expect(len > 0, true)) // anything to submit?
        {
            payload.sq.flushTail(); // advance queue index

            EnterFlags flags = EnterFlags.GETEVENTS;
            if (payload.params.flags & SetupFlags.SQPOLL)
            {
                if (_expect(payload.sq.flags & SubmissionQueueFlags.NEED_WAKEUP, false))
                    flags |= EnterFlags.SQ_WAKEUP;
            }
            static if (is(S == io_uring_getevents_arg))
                flags |= EnterFlags.EXT_ARG;

            immutable r = io_uring_enter(payload.fd, len, want, flags, args);
            if (_expect(r < 0, false)) return -errno;
            return r;
        }
        return wait(want); // just simple wait
    }

    /// ditto
    int submitAndWait(uint want) @safe
    {
        pragma(inline, true)
        return submitAndWait(want, cast(sigset_t*)null);
    }

    /**
     * Register single buffer to be mapped into the kernel for faster buffered operations.
     *
     * To use the buffers, the application must specify the fixed variants for of operations,
     * `READ_FIXED` or `WRITE_FIXED` in the `SubmissionEntry` also with used `buf_index` set
     * in entry extra data.
     *
     * An application can increase or decrease the size or number of registered buffers by first
     * unregistering the existing buffers, and then issuing a new call to io_uring_register() with
     * the new buffers.
     *
     * Params:
     *   buffer = Buffers to be registered
     *
     * Returns: On success, returns 0. On error, `-errno` is returned.
     */
    int registerBuffers(T)(T buffers)
        if (is(T == ubyte[]) || is(T == ubyte[][])) // TODO: something else?
    in (payload !is null, "Uring hasn't been initialized yet")
    in (buffers.length, "Empty buffer")
    {
        if (payload.regBuffers !is null)
            return -EBUSY; // buffers were already registered

        static if (is(T == ubyte[]))
        {
            auto p = malloc(iovec.sizeof);
            if (_expect(p is null, false)) return -errno;
            payload.regBuffers = (cast(iovec*)p)[0..1];
            payload.regBuffers[0].iov_base = cast(void*)&buffers[0];
            payload.regBuffers[0].iov_len = buffers.length;
        }
        else static if (is(T == ubyte[][]))
        {
            auto p = malloc(buffers.length * iovec.sizeof);
            if (_expect(p is null, false)) return -errno;
            payload.regBuffers = (cast(iovec*)p)[0..buffers.length];

            foreach (i, b; buffers)
            {
                assert(b.length, "Empty buffer");
                payload.regBuffers[i].iov_base = cast(void*)&b[0];
                payload.regBuffers[i].iov_len = b.length;
            }
        }

        immutable r = io_uring_register(
                payload.fd,
                RegisterOpCode.REGISTER_BUFFERS,
                cast(const(void)*)payload.regBuffers.ptr, 1
            );

        if (_expect(r < 0, false)) return -errno;
        return 0;
    }

    /**
     * Releases all previously registered buffers associated with the `io_uring` instance.
     *
     * An application need not unregister buffers explicitly before shutting down the io_uring instance.
     *
     * Returns: On success, returns 0. On error, `-errno` is returned.
     */
    int unregisterBuffers() @trusted
    in (payload !is null, "Uring hasn't been initialized yet")
    {
        if (payload.regBuffers is null)
            return -ENXIO; // no buffers were registered

        free(cast(void*)&payload.regBuffers[0]);
        payload.regBuffers = null;

        immutable r = io_uring_register(payload.fd, RegisterOpCode.UNREGISTER_BUFFERS, null, 0);
        if (_expect(r < 0, false)) return -errno;
        return 0;
    }

    /**
     * Register files for I/O.
     *
     * To make use of the registered files, the `IOSQE_FIXED_FILE` flag must be set in the flags
     * member of the `SubmissionEntry`, and the `fd` member is set to the index of the file in the
     * file descriptor array.
     *
     * Files are automatically unregistered when the `io_uring` instance is torn down. An application
     * need only unregister if it wishes to register a new set of fds.
     *
     * Use `-1` as a file descriptor to mark it as reserved in the array.*
     * Params: fds = array of file descriptors to be registered
     *
     * Returns: On success, returns 0. On error, `-errno` is returned.
     */
    int registerFiles(const(int)[] fds)
    in (payload !is null, "Uring hasn't been initialized yet")
    in (fds.length, "No file descriptors provided")
    in (fds.length < uint.max, "Too many file descriptors")
    {
        // arg contains a pointer to an array of nr_args file descriptors (signed 32 bit integers).
        immutable r = io_uring_register(payload.fd, RegisterOpCode.REGISTER_FILES, &fds[0], cast(uint)fds.length);
        if (_expect(r < 0, false)) return -errno;
        return 0;
    }

    /*
     * Register an update for an existing file set. The updates will start at
     * `off` in the original array.
     *
     * Use `-1` as a file descriptor to mark it as reserved in the array.
     *
     * Params:
     *      off = offset to the original registered files to be updated
     *      files = array of file descriptors to update with
     *
     * Returns: number of files updated on success, -errno on failure.
     */
    int registerFilesUpdate(uint off, const(int)[] fds) @trusted
    in (payload !is null, "Uring hasn't been initialized yet")
    in (fds.length, "No file descriptors provided to update")
    in (fds.length < uint.max, "Too many file descriptors")
    {
        struct Update // represents io_uring_files_update (obsolete) or io_uring_rsrc_update
        {
            uint offset;
            uint _resv;
            ulong data;
        }

        static assert (Update.sizeof == 16);

        Update u = { offset: off, data: cast(ulong)&fds[0] };
        immutable r = io_uring_register(
            payload.fd,
            RegisterOpCode.REGISTER_FILES_UPDATE,
            &u, cast(uint)fds.length);
        if (_expect(r < 0, false)) return -errno;
        return 0;
    }

    /**
     * All previously registered files associated with the `io_uring` instance will be unregistered.
     *
     * Files are automatically unregistered when the `io_uring` instance is torn down. An application
     * need only unregister if it wishes to register a new set of fds.
     *
     * Returns: On success, returns 0. On error, `-errno` is returned.
     */
    int unregisterFiles() @trusted
    in (payload !is null, "Uring hasn't been initialized yet")
    {
        immutable r = io_uring_register(payload.fd, RegisterOpCode.UNREGISTER_FILES, null, 0);
        if (_expect(r < 0, false)) return -errno;
        return 0;
    }

    /**
     * Registers event file descriptor that would be used as a notification mechanism on completion
     * queue change.
     *
     * Params: eventFD = event filedescriptor to be notified about change
     *
     * Returns: On success, returns 0. On error, `-errno` is returned.
     */
    int registerEventFD(int eventFD) @trusted
    in (payload !is null, "Uring hasn't been initialized yet")
    {
        immutable r = io_uring_register(payload.fd, RegisterOpCode.REGISTER_EVENTFD, &eventFD, 1);
        if (_expect(r < 0, false)) return -errno;
        return 0;
    }

    /**
     * Unregister previously registered notification event file descriptor.
     *
     * Returns: On success, returns 0. On error, `-errno` is returned.
     */
    int unregisterEventFD() @trusted
    in (payload !is null, "Uring hasn't been initialized yet")
    {
        immutable r = io_uring_register(payload.fd, RegisterOpCode.UNREGISTER_EVENTFD, null, 0);
        if (_expect(r < 0, false)) return -errno;
        return 0;
    }

    /**
     * Generic means to register resources.
     *
     * Note: Available from Linux 5.13
     */
    int registerRsrc(R)(RegisterOpCode type, const(R)[] data, const(ulong)[] tags)
    in (payload !is null, "Uring hasn't been initialized yet")
    in (data.length == tags.length, "Different array lengths")
    in (data.length < uint.max, "Too many resources")
    {
        struct Register // represents io_uring_rsrc_register
        {
            uint nr;
            uint flags;
            ulong _resv2;
            ulong data;
            ulong tags;
        }

        static assert (Register.sizeof == 32);

        Register r = {
            nr: cast(uint)data.length,
            data: cast(ulong)&data[0],
            tags: cast(ulong)&tags[0]
        };
        immutable ret = io_uring_register(
            payload.fd,
            type,
            &r, sizeof(r));
        if (_expect(ret < 0, false)) return -errno;
        return 0;
    }

    /**
     * Generic means to update registered resources.
     *
     * Note: Available from Linux 5.13
     */
    int registerRsrcUpdate(R)(RegisterOpCode type, uint off, const(R)[] data, const(ulong)[] tags) @trusted
    in (payload !is null, "Uring hasn't been initialized yet")
    in (data.length == tags.length, "Different array lengths")
    in (data.length < uint.max, "Too many file descriptors")
    {
        struct Update // represents io_uring_rsrc_update2
        {
            uint offset;
            uint _resv;
            ulong data;
            ulong tags;
            uint nr;
            uint _resv2;
        }

        static assert (Update.sizeof == 32);

        Update u = {
            offset: off,
            data: cast(ulong)&data[0],
            tags: cast(ulong)&tags[0],
            nr: cast(uint)data.length,
        };
        immutable r = io_uring_register(payload.fd, type, &u, sizeof(u));
        if (_expect(r < 0, false)) return -errno;
        return 0;
    }

    /**
     * Register a feature whitelist. Attempting to call any operations which are not whitelisted
     * will result in an error.
     *
     * Note: Can only be called once to prevent other code from bypassing the whitelist.
     *
     * Params: res = the struct containing the restriction info.
     *
     * Returns: On success, returns 0. On error, `-errno` is returned.
     *
     * Note: Available from Linux 5.10
     */
    int registerRestrictions(scope ref io_uring_restriction res) @trusted
    in (payload !is null, "Uring hasn't been initialized yet")
    {
        immutable r = io_uring_register(payload.fd, RegisterOpCode.REGISTER_RESTRICTIONS, &res, 1);
        if (_expect(r < 0, false)) return -errno;
        return 0;
    }

    /**
     * Enable the "rings" of this Uring if they were previously disabled with
     * `IORING_SETUP_R_DISABLED`.
     *
     * Returns: On success, returns 0. On error, `-errno` is returned.
     *
     * Note: Available from Linux 5.10
     */
    int enableRings() @trusted
    in (payload !is null, "Uring hasn't been initialized yet")
    {
        immutable r = io_uring_register(payload.fd, RegisterOpCode.ENABLE_RINGS, null, 0);
        if (_expect(r < 0, false)) return -errno;
        return 0;
    }

    /**
     * By default, async workers created by io_uring will inherit the CPU mask of its parent. This
     * is usually all the CPUs in the system, unless the parent is being run with a limited set. If
     * this isn't the desired outcome, the application may explicitly tell io_uring what CPUs the
     * async workers may run on.
     *
     * Note: Available since 5.14.
     */
    int registerIOWQAffinity(cpu_set_t[] cpus) @trusted
    in (cpus.length)
    {
        immutable r = io_uring_register(payload.fd, RegisterOpCode.REGISTER_IOWQ_AFF, cpus.ptr, cast(uint)cpus.length);
        if (_expect(r < 0, false)) return -errno;
        return 0;
    }

    /**
     * Undoes a CPU mask previously set with `registerIOWQAffinity`.
     *
     * Note: Available since 5.14
     */
    int unregisterIOWQAffinity() @trusted
    {
        immutable r = io_uring_register(payload.fd, RegisterOpCode.UNREGISTER_IOWQ_AFF, null, 0);
        if (_expect(r < 0, false)) return -errno;
        return 0;
    }

    /**
     * By default, io_uring limits the unbounded workers created to the maximum processor count set
     * by `RLIMIT_NPROC` and the bounded workers is a function of the SQ ring size and the number of
     * CPUs in the system. Sometimes this can be excessive (or too little, for bounded), and this
     * command provides a way to change the count per ring (per NUMA node) instead.
     *
     * `val` must be set to an `uint` pointer to an array of two values, with the values in the
     * array being set to the maximum count of workers per NUMA node. Index 0 holds the bounded
     * worker count, and index 1 holds the unbounded worker count. On successful return, the passed
     * in array will contain the previous maximum values for each type. If the count being passed in
     * is 0, then this command returns the current maximum values and doesn't modify the current
     * setting.
     *
     * Note: Available since 5.15
     */
    int registerIOWQMaxWorkers(ref uint[2] workers) @trusted
    {
        immutable r = io_uring_register(payload.fd, RegisterOpCode.REGISTER_IOWQ_MAX_WORKERS, &workers, 2);
        if (_expect(r < 0, false)) return -errno;
        return 0;
    }
}

/**
 * Uses custom operation definition to fill fields of `SubmissionEntry`.
 * Can be used in cases, when builtin prep* functions aren't enough.
 *
 * Custom definition fields must correspond to fields of `SubmissionEntry` for this to work.
 *
 * Note: This doesn't touch previous state of the entry, just fills the corresponding fields.
 *       So it might be needed to call `clear` first on the entry (depends on usage).
 *
 * Params:
 *   entry = entry to set parameters to
 *   op = operation to fill entry with (can be custom type)
 */
ref SubmissionEntry fill(E)(return ref SubmissionEntry entry, auto ref E op)
{
    pragma(inline);
    import std.traits : hasMember, FieldNameTuple;

    // fill entry from provided operation fields (they must have same name as in SubmissionEntry)
    foreach (m; FieldNameTuple!E)
    {
        static assert(hasMember!(SubmissionEntry, m), "unknown member: " ~ E.stringof ~ "." ~ m);
        __traits(getMember, entry, m) = __traits(getMember, op, m);
    }

    return entry;
}

/**
 * Template function to help set `SubmissionEntry` `user_data` field.
 *
 * Params:
 *      entry = `SubmissionEntry` to prepare
 *      data = data to set to the `SubmissionEntry`
 *
 * Note: data are passed by ref and must live during whole operation.
 */
ref SubmissionEntry setUserData(D)(return ref SubmissionEntry entry, ref D data) @trusted
{
    pragma(inline);
    entry.user_data = cast(ulong)(cast(void*)&data);
    return entry;
}

/**
 * Template function to help set `SubmissionEntry` `user_data` field. This differs to `setUserData`
 * in that it emplaces the provided data directly into SQE `user_data` field and not the pointer to
 * the data.
 *
 * Because of that, data must be of `ulong.sizeof`.
 */
ref SubmissionEntry setUserDataRaw(D)(return ref SubmissionEntry entry, auto ref D data) @trusted
    if (D.sizeof == ulong.sizeof)
{
    pragma(inline);
    entry.user_data = *(cast(ulong*)(cast(void*)&data));
    return entry;
}

/**
 * Helper function to retrieve data set directly to the `CompletionEntry` user_data (set by `setUserDataRaw`).
 */
D userDataAs(D)(ref CompletionEntry entry) @trusted
    if (D.sizeof == ulong.sizeof)
{
    pragma(inline);
    return *(cast(D*)(cast(void*)&entry.user_data));
}

ref SubmissionEntry prepRW(return ref SubmissionEntry entry, Operation op,
    int fd = -1, const void* addr = null, uint len = 0, ulong offset = 0) @safe
{
    pragma(inline);
    entry.opcode = op;
    entry.fd = fd;
    entry.off = offset;
    entry.flags = SubmissionEntryFlags.NONE;
    entry.ioprio = 0;
    entry.addr = cast(ulong)addr;
    entry.len = len;
    entry.rw_flags = ReadWriteFlags.NONE;
	entry.user_data = 0;
    entry.buf_index = 0;
    entry.personality = 0;
    entry.file_index = 0;
    entry.addr3 = 0;
    entry.__pad2[0] = 0;
    return entry;
}

/**
 * Prepares `nop` operation.
 *
 * Params:
 *      entry = `SubmissionEntry` to prepare
 */
ref SubmissionEntry prepNop(return ref SubmissionEntry entry) @safe
{
    entry.prepRW(Operation.NOP);
    return entry;
}

/**
 * Prepares `readv` operation.
 *
 * Params:
 *      entry = `SubmissionEntry` to prepare
 *      fd = file descriptor of file we are operating on
 *      offset = offset
 *      buffer = iovec buffers to be used by the operation
 */
ref SubmissionEntry prepReadv(V)(return ref SubmissionEntry entry, int fd, ref const V buffer, long offset) @trusted
    if (is(V == iovec[]) || is(V == iovec))
{
    static if (is(V == iovec[]))
    {
        assert(buffer.length, "Empty buffer");
        assert(buffer.length < uint.max, "Too many iovec buffers");
        return entry.prepRW(Operation.READV, fd, cast(void*)&buffer[0], cast(uint)buffer.length, offset);
    }
    else return entry.prepRW(Operation.READV, fd, cast(void*)&buffer, 1, offset);
}

/**
 * Prepares `writev` operation.
 *
 * Params:
 *      entry = `SubmissionEntry` to prepare
 *      fd = file descriptor of file we are operating on
 *      offset = offset
 *      buffer = iovec buffers to be used by the operation
 */
ref SubmissionEntry prepWritev(V)(return ref SubmissionEntry entry, int fd, ref const V buffer, long offset) @trusted
    if ((is(Unqual!V == U[], U) && is(Unqual!U == iovec)) || is(Unqual!V == iovec))
{
    static if (is(typeof(buffer.length)))
    {
        assert(buffer.length, "Empty buffer");
        assert(buffer.length < uint.max, "Too many iovec buffers");
        return entry.prepRW(Operation.WRITEV, fd, cast(void*)&buffer[0], cast(uint)buffer.length, offset);
    }
    else return entry.prepRW(Operation.WRITEV, fd, cast(void*)&buffer, 1, offset);
}

/**
 * Prepares `read_fixed` operation.
 *
 * Params:
 *      entry = `SubmissionEntry` to prepare
 *      fd = file descriptor of file we are operating on
 *      offset = offset
 *      buffer = slice to preregistered buffer
 *      bufferIndex = index to the preregistered buffers array buffer belongs to
 */
ref SubmissionEntry prepReadFixed(return ref SubmissionEntry entry, int fd, long offset, ubyte[] buffer, ushort bufferIndex) @safe
{
    assert(buffer.length, "Empty buffer");
    assert(buffer.length < uint.max, "Buffer too large");
    entry.prepRW(Operation.READ_FIXED, fd, cast(void*)&buffer[0], cast(uint)buffer.length, offset);
    entry.buf_index = bufferIndex;
    return entry;
}

/**
 * Prepares `write_fixed` operation.
 *
 * Params:
 *      entry = `SubmissionEntry` to prepare
 *      fd = file descriptor of file we are operating on
 *      offset = offset
 *      buffer = slice to preregistered buffer
 *      bufferIndex = index to the preregistered buffers array buffer belongs to
 */
ref SubmissionEntry prepWriteFixed(return ref SubmissionEntry entry, int fd, long offset, ubyte[] buffer, ushort bufferIndex) @safe
{
    assert(buffer.length, "Empty buffer");
    assert(buffer.length < uint.max, "Buffer too large");
    entry.prepRW(Operation.WRITE_FIXED, fd, cast(void*)&buffer[0], cast(uint)buffer.length, offset);
    entry.buf_index = bufferIndex;
    return entry;
}

/**
 * Prepares `recvmsg(2)` operation.
 *
 * Params:
 *      entry = `SubmissionEntry` to prepare
 *      fd = file descriptor of file we are operating on
 *      msg = message to operate with
 *      flags = `recvmsg` operation flags
 *
 * Note: Available from Linux 5.3
 *
 * See_Also: `recvmsg(2)` man page for details.
 */
ref SubmissionEntry prepRecvMsg(return ref SubmissionEntry entry, int fd, ref msghdr msg, MsgFlags flags = MsgFlags.NONE) @trusted
{
    entry.prepRW(Operation.RECVMSG, fd, cast(void*)&msg, 1, 0);
    entry.msg_flags = flags;
    return entry;
}

/**
 * Prepares `sendmsg(2)` operation.
 *
 * Params:
 *      entry = `SubmissionEntry` to prepare
 *      fd = file descriptor of file we are operating on
 *      msg = message to operate with
 *      flags = `sendmsg` operation flags
 *
 * Note: Available from Linux 5.3
 *
 * See_Also: `sendmsg(2)` man page for details.
 */
ref SubmissionEntry prepSendMsg(return ref SubmissionEntry entry, int fd, ref msghdr msg, MsgFlags flags = MsgFlags.NONE) @trusted
{
    entry.prepRW(Operation.SENDMSG, fd, cast(void*)&msg, 1, 0);
    entry.msg_flags = flags;
    return entry;
}

/**
 * Prepares `fsync` operation.
 *
 * Params:
 *      entry = `SubmissionEntry` to prepare
 *      fd = file descriptor of a file to call `fsync` on
 *      flags = `fsync` operation flags
 */
ref SubmissionEntry prepFsync(return ref SubmissionEntry entry, int fd, FsyncFlags flags = FsyncFlags.NORMAL) @safe
{
    entry.prepRW(Operation.FSYNC, fd);
    entry.fsync_flags = flags;
    return entry;
}

/**
 * Poll the fd specified in the submission queue entry for the events specified in the poll_events
 * field. Unlike poll or epoll without `EPOLLONESHOT`, this interface always works in one shot mode.
 * That is, once the poll operation is completed, it will have to be resubmitted.
 *
 * Params:
 *      entry = `SubmissionEntry` to prepare
 *      fd = file descriptor to poll
 *      events = events to poll on the FD
 *      flags = poll operation flags
 */
ref SubmissionEntry prepPollAdd(return ref SubmissionEntry entry,
    int fd, PollEvents events, PollFlags flags = PollFlags.NONE) @safe
{
    import std.system : endian, Endian;

    entry.prepRW(Operation.POLL_ADD, fd, null, flags);
    static if (endian == Endian.bigEndian)
        entry.poll_events32 = (events & 0x0000ffffUL) << 16 | (events & 0xffff0000) >> 16;
    else
        entry.poll_events32 = events;
    return entry;
}

/**
 * Remove an existing poll request. If found, the res field of the `CompletionEntry` will contain
 * `0`.  If not found, res will contain `-ENOENT`.
 *
 * Params:
 *      entry = `SubmissionEntry` to prepare
 *      userData = data with the previously issued poll operation
 */
ref SubmissionEntry prepPollRemove(D)(return ref SubmissionEntry entry, ref D userData) @trusted
{
    return entry.prepRW(Operation.POLL_REMOVE, -1, cast(void*)&userData);
}

/**
 * Allow events and user_data update of running poll requests.
 *
 * Note: available from Linux 5.13
 */
ref SubmissionEntry prepPollUpdate(U, V)(return ref SubmissionEntry entry,
    ref U oldUserData, ref V newUserData, PollEvents events = PollEvents.NONE) @trusted
{
    import std.system : endian, Endian;

    PollFlags flags;
    if (events != PollEvents.NONE) flags |= PollFlags.UPDATE_EVENTS;
    if (cast(void*)&oldUserData !is cast(void*)&newUserData) flags |= PollFlags.UPDATE_USER_DATA;

    entry.prepRW(
        Operation.POLL_REMOVE,
        -1,
        cast(void*)&oldUserData,
        flags,
        cast(ulong)cast(void*)&newUserData
    );
    static if (endian == Endian.bigEndian)
        entry.poll_events32 = (events & 0x0000ffffUL) << 16 | (events & 0xffff0000) >> 16;
    else
        entry.poll_events32 = events;
    return entry;
}

/**
 * Prepares `sync_file_range(2)` operation.
 *
 * Sync a file segment with disk, permits fine control when synchronizing the open file referred to
 * by the file descriptor fd with disk.
 *
 * If `len` is 0, then all bytes from `offset` through to the end of file are synchronized.
 *
 * Params:
 *      entry = `SubmissionEntry` to prepare
 *      fd = is the file descriptor to sync
 *      offset = the starting byte of the file range to be synchronized
 *      len = the length of the range to be synchronized, in bytes
 *      flags = the flags for the command.
 *
 * See_Also: `sync_file_range(2)` for the general description of the related system call.
 *
 * Note: available from Linux 5.2
 */
ref SubmissionEntry prepSyncFileRange(return ref SubmissionEntry entry, int fd, ulong offset, uint len,
    SyncFileRangeFlags flags = SyncFileRangeFlags.WRITE_AND_WAIT) @safe
{
    entry.prepRW(Operation.SYNC_FILE_RANGE, fd, null, len, offset);
    entry.sync_range_flags = flags;
    return entry;
}

/**
 * This command will register a timeout operation.
 *
 * A timeout will trigger a wakeup event on the completion ring for anyone waiting for events. A
 * timeout condition is met when either the specified timeout expires, or the specified number of
 * events have completed. Either condition will trigger the event. The request will complete with
 * `-ETIME` if the timeout got completed through expiration of the timer, or `0` if the timeout got
 * completed through requests completing on their own. If the timeout was cancelled before it
 * expired, the request will complete with `-ECANCELED`.
 *
 * Applications may delete existing timeouts before they occur with `TIMEOUT_REMOVE` operation.
 *
 * Params:
 *      entry = `SubmissionEntry` to prepare
 *      time = reference to `time64` data structure
 *      count = completion event count
 *      flags = define if it's a relative or absolute time
 *
 * Note: Available from Linux 5.4
 */
ref SubmissionEntry prepTimeout(return ref SubmissionEntry entry, ref KernelTimespec time,
    ulong count = 0, TimeoutFlags flags = TimeoutFlags.REL) @trusted
{
    entry.prepRW(Operation.TIMEOUT, -1, cast(void*)&time, 1, count);
    entry.timeout_flags = flags;
    return entry;
}

/**
 * Prepares operations to remove existing timeout registered using `TIMEOUT`operation.
 *
 * Attempt to remove an existing timeout operation. If the specified timeout request is found and
 * cancelled successfully, this request will terminate with a result value of `-ECANCELED`. If the
 * timeout request was found but expiration was already in progress, this request will terminate
 * with a result value of `-EALREADY`. If the timeout request wasn't found, the request will
 * terminate with a result value of `-ENOENT`.
 *
 * Params:
 *      entry = `SubmissionEntry` to prepare
 *      userData = user data provided with the previously issued timeout operation
 *
 * Note: Available from Linux 5.5
 */
ref SubmissionEntry prepTimeoutRemove(D)(return ref SubmissionEntry entry, ref D userData) @trusted
{
    return entry.prepRW(Operation.TIMEOUT_REMOVE, -1, cast(void*)&userData);
}

/**
 * Prepares operations to update existing timeout registered using `TIMEOUT`operation.
 *
 * Params:
 *      entry = `SubmissionEntry` to prepare
 *      userData = user data provided with the previously issued timeout operation
 *      time = reference to `time64` data structure with a new time spec
 *      flags = define if it's a relative or absolute time
 *
 * Note: Available from Linux 5.11
 */
ref SubmissionEntry prepTimeoutUpdate(D)(return ref SubmissionEntry entry,
    ref KernelTimespec time, ref D userData, TimeoutFlags flags) @trusted
{
    entry.prepRW(Operation.TIMEOUT_REMOVE, -1, cast(void*)&userData, 0, cast(ulong)(cast(void*)&time));
    entry.timeout_flags = flags | TimeoutFlags.UPDATE;
    return entry;
}

/**
 * Prepares `accept4(2)` operation.
 *
 * See_Also: `accept4(2)`` for the general description of the related system call.
 *
 * Params:
 *      entry = `SubmissionEntry` to prepare
 *      fd = socket file descriptor
 *      addr = reference to one of sockaddr structires to be filled with accepted client address
 *      addrlen = reference to addrlen field that would be filled with accepted client address length
 *
 * Note: Available from Linux 5.5
 */
ref SubmissionEntry prepAccept(ADDR)(return ref SubmissionEntry entry, int fd, ref ADDR addr, ref socklen_t addrlen,
    AcceptFlags flags = AcceptFlags.NONE) @trusted
{
    entry.prepRW(Operation.ACCEPT, fd, cast(void*)&addr, 0, cast(ulong)(cast(void*)&addrlen));
    entry.accept_flags = flags;
    return entry;
}

/**
 * Same as `prepAccept`, but fd is put directly into fixed file table on `fileIndex`.
 * Note: available from Linux 5.15
 */
ref SubmissionEntry prepAcceptDirect(ADDR)(return ref SubmissionEntry entry, int fd, ref ADDR addr, ref socklen_t addrlen,
    uint fileIndex, AcceptFlags flags = AcceptFlags.NONE) @trusted
{
    entry.prepRW(Operation.ACCEPT, fd, cast(void*)&addr, 0, cast(ulong)(cast(void*)&addrlen));
    entry.accept_flags = flags;
    entry.file_index = fileIndex+1;
    return entry;
}

/**
 * Prepares operation that cancels existing async work.
 *
 * This works with any read/write request, accept,send/recvmsg, etc. There’s an important
 * distinction to make here with the different kinds of commands. A read/write on a regular file
 * will generally be waiting for IO completion in an uninterruptible state. This means it’ll ignore
 * any signals or attempts to cancel it, as these operations are uncancellable. io_uring can cancel
 * these operations if they haven’t yet been started. If they have been started, cancellations on
 * these will fail. Network IO will generally be waiting interruptibly, and can hence be cancelled
 * at any time. The completion event for this request will have a result of 0 if done successfully,
 * `-EALREADY` if the operation is already in progress, and `-ENOENT` if the original request
 * specified cannot be found. For cancellation requests that return `-EALREADY`, io_uring may or may
 * not cause this request to be stopped sooner. For blocking IO, the original request will complete
 * as it originally would have. For IO that is cancellable, it will terminate sooner if at all
 * possible.
 *
 * Params:
 *      entry = `SubmissionEntry` to prepare
 *      userData = `user_data` field of the request that should be cancelled
 *
 * Note: Available from Linux 5.5
 */
ref SubmissionEntry prepCancel(D)(return ref SubmissionEntry entry, ref D userData, uint flags = 0) @trusted
{
    entry.prepRW(Operation.ASYNC_CANCEL, -1, cast(void*)&userData);
    entry.cancel_flags = cast(CancelFlags)flags;
    return entry;
}

/**
 * Prepares linked timeout operation.
 *
 * This request must be linked with another request through `IOSQE_IO_LINK` which is described below.
 * Unlike `IORING_OP_TIMEOUT`, `IORING_OP_LINK_TIMEOUT` acts on the linked request, not the completion
 * queue. The format of the command is otherwise like `IORING_OP_TIMEOUT`, except there's no
 * completion event count as it's tied to a specific request. If used, the timeout specified in the
 * command will cancel the linked command, unless the linked command completes before the
 * timeout. The timeout will complete with `-ETIME` if the timer expired and the linked request was
 * attempted cancelled, or `-ECANCELED` if the timer got cancelled because of completion of the linked
 * request.
 *
 * Note: Available from Linux 5.5
 *
 * Params:
 *      entry = `SubmissionEntry` to prepare
 *      time = time specification
 *      flags = define if it's a relative or absolute time
 */
ref SubmissionEntry prepLinkTimeout(return ref SubmissionEntry entry, ref KernelTimespec time, TimeoutFlags flags = TimeoutFlags.REL) @trusted
{
    entry.prepRW(Operation.LINK_TIMEOUT, -1, cast(void*)&time, 1, 0);
    entry.timeout_flags = flags;
    return entry;
}

/**
 * Note: Available from Linux 5.5
 */
ref SubmissionEntry prepConnect(ADDR)(return ref SubmissionEntry entry, int fd, ref const(ADDR) addr) @trusted
{
    return entry.prepRW(Operation.CONNECT, fd, cast(void*)&addr, 0, ADDR.sizeof);
}

/**
 * Note: Available from Linux 5.6
 */
ref SubmissionEntry prepFilesUpdate(return ref SubmissionEntry entry, int[] fds, int offset) @safe
{
    return entry.prepRW(Operation.FILES_UPDATE, -1, cast(void*)&fds[0], cast(uint)fds.length, offset);
}

/**
 * Note: Available from Linux 5.6
 */
ref SubmissionEntry prepFallocate(return ref SubmissionEntry entry, int fd, int mode, long offset, long len) @trusted
{
    return entry.prepRW(Operation.FALLOCATE, fd, cast(void*)len, mode, offset);
}

/**
 * Note: Available from Linux 5.6
 */
ref SubmissionEntry prepOpenat(return ref SubmissionEntry entry, int fd, const(char)* path, int flags, uint mode)
{
    entry.prepRW(Operation.OPENAT, fd, cast(void*)path, mode, 0);
    entry.open_flags = flags;
    return entry;
}

/**
 * Same as `prepOpenat`, but fd is put directly into fixed file table on `fileIndex`.
 * Note: available from Linux 5.15
 */
ref SubmissionEntry prepOpenatDirect(return ref SubmissionEntry entry, int fd, const(char)* path, int flags, uint mode, uint fileIndex)
{
    entry.prepRW(Operation.OPENAT, fd, cast(void*)path, mode, 0);
    entry.open_flags = flags;
    entry.file_index = fileIndex+1;
    return entry;
}

/**
 * Note: Available from Linux 5.6
 */
ref SubmissionEntry prepClose(return ref SubmissionEntry entry, int fd) @safe
{
    return entry.prepRW(Operation.CLOSE, fd);
}

/**
 * Same as `prepClose` but operation works directly with fd registered in fixed file table on index `fileIndex`.
 * Note: Available from Linux 5.15
 */
ref SubmissionEntry prepCloseDirect(return ref SubmissionEntry entry, int fd, uint fileIndex) @safe
{
    entry.prepRW(Operation.CLOSE, fd);
    entry.file_index = fileIndex+1;
    return entry;
}

/**
 * Note: Available from Linux 5.6
 */
ref SubmissionEntry prepRead(return ref SubmissionEntry entry, int fd, ubyte[] buffer, long offset) @safe
{
    return entry.prepRW(Operation.READ, fd, cast(void*)&buffer[0], cast(uint)buffer.length, offset);
}

/**
 * Note: Available from Linux 5.6
 */
ref SubmissionEntry prepWrite(return ref SubmissionEntry entry, int fd, const(ubyte)[] buffer, long offset) @trusted
{
    return entry.prepRW(Operation.WRITE, fd, cast(void*)&buffer[0], cast(uint)buffer.length, offset);
}

/**
 * Note: Available from Linux 5.6
 */
ref SubmissionEntry prepStatx(Statx)(return ref SubmissionEntry entry, int fd, const(char)* path,
    int flags, uint mask, ref Statx statxbuf)
{
    entry.prepRW(Operation.STATX, fd, cast(void*)path, mask, cast(ulong)(cast(void*)&statxbuf));
    entry.statx_flags = flags;
    return entry;
}

/**
 * Note: Available from Linux 5.6
 */
ref SubmissionEntry prepFadvise(return ref SubmissionEntry entry, int fd, long offset, uint len, int advice) @safe
{
    entry.prepRW(Operation.FADVISE, fd, null, len, offset);
    entry.fadvise_advice = advice;
    return entry;
}

/**
 * Note: Available from Linux 5.6
 */
ref SubmissionEntry prepMadvise(return ref SubmissionEntry entry, const(ubyte)[] block, int advice) @trusted
{
    entry.prepRW(Operation.MADVISE, -1, cast(void*)&block[0], cast(uint)block.length, 0);
    entry.fadvise_advice = advice;
    return entry;
}

/**
 * Note: Available from Linux 5.6
 */
ref SubmissionEntry prepSend(return ref SubmissionEntry entry,
    int sockfd, const(ubyte)[] buf, MsgFlags flags = MsgFlags.NONE) @trusted
{
    entry.prepRW(Operation.SEND, sockfd, cast(void*)&buf[0], cast(uint)buf.length, 0);
    entry.msg_flags = flags;
    return entry;
}

/**
 * Note: Available from Linux 5.6
 */
ref SubmissionEntry prepRecv(return ref SubmissionEntry entry,
    int sockfd, ubyte[] buf, MsgFlags flags = MsgFlags.NONE) @trusted
{
    entry.prepRW(Operation.RECV, sockfd, cast(void*)&buf[0], cast(uint)buf.length, 0);
    entry.msg_flags = flags;
    return entry;
}

/**
 * Variant that uses registered buffers group.
 *
 * Note: Available from Linux 5.6
 */
ref SubmissionEntry prepRecv(return ref SubmissionEntry entry,
    int sockfd, ushort gid, uint len, MsgFlags flags = MsgFlags.NONE) @safe
{
    entry.prepRW(Operation.RECV, sockfd, null, len, 0);
    entry.msg_flags = flags;
    entry.buf_group = gid;
    entry.flags |= SubmissionEntryFlags.BUFFER_SELECT;
    return entry;
}

/**
 * Note: Available from Linux 5.6
 */
ref SubmissionEntry prepOpenat2(return ref SubmissionEntry entry, int fd, const char *path, ref OpenHow how) @trusted
{
    return entry.prepRW(Operation.OPENAT2, fd, cast(void*)path, cast(uint)OpenHow.sizeof, cast(ulong)(cast(void*)&how));
}

/**
 * Same as `prepOpenat2`, but fd is put directly into fixed file table on `fileIndex`.
 * Note: available from Linux 5.15
 */
 ref SubmissionEntry prepOpenat2Direct(return ref SubmissionEntry entry, int fd, const char *path, ref OpenHow how, uint fileIndex) @trusted
{
    entry.prepRW(Operation.OPENAT2, fd, cast(void*)path, cast(uint)OpenHow.sizeof, cast(ulong)(cast(void*)&how));
    entry.file_index = fileIndex+1;
    return entry;
}

/**
 * Note: Available from Linux 5.6
 */
ref SubmissionEntry prepEpollCtl(return ref SubmissionEntry entry, int epfd, int fd, int op, ref epoll_event ev) @trusted
{
    return entry.prepRW(Operation.EPOLL_CTL, epfd, cast(void*)&ev, op, fd);
}

/**
 * Note: Available from Linux 5.7
 *
 * This splice operation can be used to implement sendfile by splicing to an intermediate pipe
 * first, then splice to the final destination. In fact, the implementation of sendfile in kernel
 * uses splice internally.
 *
 * NOTE that even if fd_in or fd_out refers to a pipe, the splice operation can still fail with
 * EINVAL if one of the fd doesn't explicitly support splice operation, e.g. reading from terminal
 * is unsupported from kernel 5.7 to 5.11. Check issue #291 for more information.
 *
 * Either fd_in or fd_out must be a pipe.
 *
 * Params
 *   fd_in = input file descriptor
 *   off_in = If fd_in refers to a pipe, off_in must be -1.
 *            If fd_in does not refer to a pipe and off_in is -1, then bytes are read from
 *            fd_in starting from the file offset and it is adjust appropriately;
 *            If fd_in does not refer to a pipe and off_in is not -1, then the starting
 *            offset of fd_in will be off_in.
 *   fd_out = output filedescriptor
 *   off_out = The description of off_in also applied to off_out.
 *   len = Up to len bytes would be transfered between file descriptors.
 *   splice_flags = see man splice(2) for description of flags.
 */
ref SubmissionEntry prepSplice(return ref SubmissionEntry entry,
    int fd_in, ulong off_in,
    int fd_out, ulong off_out,
    uint len, uint splice_flags) @safe
{
    entry.prepRW(Operation.SPLICE, fd_out, null, len, off_out);
    entry.splice_off_in = off_in;
    entry.splice_fd_in = fd_in;
    entry.splice_flags = splice_flags;
    return entry;
}

/**
 * Note: Available from Linux 5.7
 *
 * Params:
 *    entry = `SubmissionEntry` to prepare
 *    buf   = buffers to provide
 *    len   = length of each buffer to add
 *    bgid  = buffers group id
 *    bid   = starting buffer id
 */
ref SubmissionEntry prepProvideBuffers(return ref SubmissionEntry entry, ubyte[][] buf, uint len, ushort bgid, int bid) @safe
{
    assert(buf.length <= int.max, "Too many buffers");
    assert(len <= uint.max, "Buffer too large");
    version (assert) {
        foreach (b; buf) assert(b.length <= len, "Invalid buffer length");
    }
    entry.prepRW(Operation.PROVIDE_BUFFERS, cast(int)buf.length, cast(void*)&buf[0][0], len, bid);
    entry.buf_group = bgid;
    return entry;
}

/// ditto
ref SubmissionEntry prepProvideBuffers(size_t M, size_t N)(return ref SubmissionEntry entry, ref ubyte[M][N] buf, ushort bgid, int bid) @safe
{
    static assert(N <= int.max, "Too many buffers");
    static assert(M <= uint.max, "Buffer too large");
    entry.prepRW(Operation.PROVIDE_BUFFERS, cast(int)N, cast(void*)&buf[0][0], cast(uint)M, bid);
    entry.buf_group = bgid;
    return entry;
}

/// ditto
ref SubmissionEntry prepProvideBuffer(size_t N)(return ref SubmissionEntry entry, ref ubyte[N] buf, ushort bgid, int bid) @safe
{
    static assert(N <= uint.max, "Buffer too large");
    entry.prepRW(Operation.PROVIDE_BUFFERS, 1, cast(void*)&buf[0], cast(uint)N, bid);
    entry.buf_group = bgid;
    return entry;
}

/// ditto
ref SubmissionEntry prepProvideBuffer(return ref SubmissionEntry entry, ref ubyte[] buf, ushort bgid, int bid) @safe
{
    assert(buf.length <= uint.max, "Buffer too large");
    entry.prepRW(Operation.PROVIDE_BUFFERS, 1, cast(void*)&buf[0], cast(uint)buf.length, bid);
    entry.buf_group = bgid;
    return entry;
}

/**
 * Note: Available from Linux 5.7
 */
ref SubmissionEntry prepRemoveBuffers(return ref SubmissionEntry entry, int nr, ushort bgid) @safe
{
    entry.prepRW(Operation.REMOVE_BUFFERS, nr);
    entry.buf_group = bgid;
    return entry;
}

/**
 * Note: Available from Linux 5.8
 */
ref SubmissionEntry prepTee(return ref SubmissionEntry entry, int fd_in, int fd_out, uint nbytes, uint flags) @safe
{
    entry.prepRW(Operation.TEE, fd_out, null, nbytes, 0);
    entry.splice_off_in = 0;
    entry.splice_fd_in = fd_in;
    entry.splice_flags = flags;
    return entry;
}

/**
 * Note: Available from Linux 5.11
 */
ref SubmissionEntry prepShutdown(return ref SubmissionEntry entry, int fd, int how) @safe
{
    return entry.prepRW(Operation.SHUTDOWN, fd, null, how, 0);
}

/**
 * Note: Available from Linux 5.11
 */
ref SubmissionEntry prepRenameat(return ref SubmissionEntry entry,
    int olddfd, const(char)* oldpath, int newfd, const(char)* newpath, int flags)
{
    entry.prepRW(Operation.RENAMEAT, olddfd, cast(void*)oldpath, newfd, cast(ulong)cast(void*)newpath);
    entry.rename_flags = flags;
    return entry;
}

/**
 * Note: Available from Linux 5.11
 */
ref SubmissionEntry prepUnlinkat(return ref SubmissionEntry entry, int dirfd, const(char)* path, int flags)
{
    entry.prepRW(Operation.UNLINKAT, dirfd, cast(void*)path, 0, 0);
    entry.unlink_flags = flags;
    return entry;
}

/**
 * Note: Available from Linux 5.15
 */
ref SubmissionEntry prepMkdirat(return ref SubmissionEntry entry, int dirfd, const(char)* path, mode_t mode)
{
    entry.prepRW(Operation.MKDIRAT, dirfd, cast(void*)path, mode, 0);
    return entry;
}

/**
 * Note: Available from Linux 5.15
 */
ref SubmissionEntry prepSymlinkat(return ref SubmissionEntry entry, const(char)* target, int newdirfd, const(char)* linkpath)
{
    entry.prepRW(Operation.SYMLINKAT, newdirfd, cast(void*)target, 0, cast(ulong)cast(void*)linkpath);
    return entry;
}

/**
 * Note: Available from Linux 5.15
 */
ref SubmissionEntry prepLinkat(return ref SubmissionEntry entry,
    int olddirfd, const(char)* oldpath,
    int newdirfd, const(char)* newpath, int flags)
{
    entry.prepRW(Operation.LINKAT, olddirfd, cast(void*)oldpath, newdirfd, cast(ulong)cast(void*)newpath);
    entry.hardlink_flags = flags;
    return entry;
}

/**
 * Note: Available from Linux 5.15
 */
ref SubmissionEntry prepLink(return ref SubmissionEntry entry,
    const(char)* oldpath, const(char)* newpath, int flags)
{
    return prepLinkat(entry, AT_FDCWD, oldpath, AT_FDCWD, newpath, flags);
}

// ref SubmissionEntry prepMsgRingCqeFlags(return ref SubmissionEntry entry,
//     int fd, uint len, ulong data, uint flags, uint cqe_flags) @trusted
// {
        // io_uring_prep_rw(IORING_OP_MSG_RING, sqe, fd, NULL, len, data);
        // sqe->msg_ring_flags = IORING_MSG_RING_FLAGS_PASS | flags;
        // sqe->file_index = cqe_flags;
// }

/**
 * Note: Available from Linux 5.18
 */
ref SubmissionEntry prepMsgRing(return ref SubmissionEntry entry,
    int fd, uint len, ulong data, uint flags)
{
    entry.prepRW(Operation.MSG_RING, fd, null, len, data);
    entry.msg_ring_flags = flags;
    return entry;
}

/**
 * Note: Available from Linux 5.19
 */
ref SubmissionEntry prepGetxattr(return ref SubmissionEntry entry,
    const(char)* name, char* value, const(char)* path, uint len)
{
    entry.prepRW(Operation.GETXATTR, 0, name, len, cast(ulong)cast(void*)value);
    entry.addr3 = cast(ulong)cast(void*)path;
    entry.xattr_flags = 0;
    return entry;
}

/**
 * Note: Available from Linux 5.19
 */
ref SubmissionEntry prepSetxattr(return ref SubmissionEntry entry,
    const(char)* name, const(char)* value, const(char)* path, uint len, int flags)
{
    entry.prepRW(Operation.SETXATTR, 0, name, len, cast(ulong)cast(void*)value);
    entry.addr3 = cast(ulong)cast(void*)path;
    entry.xattr_flags = flags;
    return entry;
}

/**
 * Note: Available from Linux 5.19
 */
ref SubmissionEntry prepFgetxattr(return ref SubmissionEntry entry,
    int fd, const(char)* name, char* value, uint len)
{
    entry.prepRW(Operation.FGETXATTR, fd, name, len, cast(ulong)cast(void*)value);
    entry.xattr_flags = 0;
    return entry;
}

/**
 * Note: Available from Linux 5.19
 */
ref SubmissionEntry prepFsetxattr(return ref SubmissionEntry entry,
    int fd, const(char)* name, const(char)* value, uint len, int flags)
{
    entry.prepRW(Operation.FSETXATTR, fd, name, len, cast(ulong)cast(void*)value);
    entry.xattr_flags = flags;
    return entry;
}

ref SubmissionEntry prepSocket(return ref SubmissionEntry entry,
    int domain, int type, int protocol, uint flags)
{
    entry.prepRW(Operation.SOCKET, domain, null, protocol, type);
    entry.rw_flags = cast(ReadWriteFlags)flags;
    return entry;
}

private:

// uring cleanup
void dispose(ref Uring uring) @trusted
{
    if (uring.payload is null) return;
    // debug printf("uring(%d): dispose(%d)\n", uring.payload.fd, uring.payload.refs);
    if (--uring.payload.refs == 0)
    {
        import std.traits : hasElaborateDestructor;
        // debug printf("uring(%d): free\n", uring.payload.fd);
        static if (hasElaborateDestructor!UringDesc)
            destroy(*uring.payload); // call possible destructors
        free(cast(void*)uring.payload);
    }
    uring.payload = null;
}

// system fields descriptor
struct UringDesc
{
    nothrow @nogc:

    int fd;
    size_t refs;
    SetupParameters params;
    SubmissionQueue sq;
    CompletionQueue cq;

    iovec[] regBuffers;

    ~this() @trusted
    {
        if (regBuffers) free(cast(void*)&regBuffers[0]);
        if (sq.ring) munmap(sq.ring, sq.ringSize);
        if (sq.sqes) munmap(cast(void*)&sq.sqes[0], sq.sqes.length * SubmissionEntry.sizeof);
        if (cq.ring && cq.ring != sq.ring) munmap(cq.ring, cq.ringSize);
        close(fd);
    }

    private auto mapRings() @trusted
    {
        sq.ringSize = params.sq_off.array + params.sq_entries * uint.sizeof;
        cq.ringSize = params.cq_off.cqes + params.cq_entries * CompletionEntry.sizeof;

        if (params.features & SetupFeatures.SINGLE_MMAP)
        {
            if (cq.ringSize > sq.ringSize) sq.ringSize = cq.ringSize;
            cq.ringSize = sq.ringSize;
        }

        sq.ring = mmap(null, sq.ringSize,
            PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE,
            fd, SetupParameters.SUBMISSION_QUEUE_RING_OFFSET
        );

        if (sq.ring == MAP_FAILED)
        {
            sq.ring = null;
            return -errno;
        }

        if (params.features & SetupFeatures.SINGLE_MMAP)
            cq.ring = sq.ring;
        else
        {
            cq.ring = mmap(null, cq.ringSize,
                PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE,
                fd, SetupParameters.COMPLETION_QUEUE_RING_OFFSET
            );

            if (cq.ring == MAP_FAILED)
            {
                cq.ring = null;
                return -errno; // cleanup is done in struct destructors
            }
        }

        uint entries    = *cast(uint*)(sq.ring + params.sq_off.ring_entries);
        sq.khead        = cast(uint*)(sq.ring + params.sq_off.head);
        sq.ktail        = cast(uint*)(sq.ring + params.sq_off.tail);
        sq.localTail    = *sq.ktail;
        sq.ringMask     = *cast(uint*)(sq.ring + params.sq_off.ring_mask);
        sq.kflags       = cast(uint*)(sq.ring + params.sq_off.flags);
        sq.kdropped     = cast(uint*)(sq.ring + params.sq_off.dropped);

        // Indirection array of indexes to the sqes array (head and tail are pointing to this array).
        // As we don't need some fancy mappings, just initialize it with constant indexes and forget about it.
        // That way, head and tail are actually indexes to our sqes array.
        foreach (i; 0..entries)
        {
            *((cast(uint*)(sq.ring + params.sq_off.array)) + i) = i;
        }

        auto psqes = mmap(
            null, entries * SubmissionEntry.sizeof,
            PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE,
            fd, SetupParameters.SUBMISSION_QUEUE_ENTRIES_OFFSET
        );

        if (psqes == MAP_FAILED) return -errno;
        sq.sqes = (cast(SubmissionEntry*)psqes)[0..entries];

        entries = *cast(uint*)(cq.ring + params.cq_off.ring_entries);
        cq.khead        = cast(uint*)(cq.ring + params.cq_off.head);
        cq.localHead    = *cq.khead;
        cq.ktail        = cast(uint*)(cq.ring + params.cq_off.tail);
        cq.ringMask     = *cast(uint*)(cq.ring + params.cq_off.ring_mask);
        cq.koverflow    = cast(uint*)(cq.ring + params.cq_off.overflow);
        cq.cqes         = (cast(CompletionEntry*)(cq.ring + params.cq_off.cqes))[0..entries];
        cq.kflags       = cast(uint*)(cq.ring + params.cq_off.flags);
        return 0;
    }
}

/// Wraper for `SubmissionEntry` queue
struct SubmissionQueue
{
    nothrow @nogc:

    // mmaped fields
    uint* khead; // controlled by kernel
    uint* ktail; // controlled by us
    uint* kflags; // controlled by kernel (ie IORING_SQ_NEED_WAKEUP)
    uint* kdropped; // counter of invalid submissions (out of bound index)
    uint ringMask; // constant mask used to determine array index from head/tail

    // mmap details (for cleanup)
    void* ring; // pointer to the mmaped region
    size_t ringSize; // size of mmaped memory block

    // mmapped list of entries (fixed length)
    SubmissionEntry[] sqes;

    uint localTail; // used for batch submission

    uint head() const @safe pure { return atomicLoad!(MemoryOrder.acq)(*khead); }
    uint tail() const @safe pure { return localTail; }

    void flushTail() @safe pure
    {
        pragma(inline, true);
        // debug printf("SQ updating tail: %d\n", localTail);
        atomicStore!(MemoryOrder.rel)(*ktail, localTail);
    }

    SubmissionQueueFlags flags() const @safe pure
    {
        return cast(SubmissionQueueFlags)atomicLoad!(MemoryOrder.raw)(*kflags);
    }

    bool full() const @safe pure { return sqes.length == length; }

    size_t length() const @safe pure { return tail - head; }

    size_t capacity() const @safe pure { return sqes.length - length; }

    ref SubmissionEntry next()() @safe pure return
    {
        assert(!full, "SumbissionQueue is full");
        return sqes[localTail++ & ringMask];
    }

    void put()(auto ref SubmissionEntry entry) @safe pure
    {
        assert(!full, "SumbissionQueue is full");
        sqes[localTail++ & ringMask] = entry;
    }

    void put(OP)(auto ref OP op)
        if (!is(OP == SubmissionEntry))
    {
        assert(!full, "SumbissionQueue is full");
        sqes[localTail++ & ringMask].fill(op);
    }

    private void putWith(alias FN, ARGS...)(auto ref ARGS args)
    {
        import std.traits : Parameters, ParameterStorageClass, ParameterStorageClassTuple;

        static assert(
            Parameters!FN.length >= 1
            && is(Parameters!FN[0] == SubmissionEntry)
            && ParameterStorageClassTuple!FN[0] == ParameterStorageClass.ref_,
            "Alias function must accept at least `ref SubmissionEntry`");

        static assert(
            is(typeof(FN(sqes[localTail & ringMask], args))),
            "Provided function is not callable with " ~ (Parameters!((ref SubmissionEntry e, ARGS args) {})).stringof);

        assert(!full, "SumbissionQueue is full");
        FN(sqes[localTail++ & ringMask], args);
    }

    uint dropped() const @safe pure { return atomicLoad!(MemoryOrder.raw)(*kdropped); }
}

struct CompletionQueue
{
    nothrow @nogc:

    // mmaped fields
    uint* khead; // controlled by us (increment after entry at head was read)
    uint* ktail; // updated by kernel
    uint* koverflow;
    uint* kflags;
    CompletionEntry[] cqes; // array of entries (fixed length)

    uint ringMask; // constant mask used to determine array index from head/tail

    // mmap details (for cleanup)
    void* ring;
    size_t ringSize;

    uint localHead; // used for bulk reading

    uint head() const @safe pure { return localHead; }
    uint tail() const @safe pure { return atomicLoad!(MemoryOrder.acq)(*ktail); }

    void flushHead() @safe pure
    {
        pragma(inline, true);
        // debug printf("CQ updating head: %d\n", localHead);
        atomicStore!(MemoryOrder.rel)(*khead, localHead);
    }

    bool empty() const @safe pure { return head == tail; }

    ref CompletionEntry front() @safe pure return
    {
        assert(!empty, "CompletionQueue is empty");
        return cqes[localHead & ringMask];
    }

    void popFront() @safe pure
    {
        pragma(inline);
        assert(!empty, "CompletionQueue is empty");
        localHead++;
        flushHead();
    }

    size_t length() const @safe pure { return tail - localHead; }

    uint overflow() const @safe pure { return atomicLoad!(MemoryOrder.raw)(*koverflow); }

    /// Runtime CQ flags - written by the application, shouldn't be modified by the kernel.
    void flags(CQRingFlags flags) @safe pure { atomicStore!(MemoryOrder.raw)(*kflags, flags); }
}

// just a helper to use atomicStore more easily with older compilers
void atomicStore(MemoryOrder ms, T, V)(ref T val, V newVal) @trusted
{
    pragma(inline, true);
    import core.atomic : store = atomicStore;
    static if (__VERSION__ >= 2089) store!ms(val, newVal);
    else store!ms(*(cast(shared T*)&val), newVal);
}

// just a helper to use atomicLoad more easily with older compilers
T atomicLoad(MemoryOrder ms, T)(ref const T val) @trusted
{
    pragma(inline, true);
    import core.atomic : load = atomicLoad;
    static if (__VERSION__ >= 2089) return load!ms(val);
    else return load!ms(*(cast(const shared T*)&val));
}

version (assert)
{
    import std.range.primitives : ElementType, isInputRange, isOutputRange;
    static assert(isInputRange!Uring && is(ElementType!Uring == CompletionEntry));
    static assert(isOutputRange!(Uring, SubmissionEntry));
}

version (LDC)
{
    import ldc.intrinsics : llvm_expect;
    alias _expect = llvm_expect;
}
else
{
    T _expect(T)(T val, T expected_val) if (__traits(isIntegral, T))
    {
        pragma(inline, true);
        return val;
    }
}