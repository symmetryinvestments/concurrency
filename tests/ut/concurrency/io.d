module ut.concurrency.io;

import unit_threaded;
import concurrency.io;
import concurrency.scheduler;
import concurrency;
import concurrency.operations;
import std.typecons : tuple;
import core.time : msecs;

version (linux):

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
@("buffer.ring.recv.unconnected")
unittest {
    import concurrency.io.socket;
    import concurrency.sender;
    import std.socket;
    import std.exception : ErrnoException;

    auto socket = listenTcp("127.0.0.1", 0);
    auto io = IOContext.construct(16);

    io.run(
        recvAsync(socket, 1024)
    ).syncWait().assumeOk.shouldThrowWithMessage!(ErrnoException)("Read failed (Transport endpoint is not connected)");
}

@safe
@("buffer.ring.recv.pair")
unittest {
    import concurrency.io.socket;

    auto sockets = socketPair();
    auto io = IOContext.construct(16);
    ubyte[] buffer = [1,2,3,4];

    import during : ManagedBuffer;

    auto result = io.run(
        whenAll(
            recvAsync(sockets.a, 4).then((ref ManagedBuffer b) => b.data.dup),
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
    import std.socket : socket_t;
    import during : ManagedBuffer;

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
                    b.data.should == [0,1,2,3];
                }),
            connectAsync(socket, "127.0.0.1", port)
                .letValue(() {
                    return sendAsync(socket, [0,1,2,3]);
                })
        )
    ).syncWait().assumeOk;
}
