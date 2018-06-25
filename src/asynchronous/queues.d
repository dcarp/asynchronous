/**
 * Queues.
 *
 * Copyright: © 2015-2016 Dragos Carp
 * License: Boost Software License - Version 1.0
 * Authors: Dragos Carp
 */
module asynchronous.queues;

import std.algorithm;
import std.exception;
import std.range;
import std.typecons;
import asynchronous.events : EventLoop, getEventLoop;
import asynchronous.futures : Waiter;
import asynchronous.locks : Event;
import asynchronous.tasks : waitFor;
import asynchronous.types : Coroutine;

/**
 * Exception thrown when $(D_PSYMBOL Queue.getNowait()) is called on a
 * $(D_PSYMBOL Queue) object which is empty.
 */
class QueueEmptyException : Exception
{
    this(string message = null, string file = __FILE__, size_t line = __LINE__,
        Throwable next = null) @safe pure nothrow
    {
        super(message, file, line, next);
    }
}

/**
 * Exception thrown when $(D_PSYMBOL Queue.putNowait()) is called on a
 * $(D_PSYMBOL Queue) object which is full.
 */
class QueueFullException : Exception
{
    this(string message = null, string file = __FILE__, size_t line = __LINE__,
        Throwable next = null) @safe pure nothrow
    {
        super(message, file, line, next);
    }
}

/**
 * A queue, useful for coordinating producer and consumer coroutines.
 *
 * If $(D_PSYMBOL maxSize) is equal to zero, the queue size is infinite.
 * Otherwise $(D_PSYMBOL put()) will block when the queue reaches maxsize, until
 * an item is removed by $(D_PSYMBOL get()).
 *
 * You can reliably know this $(D_PSYMBOL Queue)'s size with $(D_PSYMBOL
 * qsize()), since your single-threaded asynchronous application won't be
 * interrupted between calling $(D_PSYMBOL qsize()) and doing an operation on
 * the Queue.
 *
 * This class is not thread safe.
 */
class Queue(T, size_t maxSize = 0)
{
    private EventLoop eventLoop;
    private Waiter[] getters;
    private Waiter[] putters;
    private size_t unfinishedTasks = 0;
    private Event finished;
    private T[] queue;
    private size_t start = 0;
    private size_t length = 0;

    this(EventLoop eventLoop = null)
    {
        if (eventLoop is null)
            this.eventLoop = getEventLoop;
        else
            this.eventLoop = eventLoop;

        this.finished = new Event(this.eventLoop);
        this.finished.set;
    }

    override string toString() const
    {
        import std.format : format;

        auto data = chain(cast(T[]) queue, cast(T[]) queue)[start .. start + length];

        return "%s(maxsize %s, queue %s, getters %s, putters %s, unfinishedTasks %s)"
            .format(typeid(this), maxSize, data, getters, putters, unfinishedTasks);
    }

    protected T get_()
    {
        auto result = queue[start];
        queue[start] = T.init;
        ++start;
        if (start == queue.length)
            start = 0;
        --length;
        return result;
    }

    protected void put_(T item)
    {
        queue[(start + length) % $] = item;
        ++length;
    }

    private void ensureCapacity()
    {
        if (length < queue.length)
            return;

        static if (maxSize > 0)
            assert(length < maxSize);
        assert(length == queue.length);

        size_t newLength = max(8, length * 2);

        static if (maxSize > 0)
            newLength = min(newLength, maxSize);

        bringToFront(queue[0 .. start], queue[start .. $]);
        start = 0;

        queue.length = newLength;

        static if (maxSize == 0)
            queue.length = queue.capacity;
    }

    private void wakeupNext(ref Waiter[] waiters)
    {
        waiters = waiters.remove!(a => a.done);

        if (!waiters.empty)
            waiters[0].setResult;
    }

    private void consumeDonePutters()
    {
        // Delete waiters at the head of the put() queue who've timed out.
        putters = putters.find!(g => !g.done);
    }

    /**
     * Return $(D_KEYWORD true) if the queue is empty, $(D_KEYWORD false)
     * otherwise.
     */
    @property bool empty()
    {
        return length == 0;
    }

    /**
     * Return $(D_KEYWORD true) if there are maxsize items in the queue.
     *
     * Note: if the Queue was initialized with $(D_PSYMBOL maxsize) = 0 (the
     * default), then $(D_PSYMBOL full()) is never $(D_KEYWORD true).
     */
    @property bool full()
    {
        static if (maxSize == 0)
            return false;
        else
            return qsize >= maxSize;
    }

    /**
     * Remove and return an item from the queue.
     *
     * If queue is empty, wait until an item is available.
     */
    @Coroutine
    T get()
    {
        while (empty)
        {
            auto waiter = new Waiter(eventLoop);

            getters ~= waiter;
            eventLoop.waitFor(waiter);
        }

        return getNowait;
    }

    /**
     * Remove and return an item from the queue.
     *
     * Return an item if one is immediately available, else throw $(D_PSYMBOL
     * QueueEmptyException).
     */
    @Coroutine
    T getNowait()
    {
        enforce!QueueEmptyException(length > 0);

        T item = get_;

        wakeupNext(putters);

        return item;
    }

    /**
     * Block until all items in the queue have been gotten and processed.
     *
     * The count of unfinished tasks goes up whenever an item is added to the
     * queue. The count goes down whenever a consumer calls $(D_PSYMBOL
     * taskDone()) to indicate that the item was retrieved and all work on it is
     * complete.
     * When the count of unfinished tasks drops to zero, $(D_PSYMBOL join())
     * unblocks.
     */
    @Coroutine
    void join()
    {
        if (unfinishedTasks > 0)
            finished.wait;
    }

    /**
     * Put an item into the queue.
     *
     * If the queue is full, wait until a free slot is available before adding
     * item.
     */
    @Coroutine
    void put(T item)
    {
        static if (maxSize > 0)
        {
            while (full)
            {
                auto waiter = new Waiter(eventLoop);

                putters ~= waiter;
                eventLoop.waitFor(waiter);
            }
        }

        putNowait(item);
    }

    /**
     * Put an item into the queue without blocking.
     *
     * If no free slot is immediately available, throw $(D_PSYMBOL
     * QueueFullException).
     */
    void putNowait(T item)
    {
        static if (maxSize > 0)
            enforce!QueueFullException(qsize < maxSize);

        ensureCapacity;
        put_(item);
        ++unfinishedTasks;
        finished.clear;

        wakeupNext(getters);
    }

    /**
     * Number of items in the queue.
     */
    @property size_t qsize()
    {
        return length;
    }

    /**
     * Indicate that a formerly enqueued task is complete.
     *
     * Used by queue consumers. For each $(D_PSYMBOL get()) used to fetch a
     * task, a subsequent call to $(D_PSYMBOL taskDone()) tells the queue that
     * the processing on the task is complete.
     *
     * If a $(D_PSYMBOL join()) is currently blocking, it will resume when all
     * items have been processed (meaning that a $(D_PSYMBOL taskDone()) call
     * was received for every item that had been $(D_PSYMBOL put()) into the
     * queue).
     *
     * Throws $(D_PSYMBOL Exception) if called more times than there were items
     * placed in the queue.
     */
    void taskDone()
    {
        enforce(unfinishedTasks > 0, "taskDone() called too many times");

        --unfinishedTasks;
        if (unfinishedTasks == 0)
            finished.set;
    }

    /**
     * Number of items allowed in the queue.
     */
    @property size_t maxsize()
    {
        return maxSize;
    }
}

unittest
{
    auto queue = new Queue!int;

    foreach (i; iota(200))
        queue.putNowait(i);

    foreach (i; iota(200))
        assert(queue.getNowait == i);
}

unittest
{
    auto queue = new Queue!(int, 10);

    foreach (i; iota(10))
        queue.putNowait(i);

    assertThrown!QueueFullException(queue.putNowait(11));
}

/**
 * A subclass of $(D_PSYMBOL Queue); retrieves entries in priority order
 * (largest first).
 *
 * Entries are typically tuples of the form: (priority number, data).
 */
class PriorityQueue(T, size_t maxSize = 0, alias less = "a < b") :
    Queue!(T, maxSize)
{
    import std.container : BinaryHeap;

    private BinaryHeap!(T[], less) binaryHeap;

    this(EventLoop eventLoop = null)
    {
        super(eventLoop);
        binaryHeap.acquire(queue, length);
    }

    protected override T get_()
    {
        --length;
        auto result = binaryHeap.front;
        binaryHeap.removeFront;
        return result;
    }

    protected override void put_(T item)
    {
        // underlying store is reallocated
        if (binaryHeap.capacity != queue.length)
            binaryHeap.assume(queue, length);

        assert(binaryHeap.capacity == queue.length);

        binaryHeap.insert(item);
        ++length;
    }
}

unittest
{
    auto queue = new PriorityQueue!int;

    foreach (i; iota(200))
        queue.putNowait(i);

    foreach (i; iota(199, -1, -1))
        assert(queue.getNowait == i);
}

/**
 * A subclass of $(D_PSYMBOL Queue) that retrieves most recently added entries
 * first.
 */
class LifoQueue(T, size_t maxSize = 0) : Queue!(T, maxSize)
{
    this(EventLoop eventLoop = null)
    {
        super(eventLoop);
    }

    protected override T get_()
    {
        auto result = queue[--length];
        queue[length] = T.init;
        return result;
    }

    protected override void put_(T item)
    {
        queue[length++] = item;
    }
}

unittest
{
    auto queue = new LifoQueue!int;

    foreach (i; iota(200))
        queue.putNowait(i);

    foreach (i; iota(199, -1, -1))
        assert(queue.getNowait == i);
}
