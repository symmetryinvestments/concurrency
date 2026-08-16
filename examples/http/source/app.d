import std.stdio : writeln;
import concurrency;
import concurrency.io.socket;
import concurrency.io;
import concurrency.ioscheduler;
import httparsed;
import std.typecons : Nullable;
import std.socket : socket_t;

struct Peer {
    import std.socket : socket_t;
    import concurrency.operations : letValue, letDone, repeat, ignoreValue, ignoreError;

    socket_t fd;

    this (Client client) @safe {
        this.fd = client.fd;
    }

    auto handleConnection() @safe {

        // What we need to do is issue the next read at least when we order the send,
        // this ensures we are ready waiting for data as soon as possible.
        // Alternatively we build a multishot adapter that queues completion events
        // and manages the underlying multishot request by starting/stopping when the
        // internal queue is getting empty/full. This need to properly wrap the socket
        // to ensure it can handover leftover data between phases.

        return recvAsync(fd)
            .letValue(&handleRead)
            .repeat()
            .ignoreError()
            // what happens with the Cancelled in http is that
            // there is a read exception, and repeat just propagates the
            // error, and then in ignoreError it flips to Cancelled
            // afterwhich things get cancelled.

            // needs to be letFinally ??
            .letDone(&handleClose);
            // Or do a letError here to catch any peer closes and close anyway
            // Alternatively readAsync (and writeAsync) should handle the peer closing
            // and call setDone
            // However, that doesn't allow us to distinguish between external cancellation
            // or self-termination. Although we could use the stoptoken to check though...
    }

    // TODO: This can't be a during object directly...
    import during : ManagedBuffer;
    auto handleRead(ref ManagedBuffer input) @safe {
        MsgParser!(Request) parser;
        uint lastPos = 0;
        auto result = parser.parseRequest(input.data, lastPos);
        assert(result > 0);
        assert(input.data.length == result);

        import std.string : representation;
        string response = "HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 3\r\nConnection: keep-alive\r\n\r\nfoo";
        return sendAsync(fd, response.representation).ignoreValue;
    }

    auto handleClose() @safe {
        return closeAsync(fd);
    }
}

void main() @safe
{
    import concurrency;
    import std.range : repeat;
    import std.array : array;
    import concurrency.operations : whenAll;

    // handler();
    // whenAll(
        // handler().repeat(1).array729809
    // ).syncWait.assumeOk;

    import std.range : repeat;

    shared fd = listenTcp("127.0.0.1", 8888, 3200);
    handler(fd).repeat(2).whenAll().syncWait().assumeOk();
}

// Almost at a million
// one IO enter syscall was blocked
// I suspect the wakeup not being done correctly.


auto handler() @safe {
    import concurrency.thread;
    import concurrency.operations : then;

    // return ThreadSender().then((){
        // can we grab the StopSource here?
        auto io = IOContext.construct(1024);
        shared fd = listenTcp("127.0.0.1", 8888, 800);
        import concurrency.operations;

        auto peer = acceptAsync(fd)
            .then((Client client) { return Peer(client); })
            .letValue((ref Peer peer) { return peer.handleConnection(); })
            .ignoreError
            .repeat;

        import std.range : repeat;
        import std.array : array;

    // io.run(peer).syncWait.assumeOk;

        io.run(
            whenAll(peer.repeat(800).array)
                // arguably this needs to happen for all completions
                // .letDone(() {
                //     import std.stdio;
                //     debug writeln("Closing fd");
                //     return closeAsync(fd);
                // })
        ).syncWait().assumeOk;

        closeSocket(fd);
    // });
    // io.run(peer).syncWait.assumeOk;
}

auto handler(shared socket_t fd) @safe {
    import concurrency.thread;
    import concurrency.operations : then, via, letValue, withStopToken;
    import concurrency : just;

    return just(fd)
        .via(ThreadSender())
        .withStopToken((shared StopToken token, shared socket_t fd) {
            auto io = IOContext.construct(512);
            import concurrency.operations;

            auto peer = acceptAsync(fd)
                .then((Client client) { 
                    return Peer(client);
                })
                .letValue((ref Peer peer) { return peer.handleConnection(); })
                .ignoreError
                .repeat;

            import std.range : repeat;
            import std.array : array;

            shared StopSource childStopSource;
            shared StopCallback cb;
            cb.register(token, () shared {
                childStopSource.stop();
            });
            io.run(whenAll(peer.repeat(256).array)).syncWait(childStopSource);
            import std.stdio;
            writeln("Done");
        });
}



struct Header
{
    const(char)[] name;
    const(char)[] value;
}

struct Request
{
    @safe pure:
    void onMethod(const(char)[] method) { this.method = method; }
    void onUri(const(char)[] uri) { this.uri = uri; }
    int onVersion(const(char)[] ver)
    {
        minorVer = parseHttpVersion(ver);
        return minorVer >= 0 ? 0 : minorVer;
    }
    void onHeader(const(char)[] name, const(char)[] value) {
        if (m_headersLength < m_headers.length) {
            // import std.uni : asLowerCase;
            // import std.conv : text;
            this.m_headers[m_headersLength].name = name;//.asLowerCase.text;
            this.m_headers[m_headersLength++].value = value;//.idup;
        }
    }
    void onStatus(int status) { this.status = status; }
    void onStatusMsg(const(char)[] statusMsg) { this.statusMsg = statusMsg; }

    const(char)[] method;
    const(char)[] uri;
    int minorVer;
    int status;
    const(char)[] statusMsg;

    private {
        Header[32] m_headers;
        size_t m_headersLength;
    }

    size_t contentLength() {
        import std.algorithm : find;
        import std.conv : to;
        import std.range : empty, front;

        auto header = headers.find!(h => h.name == "content-length");
        if (header.empty)
            return 0;

        return header.front().value.to!size_t;
    }

    Header[] headers() return { return m_headers[0..m_headersLength]; }
}
