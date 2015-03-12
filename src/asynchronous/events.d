module asynchronous.events;

import core.thread;
import std.algorithm;
import std.array;
import std.datetime;
import std.exception;
import std.process;
import std.socket;
import std.string;
import std.traits;
import std.typecons;
import asynchronous.futures;
import asynchronous.protocols;
import asynchronous.tasks;
import asynchronous.transports;
import asynchronous.types;

alias Protocol = asynchronous.protocols.Protocol;

/**
 * Interface server returned by $(D createServer()).
 */
interface Server
{
    /// Stop serving.  This leaves existing connections open.
    void close();

    /// Coroutine to wait until service is closed.
    void waitClosed();
}

interface CallbackHandle
{
    public void cancel();

    package void opCall()
    {
        opCallImpl;
    }

    protected void opCallImpl();
}

/**
 * A callback wrapper object returned by $(D_PSYMBOL EventLoop.callSoon),
 * $(D_PSYMBOL EventLoop.callSoonThreadsafe),
 * $(D_PSYMBOL BaseEventLoop.callLater), and $(D_PSYMBOL BaseEventLoop.callAt).
 */
class Callback(Dg, Args...) : CallbackHandle
    if (isDelegate!Dg)
{
    private bool cancelled;

    private EventLoop eventLoop;

    private Dg dg;

    private Args args;

    alias ResultType = ReturnType!Dg;

    public this(EventLoop eventLoop, Dg dg, Args args)
    {
        this.eventLoop = eventLoop;
        this.cancelled = false;
        this.dg = dg;
        static if(args.length > 0)
        {
            this.args = args;
        }
    }

    public override void cancel()
    {
        this.cancelled = true;
    }

    protected override void opCallImpl()
    {
        try
        {
            enforceEx!CancelledException(!this.cancelled, "Callback cancelled");

            this.dg(this.args);
        }
        catch (Throwable throwable)
        {
            if (this.eventLoop is null)
                this.eventLoop = getEventLoop;

            //TODO
            //this.eventLoop.callExceptionHandler(this, throwable, "Exception on calling " ~ toString);
        }
    }

    override public string toString()
    {
        import std.string;

        return "%s(dg: %s, cancelled: %s".format(typeid(this),
                                                 __traits(identifier, dg), cancelled);
    }
}

auto callback(Dg, Args...)(EventLoop eventLoop, Dg dg, Args args)
{
    return new Callback!(Dg, Args)(eventLoop, dg, args);
}

/**
 * Interface of event loop.
 */
abstract class EventLoop
{
    protected enum State
    {
        STOPPED,
        RUNNING,
        STOPPING,
        CLOSED,
    }

    protected State state = State.STOPPED;
    //private size_t timerCancelledCount = 0;
    //self._ready = collections.deque()
    //self._scheduled = []
    //self._default_executor = None
    //self._internal_fds = 0
    //self._clock_resolution = time.get_clock_info('monotonic').resolution
    //self._exception_handler = None
    //self._debug = (not sys.flags.ignore_environment
    //               and bool(os.environ.get('PYTHONASYNCIODEBUG')))
    //# In debug mode, if the execution of a callback or a step of a task
    //# exceed this duration in seconds, the slow callback/task is logged.
    //self.slow_callback_duration = 0.1

public:
    /// Run an event loop

    /**
     * Run until $(D_PSYMBOL stop()) is called.
     */
    void runForever();

    /**
     * Run until $(PARAM future) is done.
     *
     * If the argument is a $(I coroutine object), it is wrapped by $(D_PSYMBOL
     * async()).
     *
     * Returns: the Future's result, or throws its exception.
     */
    final T runUntilComplete(T)(Future!T future)
    {
        future.addDoneCallback(&stop);
        runForever;
        assert(future.done);
        if (future.exception)
            throw future.exception;

        static if (!is(T == void))
        {
            return future.result;
        }
    }

    /**
     * Returns: running status of event loop.
     */
    final bool isRunning()
    {
        return this.state == State.RUNNING || this.state == State.STOPPING;
    }

    /**
     * Stop running the event loop.
     *
     * Every callback scheduled before $(D_PSYMBOL stop()) is called will run.
     * Callbacks scheduled after $(D_PSYMBOL stop()) is called will not run.
     * Howerver, those callbacks will run if $(D_PSYMBOL runForever()) is
     * called again later.
     */
    final void stop()
    {
        final switch (this.state)
        {
            case State.STOPPED:
            case State.STOPPING:
                break;
            case State.RUNNING:
                this.state = State.STOPPING;
                break;
            case State.CLOSED:
                throw new Exception("Cannot stop a closed event loop");
        }
    }


    /**
     * Returns: $(D_KEYWORD true) if the event loop was closed.
     */
    final bool isClosed()
    {
        return this.state == State.CLOSED;
    }

    /**
     * Close the event loop. The loop must not be running.
     *
     * This clears the queues and shuts down the executor, but does not wait
     * for the executor to finish.
     *
     * This is idempotent and irreversible. No other methods should be called
     * after this one.
     */
    final void close()
    {
        final switch (this.state)
        {
            case State.STOPPED:
                this.state = State.CLOSED;
                break;
            case State.RUNNING:
            case State.STOPPING:
                throw new Exception("Cannot close a running event loop");
            case State.CLOSED:
                break;
        }
    }


    /// Calls

    /**
     * Arrange for a callback to be called as soon as possible.
     *
     * This operates as a FIFO queue, callbacks are called in the order in
     * which they are registered. Each callback will be called exactly once.
     *
     * Any positional arguments after the callback will be passed to the
     * callback when it is called.
     *
     * Returns: an instance of $(D_PSYMBOL Future).
     */
    final auto callSoon(Dg, Args...)(Dg dg, Args args)
    {
        auto callback = new Callback!(Dg, Args)(this, dg, args);

        scheduleCallback(callback);

        return callback;
    }

    /**
     * Like $(D_PSYMBOL call_soon()), but thread safe.
     */
    //ReturnType!callback callSoonThreadsafe(alias callback, Args...)(Args args)
    //{
    //    return callLater!callback(0, args);
    //}


    /// Delayed calls

    /**
     * Arrange for the callback to be called after the given delay.
     *
     * An instance of $(D_PSYMBOL Callback) is returned.
     *
     * $(D_PSYMBOL dg) delegate will be called exactly once per call to
     * $(D_PSYMBOL callLater()). If two callbacks are scheduled for exactly
     * the same time, it is undefined which will be called first.
     *
     * The optional positional args will be passed to the callback when it is
     * called.
     */
    final auto callLater(Dg, Args...)(Duration delay, Dg dg, Args args)
    {
        auto callback = new Callback!(Dg, Args)(this, dg, args);

        scheduleCallback(delay, callback);

        return callback;
    }

    /**
     * Arrange for the callback to be called at the given absolute timestamp
     * when (an int or float), using the same time reference as time().
     *
     * This method’s behavior is the same as $(D_PSYMBOL callLater()).
     */
    final auto callAt(Callback, Args...)(SysTime when, Dg dg, Args args)
    {
        auto callback = new Callback!(Dg, Args)(this, dg, args);

        scheduleCallback(when, callback);

        return callback;
    }

    /**
     * Return the current time according to the event loop’s internal clock.
     *
     * See_Also: $(D_PSYMBOL sleep()).
     */
    SysTime time()
    {
        return Clock.currTime;
    }


    /// Fibers

    /**
     * Schedule the execution of a fiber object: wrap it in a future.
     *
     * Third-party event loops can use their own subclass of Task for
     * interoperability. In this case, the result type is a subclass of Task.
     *
     * Returns: a $(D_PSYMBOL Task) object.
     *
     * See_Also: $(D_PSYMBOL async()).
     */
    final auto createTask(Coroutine, Args...)(Coroutine coroutine, Args args)
        if (isDelegate!Coroutine)
    {
        return new Task!(Coroutine, Args)(this, coroutine, args);
    }

    //// Methods for interacting with threads.

    //ReturnType!callback runInExecutor(alias callback, Args...)(executor, Args args);

    //void setDefaultExecutor(executor);

    //// Network I/O methods returning Futures.

    //AddressInfo[] getAddressInfo(T...)(in char[] node, T options);

    //// def getNameInfo(sockaddr, flags = 0);


    /// Creating connections

    /**
     * Create a streaming transport connection to a given Internet host and
     * port: socket family $(D_PSYMBOL AddressFamily.INET) or $(D_PSYMBOL
     * AddressFamily.INET6) depending on host (or family if specified), socket
     * type $(D_PSYMBOL SocketType.STREAM). protocol_factory must be a callable
     * returning a protocol instance.
     *
     * This method is a coroutine which will try to establish the connection in
     * the background. When successful, the coroutine returns a (transport,
     * protocol) tuple.
     *
     * The chronological synopsis of the underlying operation is as follows:
     *
     * The connection is established, and a transport is created to represent
     * it. $(D_PSYMBOL protocolFactory) is called without arguments and must
     * return a protocol instance.
     * The protocol instance is tied to the transport, and its $(D_PSYMBOL
     * connectionMade()) method is called.
     * The coroutine returns successfully with the (transport, protocol) tuple.
     *
     * The created transport is an implementation-dependent bidirectional
     * stream.
     *
     * Options allowing to change how the connection is created:
     * Params:
     *  ssl = if not false, a SSL/TLS transport is created (by default a plain
     *        TCP transport is created). If ssl is a ssl.SSLContext object, this
     *        context is used to create the transport; if ssl is True, a context
     *        with some unspecified default settings is used.
     * serverHostname = is only for use together with ssl, and sets or overrides
     *                  the hostname that the target server’s certificate will
     *                  be matched against. By default the value of the host
     *                  argument is used. If host is empty, there is no default
     *                  and you must pass a value for $(D_PSYMBOL serverHostname).
     *                  If $(D_PSYMBOL serverHostname) is an empty, hostname
     *                  matching is disabled (which is a serious security risk,
     *                  allowing for man-in-the-middle-attacks).
     * addressFamily = optional adress family.
     * protocolType = optional protocol.
     * addressInfoFlags = optional flags.
     * socket = if not $(D_KEYWORD null), should be an existing, already
     *          connected $(D_PSYMBOL Socket) object to be used by the
     *          transport. If $(D_PSYMBOL socket) is given, none of $(D_PSYMBOL
     *          host), $(D_PSYMBOL service), $(D_PSYMBOL addressFamily),
     *          $(D_PSYMBOL protocolType), $(D_PSYMBOL addressInfoFlags) and
     *          $(D_PSYMBOL localAddress) should be specified.
     * localHost = if given, together with $(D_PSYMBOL localService) is used to
     *             bind the socket to locally. The $(D_PSYMBOL localHost) and
     *             $(D_PSYMBOL localService are looked up using $(D_PSYMBOL
     *             getAddressInfo()), similarly to host and service.
     * localService = see $(D_PSYMBOL localHost).
     *
     * Returns: Tuple!(Transport, Protocol)
     */
    @Coroutine
    auto createConnection(ProtocolFactory protocolFactory,
            in char[] host = null, in char[] service = null, bool ssl = false,
            AddressFamily addressFamily = UNSPECIFIED!AddressFamily,
            ProtocolType protocolType = UNSPECIFIED!ProtocolType,
            AddressInfoFlags addressInfoFlags = UNSPECIFIED!AddressInfoFlags,
            Socket socket = null, in char[] localHost = null,
            in char[] localService = null, in char[] serverHostname = null)
    {
        enforce(serverHostname.empty || ssl,
                "serverHostname is only meaningful with ssl");
        enforce(!(serverHostname.empty && ssl && host.empty),
                "You must set serverHostname when using ssl without a host");

        if (!host.empty || !service.empty)
        {
            enforce(socket is null,
                    "host/service and socket can not be specified at the same time");

            Future!(AddressInfo[])[] fs = [createTask(&this.getAddressInfo,
                                                      host, service,
                                                      addressFamily,
                                                      SocketType.STREAM,
                                                      protocolType,
                                                      addressInfoFlags)];

            if (!localHost.empty)
                fs ~= createTask(&this.getAddressInfo, localHost, localService,
                                 addressFamily, SocketType.STREAM, protocolType,
                                 addressInfoFlags);

            this.wait(fs);

            auto addressInfos = fs.map!"a.result";

            enforceEx!SocketOSException(addressInfos.all!(a => !a.empty),
                                        "getAddressInfo() returned empty list");

            SocketOSException[] exceptions = null;
            bool connected = false;

            foreach (addressInfo; addressInfos[0])
            {
                try
                {
                    socket = new Socket(addressInfo.family, addressInfo.type,
                                        addressInfo.protocol);
                    socket.blocking(false);

                    if (addressInfos.length > 1)
                    {
                        bool bound = false;

                        foreach (localAddressInfo; addressInfos[1])
                        {
                            try
                            {
                                socket.bind(localAddressInfo.address);
                                bound = true;
                                break;
                            }
                            catch (SocketOSException socketOSException)
                            {
                                exceptions ~= new SocketOSException(
                                    "error while attempting to bind on address '%s'"
                                        .format(localAddressInfo.address),
                                    socketOSException);
                            }
                        }
                        if (!bound)
                        {
                            socket.close;
                            socket = null;
                            continue;
                        }
                    }

                    socketConnect(socket, addressInfo.address);
                    connected = true;
                    break;
                }
                catch (SocketOSException socketOSException)
                {
                    if (socket !is null)
                        socket.close;

                    exceptions ~= socketOSException;
                }
                catch (Throwable throwable)
                {
                    if (socket !is null)
                        socket.close;

                    throw throwable;
                }
            }

            if (!connected)
            {
                assert(!exceptions.empty);

                if (exceptions.length == 1)
                {
                    throw exceptions[0];
                }
                else
                {
                    if (exceptions.all!(a => a.msg == exceptions[0].msg))
                        throw exceptions[0];

                    throw new SocketOSException("Multiple exceptions: %(%s, %)"
                        .format(exceptions));
                }
            }
        }
        else
        {
            enforce(socket !is null,
                    "host and port was not specified and no socket specified");
        }

        socket.blocking(false);

        return createConnectionTransport(socket, protocolFactory, ssl,
                                         serverHostname.empty ? serverHostname : host);
    }


    /**
     * Create datagram connection: socket family $(D_PSYMBOL AddressFamily.INET)
     * or $(D_PSYMBOL AddressFamily.INET6) depending on host (or family if
     * specified), socket type $(D_PSYMBOL SocketType.DGRAM).
     *
     * This method is a coroutine which will try to establish the connection in
     * the background.
     *
     * See the create_connection() method for parameters.
     *
     * Returns: Tuple!(DatagramTransport, DatagramProtocol)
     */
    @Coroutine
    auto createDatagramEndpoint(DatagramProtocolFactory datagramProtocolFactory,
            in char[] localHost = null, in char[] localService = null,
            in char[] remoteHost = null, in char[] remoteService = null,
            AddressFamily addressFamily = UNSPECIFIED!AddressFamily,
            ProtocolType protocolType = UNSPECIFIED!ProtocolType,
            AddressInfoFlags addressInfoFlags = UNSPECIFIED!AddressInfoFlags)
    {
        alias AddressPairInfo = Tuple!(AddressFamily, "addressFamily",
                                       ProtocolType, "protocolType",
                                       Address, "localAddress",
                                       Address, "remoteAddress");

        AddressPairInfo[] addressPairInfos = null;


        if (localHost.empty && remoteHost.empty)
        {
            enforce(addressFamily != UNSPECIFIED!AddressFamily,
                    "Unexpected address family");
            addressPairInfos ~= AddressPairInfo(addressFamily, protocolType,
                                                null, null);
        }
        else
        {
            enforce(remoteHost.empty, "Remote host parameter not supportored yet");

            auto addressInfos = getAddressInfo(localHost, localService,
                                               addressFamily, SocketType.DGRAM,
                                               protocolType, addressInfoFlags);

            enforceEx!SocketOSException(!addressInfos.empty,
                                        "getAddressInfo() returned empty list");

            foreach (addressInfo; addressInfos)
            {
                addressPairInfos ~= AddressPairInfo(addressInfo.family,
                                                    addressInfo.protocol,
                                                    addressInfo.address, null);
            }
        }

        Socket socket = null;
        Address remoteAddress = null;
        SocketOSException[] exceptions = null;

        foreach (addressPairInfo; addressPairInfos)
        {
            try
            {
                socket = new Socket(addressPairInfo.addressFamily,
                                    SocketType.DGRAM,
                                    addressPairInfo.protocolType);
                socket.setOption(SocketOptionLevel.SOCKET,
                                 SocketOption.REUSEADDR, 1);
                socket.blocking(false);

                if (addressPairInfo.localAddress)
                    socket.bind(addressPairInfo.localAddress);


                remoteAddress = addressPairInfo.remoteAddress;
                enforce(remoteAddress is null, "remote connect not supported yet");

                break;
            }
            catch (SocketOSException socketOSException)
            {
                if (socket !is null)
                    socket.close;

                exceptions ~= socketOSException;
            }
            catch (Throwable throwable)
            {
                if (socket !is null)
                    socket.close;

                throw throwable;
            }
        }

        auto protocol = datagramProtocolFactory();
        auto waiter = new Future!void(this);
        auto transport = makeDatagramTransport(socket, protocol, remoteAddress,
                                               waiter);
        try
        {
            this.waitFor(waiter);
        }
        catch (Throwable throwable)
        {
            transport.close;
            throw throwable;
        }

        return tuple(transport, protocol);
    }


    ////"""A coroutine which creates a TCP server bound to host and port.

    ////The return value is a Server object which can be used to stop
    ////the service.

    ////If host is an empty string or None all interfaces are assumed
    ////and a list of multiple sockets will be returned (most likely
    ////one for IPv4 and another one for IPv6).

    ////family can be set to either AF_INET or AF_INET6 to force the
    ////socket to use IPv4 or IPv6. If not set it will be determined
    ////from host (defaults to AF_UNSPEC).

    ////flags is a bitmask for getaddrinfo().

    ////sock can optionally be specified in order to use a preexisting
    ////socket object.

    ////backlog is the maximum number of queued connections passed to
    ////listen() (defaults to 100).

    ////ssl can be set to an SSLContext to enable SSL over the
    ////accepted connections.

    ////reuse_address tells the kernel to reuse a local socket in
    ////TIME_WAIT state, without waiting for its natural timeout to
    ////expire. If not specified will automatically be set to True on
    ////UNIX.
    ////"""
    //AbstractServer createServer(Protocol function() protocol_factory,
    //    in char[] host = null, ushort port = 0, AddressFamily family = AddressFamily.UNSPEC,
    //    AddressInfoFlags flags = AddressInfoFlags.PASSIVE, Socket sock = null,
    //    int backlog = 100, bool ssl = false, bool reuseAddress = true);

    //Tuple!(Transport, Protocol) createUnixConnection(Protocol function() protocol_factory,
    //    in char[] path, bool ssl = false, Socket sock = null, in char[] serverHostname = null);

    ////"""A coroutine which creates a UNIX Domain Socket server.

    ////The return value is a Server object, which can be used to stop
    ////the service.

    ////path is a str, representing a file systsem path to bind the
    ////server socket to.

    ////sock can optionally be specified in order to use a preexisting
    ////socket object.

    ////backlog is the maximum number of queued connections passed to
    ////listen() (defaults to 100).

    ////ssl can be set to an SSLContext to enable SSL over the
    ////accepted connections.
    ////"""
    //AbstractServer createUnixServer(Protocol function() protocol_factory,
    //    in char[] path, Socket sock = null, int backlog = 100, bool ssl = false);

    //Tuple!(Transport, Protocol) createDatagramEndpoint(Protocol function() protocol_factory,
    //    in char[] localAddr = null, in char[] remoteAddr = null, AddressFamily family = AddressFamily.UNSPEC,
    //    SocketType proto = SocketType.STREAM, AddressInfoFlags flags = AddressInfoFlags.PASSIVE);

    //// Pipes and subprocesses.

    ////"""Register read pipe in event loop.

    ////protocol_factory should instantiate object with Protocol interface.
    ////pipe is file-like object already switched to nonblocking.
    ////Return pair (transport, protocol), where transport support
    ////ReadTransport interface."""
    ////# The reason to accept file-like object instead of just file descriptor
    ////# is: we need to own pipe and close it at transport finishing
    ////# Can got complicated errors if pass f.fileno(),
    ////# close fd in pipe transport then close f and vise versa.
    //Tuple!(Transport, Protocol) connectReadPipe(Protocol function() protocol_factory,
    //    Pipe pipe);

    ////"""Register write pipe in event loop.

    ////protocol_factory should instantiate object with BaseProtocol interface.
    ////Pipe is file-like object already switched to nonblocking.
    ////Return pair (transport, protocol), where transport support
    ////WriteTransport interface."""
    ////# The reason to accept file-like object instead of just file descriptor
    ////# is: we need to own pipe and close it at transport finishing
    ////# Can got complicated errors if pass f.fileno(),
    ////# close fd in pipe transport then close f and vise versa.
    //Tuple!(Transport, Protocol) connectWritePipe(Protocol function() protocol_factory,
    //    Pipe pipe);

    //Tuple!(Transport, Protocol) processShell(Protocol function() protocol_factory,
    //    in char[] cmd, File stdin = subprocess.PIPE, File stdout = subprocess.PIPE,
    //    File stderr = subprocess.PIPE);

    //Tuple!(Transport, Protocol) processProcess(Protocol function() protocol_factory,
    //    in char[][] args, File stdin = subprocess.PIPE, File stdout = subprocess.PIPE,
    //    File stderr = subprocess.PIPE);

    ////# Ready-based callback registration methods.
    ////# The add_*() methods return None.
    ////# The remove_*() methods return True if something was removed,
    ////# False if there was nothing to delete.

    //void addReader(int fd, void delegate() callback);

    //void removeReader(int fd);

    //void addWriter(int fd, void delegate() callback);

    //void removeWriter(int fd);

    //// # Completion based I/O methods returning Futures.

    //ptrdiff_t socketReceive(Socket sock, void[] buf);

    //ptrdiff_t socketSend(Socket sock, void[] buf);

    //void socketConnect(Socket sock, Address address);

    //Socket socketAccept(Socket sock);

    /// Resolve host name

    @Coroutine
    AddressInfo[] getAddressInfo(in char[] host, in char[] service,
            AddressFamily addressFamily = UNSPECIFIED!AddressFamily,
            SocketType socketType = UNSPECIFIED!SocketType,
            ProtocolType protocolType = UNSPECIFIED!ProtocolType,
            AddressInfoFlags addressInfoFlags = UNSPECIFIED!AddressInfoFlags);


    /// Signal handling.
    version(Posix)
    {
        void addSignalHandler(int sig, void delegate() handler);

        void removeSignalHandler(int sig);
    }

    /// Error handlers.
    //void setExceptionHandler(void function(EventLoop, ExceptionContext) handler);

    //void defaultExceptionHandler(ExceptionContext context);

    //void callExceptionHandler(ExceptionContext context);

    override string toString()
    {
        return "%s(%s)".format(typeid(this), this.state);
    }

    //// # Debug flag management.

    //bool getDebug();

    //void setDebug(bool enabled);

protected:

    void scheduleCallback(CallbackHandle callback);

    void scheduleCallback(Duration delay, CallbackHandle callback);

    void scheduleCallback(SysTime when, CallbackHandle callback);

    void socketConnect(Socket socket, Address address);

    Transport makeSocketTransport(Socket socket, Protocol protocol,
            Future!void waiter);

    DatagramTransport makeDatagramTransport(Socket socket,
            DatagramProtocol datagramProtocol, Address remoteAddress,
            Future!void waiter);
private:

    @Coroutine
    auto createConnectionTransport(Socket socket,
                                   ProtocolFactory protocolFactory,
                                   bool ssl, in char[] serverHostname = null)
    {
        Protocol protocol = protocolFactory();
        Transport transport = null;
        auto waiter = new Future!void(this);

        if (ssl)
        {
            assert(0, "SSL support not implemented yet");
            //sslcontext = None if isinstance(ssl, bool) else ssl
            //transport = self._make_ssl_transport(
            //    sock, protocol, sslcontext, waiter,
            //    server_side = False, server_hostname = server_hostname)
        }
        else
        {
            transport = makeSocketTransport(socket, protocol, waiter);
        }

        try
        {
            this.waitFor(waiter);
        }
        catch (Throwable throwable)
        {
            transport.close;
            throw throwable;
        }

        return tuple(transport, protocol);
    }
}


struct ExceptionContext
{
    string message;
    Exception exception;
    //AbstractHandle handle;
}

/**
 * Interface of policy for accessing the event loop.
 */
abstract class EventLoopPolicy
{
    protected EventLoop eventLoop = null;
    protected bool setCalled = false;

    /**
     * Get the event loop.
     *
     * This may be $(D null) or an instance of EventLoop.
     */
    EventLoop getEventLoop()
    {
        if (eventLoop is null && !setCalled && thread_isMainThread)
            setEventLoop(newEventLoop);
        return eventLoop;
    }

    /**
     * Set the event loop.
     */
    void setEventLoop(EventLoop loop)
    {
        setCalled = true;
        eventLoop = loop;
    }

    /**
     * Create a new event loop.
     *
     * You must call $(D setEventLoop()) to make this the current event loop.
     */
    EventLoop newEventLoop();

    //version(Posix)
    //{
    //    ChildWatcher getChildWatcher();

    //    void setChildWatcher(ChildWatcher watcher);
    //}
}

/**
 * Default policy implementation for accessing the event loop.
 *
 * In this policy, each thread has its own event loop.  However, we only
 * automatically create an event loop by default for the main thread; other
 * threads by default have no event loop.
 *
 * Other policies may have different rules (e.g. a single global event loop, or
 * automatically creating an event loop per thread, or using some other notion
 * of context to which an event loop is associated).
 */

private __gshared EventLoopPolicy eventLoopPolicy;

import asynchronous.libasync.events;
alias DefaultEventLoopPolicy = LibasyncEventLoopPolicy;

/**
 * Get the current event loop policy.
 */
EventLoopPolicy getEventLoopPolicy()
{
    if (eventLoopPolicy is null)
    {
        synchronized
        {
            if (eventLoopPolicy is null)
                eventLoopPolicy = new DefaultEventLoopPolicy;
        }
    }

    return eventLoopPolicy;
}

/**
 * Set the current event loop policy.
 *
 * If policy is $(D null), the default policy is restored.
 */
void setEventLoopPolicy(EventLoopPolicy policy)
{
    eventLoopPolicy = policy;
}

/**
 * Equivalent to calling $(D getEventLoopPolicy.getEventLoop).
 */
EventLoop getEventLoop()
{
    return getEventLoopPolicy.getEventLoop;
}

unittest
{
    assert(getEventLoop !is null);
}

/**
 * Equivalent to calling $(D getEventLoopPolicy.setEventLoop(loop)).
 */
void setEventLoop(EventLoop loop)
{
    getEventLoopPolicy.setEventLoop(loop);
}

/**
 * Equivalent to calling $(D getEventLoopPolicy.newEventLoop).
 */
EventLoop newEventLoop()
{
    return getEventLoopPolicy.newEventLoop;
}
