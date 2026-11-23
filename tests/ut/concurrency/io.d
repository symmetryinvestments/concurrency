module ut.concurrency.io;

import unit_threaded;
import concurrency.io;
import concurrency.scheduler;
import concurrency;
import concurrency.operations;
import concurrency.sender : ValueSender;
import std.typecons : tuple;
import std.socket : socket_t;
import core.time : msecs;

private class RecordingIOScheduler {
    size_t recvCalls;
    size_t readCalls;

    auto recv(socket_t, ubyte[] buffer, long = 0) @safe {
        recvCalls++;
        return ValueSender!(ubyte[])(buffer);
    }

    auto read(socket_t, ubyte[] buffer, long = 0) @safe {
        readCalls++;
        return ValueSender!(ubyte[])(buffer);
    }
}

version (linux):

import concurrency.io.iouring : IOUringContext;
import concurrency.io.epoll : EpollContext;

private void checkStableContext(Context)() @trusted {
    import concurrency.io.socket : listenTcp, tcpSocket, socketPair, getPort, closeSocket;
    import core.sys.posix.sys.socket : shutdown, SHUT_WR;

    {
        auto context = Context.construct(8);
        context.run(nopAsync()).syncWait().value.should == 0;
    }
    {
        auto context = Context.construct(8);
        context.run(ScheduleAfter(1.msecs)).syncWait().assumeOk;
    }
    {
        auto listener = listenTcp("127.0.0.1", 0);
        auto client = tcpSocket();
        auto context = Context.construct(8);
        context.run(whenAll(
            acceptAsync(listener),
            connectAsync(client, "127.0.0.1", listener.getPort()),
        )).syncWait().assumeOk;
    }
    {
        auto sockets = socketPair();
        ubyte[] expected = [31, 32, 33];
        ubyte[8] storage;
        auto context = Context.construct(8);
        auto result = context.run(whenAll(
            recvAsync(sockets.a, storage),
            sendAsync(sockets.b, expected),
        )).syncWait().assumeOk;
        result[0].should == expected;
        assert(result[1] > 0 && result[1] <= expected.length);
    }
    {
        auto sockets = socketPair();
        auto peer = sockets.b.release();
        scope(exit) closeSocket(peer);
        assert(shutdown(peer, SHUT_WR) == 0);
        ubyte[8] storage;
        auto context = Context.construct(8);
        auto result = context.run(recvAsync(sockets.a, storage)).syncWait();
        result.isCancelled.should == true;
    }
    {
        auto socket = tcpSocket();
        ubyte[8] storage;
        auto context = Context.construct(8);
        auto result = context.run(recvAsync(socket, storage)).syncWait();
        result.isError.should == true;
    }
}

@("IO backends share stable scheduler and socket scenarios") @trusted
unittest {
    checkStableContext!IOUringContext();
    checkStableContext!EpollContext();
}

@("IOUringScheduler.IOScheduler") @safe
unittest {
    import concurrency.io.iouring : IOUringScheduler;
    import concurrency.ioscheduler : Client, isIOScheduler, NullIOScheduler,
        toIOSchedulerObject;
    import concurrency.io : ManagedBuffer;
    import concurrency.sender : SenderObjectBase;

    alias BufferlessRecvSender =
        typeof(IOUringScheduler.init.recv(socket_t.init, uint.init));
    alias CallerBufferRecvSender =
        typeof(IOUringScheduler.init.recv(socket_t.init, ubyte[].init));
    alias NullBufferlessRecvSender =
        typeof(NullIOScheduler.init.recv(socket_t.init, uint.init));
    alias NullCallerBufferRecvSender =
        typeof(NullIOScheduler.init.recv(socket_t.init, ubyte[].init));
    auto erased = IOUringScheduler.init.toIOSchedulerObject;

    static assert(isIOScheduler!IOUringScheduler);
    static assert(isIOScheduler!NullIOScheduler);
    static assert(is(BufferlessRecvSender.Value == ManagedBuffer));
    static assert(is(CallerBufferRecvSender.Value == ubyte[]));
    static assert(is(NullBufferlessRecvSender == ValueSender!ManagedBuffer));
    static assert(is(NullCallerBufferRecvSender == ValueSender!(ubyte[])));
    static assert(is(typeof(erased.recv(socket_t.init, uint.init))
        == SenderObjectBase!ManagedBuffer));
    static assert(is(typeof(erased.recv(socket_t.init, ubyte[].init, long.init))
        == SenderObjectBase!(ubyte[])));
    static assert(is(typeof(erased.read(socket_t.init, ubyte[].init, long.init))
        == SenderObjectBase!(ubyte[])));
    static assert(is(typeof(erased.accept(socket_t.init)) == SenderObjectBase!Client));
    static assert(is(typeof(erased.connect(socket_t.init, string.init, ushort.init))
        == SenderObjectBase!void));
    static assert(is(typeof(erased.send(socket_t.init, const(ubyte[]).init))
        == SenderObjectBase!int));
    static assert(is(typeof(erased.write(socket_t.init, const(ubyte[]).init, long.init))
        == SenderObjectBase!int));
    static assert(is(typeof(erased.close(socket_t.init)) == SenderObjectBase!void));
    static assert(is(typeof(erased.nop()) == SenderObjectBase!int));
}

@safe
@("Schedule.single")
unittest {
	auto io = IOContext.construct(12);
    io.run(Schedule().then(() => 1))
        .syncWait().value.should == 1;
}

@safe
@("Schedule.double")
unittest {
	auto io = IOContext.construct(12);
    io.run(
        whenAll(
            Schedule().then(() => 1),
            Schedule().then(() => 2)
        )
    ).syncWait().value.should == tuple(1,2);
}

@safe
@("ScheduleAfter.single")
unittest {
    auto io = IOContext.construct(12);
    io.run(ScheduleAfter(1.msecs).then(() => 1))
        .syncWait().value.should == 1;
}

@safe
@("ScheduleAfter.double")
unittest {
    auto io = IOContext.construct(12);
    io.run(
        whenAll(
            ScheduleAfter(1.msecs).then(() => 1),
            ScheduleAfter(1.msecs).then(() => 2)
        )
    ).syncWait().value.should == tuple(1,2);
}

@safe
@("acceptAsync.connectAsync")
unittest {
    import concurrency.io.socket;
    auto serverSocket = listenTcp("127.0.0.1", 0);
    auto socket = tcpSocket();
    auto port = serverSocket.getPort();
    auto io = IOContext.construct(12);

    auto result = io.run(
        whenAll(
            acceptAsync(serverSocket),
            connectAsync(socket, "127.0.0.1", port),
        )
    ).syncWait().assumeOk;
}

@safe
@("acceptAsync.missing.ioscheduler")
unittest {
    import concurrency.io.socket;
    import concurrency.sender;

    auto socket = Socket();

    acceptAsync(socket)
        .toSenderObject
        .syncWait().value.shouldThrow;
}

@safe
@("recvAsync.caller-buffer.uses-recv")
unittest {
    import concurrency.io.socket : Socket;
    import concurrency.operations.withioscheduler : withIOScheduler;

    auto socket = Socket();
    ubyte[4] storage;
    auto scheduler = new RecordingIOScheduler;

    recvAsync(socket, storage[]).withIOScheduler(scheduler)
        .syncWait().value.should == storage[];

    scheduler.recvCalls.should == 1;
    scheduler.readCalls.should == 0;
}

@safe
@("readAsync.caller-buffer.uses-read")
unittest {
    import concurrency.io.socket : Socket;
    import concurrency.operations.withioscheduler : withIOScheduler;

    auto socket = Socket();
    ubyte[4] storage;
    auto scheduler = new RecordingIOScheduler;

    readAsync(socket, storage[]).withIOScheduler(scheduler)
        .syncWait().value.should == storage[];

    scheduler.readCalls.should == 1;
    scheduler.recvCalls.should == 0;
}

@safe
@("recvAsync.caller-buffer.unconnected")
unittest {
    import concurrency.io.socket;
    import concurrency.sender;
    import core.stdc.errno : ENOTCONN;
    import std.socket;
    import std.exception : ErrnoException;

    auto socket = listenTcp("127.0.0.1", 0);
    auto io = IOContext.construct(16);
    ubyte[1024] storage;

    auto result = io.run(recvAsync(socket, storage[])).syncWait();
    result.isError.should == true;
    auto error = cast(ErrnoException) result.get!Exception;
    assert(error !is null);
    error.errno.should == ENOTCONN;
    error.msg.should == "Receive failed (Transport endpoint is not connected)";
}

@safe
@("buffer.ring.recv.pair")
unittest {
    import concurrency.io.socket;
    import concurrency.io : ManagedBuffer;

    auto sockets = socketPair();
    auto io = IOContext.construct(16);
    ubyte[] buffer = [1,2,3,4];

    auto result = io.run(
        whenAll(
            recvAsync(sockets.a, 4).then((ref ManagedBuffer b) => b.view.data.dup),
            sendAsync(sockets.b, buffer),
        )
    ).syncWait().value;

    result[0].should == buffer;
}

@safe
@("server.client")
unittest {
    import concurrency.io.socket;
    import concurrency.ioscheduler : Client;
    import concurrency.io : ManagedBuffer;
    import std.socket : socket_t;

    auto fd = listenTcp("127.0.0.1", 0);
    auto socket = tcpSocket();
    auto port = fd.getPort();
    auto io = IOContext.construct(12);

    auto result = io.run(
        whenAll(
            acceptAsync(fd)
                .letValue((ref Client client) {
                    return recvAsync(client.socket);
                })
                .then((ref ManagedBuffer b) {
                    b.view.data.should == [0,1,2,3];
                }),
            connectAsync(socket, "127.0.0.1", port)
                .letValue(() {
                    return sendAsync(socket, [0,1,2,3]);
                })
        )
    ).syncWait().assumeOk;
}
