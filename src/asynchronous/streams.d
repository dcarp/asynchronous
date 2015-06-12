/**
 * High-level stream API.
 */
module asynchronous.streams;

import std.algorithm : findSplit;
import std.array : Appender, empty;
import std.exception : enforce, enforceEx;
import std.socket : AddressFamily, AddressInfoFlags, ProtocolType, Socket,
    SocketOSException;
import std.string : format;
import std.typecons : tuple;
import asynchronous.events;
import asynchronous.futures;
import asynchronous.tasks;
import asynchronous.transports;
import asynchronous.types;

enum DEFAULT_LIMIT = 1 << 16; // 2 ** 16

/**
 * Incomplete read error.
 */
class IncompleteReadError : Exception
{
    /**
     * Read bytes string before the end of stream was reached.
     */
    const(void)[] partial;

    /**
     * Total number of expected bytes.
     */
    const size_t expected;

    this(const(void)[] partial, size_t expected, string file = __FILE__,
        size_t line = __LINE__, Throwable next = null) @safe pure
    {
        import std.string;

        this.partial = partial;
        this.expected = expected;

        super("%s bytes read on a total of %s expected bytes"
                .format(partial.length, expected), file, line, next);
    }
}

/**
 * A wrapper for $(D_PSYMBOL createConnection()) returning a (reader, writer)
 * pair.
 *
 * The reader returned is a $(D_PSYMBOL StreamReader) instance; the writer is a
 * $(D_PSYMBOL StreamWriter) instance.
 *
 * The arguments are all the usual arguments to $(D_PSYMBOL createConnection())
 * except protocolFactory; most common are host and port, with various optional
 * arguments following.
 *
 * Additional arguments are $(D_PSYMBOL eventLoop) (to set the event loop
 * instance to use) and $(D_PSYMBOL limit) (to set the buffer limit passed to
 * the $(D_PSYMBOL StreamReader)).
 *
 * (If you want to customize the $(D_PSYMBOL StreamReader) and/or
 * $(D_PSYMBOL StreamReaderProtocol) classes, just copy the code -- there's
 * really nothing special here except some convenience.)
 */
@Coroutine
auto openConnection(EventLoop eventLoop, in char[] host = null,
    in char[] service = null, size_t limit = DEFAULT_LIMIT,
    SslContext sslContext = null,
    AddressFamily addressFamily = UNSPECIFIED!AddressFamily,
    ProtocolType protocolType = UNSPECIFIED!ProtocolType,
    AddressInfoFlags addressInfoFlags = UNSPECIFIED!AddressInfoFlags,
    Socket socket = null, in char[] localHost = null,
    in char[] localService = null, in char[] serverHostname = null)
{
    if (eventLoop is null)
        eventLoop = getEventLoop;

    auto streamReader = new StreamReader(eventLoop, limit);
    auto connection = eventLoop.createConnection(
        () => new StreamReaderProtocol(eventLoop, streamReader), host, service,
        sslContext, addressFamily, protocolType, addressInfoFlags, socket,
        localHost, localService, serverHostname);
    auto streamWriter = new StreamWriter(eventLoop, connection.transport,
        connection.protocol, streamReader);

    return tuple!("reader", "writer")(streamReader, streamWriter);
}

alias ClientConnectedCallback = void delegate(StreamReader, StreamWriter);
/**
 * Start a socket server, call back for each client connected.
 *
 * The first parameter, $(D_PSYMBOL clientConnectedCallback), takes two
 * parameters: $(D_PSYMBOL clientReader), $(D_PSYMBOL clientWriter). $(D_PSYMBOL
 * clientReader) is a $(D_PSYMBOL StreamReader) object, while $(D_PSYMBOL
 * clientWriter) is a $(D_PSYMBOL StreamWriter) object.  This parameter is a
 * coroutine, that will be automatically converted into a $(D_PSYMBOL Task).
 *
 * The rest of the arguments are all the usual arguments to $(D_PSYMBOL
 * eventLoop.createServer()) except $(D_PSYMBOL protocolFactory). The return
 * value is the same as $(D_PSYMBOL eventLoop.create_server()).
 *
 * Additional optional keyword arguments are loop (to set the event loop
 * instance to use) and limit (to set the buffer limit passed to the
 * $(D_PSYMBOL StreamReader)).
 *
 * The return value is the same as $(D_PSYMBOL loop.createServer()), i.e. a
 * $(D_PSYMBOL Server) object which can be used to stop the service.
 */
@Coroutine
Server startServer(EventLoop eventLoop,
    ClientConnectedCallback clientConnectedCallback, in char[] host = null,
    in char[] service = null, size_t limit = DEFAULT_LIMIT,
    AddressFamily addressFamily = UNSPECIFIED!AddressFamily,
    AddressInfoFlags addressInfoFlags = AddressInfoFlags.PASSIVE,
    Socket socket = null, int backlog = 100, SslContext sslContext = null,
    bool reuseAddress = true)
{
    if (eventLoop is null)
        eventLoop = getEventLoop;

    Protocol protocolFactory()
    {
        auto reader = new StreamReader(eventLoop, limit);
        return new StreamReaderProtocol(eventLoop, reader,
            clientConnectedCallback);
    }

    return eventLoop.createServer(&protocolFactory, host, service,
        addressFamily, addressInfoFlags, socket, backlog, sslContext,
        reuseAddress);
}

/**
 * A wrapper for $(D_PSYMBOL createUnixConnection()) returning a (reader,
 * writer) pair.
 *
 * See $(D_PSYMBOL openConnection()) for information about return value and
 * other details.
 */
version (Posix)
@Coroutine
auto openUnixConnection(EventLoop eventLoop, in char[] path = null,
    size_t limit = DEFAULT_LIMIT, SslContext sslContext = null,
    Socket socket = null, in char[] serverHostname = null)
{
    if (eventLoop is null)
        eventLoop = getEventLoop;

    auto streamReader = new StreamReader(eventLoop, limit);
    auto connection = eventLoop.createUnixConnection(
        () => new StreamReaderProtocol(eventLoop, streamReader), path,
        sslContext, socket, serverHostname);
    auto streamWriter = new StreamWriter(eventLoop, connection.transport,
        connection.protocol, streamReader);

    return tuple!("reader", "writer")(streamReader, streamWriter);
}

/**
 * Start a UNIX Domain Socket server, with a callback for each client connected.
 *
 * See $(D_PSYMBOL startServer()) for information about return value and other
 * details.
 */
version (Posix)
@Coroutine
Server startUnixServer(EventLoop eventLoop,
    ClientConnectedCallback clientConnectedCallback, in char[] path = null,
    size_t limit = DEFAULT_LIMIT, Socket socket = null, int backlog = 100,
    SslContext sslContext = null)
{
    if (eventLoop is null)
        eventLoop = getEventLoop;

    Protocol protocolFactory()
    {
        auto reader = new StreamReader(eventLoop, limit);
        return new StreamReaderProtocol(eventLoop, reader,
            clientConnectedCallback);
    }

    return eventLoop.createUnixServer(&protocolFactory, path, socket, backlog,
        sslContext);
}

/**
 * Reusable flow control logic for $(D_PSYMBOL StreamWriter.drain()).
 *
 * This implements the protocol methods $(D_PSYMBOL pauseWriting()), $(D_PSYMBOL
 * resumeReading()) and $(D_PSYMBOL connectionLost()).  If the subclass
 * overrides these it must call the super methods.
 *
 * $(D_PSYMBOL StreamWriter.drain()) must wait for $(D_PSYMBOL drainHelper())
 * coroutine.
 */
private abstract class FlowControlProtocol : Protocol
{
    private EventLoop eventLoop;
    private bool paused = false;
    private Waiter drainWaiter = null;
    private bool connectionLost_ = false;

    this(EventLoop eventLoop)
    {
        if (eventLoop is null)
            this.eventLoop = getEventLoop;
        else
            this.eventLoop = eventLoop;

    }

    override void pauseWriting()
    in
    {
        assert(!paused);
    }
    body
    {
        paused = true;
    }

    override void resumeWriting()
    in
    {
        assert(paused);
    }
    body
    {
        paused = false;

        if (drainWaiter !is null)
        {
            auto waiter = drainWaiter;

            drainWaiter = null;
            if (!waiter.done)
                waiter.setResult;
        }
    }

    override void connectionMade(BaseTransport transport)
    {
        throw new NotImplementedException;
    }

    override void connectionLost(Exception exception)
    {
        connectionLost_ = true;

        if (!paused || drainWaiter is null || drainWaiter.done)
            return;

        auto waiter = drainWaiter;

        drainWaiter = null;
        if (exception is null)
            waiter.setResult;
        else
            waiter.setException(exception);
    }

    @Coroutine
    protected void drainHelper()
    {
        enforceEx!SocketOSException(!connectionLost_, "Connection lost");

        if (!paused)
            return;

        assert(drainWaiter is null || drainWaiter.cancelled);

        drainWaiter = new Waiter(eventLoop);
        eventLoop.waitFor(drainWaiter);
    }

    override void dataReceived(const(void)[] data)
    {
        throw new NotImplementedException;
    }

    override bool eofReceived()
    {
        throw new NotImplementedException;
    }
}


/**
 * Helper class to adapt between $(D_PSYMBOL Protocol) and $(D_PSYMBOL
 * StreamReader).
 *
 * (This is a helper class instead of making StreamReader itself a $(D_PSYMBOL
 * Protocol) subclass, because the StreamReader has other potential uses, and to
 * prevent the user of the StreamReader to accidentally call inappropriate
 * methods of the protocol.)
 */
class StreamReaderProtocol : FlowControlProtocol
{
    private StreamReader streamReader;
    private StreamWriter streamWriter;
    private ClientConnectedCallback clientConnectedCallback;

    this(EventLoop eventLoop, StreamReader streamReader,
        ClientConnectedCallback clientConnectedCallback = null)
    {
        super(eventLoop);
        this.streamReader = streamReader;
        this.streamWriter = null;
        this.clientConnectedCallback = clientConnectedCallback;
    }

    override void connectionMade(BaseTransport transport)
    {
        auto transport1 = cast(Transport) transport;

        enforce(transport1 !is null);
        streamReader.setTransport(transport1);

        if (clientConnectedCallback !is null)
        {
            streamWriter = new StreamWriter(eventLoop, transport1, this, 
                streamReader);
            eventLoop.createTask(clientConnectedCallback, streamReader,
                streamWriter);
        }
    }

    override void connectionLost(Exception exception)
    {
        if (exception is null)
            streamReader.feedEof;
        else
            streamReader.setException(exception);
        super.connectionLost(exception);
    }

    override void dataReceived(const(void)[] data)
    {
        streamReader.feedData(data);
    }

    override bool eofReceived()
    {
        streamReader.feedEof;
        return true;
    }
}

final class StreamReader
{
    private EventLoop eventLoop;
    private size_t limit;
    private const(void)[] buffer;
    private bool eof = false;
    private Waiter flowWaiter;
    private Throwable exception_;
    private ReadTransport transport;
    private bool paused = false;

    this(EventLoop eventLoop, size_t limit = DEFAULT_LIMIT)
    {
        if (eventLoop is null)
            this.eventLoop = getEventLoop;
        else
            this.eventLoop = eventLoop;
        // The line length limit is  a security feature;
        // it also doubles as half the buffer limit.
        this.limit = limit;
    }

    /**
     * Get the exception.
     */
    @property Throwable exception()
    {
        return exception_;
    }

    /**
     * Acknowledge the EOF.
     */
    void feedEof()
    {
        eof = true;
        wakeupWaiter;
    }

    /**
     * Feed $(D_PSYMBOL data) bytes in the internal buffer. Any operations
     * waiting for the data will be resumed.
     */
    void feedData(const(void)[] data)
    in
    {
        assert(!eof); // feedData after feedEof
    }
    body
    {
        if (data.empty)
            return;

        buffer ~= data;
        wakeupWaiter;

        if (transport is null || paused || buffer.length <= 2 * limit)
            return;

        try
        {
            transport.pauseReading;
            paused = true;
        }
        catch (NotImplementedException)
        {
            // The transport can't be paused.
            // We'll just have to buffer all data.
            // Forget the transport so we don't keep trying.
            transport = null;
        }
    }

    /**
     * Set the exception.
     */
    void setException(Throwable exception)
    {
        exception_ = exception;

        if (flowWaiter is null)
            return;

        auto waiter = flowWaiter;
        flowWaiter = null;
        if (!waiter.cancelled)
            waiter.setException(exception);
    }

    /**
     * Set the exception.
     */
    void setTransport(ReadTransport transport)
    in
    {
        assert(this.transport is null);
    }
    body
    {
        this.transport = transport;
    }

    /**
     * Wakeup $(D_PSYMBOL read()) or $(D_PSYMBOL readline()) function waiting
     * for data or EOF.
     */
    private void wakeupWaiter()
    {
        if (flowWaiter is null)
            return;

        auto waiter = flowWaiter;
        flowWaiter = null;
        if (!waiter.cancelled)
            waiter.setResult;
    }

    private void maybeResumeTransport()
    {
        if (paused && buffer.length <= limit)
        {
            paused = false;
            transport.resumeReading;
        }
    }

    /**
     * Wait until $(D_PSYMBOL feedData()) or $(D_PSYMBOL feedEof()) is called.
     */
    @Coroutine
    private void waitForData(string functionName)
    {
        // StreamReader uses a future to link the protocol feed_data() method
        // to a read coroutine. Running two read coroutines at the same time
        // would have an unexpected behaviour. It would not possible to know
        // which coroutine would get the next data.
        enforce(flowWaiter is null,
            "%s() called while another coroutine is already waiting for incoming data"
                .format(functionName));

        flowWaiter = new Waiter(eventLoop);
        eventLoop.waitFor(flowWaiter);
        flowWaiter = null;
    }

    /**
     * Read up to $(D_PSYMBOL n) bytes. If $(D_PSYMBOL n) is not provided, or
     * set to -1, read until EOF and return all read bytes.
     *
     * If the EOF was received and the internal buffer is empty, return an empty
     * array.
     */
    @Coroutine
    const(void)[] read(ptrdiff_t n = -1)
    {
        if (exception !is null)
            throw exception;

        if (n == 0)
            return null;

        if (n < 0)
        {
            // This used to just loop creating a new waiter hoping to
            // collect everything in this.buffer, but that would
            // deadlock if the subprocess sends more than this.limit
            // bytes. So just call read(limit) until EOF.
            Appender!(const(char)[]) buff;

            while (true)
            {
                const(char)[] chunk = cast(const(char)[]) read(limit);
                if (chunk.empty)
                    break;
                buff ~= chunk;
            }

            return buff.data;
        }

        if (buffer.empty && !eof)
            waitForData("read");

        const(void)[] data;

        if (buffer.length <= n)
        {
            data = buffer;
            buffer = null;
        }
        else
        {
            data = buffer[0 .. n];
            buffer = buffer[n .. $];
        }

        maybeResumeTransport;

        return data;
    }

    /**
     * Read one line, where “line” is a sequence of bytes ending with '\n'.
     *
     * If EOF is received, and '\n' was not found, the method will return the
     * partial read bytes.
     *
     * If the EOF was received and the internal buffer is empty, return an empty
     * array.
     */
    @Coroutine
    const(char)[] readline()
    {
        if (exception !is null)
            throw exception;

        Appender!(const(char)[]) line;
        bool notEnough = true;

        while (notEnough)
        {
            while (!buffer.empty && notEnough)
            {
                const(char)[] buffer1 = cast(const(char)[]) buffer;
                auto r = buffer1.findSplit(['\n']);
                line ~= r[0];
                buffer = r[2];

                if (!r[1].empty)
                    notEnough = false;

                if (line.data.length > limit)
                {
                    maybeResumeTransport;
                    throw new Exception("Line is too long");
                }
            }

            if (eof)
                break;

            if (notEnough)
                waitForData("readline");
        }

        maybeResumeTransport;
        return line.data;
    }

    /**
     * Read exactly $(D_PSYMBOL n) bytes. Raise an $(D_PSYMBOL
     * IncompleteReadError) if the end of the stream is reached before
     * $(D_PSYMBOL n) can be read, the $(D_PSYMBOL IncompleteReadError.partial)
     * attribute of the exception contains the partial read bytes.
     */
    @Coroutine
    const(void)[] readexactly(size_t n)
    {
        if (exception !is null)
            throw exception;

        // There used to be "optimized" code here.  It created its own
        // Future and waited until self._buffer had at least the n
        // bytes, then called read(n).  Unfortunately, this could pause
        // the transport if the argument was larger than the pause
        // limit (which is twice self._limit).  So now we just read()
        // into a local buffer.

        Appender!(const(char)[]) data;

        while (n > 0)
        {
            const(char)[] block = cast(const(char)[]) read(n);

            if (block.empty)
                throw new IncompleteReadError(data.data, data.data.length + n);

            data ~= block;
            n -= block.length;
        }

        return data.data;
    }

    /**
     * Return $(D_KEYWORD true) if the buffer is empty and $(D_PSYMBOL feedEof())
     * was called.
     */
    bool atEof()
    {
        return eof && buffer.empty;
    }
}

/**
 * Wraps a Transport.
 *
 * This exposes $(D_PSYMBOL write()), $(D_PSYMBOL writeEof()), $(D_PSYMBOL
 * canWriteEof()), $(D_PSYMBOL getExtraInfo()) and $(D_PSYMBOL close()). It adds
 * $(D_PSYMBOL drain()) coroutine for waiting for flow control.  It also adds a
 * $(D_PSYMBOL transport) property which references the Transport directly.
 *
 * This class is not thread safe.
 */
final class StreamWriter
{
    private EventLoop eventLoop;
    private WriteTransport transport_;
    private StreamReaderProtocol protocol;
    private StreamReader streamReader;

    this(EventLoop eventLoop, Transport transport, Protocol protocol,
        StreamReader streamReader)
    {
        this.eventLoop = eventLoop;
        this.transport_ = transport;
        this.protocol = cast(StreamReaderProtocol) protocol;
        enforce(this.protocol !is null, "StreamReaderProtocol is needed");
        this.streamReader = streamReader;
    }

    override string toString()
    {
        import std.string;

        return "%s(transport = %s, reader = %s)".format(typeof(this).stringof,
            transport, streamReader);
    }

    /**
     * Transport.
     */
    @property WriteTransport transport()
    {
        return transport_;
    }

    /**
     * Return $(D_KEYWORD true) if the transport supports $(D_PSYMBOL
     * writeEof()), $(D_KEYWORD false) if not. See $(D_PSYMBOL
     * WriteTransport.canWriteEof()).
     */
    bool canWriteEof()
    {
        return transport_.canWriteEof;
    }

    /**
     * Close the transport: see $(D_PSYMBOL BaseTransport.close()).
     */
    void close()
    {
        return transport_.close;
    }

    /**
     * Let the write buffer of the underlying transport a chance to be flushed.
     *
     * The intended use is to write:
     *
     * w.write(data)
     * w.drain()
     *
     * When the size of the transport buffer reaches the high-water limit (the
     * protocol is paused), block until the size of the buffer is drained down
     * to the low-water limit and the protocol is resumed. When there is nothing
     * to wait for, the continues immediately.
     *
     * Calling $(D_PSYMBOL drain()) gives the opportunity for the loop to
     * schedule the write operation and flush the buffer. It should especially
     * be used when a possibly large amount of data is written to the transport,
     * and the coroutine does not process the event loop between calls to
     * $(D_PSYMBOL write()).
     */
    @Coroutine
    void drain()
    {
        if (streamReader !is null)
        {
            auto exception = streamReader.exception;
            if (exception !is null)
                throw exception;
        }
        protocol.drainHelper;
    }

    /**
     * Return optional transport information: see $(D_PSYMBOL
     * BaseTransport.getExtraInfo()).
     */
    string getExtraInfo(string name)()
    {
        return transport_.getExtraInfo!name;
    }

    /**
     * Write some data bytes to the transport: see $(D_PSYMBOL
     * WriteTransport.write()).
     */
    void write(const(void)[] data)
    {
        transport_.write(data);
    }

    /**
     * Close the write end of the transport after flushing buffered data: see
     * $(D_PSYMBOL WriteTransport.write_eof()).
     */
    void writeEof()
    {
        transport_.writeEof;
    }
}
