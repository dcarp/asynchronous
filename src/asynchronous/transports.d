module asynchronous.transports;

import std.process : Pid, Pipe;
import std.socket : Address;
import std.typecons;

/**
 * Interface for transports.
 */
interface BaseTransport
{
    /**
     * Get optional transport information.
     */
    string getExtraInfo(string name)();

    /**
     * Close the transport.
     *
     * If the transport has a buffer for outgoing data, buffered data will be
     * flushed asynchronously. No more data will be received. After all buffered
     * data is flushed, the protocol’s $(D_PSYMBOL connectionLost()) method will
     * be called with $(D_KEYWORD null) as its argument.
     */
    void close();
}


/**
 * Interface for read-only transports.
 */
interface ReadTransport : BaseTransport
{
    /**
     * Pause the receiving end.
     *
     * No data will be passed to the protocol's $(D_PSYMBOL dataReceived())
     * method until $(D_PSYMBOL resumeReading()) is called.
     */
    void pauseReading();

    /**
     * Resume the receiving end.
     *
     * The protocol’s $(D_PSYMBOL dataReceived()) method will be called once
     * again if some data is available for reading.
     */
    void resumeReading();
}

alias BufferLimits = Tuple!(size_t, "high", size_t, "low");

/**
 * Interface for write-only transports.
 */
interface WriteTransport : BaseTransport
{
    /**
     * Close the transport immediately, without waiting for pending operations
     * to complete.
     *
     * Buffered data will be lost. No more data will be received. The protocol's
     * $(D_PSYMBOL connectionLost()) method will eventually be called with
     * $(D_KEYWORD null) as its argument.
     */
    void abort();

    /**
     * Returns: $(D_KEYWORD true) if this transport supports $(D_PSYMBOL
     * writeEof()), $(D_KEYWORD false) if not.
     */
    bool canWriteEof();

    /**
     * Returns: the current size of the output buffer used by the transport.
     */
    size_t getWriteBufferSize();

    /**
     * Get the high- and low-water limits for write flow control.
     *
     * Returns: a tuple (low, high) where low and high are positive number of
     *          bytes.
     */
    BufferLimits getWriteBufferLimits();

    /**
     * Set the high- and low-water limits for write flow control.
     *
     * These two values control when call the protocol's $(D_PSYMBOL
     * pauseWriting()) and $(D_PSYMBOL resumeWriting()) methods are called. If
     * specified, the low-water limit must be less than or equal to the
     * high-water limit.
     * 
     * The defaults are implementation-specific.  If only the high-water limit
     * is given, the low-water limit defaults to a implementation-specific value
     * less than or equal to the high-water limit.  Setting $(D_PSYMBOL high) to
     * zero forces low to zero as well, and causes $(D_PSYMBOL pauseWriting())
     * to be called whenever the buffer becomes non-empty. Setting $(D_PSYMBOL
     * low) to zero causes $(D_PSYMBOL resumeWriting()) to be called only once
     * the buffer is empty. Use of zero for either limit is generally
     * sub-optimal as it reduces opportunities for doing I/O and computation
     * concurrently.
     */
    void setWriteBufferLimits(Nullable!size_t high = Nullable!size_t(),
                              Nullable!size_t low = Nullable!size_t());

    /**
     * Write some data bytes to the transport.
     *
     * This does not block; it buffers the data and arranges for it to be sent
     * out asynchronously.
     */
    void write(const(void)[] data);
 
    /**
     * Close the write end of the transport after flushing buffered data.
     *
     * Data may still be received.
     *
     * This method can throw $(D_PSYMBOL NotImplementedError) if the transport
     * (e.g. SSL) doesn’t support half-closes.
     */
    void writeEof();
}


/**
 * Interface representing a bidirectional transport.
 *
 * There may be several implementations, but typically, the user does not
 * implement new transports; rather, the platform provides some useful
 * transports that are implemented using the platform's best practices.
 *
 * The user never instantiates a transport directly; they call a utility
 * function, passing it a protocol factory and other information necessary to
 * create the transport and protocol. (E.g. $(D_PSYMBOL
 * EventLoop.createConnection()) or $(D_PSYMBOL EventLoop.createServer()).)
 *
 * The utility function will asynchronously create a transport and a protocol
 * and hook them up by calling the protocol's $(D_PSYMBOL connectionMade())
 * method, passing it the transport.
 */
interface Transport : ReadTransport, WriteTransport
{
}


/**
 * Interface for datagram (UDP) transports.
 */
interface DatagramTransport : BaseTransport
{
    /**
     * Send the data bytes to the remote peer given by address (a
     * transport-dependent target address).
     *
     * If $(D_PSYMBOL address) is $(D_KEYWORD null), the data is sent to the
     * target address given on transport
     * creation.
     *
     * This method does not block; it buffers the data and arranges for it to be
     * sent out asynchronously.
     */
    void sendTo(const(void)[] data, Address address = null);

    /**
     * Close the transport immediately, without waiting for pending operations
     * to complete.
     *
     * Buffered data will be lost. No more data will be received. The protocol’s
     * $(D_PSYMBOL connectionLost()) method will eventually be called with
     * $(D_KEYWORD null) as its argument.
     */
    void abort();
}

alias SubprocessStatus = Tuple!(bool, "terminated", int, "status");

interface SubprocessTransport : BaseTransport
{
    /**
     * Returns: the subprocess process id as an integer.
     */
    Pid getPid();


    /**
     * Returns: the transport for the communication pipe corresponding to the
     * integer file descriptor fd:
     *
     * 0: readable streaming transport of the standard input (stdin), or throws
     *    $(D_PSYMBOL Exception) if the subprocess was not created with stdin =
     *    PIPE
     * 1: writable streaming transport of the standard output (stdout), or
     *    throws $(D_PSYMBOL Exception) if the subprocess was not created with
     *    stdout = PIPE
     * 2: writable streaming transport of the standard error (stderr), or throws
     *    $(D_PSYMBOL Exception) if the subprocess was not created with stderr =
     *    PIPE
     * other fd: throws $(D_PSYMBOL Exception)
     */
    Pipe getPipeTransport(int fd);

    /**
     * Returns: the subprocess exit status, similarly to the $(D_PSYMBOL
     *          std.process.tryWait).
     */
    SubprocessStatus getStatus();

    /**
     * Kill the subprocess.
     *
     * On POSIX systems, the function sends SIGKILL to the subprocess. On
     * Windows, this method is an alias for $(D_PSYMBOL terminate()).
     */
    void kill();

    /**
     * Send the signal number to the subprocess, as in $(D_PSYMBOL
     * std.process.kill).
     */
    void sendSignal(int signal);

    /**
     * Ask the subprocess to stop. This method is an alias for the close()
     * method.
     *
     * On POSIX systems, this method sends SIGTERM to the subprocess. On
     * Windows, the Windows API function TerminateProcess() is called to stop
     * the subprocess.
     */
    void terminate();

    /**
     * Ask the subprocess to stop by calling the terminate() method if the
     * subprocess hasn’t returned yet, and close transports of all pipes (stdin,
     * stdout and stderr).
     */
    void close();
}

/*
class _FlowControlMixin(Transport):
    """All the logic for (write) flow control in a mix-in base class.

    The subclass must implement get_write_buffer_size().  It must call
    _maybe_pause_protocol() whenever the write buffer size increases,
    and _maybe_resume_protocol() whenever it decreases.  It may also
    override set_write_buffer_limits() (e.g. to specify different
    defaults).

    The subclass constructor must call super().__init__(extra).  This
    will call set_write_buffer_limits().

    The user may call set_write_buffer_limits() and
    get_write_buffer_size(), and their protocol's pause_writing() and
    resume_writing() may be called.
    """

    def __init__(self, extra=None, loop=None):
        super().__init__(extra)
        assert loop is not None
        self._loop = loop
        self._protocol_paused = False
        self._set_write_buffer_limits()

    def _maybe_pause_protocol(self):
        size = self.get_write_buffer_size()
        if size <= self._high_water:
            return
        if not self._protocol_paused:
            self._protocol_paused = True
            try:
                self._protocol.pause_writing()
            except Exception as exc:
                self._loop.call_exception_handler({
                    'message': 'protocol.pause_writing() failed',
                    'exception': exc,
                    'transport': self,
                    'protocol': self._protocol,
                })

    def _maybe_resume_protocol(self):
        if (self._protocol_paused and
            self.get_write_buffer_size() <= self._low_water):
            self._protocol_paused = False
            try:
                self._protocol.resume_writing()
            except Exception as exc:
                self._loop.call_exception_handler({
                    'message': 'protocol.resume_writing() failed',
                    'exception': exc,
                    'transport': self,
                    'protocol': self._protocol,
                })

    def get_write_buffer_limits(self):
        return (self._low_water, self._high_water)

    def _set_write_buffer_limits(self, high=None, low=None):
        if high is None:
            if low is None:
                high = 64*1024
            else:
                high = 4*low
        if low is None:
            low = high // 4
        if not high >= low >= 0:
            raise ValueError('high (%r) must be >= low (%r) must be >= 0' %
                             (high, low))
        self._high_water = high
        self._low_water = low

    def set_write_buffer_limits(self, high=None, low=None):
        self._set_write_buffer_limits(high=high, low=low)
        self._maybe_pause_protocol()

    def get_write_buffer_size(self):
        raise NotImplementedError
*/
