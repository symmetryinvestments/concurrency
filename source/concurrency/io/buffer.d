module concurrency.io.buffer;

struct ManagedBuffer
{
    alias Release = void delegate(scope ubyte[] base) shared @safe nothrow @nogc;

    private {
        Release release;
        ubyte[] buffer;
        // TODO: we can avoid the len when we adopt homogenous buffergroups,
        // or avoid storing the buffer's capacity elsewhere. There is really
        // no value storing it here and moving it around.
        uint len;
    }

    /// Adopt a provider-owned buffer. The caller must ensure the bound
    /// provider and backing storage outlive this value.
    static ManagedBuffer adopt(Release release, ubyte[] buffer, uint len)
        @system nothrow @nogc
    {
        assert(release !is null);
        assert(buffer.length > 0);
        assert(len <= buffer.length);
        return ManagedBuffer(release, buffer, len);
    }

    private this(Release release, ubyte[] buffer, uint len)
        @safe nothrow @nogc
    {
        this.release = release;
        this.buffer = buffer;
        this.len = len;
    }

    ~this() @safe nothrow @nogc scope {
        releaseNow();
    }

    @disable this(ref return scope typeof(this) rhs);
    @disable this(this);
    @disable void opAssign(typeof(this));
    @disable void opAssign(ref typeof(this));

    /// Return the buffer to its provider. Repeated calls and destruction of a
    /// moved-from value are inert.
    void releaseNow() @safe nothrow @nogc scope {
        if (release is null)
            return;

        auto callback = release;
        auto base = buffer;

        // Invalidate before calling provider code so callback reentrancy
        // cannot return the same buffer twice.
        release = Release.init;
        buffer = null;
        len = 0;

        if (callback !is null)
            callback(base);
    }

    bool isValid() const scope @safe pure nothrow @nogc {
        return release !is null;
    }

    size_t length() const scope @safe pure nothrow @nogc {
        return len;
    }

    size_t capacity() const scope @safe pure nothrow @nogc {
        return buffer.length;
    }

    private const(ubyte)[] readable() const return scope @safe pure nothrow @nogc {
        return buffer[0..len];
    }
}

/// A non-owning observation of a ManagedBuffer. Its result lifetime is tied
/// to the ManagedBuffer passed to view().
struct ManagedBufferView
{
    private const(ManagedBuffer)* owner;

    private this(return ref const ManagedBuffer owner)
        @trusted pure nothrow @nogc
    {
        this.owner = &owner;
    }

    const(ubyte)[] data() const return scope @safe pure nothrow @nogc {
        assert(owner !is null && owner.isValid);
        return owner.readable;
    }

    size_t length() const scope @safe pure nothrow @nogc {
        return data.length;
    }

    bool empty() const scope @safe pure nothrow @nogc {
        return length == 0;
    }

    ubyte opIndex(size_t index) const scope @safe pure nothrow @nogc {
        return data[index];
    }
}

ManagedBufferView view(return ref const ManagedBuffer buffer)
    @safe pure nothrow @nogc
{
    return ManagedBufferView(buffer);
}
