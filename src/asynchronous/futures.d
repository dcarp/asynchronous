/**
 * Future classes.
 *
 * Copyright: © 2015-2016 Dragos Carp
 * License: Boost Software License - Version 1.0
 * Authors: Dragos Carp
 */
module asynchronous.futures;

import std.algorithm;
import std.array;
import asynchronous.events;
import asynchronous.types;

interface FutureHandle
{
    /**
     * Cancel the future and schedule callbacks.
     *
     * If the future is already done or cancelled, return $(D_KEYWORD false).
     * Otherwise, change the future's state to cancelled, schedule the
     * callbacks and return $(D_KEYWORD true).
     */
    bool cancel();

    /**
     * Return $(D_KEYWORD true) if the future was cancelled.
     */
    bool cancelled() const;

    /**
     * Return $(D_KEYWORD true) if the future is done.
     *
     * Done means either that a result/exception are available, or that the
     * future was cancelled.
     */
    bool done() const;

    /**
     * Returns: the exception that was set on this future.
     *
     * The exception (or $(D_KEYWORD null) if no exception was set) is returned
     * only if the future is done. If the future has been cancelled, throws
     * $(D_PSYMBOL CancelledException). If the future isn't done, throws
     * $(D_PSYMBOL InvalidStateException).
     */
    Throwable exception();

    /**
     * Add a callback to be run when the future becomes done.
     *
     * The callback is called with a single argument - the future object. If
     * the future is already done when this is called, the callback is
     * scheduled with $(D_PSYMBOL callSoon())
     */
    void addDoneCallback(void delegate(FutureHandle) callback);

    /**
     * Remove all instances of a callback from the "call when done" list.
     *
     * Returns: the number of callbacks removed;
     */
    size_t removeDoneCallback(void delegate(FutureHandle) callback);

    /**
     * Mark the future done and set an exception.
     *
     * If the future is already done when this method is called, throws
     * $(D_PSYMBOL InvalidStateError).
     */
    void setException(Throwable exception);

    string toString() const;
}

abstract class BaseFuture : FutureHandle
{
    private enum State : ubyte
    {
        PENDING,
        CANCELLED,
        FINISHED,
    }

    package EventLoop eventLoop;

    private void delegate(FutureHandle)[] callbacks = null;

    private State state = State.PENDING;

    private Throwable exception_;

    this(EventLoop eventLoop = null)
    {
        this.eventLoop = eventLoop is null ? getEventLoop : eventLoop;
    }

    bool cancel()
    {
        if (this.state != State.PENDING)
            return false;

        this.state = State.CANCELLED;
        scheduleCallbacks;
        return true;
    }

    private void scheduleCallbacks()
    {
        if (this.callbacks.empty)
            return;

        auto scheduledCallbacks = this.callbacks;
        this.callbacks = null;

        foreach (callback; scheduledCallbacks)
        {
            this.eventLoop.callSoon(callback, this);
        }
    }

    override bool cancelled() const
    {
        return this.state == State.CANCELLED;
    }

    override bool done() const
    {
        return this.state != State.PENDING;
    }

    override Throwable exception()
    {
        final switch (this.state)
        {
        case State.PENDING:
            throw new InvalidStateException("Exception is not set.");
        case State.CANCELLED:
            throw new CancelledException;
        case State.FINISHED:
            return this.exception_;
        }
    }

    override void addDoneCallback(void delegate(FutureHandle) callback)
    {
        if (this.state != State.PENDING)
            this.eventLoop.callSoon(callback, this);
        else
            this.callbacks ~= callback;
    }

    override size_t removeDoneCallback(void delegate(FutureHandle) callback)
    {
        size_t length = this.callbacks.length;

        this.callbacks = this.callbacks.remove!(a => a is callback);

        return length - this.callbacks.length;
    }

    override void setException(Throwable exception)
    {
        if (this.state != State.PENDING)
            throw new InvalidStateException("Result or exception already set");

        this.exception_ = exception;
        this.state = State.FINISHED;
        scheduleCallbacks;
    }

    override string toString() const
    {
        import std.format : format;

        return "%s(done: %s, cancelled: %s)".format(typeid(this), done, cancelled);
    }
}

/**
 * Encapsulates the asynchronous execution of a callable.
 */
class Future(T) : BaseFuture
{
    static if (!is(T == void))
        private T result_;

    alias ResultType = T;

    this(EventLoop eventLoop = null)
    {
        super(eventLoop);
    }

    /**
     * Returns: the result this future represents.
     *
     * If the future has been cancelled, throws
     * $(D_PSYMBOL CancelledException). If the future's result isn't yet
     * available, throws $(D_PSYMBOL InvalidStateException). If the future is
     * done and has an exception set, this exception is thrown.
     */
    T result()
    {
        final switch (this.state)
        {
        case State.PENDING:
            throw new InvalidStateException("Result is not ready.");
        case State.CANCELLED:
            throw new CancelledException;
        case State.FINISHED:
            if (this.exception_)
                throw this.exception_;
            return this.result_;
        }
    }

    /**
     * Helper setting the result only if the future was not cancelled.
     */
    package void setResultUnlessCancelled(T result)
    {
        if (cancelled)
            return;
        setResult(result);
    }

    /**
     * Mark the future done and set its result.
     *
     * If the future is already done when this method is called, throws
     * $(D_PSYMBOL InvalidStateError).
     */
    void setResult(T result)
    {
        if (this.state != State.PENDING)
            throw new InvalidStateException("Result or exception already set");

        this.result_ = result;
        this.state = State.FINISHED;
        scheduleCallbacks;
    }
}

alias Waiter = Future!void;

class Future(T : void) : BaseFuture
{
    alias ResultType = void;

    this(EventLoop eventLoop = null)
    {
        super(eventLoop);
    }

    /**
     * Returns: void.
     *
     * If the future has been cancelled, throws
     * $(D_PSYMBOL CancelledException). If the future's result isn't yet
     * available, throws $(D_PSYMBOL InvalidStateException). If the future is
     * done and has an exception set, this exception is thrown.
     */
    T result()
    {
        final switch (this.state)
        {
        case State.PENDING:
            throw new InvalidStateException("Result is not ready.");
        case State.CANCELLED:
            throw new CancelledException;
        case State.FINISHED:
            if (this.exception_)
                throw this.exception_;
            return;
        }
    }

    /**
     * Helper setting the result only if the future was not cancelled.
     */
    package void setResultUnlessCancelled()
    {
        if (cancelled)
            return;
        setResult();
    }

    /**
     * Mark the future done.
     *
     * If the future is already done when this method is called, throws
     * $(D_PSYMBOL InvalidStateError).
     */
    void setResult()
    {
        if (this.state != State.PENDING)
            throw new InvalidStateException("Result or exception already set");

        this.state = State.FINISHED;
        scheduleCallbacks;
    }
}

unittest
{
    import std.exception : assertNotThrown, assertThrown;

    auto future = new Future!int;
    assert(!future.done);
    assert(!future.cancelled);
    assertThrown(future.exception);
    assertThrown(future.result);

    future = new Future!int;
    future.setResult(42);
    assert(future.done);
    assert(!future.cancelled);
    assert(future.result == 42);
    assert(future.exception is null);

    future = new Future!int;
    future.cancel;
    assert(future.done);
    assert(future.cancelled);
    assertThrown(future.exception);
    assertThrown(future.result);

    future = new Future!int;
    future.setException(new Exception("foo"));
    assert(future.done);
    assert(!future.cancelled);
    assert(future.exception !is null);
    assertThrown(future.result);

    auto future2 = new Future!void;
    assert(!future2.done);
    assert(!future2.cancelled);
    assertThrown(future2.exception);
    assertThrown(future2.result);

    future2 = new Future!void;
    future2.setResult;
    assert(future2.done);
    assert(!future2.cancelled);
    assert(future2.exception is null);
    assertNotThrown(future2.result);

    future2 = new Future!void;
    future2.cancel;
    assert(future2.done);
    assert(future2.cancelled);
    assertThrown(future2.exception);
    assertThrown(future2.result);

    future2 = new Future!void;
    future2.setException(new Exception("foo"));
    assert(future2.done);
    assert(!future2.cancelled);
    assert(future2.exception !is null);
    assertThrown(future2.result);
}
