module concurrency.io;

import concurrency.io.iouring;
import during : ManagedBuffer;
import concurrency.ioscheduler : Client;

import std.socket : socket_t;

version (linux)
    alias IOContext = IOUringContext;

auto recvAsync(socket_t fd, uint len = 0) @safe nothrow @nogc {
    return RecvAsyncRegisteredBufferSender(fd, len);
}

struct RecvAsyncRegisteredBufferSender {
    alias Value = ManagedBuffer;
    socket_t fd;
    uint len;
    auto connect(Receiver)(return Receiver receiver) @safe return scope {
        // ensure NRVO
        auto op = receiver.getIOScheduler().recv(fd, len).connect(receiver);
        return op;
    }
}

auto recvAsync(socket_t fd, ubyte[] buffer, long len = 0) @safe nothrow @nogc {
    return ReadAsyncSender(fd, buffer, len);
}

// TODO: read should be used for file descriptors
auto readAsync(socket_t fd, ubyte[] buffer, long len = 0) @safe nothrow @nogc {
    return ReadAsyncSender(fd, buffer, len);
}

struct ReadAsyncSender {
    alias Value = ubyte[];
    socket_t fd;
    ubyte[] buffer;
    long offset;
    auto connect(Receiver)(return Receiver receiver) @safe return scope {
        // ensure NRVO
        auto op = receiver.getIOScheduler().read(fd, buffer, offset).connect(receiver);
        return op;
    }
}

auto acceptAsync(socket_t fd) @safe nothrow @nogc {
    return AcceptAsyncSender(fd);
}

struct AcceptAsyncSender {
    alias Value = Client;
    socket_t fd;
    auto connect(Receiver)(return Receiver receiver) @safe return scope {
        // ensure NRVO
        auto op = receiver.getIOScheduler().accept(fd).connect(receiver);
        return op;
    }
}

auto connectAsync(socket_t fd, string address, ushort port) @safe nothrow @nogc {
    return ConnectAsyncSender(fd, address, port);
}

struct ConnectAsyncSender {
    import std.socket : socket_t;
    alias Value = socket_t;
    socket_t fd;
    string address;
    ushort port;
    auto connect(Receiver)(return Receiver receiver) @safe return scope {
        // ensure NRVO
        auto op = receiver.getIOScheduler().connect(fd, address, port).connect(receiver);
        return op;
    }
}

auto sendAsync(socket_t fd, const(ubyte)[] buffer) @safe nothrow @nogc {
    return WriteAsyncSender(fd, buffer, 0);
}

// TODO: write should be used for file descriptors
auto writeAsync(socket_t fd, const(ubyte)[] buffer, long offset = 0) @safe nothrow @nogc {
    return WriteAsyncSender(fd, buffer, offset);
}

struct WriteAsyncSender {
    alias Value = int;
    socket_t fd;
    const(ubyte)[] buffer;
    long offset;
    auto connect(Receiver)(return Receiver receiver) @safe return scope {
        // ensure NRVO
        auto op = receiver.getIOScheduler().write(fd, buffer, offset).connect(receiver);
        return op;
    }
}

auto closeAsync(socket_t fd) @safe nothrow @nogc {
    return CloseAsyncSender(fd);
}

struct CloseAsyncSender {
    alias Value = void;
    socket_t fd;
    auto connect(Receiver)(return Receiver receiver) @safe return scope {
        // ensure NRVO
        auto op = receiver.getIOScheduler().close(fd).connect(receiver);
        return op;
    }
}
