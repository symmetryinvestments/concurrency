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
    auto fd = listenTcp("127.0.0.1", 0);
    auto socket = tcpSocket();
    auto port = fd.getPort();
    auto io = IOContext.construct(12);

    auto result = io.run(
        whenAll(
            acceptAsync(fd),
            connectAsync(socket, "127.0.0.1", port),
        )
    ).syncWait().assumeOk;

    auto client = result[0];

	closeSocket(client.fd);
	closeSocket(socket);
	closeSocket(fd);
}

@safe
@("acceptAsync.missing.ioscheduler")
unittest {
    import concurrency.io.socket;
    import concurrency.sender;
    import std.socket;
    acceptAsync(cast(socket_t)0)
        .toSenderObject
        .syncWait().value.shouldThrow;
}
/+
not working due to non-copyable managedbuffer
@safe
@("buffer.ring.recv.unconnected")
unittest {
    import concurrency.io.socket;
    import concurrency.sender;
    import std.socket;
    import std.exception : ErrnoException;

    auto fd = listenTcp("127.0.0.1", 0);
    auto io = IOContext.construct(16);

    io.run(
        recvAsync(fd, 1024)
    ).syncWait().assumeOk.shouldThrowWithMessage!(ErrnoException)("Read failed (Transport endpoint is not connected)");

    // TODO: This required closeSocket is not very friendly
    // would rather have a socket that is movable and closes
    // when going out of scope.
	closeSocket(fd);
}

@safe
@("buffer.ring.recv.pair")
unittest {
    import concurrency.io.socket;

    auto fds = socketPair();
    auto io = IOContext.construct(16);
    ubyte[] buffer = [1,2,3,4];

    import during : ManagedBuffer;

    auto result = io.run(
        whenAll(
            recvAsync(fds[0], 4).then((ManagedBuffer b) => b.data.dup),
            sendAsync(fds[1], buffer),
        )
    ).syncWait().value;

    result[0].should == buffer;

	
	closeSocket(fds[0]);
	closeSocket(fds[1]);
}
+/