module asynchronous.libasync.events;

import std.array;
import std.datetime;
import std.process;
import std.socket;
import std.string;
import std.traits;
import libasync.events : EventLoop_ = EventLoop;
import libasync.timer : AsyncTimer;
import libasync.tcp : AsyncTCPConnection, NetworkAddress, TCPEvent;
import asynchronous.events;
import asynchronous.futures;
import asynchronous.protocols;
import asynchronous.tasks;
import asynchronous.transports;
import asynchronous.types;

alias Protocol = asynchronous.protocols.Protocol;

package class LibasyncEventLoop : EventLoop
{
    private EventLoop_ eventLoop;

    alias Timers = ResourcePool!(AsyncTimer, EventLoop_);
    private Timers timers;

    private Appender!(CallbackHandle[]) nextCallbacks1;
    private Appender!(CallbackHandle[]) nextCallbacks2;
    private Appender!(CallbackHandle[])* currentAppender;

    private TCPConnection[] pendingConnections;

    this()
    {
        this.eventLoop = new EventLoop_;
        this.timers = new Timers(this.eventLoop);
        this.currentAppender = &nextCallbacks1;
    }

    override void runForever()
    {
        final switch (this.state)
        {
            case State.STOPPED:
                this.state = State.RUNNING;
                break;
            case State.STOPPING:
            case State.RUNNING:
            case State.CLOSED:
                throw new Exception("Unexpected event loop state %s".format(this.state));
        }

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
                        this.eventLoop.loop(0.seconds);
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
        if (delay <= 0.seconds)
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
        auto thisTask = TaskHandle.currentTask;
        auto asyncTCPConnection = new AsyncTCPConnection(this.eventLoop, socket.handle);
        NetworkAddress peerAddress;

        (cast(byte*) peerAddress.sockAddr)[0 .. address.nameLen] = (cast(byte*) address.name)[0 .. address.nameLen];
        asyncTCPConnection.peer = peerAddress;

        assert(thisTask !is null);
        auto connection = TCPConnection(socket, asyncTCPConnection, {
            thisTask.resume;
        });

        asyncTCPConnection.run(&connection.handleTCPEvent);
        getEventLoop.yield;
    }

    override Transport makeSocketTransport(Socket socket, Protocol protocol, Future!void waiter)
    {
        import std.stdio;

        writeln("ggjkdjksgjlkgjs;gjs");

        return null;
    }

    @Coroutine
    override AddressInfo[] getAddressInfo(in char[] host, in char[] service,
            AddressFamily addressFamily = UNSPECIFIED!AddressFamily,
            SocketType socketType = UNSPECIFIED!SocketType, ProtocolType protocolType = UNSPECIFIED!ProtocolType,
            AddressInfoFlags addressInfoFlags = UNSPECIFIED!AddressInfoFlags)
    {
        // no async implementation in libasync yet, use the std.socket.getAddresInfo implementation;
        return std.socket.getAddressInfo(host, service, addressFamily, socketType, protocolType, addressInfoFlags);
    }

    version(Posix)
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

    //version(Posix)
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

private struct TCPConnection
{
    private Socket socket;
    private AsyncTCPConnection connection;
    private void delegate() onConnect;
    private Transport transport;

    this(Socket socket, AsyncTCPConnection connection, void delegate() onConnect)
    in
    {
        assert(socket !is null);
        assert(connection !is null);
        assert(onConnect !is null);
    }
    body
    {
        this.socket = socket;
        this.connection = connection;
        this.onConnect = onConnect;
    }

    void setTransport(Transport transport)
    in
    {
        assert(this.transport is null);
        assert(transport !is null);
    }
    body
    {
        this.transport = transport;
    }

    private void onRead()
    in
    {
        assert(this.transport !is null);
    }
    body
    {

    }

    private void onWrite()
    in
    {
        assert(this.transport !is null);
    }
    body
    {

    }

    private void onClose()
    in
    {
        assert(this.transport !is null);
    }
    body
    {

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
                onClose();
                break;
            case TCPEvent.ERROR:
                assert(0, connection.error());
        }
    }
}

private class LibasyncTcpTransport : Transport
{
    private AsyncTCPConnection connection;
    private Protocol protocol;

    string getExtraInfo(string name)
    {
        assert(0, "Unknown transport information " ~ name);
    }

    void close();
    void pauseReading();
    void resumeReading();
    void abort();
    bool canWriteEof();
    size_t getWriteBufferSize();
    BufferLimits getWriteBufferLimits();
    void setWriteBufferLimits(size_t high = 0, size_t low = 0);
    void write(const(void)[] data);
    void writeEof();

}
