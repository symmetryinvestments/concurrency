module concurrency.io;

import concurrency.io.iouring;
import concurrency.ioscheduler : Client;

import std.socket : socket_t;

version (linux)
    alias IOContext = IOUringContext;

auto readAsync(socket_t fd, ubyte[] buffer, long offset = 0) @safe nothrow @nogc {
    return ReadAsyncSender(fd, buffer, offset);
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
