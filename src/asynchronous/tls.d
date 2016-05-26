/**
 * TLS support.
 *
 * Copyright: © 2015-2016 Dragos Carp
 * License: Boost Software License - Version 1.0
 * Authors: Dragos Carp
 */
module asynchronous.tls;

import std.typecons : Tuple, tuple, Nullable;
import asynchronous.protocols : Protocol;
import asynchronous.transports;
import asynchronous.events : TLSContext, EventLoop;
import asynchronous.types : NotImplementedException;

version (Have_botan)
{
    import asynchronous.internal.botan;
}

/** Supported TLS protocol versions */
enum ProtocolVersion
{
    TLSv1_2,
}

/**
 * Handshake failed.
 */
class TLSHandshakeException : Exception
{
    this(string message = null, string file = __FILE__, size_t line = __LINE__,
        Throwable next = null) @safe pure nothrow
    {
        super(message ? message : "TLS handshake failed.", file, line, next);
    }
}

/**
 * Creates a new TLS context.
 *
 * Params:
 *  ver = the protocol version.
 *
 * See_Also: $(D_PSYMBOL ProtocolVersion)
 */
TLSContext createTLSContext(ProtocolVersion ver = ProtocolVersion.TLSv1_2)
{
    version (Have_botan)
    {
        return new BotanTLSContext(ver);
    }
    assert(0, "TLS cryptographic library (like Botan) missing");
}

abstract class TLSProtocol : Protocol
{
    protected Transport transport;

    void abort()
    {
        if (transport !is null)
        {
            try
            {
                transport.abort();
            }
            finally
            {
                transport.close();
            }
        }
    }

    protected void startShutdown();

    protected void writeAppdata(const(void)[] data);
}

TLSProtocol createTLSProtocol(EventLoop eventLoop,
                              Protocol protocol,
                              TLSContext tlsContext)
{
    version (Have_botan)
    {
        return new BotanTLSProtocol(eventLoop, protocol,
            cast(BotanTLSContext) tlsContext);
    }
    assert(0, "TLS cryptographic library (like Botan) missing");
}

package class TLSTransport : FlowControlTransport
{
    this(EventLoop eventLoop, TLSProtocol tlsProtocol, Protocol appProtocol)
    {
        super(eventLoop);

        this.tlsProtocol = tlsProtocol;
        this.appProtocol = appProtocol;
    }

    override @property TLSProtocol protocol() pure nothrow @safe
    {
        return tlsProtocol;
    }

    bool isClosing() pure nothrow @safe
    {
        return closed;
    }

    /**
     * Close the transport.
     *
     * Buffered data will be flushed asynchronously.  No more data
     * will be received. After all buffered data is flushed, the
     * protocol's $(D_PSYMBOL connectionLost()) method will be
     * (eventually) called with $(D_KEYWORD null) as its argument.
     */
    void close()
    {
        closed = true;
        protocol.startShutdown();
    }

    /**
     * Pause the receiving end.
     *
     * No data will be passed to the protocol's data_received()
     * method until resume_reading() is called.
     */
    void pauseReading()
    {
        protocol.transport.resumeReading();
    }

    /**
     * Resume the receiving end.
     *
     * Data received will once again be passed to the protocol's
     * $(D_PSYMBOL data_received()) method.
     */
    void resumeReading()
    {
        protocol.transport.resumeReading();
    }

    /**
     * Set the high- and low-water limits for write flow control.
     *
     * These two values control when to call the protocol's
     * $(D_PSYMBOL pauseWriting()) and $(D_PSYMBOL resumeWriting())
     *  methods. If specified, the low-water limit must be less than
     * or equal to the high-water limit.  Neither value can be negative.
     *
     * The defaults are implementation-specific. If only the
     * high-water limit is given, the low-water limit defaults to an
     * implementation-specific value less than or equal to the high-water
     * limit.  Setting high to zero forces low to zero as well, and causes
     * $(D_PSYMBOL pauseWriting()) to be called whenever the buffer becomes
     * non-empty. Setting low to zero causes $(D_PSYMBOL resumeWriting())
     * to be called only once the buffer is empty.
     * Use of zero for either limit is generally sub-optimal as it
     * reduces opportunities for doing I/O and computation concurrently.
     */
    override void setWriteBufferLimits(Nullable!size_t high = Nullable!size_t(),
                                       Nullable!size_t low = Nullable!size_t())
    {
        protocol.transport.setWriteBufferLimits(high, low);
    }

    /**
     * Return the current size of the write buffer.
     */
    size_t getWriteBufferSize()
    {
        return protocol.transport.getWriteBufferSize();
    }

    /**
     * Write some data bytes to the transport.
     *
     * This does not block; it buffers the data and arranges for it
     * to be sent out asynchronously.
     */
    void write(const(void)[] data)
    {
        if (data)
        {
            protocol.writeAppdata(data);
        }
    }

    /**
     * Return $(D_KEYWORD true) if this transport supports
     * $(D_PSYMBOL writeEof()), $(D_KEYWORD false) if not.
     */
    bool canWriteEof()
    {
        return false;
    }

    /**
     * Close the transport immediately.
     *
     * Buffered data will be lost. No more data will be received.
     * The protocol's $(D_PSYMBOL connectionLost()) method will
     * (eventually) be called with $(D_KEYWORD null) as its argument.
     */
    void abort()
    {
        protocol.abort();
    }

    /**
     * Close the write end of the transport after flushing buffered data.
     *
     * Data may still be received.
     *
     * Throws: $(D_PSYMBOL NotImplementedException).
     */
    void writeEof()
    {
        throw new NotImplementedException("SSL doesn't support half-closes");
    }

private:
    Protocol appProtocol;
    TLSProtocol tlsProtocol;
    bool closed;
}
