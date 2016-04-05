/**
 * Synchronization primitives.
 *
 * Copyright: © 2015-2016 Dragos Carp
 * License: Boost Software License - Version 1.0
 * Authors: Dragos Carp
 */
module asynchronous.locks;

import std.algorithm;
import std.array;
import std.exception;
import asynchronous.events : EventLoop, getEventLoop;
import asynchronous.futures : Waiter;
import asynchronous.tasks : TaskHandle;
import asynchronous.types : Coroutine;

// Locks

/**
 * Primitive lock objects.
 *
 * A primitive lock is a synchronization primitive that is not owned by a
 * particular coroutine when locked. A primitive lock is in one of two states,
 * ‘locked’ or ‘unlocked’.
 *
 * It is created in the unlocked state. It has two basic methods, $(D_PSYMBOL
 * acquire()) and $(D_PSYMBOL release()). When the state is unlocked,
 * $(D_PSYMBOL acquire()) changes the state to locked and returns immediately.
 * When the state is locked, $(D_PSYMBOL acquire()) blocks until a call to
 * $(D_PSYMBOL release()) in another coroutine changes it to unlocked, then the
 * $(D_PSYMBOL acquire()) call resets it to locked and returns. The $(D_PSYMBOL
 * release()) method should only be called in the locked state; it changes the
 * state to unlocked and returns immediately. If an attempt is made to release
 * an unlocked lock, an $(D_PSYMBOL Exception) will be thrown.
 *
 * When more than one coroutine is blocked in $(D_PSYMBOL acquire()) waiting for
 * the state to turn to unlocked, only one coroutine proceeds when a $(D_PSYMBOL
 * release()) call resets the state to unlocked; first coroutine which is
 * blocked in $(D_PSYMBOL acquire()) is being processed.
 *
 * $(D_PSYMBOL acquire()) is a coroutine.
 *
 * This class is not thread safe.
 *
 * Usage:
 *
 *   lock = new Lock();
 *   ...
 *   lock.acquire();
 *   scope (exit) lock.release();
 *   ...
 *
 * Lock objects can be tested for locking state:
 *
 *   if (!lock.locked)
 *      lock.acquire();
 *   else;
 *      // lock is acquired
 *      ...
 */
final class Lock
{
    package EventLoop eventLoop;
    private Waiter[] waiters;
    private bool locked_ = false;

    this(EventLoop eventLoop = null)
    {
        if (eventLoop is null)
            this.eventLoop = getEventLoop;
        else
            this.eventLoop = eventLoop;
    }

    override string toString() const
    {
        import std.format : format;

        return "%s(%s, waiters %s)".format(typeid(this),
            locked ? "locked" : "unlocked", waiters);
    }

    /**
     * Return $(D_KEYWORD true) if lock is acquired.
     */
    @property bool locked() const
    {
        return locked_;
    }

    /**
     * Acquire a lock.
     *
     * This method blocks until the lock is unlocked, then sets it to locked and
     * returns $(D_KEYWORD true).
     */
    @Coroutine
    bool acquire()
    {
        if (waiters.empty && !locked_)
        {
            locked_ = true;
            return true;
        }

        auto waiter = new Waiter(eventLoop);
        scope (exit)
        {
            waiters = waiters.remove!(w => w is waiter);
        }

        waiter.addDoneCallback(&TaskHandle.currentTask(eventLoop).scheduleStep);
        waiters ~= waiter;

        TaskHandle.yield;
        locked_ = true;
        return true;
    }

    /**
     * Release a lock.
     *
     * When the lock is locked, reset it to unlocked, and return. If any other
     * coroutines are blocked waiting for the lock to become unlocked, allow
     * exactly one of them to proceed.
     *
     * When invoked on an unlocked lock, an $(D_PSYMBOL Exception) is thrown.
     */
    void release()
    {
        enforce(locked_, "Lock is not acquired.");

        locked_ = false;

        // Wake up the first waiter who isn't cancelled.
        auto found = waiters.find!(w => !w.done);

        if (!found.empty)
            found[0].setResult;
    }
}

/**
 * Class implementing event objects.
 *
 * An event manages a flag that can be set to true with the $(D_PSYMBOL set())
 * method and reset to false with the $(D_PSYMBOL clear()) method. The
 * $(D_PSYMBOL wait()) method blocks until the flag is true. The flag is
 * initially false.
 *
 * This class is not thread safe.
 */ 
final class Event
{
    private EventLoop eventLoop;
    private Waiter[] waiters;
    private bool value = false;

    this(EventLoop eventLoop = null)
    {
        if (eventLoop is null)
            this.eventLoop = getEventLoop;
        else
            this.eventLoop = eventLoop;
    }

    override string toString() const
    {
        import std.format : format;

        return "%s(%s, waiters %s)".format(typeid(this),
            value ? "set" : "unset", waiters);
    }

    /**
     * Reset the internal flag to false. Subsequently, coroutines calling
     * $(D_PSYMBOL wait()) will block until $(D_PSYMBOL set()) is called to set
     * the internal flag to true again.
     */
    void clear()
    {
        value = false;
    }

    /**
     * Return $(D_KEYWORD true) if and only if the internal flag is true.
     */
    bool isSet() const
    {
        return value;
    }

    /**
     * Set the internal flag to true. All coroutines waiting for it to become
     * true are awakened. Coroutine that call $(D_PSYMBOL wait()) once the flag
     * is true will not block at all.
     */
    void set()
    {
        if (value)
            return;

        value = true;

        auto found = waiters.find!(w => !w.done);

        if (!found.empty)
            found[0].setResult;
    }

    /**
     * Block until the internal flag is true.
     *
     * If the internal flag is true on entry, return $(D_KEYWORD true)
     * immediately. Otherwise, block until another coroutine calls $(D_PSYMBOL
     * set()) to set the flag to true, then return $(D_KEYWORD true).
     */
    @Coroutine
    bool wait()
    {
        if (value)
            return true;

        auto waiter = new Waiter(eventLoop);
        scope (exit)
        {
            waiters = waiters.remove!(w => w is waiter);
        }

        waiter.addDoneCallback(&TaskHandle.currentTask(eventLoop).scheduleStep);
        waiters ~= waiter;

        TaskHandle.yield;
        return true;
    }
}

/**
 * This class implements condition variable objects.
 *
 * A condition variable allows one or more coroutines to wait until they are
 * notified by another coroutine.
 *
 * If the lock argument is given and not $(D_KEYWORD null) then it is used as
 * the underlying lock. Otherwise, a new Lock object is created and used as the
 * underlying lock.
 *
 * This class is not thread safe.
 */
final class Condition
{
    private EventLoop eventLoop;
    private Lock lock;
    private Waiter[] waiters;
    private bool value = false;

    this(EventLoop eventLoop = null, Lock lock = null)
    {
        if (eventLoop is null)
            this.eventLoop = getEventLoop;
        else
            this.eventLoop = eventLoop;

        if (lock is null)
            lock = new Lock(this.eventLoop);
        else
            enforce(lock.eventLoop == this.eventLoop,
                "loop argument must agree with lock");
        this.lock = lock;
    }

    override string toString() const
    {
        import std.format : format;

        return "%s(%s, waiters %s)".format(typeid(this),
            locked ? "locked" : "unlocked", waiters);
    }

    /**
     * Acquire the underlying lock.
     *
     * This method blocks until the lock is unlocked, then sets it to locked and
     * returns $(D_KEYWORD true).
     */
    @Coroutine
    bool acquire()
    {
        return lock.acquire;
    }

    /**
     * By default, wake up one coroutine waiting on this condition, if any. If
     * the calling coroutine has not acquired the lock when this method is
     * called, an $(D_PSYMBOL Exception) is thrown.
     *
     * This method wakes up at most $(D_PSYMBOL n) of the coroutines waiting for
     * the condition variable; it is a no-op if no coroutines are waiting.
     *
     * Note: an awakened coroutine does not actually return from its $(D_PSYMBOL
     * wait()) call until it can reacquire the lock. Since $(D_PSYMBOL notify())
     * does not release the lock, its caller should.
     */
    void notify(size_t n = 1)
    {
        enforce(locked, "cannot notify on un-acquired lock");

        foreach (waiter; waiters.filter!(w => !w.done))
        {
            if (n == 0)
                break;

            --n;
            waiter.setResult;
        }
    }

    /**
     * Return $(D_KEYWORD true) if the underlying lock is acquired.
     */
    @property bool locked() const
    {
        return lock.locked;
    }

    /**
     * Wake up all coroutines waiting on this condition. This method acts like
     * $(D_PSYMBOL notify()), but wakes up all waiting coroutines instead of
     * one. If the calling coroutines has not acquired the lock when this method
     * is called, an $(D_PSYMBOL Exception) is thrown.
     */
    void notifyAll()
    {
        notify(waiters.length);
    }

    /**
     * Release the underlying lock.
     *
     * When the lock is locked, reset it to unlocked, and return. If any other
     * coroutines are blocked waiting for the lock to become unlocked, allow
     * exactly one of them to proceed.
     *
     * When invoked on an unlocked lock, an $(D_PSYMBOL Exception) is thrown.
     */
    void release()
    {
        lock.release;
    }


    /**
     * Wait until notified.
     *
     * If the calling coroutine has not acquired the lock when this method is
     * called, an $(D_PSYMBOL Exception) is thrown.
     *
     * This method releases the underlying lock, and then blocks until it is
     * awakened by a $(D_PSYMBOL notify()) or $(D_PSYMBOL notifyAll()) call for
     * the same condition variable in another coroutine. Once awakened, it
     * re-acquires the lock and returns $(D_KEYWORD true).
     */
    @Coroutine
    bool wait()
    {
        enforce(locked, "cannot wait on un-acquired lock");

        release;
        scope (exit)
        {
            acquire;
        }

        auto waiter = new Waiter(eventLoop);
        scope (exit)
        {
            waiters = waiters.remove!(w => w is waiter);
        }

        waiter.addDoneCallback(&TaskHandle.currentTask(eventLoop).scheduleStep);
        waiters ~= waiter;

        TaskHandle.yield;
        return true;
    }

    /**
     * Wait until a predicate becomes true.
     *
     * The predicate should be a callable returning a boolean value. The final
     * predicate value is the return value.
     */
    @Coroutine
    bool waitFor(bool delegate() predicate)
    {
        while (!predicate())
            wait;

        return true;
    }
}

// Semaphores

/**
 * A Semaphore implementation.
 *
 * A semaphore manages an internal counter which is decremented by each
 * $(D_PSYMBOL acquire()) call and incremented by each $(D_PSYMBOL release())
 * call. The counter can never go below zero; when $(D_PSYMBOL acquire()) finds
 * that it is zero, it blocks, waiting until some other thread calls $(D_PSYMBOL
 * release()).
 *
 * The optional argument gives the initial value for the internal counter; it
 * defaults to 1.
 *
 * This class is not thread safe.
 */
class Semaphore
{
    private EventLoop eventLoop;
    private size_t value;
    private Waiter[] waiters;

    this(EventLoop eventLoop = null, size_t value = 1)
    {
        if (eventLoop is null)
            this.eventLoop = getEventLoop;
        else
            this.eventLoop = eventLoop;

        this.value = value;
    }

    override string toString() const
    {
        import std.format : format;

        if (locked)
            return "%s(locked, waiters %s)".format(typeid(this), waiters);
        else
            return "%s(unlocked, value %s, waiters %s)".format(typeid(this),
                value, waiters);
    }

    /**
     * Acquire a semaphore.
     *
     * If the internal counter is larger than zero on entry, decrement it by one
     * and return $(D_KEYWORD true) immediately. If it is zero on entry, block,
     * waiting until some other coroutine has called $(D_PSYMBOL release()) to
     * make it larger than 0, and then return $(D_KEYWORD true).
     */
    @Coroutine
    bool acquire()
    {
        if (waiters.empty && value > 0)
        {
            --value;
            return true;
        }

        auto waiter = new Waiter(eventLoop);
        scope (exit)
        {
            waiters = waiters.remove!(w => w is waiter);
        }

        waiter.addDoneCallback(&TaskHandle.currentTask(eventLoop).scheduleStep);
        waiters ~= waiter;

        TaskHandle.yield;
        --value;
        return true;
    }

    /**
     * Returns $(D_KEYWORD true) if semaphore can not be acquired immediately.
     */
    @property bool locked() const
    {
        return value == 0;
    }

    /**
     * Release a semaphore, incrementing the internal counter by one. When it
     * was zero on entry and another coroutine is waiting for it to become
     * larger than zero again, wake up that coroutine.
     */
    void release()
    {
        ++value;

        auto found = waiters.find!(w => !w.done);

        if (!found.empty)
            found[0].setResult;
    }
}

/**
 * A bounded semaphore implementation.
 * 
 * This throws an Exception in $(D_PSYMBOL release()) if it would increase the
 * value above the initial value.
 */
class BoundedSemaphore : Semaphore
{
    private size_t boundValue;

    this(EventLoop eventLoop = null, size_t value = 1)
    {
        boundValue = value;
        super(eventLoop, value);
    }

    override void release()
    {
        enforce(value < boundValue, "BoundedSemaphore released too many times");
        super.release;
    }
}
