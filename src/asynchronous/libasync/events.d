module asynchronous.libasync.events;

import std.algorithm;
import std.array;
import std.datetime;
import std.process;
import std.socket;
import std.string;
import std.traits;
import std.typecons;
import libasync.events : EventLoop_ = EventLoop, NetworkAddress;
import libasync.timer : AsyncTimer;
import libasync.tcp : AsyncTCPConnection, AsyncTCPListener, TCPEvent;
import libasync.threads : destroyAsyncThreads, gs_threads;
import libasync.udp : AsyncUDPSocket, UDPEvent;
import asynchronous.events;
import asynchronous.futures;
import asynchronous.protocols;
import asynchronous.tasks;
import asynchronous.transports;
import asynchronous.types;

alias Protocol = asynchronous.protocols.Protocol;

shared static ~this()
{
    destroyAsyncThreads;
}

package class LibasyncEventLoop : EventLoop
{
    private EventLoop_ eventLoop;

    alias Timers = ResourcePool!(AsyncTimer, EventLoop_);
    private Timers timers;

    private Appender!(CallbackHandle[]) nextCallbacks1;
    private Appender!(CallbackHandle[]) nextCallbacks2;
    private Appender!(CallbackHandle[])* currentAppender;

    private LibasyncTransport[] pendingConnections;

    alias Listener = Tuple!(ServerImpl, "server", AsyncTCPListener, "listener");

    private Listener[] activeListeners;

    this()
    {
        this.eventLoop = new EventLoop_;
        this.timers = new Timers(this.eventLoop);
        this.currentAppender = &nextCallbacks1;
    }

    override void runForever()
    {
        enforce(this.state == State.STOPPED,
            "Unexpected event loop state %s".format(this.state));

        this.state = State.RUNNING;

        while (true)
        {
            final switch (this.state)
            {
            case State.STOPPED:
            case State.STOPPING:
                this.state = State.STOPPED;
                return;
            case State.RUNNING:
                auto callbacks = this.currentAppender;

                if (this.currentAppender == &this.nextCallbacks1)
                    this.currentAppender = &this.nextCallbacks2;
                else
                    this.currentAppender = &this.nextCallbacks1;

                assert(this.currentAppender.data.empty);

                if (callbacks.data.empty)
                {
                    this.eventLoop.loop(-1.msecs);
                }
                else
                {
                    foreach (callback; callbacks.data)
                        callback();

                    callbacks.clear;
                }
                break;
            case State.CLOSED:
                throw new Exception("Event loop closed while running.");
            }
        }
    }

    override void scheduleCallback(CallbackHandle callback)
    {
        currentAppender.put(callback);
    }

    override void scheduleCallback(Duration delay, CallbackHandle callback)
    {
        if (delay <= Duration.zero)
        {
            scheduleCallback(callback);
            return;
        }

        auto timer = this.timers.acquire();
        timer.duration(delay).run({
            callback();
            this.timers.release(timer);
        });
    }

    override void scheduleCallback(SysTime when, CallbackHandle callback)
    {
        Duration duration = when - time;

        scheduleCallback(duration, callback);
    }

    @Coroutine
    override void socketConnect(Socket socket, Address address)
    {
        auto asyncTCPConnection = new AsyncTCPConnection(this.eventLoop,
            socket.handle);
        NetworkAddress peerAddress;

        (cast(byte*) peerAddress.sockAddr)[0 .. address.nameLen] =
            (cast(byte*) address.name)[0 .. address.nameLen];
        asyncTCPConnection.peer = peerAddress;

        auto connection = new LibasyncTransport(this, socket,
            asyncTCPConnection);

        asyncTCPConnection.run(&connection.handleTCPEvent);

        this.pendingConnections ~= connection;
    }

    override Transport makeSocketTransport(Socket socket, Protocol protocol,
        Waiter waiter)
    {
        auto index = this.pendingConnections.countUntil!(
            a => a.socket == socket);

        enforce(index >= 0, "Internal error");

        auto transport = this.pendingConnections[index];

        if (this.pendingConnections.length > 1)
        {
            this.pendingConnections[index] = this.pendingConnections[$ - 1];
        }
        this.pendingConnections.length -= 1;

        transport.setProtocol(protocol, waiter);

        return transport;
    }

    override DatagramTransport makeDatagramTransport(Socket socket,
        DatagramProtocol datagramProtocol, Address remoteAddress, Waiter waiter)
    {
        auto asyncUDPSocket = new AsyncUDPSocket(this.eventLoop, socket.handle);

        auto datagramTransport = new LibasyncDatagramTransport(this, socket,
            asyncUDPSocket);

        asyncUDPSocket.run(&datagramTransport.handleUDPEvent);

        datagramTransport.setProtocol(datagramProtocol, waiter);

        if (waiter !is null)
            this.callSoon(&waiter.setResultUnlessCancelled);

        return datagramTransport;
    }

    @Coroutine
    override AddressInfo[] getAddressInfo(in char[] host, in char[] service,
        AddressFamily addressFamily = UNSPECIFIED!AddressFamily,
        SocketType socketType = UNSPECIFIED!SocketType,
        ProtocolType protocolType = UNSPECIFIED!ProtocolType,
        AddressInfoFlags addressInfoFlags = UNSPECIFIED!AddressInfoFlags)
    {
        // no async implementation in libasync yet, use the std.socket.getAddresInfo implementation;
        return std.socket.getAddressInfo(host, service, addressFamily,
            socketType, protocolType, addressInfoFlags);
    }

    override void startServing(ProtocolFactory protocolFactory, Socket socket,
            SslContext sslContext, ServerImpl server)
    {
        auto asyncTCPListener = new AsyncTCPListener(this.eventLoop,
            socket.handle);
        NetworkAddress localAddress;
        Address address = socket.localAddress;

        (cast(byte*) localAddress.sockAddr)[0 .. address.nameLen] =
            (cast(byte*) address.name)[0 .. address.nameLen];
        asyncTCPListener.local(localAddress);

        this.activeListeners ~= Listener(server, asyncTCPListener);

        asyncTCPListener.run((AsyncTCPConnection connection) {
            auto socket1 = new Socket(cast(socket_t) connection.socket,
                socket.addressFamily);

            auto transport = new LibasyncTransport(this, socket1, connection);

            transport.setProtocol(protocolFactory());
            return &transport.handleTCPEvent;
        });
        server.attach;
    }

    override void stopServing(Socket socket)
    {
        auto found = this.activeListeners.find!(
            l => l.listener.socket == socket.handle);

        assert(!found.empty);

        auto server = found[0].server;
        auto listener = found[0].listener;

        found[0] = found[$ - 1];
        found[$ - 1] = Listener(null, null);
        --this.activeListeners.length;

        listener.kill;

        // normally detach should be called on closing event of the listening
        // socket, but libasync does not have such an event. so just call it
        // 10 milliseconds later.
        scheduleCallback(10.msecs, callback(this, &server.detach));
    }


    version (Posix)
    {
        override void addSignalHandler(int sig, void delegate() handler)
        {
            assert(0, "addSignalHandler not implemented yet");
        }

        override void removeSignalHandler(int sig)
        {
            assert(0, "removeSignalHandler not implemented yet");
        }
    }

    //void setExceptionHandler(void function(EventLoop, ExceptionContext) handler)
    //{

    //}

    //void defaultExceptionHandler(ExceptionContext context)
    //{

    //}

    //void callExceptionHandler(ExceptionContext context)
    //{

    //}
}

class LibasyncEventLoopPolicy : EventLoopPolicy
{
    override EventLoop newEventLoop()
    {
        return new LibasyncEventLoop;
    }

    //version (Posix)
    //{
    //    override ChildWatcher getChildWatcher()
    //    {
    //        assert(0, "Not implemented");
    //    }

    //    override void setChildWatcher(ChildWatcher watcher)
    //    {
    //        assert(0, "Not implemented");
    //    }
    //}
}

private final class LibasyncTransport : Transport
{
    private EventLoop eventLoop;
    private Socket _socket;
    private AsyncTCPConnection connection;
    private Waiter waiter = null;
    private Protocol protocol;
    private uint connectionLost = 0;
    private bool closing = false;
    private bool readingPaused = false;
    private bool writingPaused = false;
    private void[] writeBuffer;
    private BufferLimits writeBufferLimits;

    this(EventLoop eventLoop, Socket socket, AsyncTCPConnection connection)
    in
    {
        assert(eventLoop !is null);
        assert(socket !is null);
        assert(connection !is null);
    }
    body
    {
        this.eventLoop = eventLoop;
        this._socket = socket;
        this.connection = connection;
        setWriteBufferLimits;
    }

    @property
    Socket socket()
    {
        return this._socket;
    }

    void setProtocol(Protocol protocol, Waiter waiter = null)
    in
    {
        assert(protocol !is null);
        assert(this.protocol is null);
        assert(this.waiter is null);
    }
    body
    {
        this.protocol = protocol;
        this.waiter = waiter;
    }

    private void onConnect()
    in
    {
        assert(this.connection.isConnected);
        assert(this._socket.handle == this.connection.socket);
        assert(this.protocol !is null);
    }
    body
    {
        this.eventLoop.callSoon(&this.protocol.connectionMade, this);

        if (this.waiter !is null)
            this.eventLoop.callSoon(&this.waiter.setResultUnlessCancelled);
    }

    private void onRead()
    in
    {
        assert(this.protocol !is null);
    }
    body
    {
        if (this.readingPaused)
            return;

        static ubyte[] readBuffer = new ubyte[64 * 1024];
        Appender!(ubyte[]) receivedData;

        while (true)
        {
            auto length = this.connection.recv(readBuffer);

            receivedData ~= readBuffer[0 .. length];

            if (length < readBuffer.length)
                break;
        }

        if (!receivedData.data.empty)
        {
            this.eventLoop.callSoon(&this.protocol.dataReceived,
                receivedData.data);
        }
    }

    private void onWrite()
    in
    {
        assert(this.protocol !is null);
    }
    body
    {
        if (!this.writeBuffer.empty)
        {
            auto sent = this.connection.send(cast(ubyte[]) this.writeBuffer);
            this.writeBuffer = this.writeBuffer[sent .. $];
        }

        if (this.writingPaused &&
            this.writeBuffer.length <= this.writeBufferLimits.low)
        {
            this.protocol.resumeWriting;
            this.writingPaused = false;
        }
    }

    private void onClose(SocketOSException socketOSException)
    in
    {
        assert(this.protocol !is null);
    }
    body
    {
        this.eventLoop.callSoon(&this.protocol.connectionLost,
            socketOSException);
    }

    void handleTCPEvent(TCPEvent event)
    {
        final switch (event)
        {
        case TCPEvent.CONNECT:
            onConnect();
            break;
        case TCPEvent.READ:
            onRead();
            break;
        case TCPEvent.WRITE:
            onWrite();
            break;
        case TCPEvent.CLOSE:
            onClose(null);
            break;
        case TCPEvent.ERROR:
            onClose(new SocketOSException(connection.error()));
        }
    }

    /**
     * Transport interface
     */

    override string getExtraInfo(string name)()
    {
        assert(0, "Unknown transport information " ~ name);
    }

    void close()
    {
        if (this.closing)
            return;

        this.closing = true;
        this.eventLoop.callSoon(&this.connection.kill, false);
    }

    void pauseReading()
    {
        if (this.closing || this.connectionLost)
            throw new Exception("Cannot pauseReading() when closing");
        if (this.readingPaused)
            throw new Exception("Reading is already paused");

        this.readingPaused = true;
    }

    void resumeReading()
    {
        if (!this.readingPaused)
            throw new Exception("Reading is not paused");
        this.readingPaused = false;
    }

    void abort()
    {
        if (this.connectionLost)
            return;

        this.eventLoop.callSoon(&this.connection.kill, true);
        ++this.connectionLost;
    }

    bool canWriteEof()
    {
        return true;
    }

    size_t getWriteBufferSize()
    {
        return writeBuffer.length;
    }

    BufferLimits getWriteBufferLimits()
    {
        return writeBufferLimits;
    }

    void setWriteBufferLimits(Nullable!size_t high = Nullable!size_t(),
        Nullable!size_t low = Nullable!size_t())
    {
        if (high.isNull)
        {
            if (low.isNull)
                high = 64 * 1024;
            else
                high = 4 * low;
        }

        if (low.isNull)
            low = high / 4;

        if (high < low)
            low = high;

        this.writeBufferLimits.high = high;
        this.writeBufferLimits.low = low;
    }

    void write(const(void)[] data)
    in
    {
        assert(this.protocol !is null);
        assert(!this.writingPaused);
    }
    body
    {
        if (this.writeBuffer.empty)
        {
            auto sent = this.connection.send(cast(const ubyte[]) data);
            if (sent < data.length)
                this.writeBuffer = data[sent .. $].dup;
        }
        else
        {
            this.writeBuffer ~= data;
        }

        if (this.writeBuffer.length >= this.writeBufferLimits.high)
        {
            this.protocol.pauseWriting;
            this.writingPaused = true;
        }
    }

    void writeEof()
    {
        close;
    }
}

private final class LibasyncDatagramTransport : DatagramTransport
{
    private EventLoop eventLoop;
    private Socket _socket;
    private AsyncUDPSocket udpSocket;
    private Waiter waiter = null;
    private DatagramProtocol datagramProtocol = null;

    this(EventLoop eventLoop, Socket socket, AsyncUDPSocket udpSocket)
    in
    {
        assert(eventLoop !is null);
        assert(socket !is null);
        assert(udpSocket !is null);
        assert(socket.handle == udpSocket.socket);
    }
    body
    {
        this.eventLoop = eventLoop;
        this._socket = socket;
        this.udpSocket = udpSocket;
    }

    @property
    Socket socket()
    {
        return this._socket;
    }

    void setProtocol(DatagramProtocol datagramProtocol, Waiter waiter = null)
    in
    {
        assert(datagramProtocol !is null);
        assert(this.datagramProtocol is null);
        assert(this.waiter is null);
    }
    body
    {
        this.datagramProtocol = datagramProtocol;
        this.waiter = waiter;
    }

    private void onRead()
    in
    {
        assert(this.datagramProtocol !is null);
    }
    body
    {
        ubyte[] readBuffer = new ubyte[1501];
        NetworkAddress networkAddress;

        auto length = this.udpSocket.recvFrom(readBuffer, networkAddress);

        enforce(length < readBuffer.length,
            "Unexpected UDP package size > 1500 bytes");

        Address tmp;
        Address address = new UnknownAddressReference(
            cast(typeof(tmp.name)) networkAddress.sockAddr,
            cast(uint) networkAddress.sockAddrLen);

        this.eventLoop.callSoon(&this.datagramProtocol.datagramReceived,
            readBuffer[0 .. length], address);
    }

    private void onWrite()
    in
    {
        assert(this.datagramProtocol !is null);
    }
    body
    {
    }

    void handleUDPEvent(UDPEvent event)
    {
        final switch (event)
        {
        case UDPEvent.READ:
            onRead();
            break;
        case UDPEvent.WRITE:
            onWrite();
            break;
        case UDPEvent.ERROR:
            assert(0, udpSocket.error());
        }
    }

    /**
     * DatagramTransport interface
     */

    string getExtraInfo(string name)
    {
        assert(0, "Unknown transport information " ~ name);
    }

    void close()
    {
        this.eventLoop.callSoon(&this.udpSocket.kill);
    }

    void sendTo(const(void)[] data, Address address = null)
    in
    {
        assert(this.datagramProtocol !is null);
    }
    body
    {
        enforce(address !is null, "default remote not supported yet");

        NetworkAddress networkAddress;

        (cast(byte*) networkAddress.sockAddr)[0 .. address.nameLen] =
            (cast(byte*) address.name)[0 .. address.nameLen];

        this.udpSocket.sendTo(cast(const ubyte[]) data, networkAddress);
    }

    void abort()
    {
        this.eventLoop.callSoon(&this.udpSocket.kill);
    }
}
