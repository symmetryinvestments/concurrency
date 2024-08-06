import std.stdio : writeln;
import concurrency;
import concurrency.socket;
import concurrency.io;
import concurrency.operations.whenall;

void main() @safe
{
	auto fd = listen("127.0.0.1", 0);
	auto io = IOUringContext.construct(256);
	auto socket = getSocket();
	auto port = fd.getPort();

	writeln("Listening on 127.0.0.1:", port);

	writeln("Connecting...");
	auto client = io.run(
		whenAll(
			io.accept(fd),
			io.connect(socket, "127.0.0.1", port),
		)
	).syncWait().value[0];


	ubyte[4] bufferRead;
	ubyte[4] bufferSend;
	bufferSend[0..4] = [1,2,3,4];

	writeln("Transmitting...");
	auto result = io.run(
		whenAll(
			io.write(socket, bufferSend[]),
			io.read(client.fd, bufferRead[]),
		)
	).syncWait().value[1];


	writeln("Closing...");
	closeSocket(client.fd);
	closeSocket(socket);
	closeSocket(fd);

	writeln("Got: ", result);
}
