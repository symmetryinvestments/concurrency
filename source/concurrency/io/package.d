module concurrency.io;

import concurrency.io.iouring;
import during : ManagedBuffer;
import concurrency.ioscheduler : Client;
import concurrency.io.socket : Socket;

import std.socket : socket_t;

version (linux)
    alias IOContext = IOUringContext;

auto recvAsync(ref Socket socket, uint len = 0) @safe nothrow @nogc {
    return RecvAsyncRegisteredBufferSender(&socket, len);
}

struct RecvAsyncRegisteredBufferSender {
    alias Value = ManagedBuffer;
    Socket* socket;
    uint len;
    auto connect(Receiver)(return Receiver receiver) @safe return scope {
        // ensure NRVO
        auto op = receiver.getIOScheduler().recv(socket.fd, len).connect(receiver);
        return op;
    }
}

auto recvAsync(ref Socket socket, ubyte[] buffer, long len = 0) @safe nothrow @nogc {
    return ReadAsyncSender(&socket, buffer, len);
}

// TODO: read should be used for file descriptors
auto readAsync(ref Socket socket, ubyte[] buffer, long len = 0) @safe nothrow @nogc {
    return ReadAsyncSender(&socket, buffer, len);
}

struct ReadAsyncSender {
    alias Value = ubyte[];
    Socket* socket;
    ubyte[] buffer;
    long offset;
    auto connect(Receiver)(return Receiver receiver) @safe return scope {
        // ensure NRVO
        auto op = receiver.getIOScheduler().read(socket.fd, buffer, offset).connect(receiver);
        return op;
    }
}

auto acceptAsync(ref Socket socket) @safe nothrow @nogc {
    return AcceptAsyncSender(&socket);
}

struct AcceptAsyncSender {
    alias Value = Client;
    Socket* socket;
    auto connect(Receiver)(return Receiver receiver) @safe return scope {
        // ensure NRVO
        auto op = receiver.getIOScheduler().accept(socket.fd).connect(receiver);
        return op;
    }
}

auto connectAsync(ref Socket socket, string address, ushort port) @safe nothrow @nogc {
    return ConnectAsyncSender(&socket, address, port);
}

struct ConnectAsyncSender {
    alias Value = void;
    Socket* socket;
    string address;
    ushort port;
    auto connect(Receiver)(return Receiver receiver) @safe return scope {
        // ensure NRVO
        auto op = receiver.getIOScheduler().connect(socket.fd, address, port).connect(receiver);
        return op;
    }
}

auto writeAsync(socket_t fd, const(ubyte)[] buffer) @safe nothrow @nogc {
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

// TODO: write should be used for file descriptors
auto sendAsync(ref Socket socket, const(ubyte)[] buffer) @safe nothrow @nogc {
    return SendAsyncSender(&socket, buffer);
}

struct SendAsyncSender {
    alias Value = int;
    Socket* socket;
    const(ubyte)[] buffer;
    auto connect(Receiver)(return Receiver receiver) @safe return scope {
        // ensure NRVO
        auto op = receiver.getIOScheduler().send(socket.fd, buffer).connect(receiver);
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

auto nopAsync() @safe nothrow @nogc {
    return NopAsyncSender();
}

struct NopAsyncSender {
    alias Value = int;
    auto connect(Receiver)(return Receiver receiver) @safe return scope {
        // ensure NRVO
        auto op = receiver.getIOScheduler().nop().connect(receiver);
        return op;
    }
}
