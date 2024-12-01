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
@("acceptAsync.connectAsync.basic")
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

@safe
@("acceptAsync.connectAsync.fiber")
unittest {
    import concurrency.io.socket;
    import concurrency.fiber;

    auto io = IOContext.construct(12);
    io.run(fiber({
        auto fd = listenTcp("127.0.0.1", 0);
        auto socket = tcpSocket();
        auto port = fd.getPort();

        auto result = whenAll(
            acceptAsync(fd),
            connectAsync(socket, "127.0.0.1", port),
        ).yield();

        auto client = result[0];

        closeSocket(client.fd);
        closeSocket(socket);
        closeSocket(fd);
    })).syncWait.assumeOk;
}
