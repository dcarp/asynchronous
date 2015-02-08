module asynchronous.protocols;

import asynchronous.transports;

alias ProtocolFactory = Protocol function();

/**
 * Common interface for protocol interfaces.
 *
 * Usually user implements protocols that derived from BaseProtocol like
 * Protocol or ProcessProtocol.
 *
 * The only case when BaseProtocol should be implemented directly is write-only
 * transport like write pipe
 */
interface BaseProtocol
{
    /// Connection callbacks
    /**
     * $(D_PSYMBOL connectionMade()) and $(D_PSYMBOL connectionLost()) are
     * called exactly once per successful connection. All other callbacks will
     * be called between those two methods, which allows for easier resource
     * management in your protocol implementation.
     */

    /**
     * Called when a connection is made.
     *
     * Params:
     *  transport = is the transport representing the connection. You are
     *              responsible for storing it somewhere if you need to.
     */
    void connectionMade(BaseTransport transport);

    /**
     * Called when the connection is lost or closed.
     *
     * Params:
     *  exception = is either an exception object or $(D_KEYWORD null). The
     *              latter means a regular EOF is received, or the connection
     *              was aborted or closed by this side of the connection.
     */
    void connectionLost(Exception exception);

    /// Flow control callbacks
    /**
     * $(D_PSYMBOL pauseWriting()) and $(D_PSYMBOL resumeWriting()) calls are
     * paired – $(D_PSYMBOL pauseWriting() is called once when the buffer goes
     * strictly over the high-water mark (even if subsequent writes increases
     * the buffer size even more), and eventually $(D_PSYMBOL resumeWriting())
     * is called once when the buffer size reaches the low-water mark.
     */


    /**
     * Called when the transport’s buffer goes over the high-water mark.
     */
    void pauseWriting();

    /**
     * Called when the transport’s buffer drains below the low-water mark.
     */
    void resumeWriting();
}


/**
 * Interface for stream protocol.
 */
interface Protocol : BaseProtocol
{
    /**
     * Called when some data is received.
     *
     * Params:
     *  data = is a non-empty array containing the incoming data.
     */
    void dataReceived(const(void)[] data);

    /**
     * Calls when the other end signals it won’t send any more data (for example
     * by calling $(D_PSYMBOL writeEof()), if the other end also uses
     * asynchronous IO).
     *
     * This method may return a $(D_KEYWORD false) value, in which case the
     * transport will close itself. Conversely, if this method returns a
     * $(D_KEYWORD true) value, closing the transport is up to the protocol.
     */
    bool eofReceived();

    /**
     * $(D_PSYMBOL dataReceived()) can be called an arbitrary number of times
     * during a connection. However, $(D_PSYMBOL eofReceived()) is called at
     * most once and, if called, $(D_PSYMBOL dataReceived()) won’t be called
     * after it.
     */
}


/**
 * Interface for datagram protocol.
 */
interface DatagramProtocol : BaseProtocol
{
    /**
     * Called when a datagram is received.
     *
     * Params:
     *  data = is an array containing the incoming data.
     *  address = is the address of the peer sending the data; the exact format
     *            depends on the transport.
     */
    void datagramReceived(const(void)[] data, Address address);

    /**
     * Called when a previous send or receive operation raises an exception.
     *
     * Params:
     *  exception = is the exception instance.
     *
     * This method is called in rare conditions, when the transport (e.g. UDP)
     * detects that a datagram couldn’t be delivered to its recipient. In many
     * conditions though, undeliverable datagrams will be silently dropped.
     */
    void errorReceived(Exception exception);
}


/**
 * Interface for protocol for subprocess calls.
 */
interface SubprocessProtocol : BaseProtocol
{
    /**
     * Called when the child process writes data into its stdout or stderr pipe.
     *
     * Params:
     *  fd = is the file descriptor of the pipe.
     *  data = is a non-empty array containing the data.
     */
    void pipeDataReceived(int fd, const(void)[] data);

    /**
     * Called when one of the pipes communicating with the child process is
     * closed.
     *
     * Params:
     *  fd = is the file descriptor that was closed.
     */
    void pipeConnectionLost(int fd, Exception exception);

    /**
     * Called when the child process has exited.
     */
    void processExited();
}
