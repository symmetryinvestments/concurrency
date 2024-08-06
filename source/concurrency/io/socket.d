module concurrency.io.socket;
import std.socket : socket_t;

auto tcpSocket() @trusted {
    import std.socket : socket_t;
    version(Windows) {
        import core.sys.windows.windows;
    } else version(Posix) {
        import core.sys.posix.unistd;
        import core.sys.posix.sys.socket;
        import core.sys.posix.netinet.in_;
        import core.sys.posix.sys.wait;
        import core.sys.posix.sys.select;
        import core.sys.posix.netinet.tcp;
    }

    version(linux) {
        import core.sys.linux.sys.eventfd;
        enum SOCK_NONBLOCK = 0x800;
        socket_t sock = cast(socket_t) socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0);
    } else version(Windows) {
        socket_t sock = cast(socket_t) socket(AF_INET, SOCK_STREAM, 0);
        uint nonblocking_long = 1;
        if (ioctlsocket(sock, FIONBIO, &nonblocking_long) == SOCKET_ERROR)
            throw new Exception("ioctlsocket failed");
    }

    if (sock == -1)
        throw new Exception("socket");

    int on = 1;
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &on, on.sizeof);
    setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, &on, on.sizeof);
    version(Posix) // on windows REUSEADDR includes REUSEPORT
        setsockopt(sock, SOL_SOCKET, SO_REUSEPORT, &on, on.sizeof);

    return sock;
}

auto listenTcp(string address = "", ushort port = 0, int backlog = 128) @trusted {
    import core.stdc.stdio : fprintf, stderr;
    import std.socket : socket_t;
    version(Windows) {
        import core.sys.windows.windows;
    } else version(Posix) {
        import core.sys.posix.unistd;
        import core.sys.posix.sys.socket;
        import core.sys.posix.netinet.in_;
        import core.sys.posix.sys.wait;
        import core.sys.posix.sys.select;
        import core.sys.posix.netinet.tcp;
    }

    version(linux) {
        import core.sys.linux.sys.eventfd;
    }
    import core.stdc.errno;

    socket_t sock = tcpSocket();

    sockaddr_in addr;
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);

    if (address.length) {
        import std.string : toStringz;
        uint uiaddr = ntohl(inet_addr(address.toStringz()));
        if (INADDR_NONE == uiaddr) {
            throw new Exception(
                "bad listening host given, please use an IP address.\nExample: --listening-host 127.0.0.1 means listen only on Localhost.\nExample: --listening-host 0.0.0.0 means listen on all interfaces.\nOr you can pass any other single numeric IPv4 address."
            );
        }

        addr.sin_addr.s_addr = htonl(uiaddr);
    } else
        addr.sin_addr.s_addr = INADDR_ANY;

    if (bind(sock, cast(sockaddr*) &addr, addr.sizeof) == -1) {
        closeSocket(sock);
        throw new Exception("bind");
    }

    if (listen(sock, backlog) == -1) {
        closeSocket(sock);
        throw new Exception("listen");
    }

    return sock;
}

auto closeSocket(socket_t sock) @trusted {
    import core.sys.posix.unistd;
    version(Windows) {
        import core.sys.windows.windows;
        closesocket(sock);
    } else
        close(sock);
}

ushort getPort(socket_t socket) @trusted {
    import std.socket;
    version(Windows) {
        import core.sys.windows.windows;
    } else version(Posix) {
        import core.sys.posix.unistd;
        import core.sys.posix.sys.socket;
        import core.sys.posix.netinet.in_;
        import core.sys.posix.sys.wait;
        import core.sys.posix.sys.select;
        import core.sys.posix.netinet.tcp;
    }

    version(linux) {
        import core.sys.linux.sys.eventfd;
        enum SOCK_NONBLOCK = 0x800;
    }

    sockaddr_in sin;
    socklen_t nameLen = sin.sizeof;
    if (Socket.ERROR == getsockname(socket, cast(sockaddr*)&sin, &nameLen))
        throw new SocketOSException("Unable to obtain local socket address");

    return ntohs(sin.sin_port);
}