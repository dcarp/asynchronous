/**
 * Miscellaneous types.
 */
module asynchronous.types;

import std.algorithm;
import std.container.array;
import std.exception;
import std.traits;

struct Coroutine
{
}

template UNSPECIFIED(E)
if (is(E == enum))
{
    E UNSPECIFIED()
    {
        return cast(E) 0;
    }
}

/**
 * This operation was cancelled.
 */
class CancelledException : Exception
{
    this(string message = null, string file = __FILE__, size_t line = __LINE__,
        Throwable next = null) @safe pure nothrow
    {
        super(message, file, line, next);
    }
}

/**
 * This operation is not allowed in this state.
 */
class InvalidStateException : Exception
{
    this(string message = null, string file = __FILE__, size_t line = __LINE__,
        Throwable next = null) @safe pure nothrow
    {
        super(message, file, line, next);
    }
}

/**
 * This operation exceeded the given deadline.
 */
class TimeoutException : Exception
{
    this(string message = null, string file = __FILE__, size_t line = __LINE__,
        Throwable next = null) @safe pure nothrow
    {
        super(message, file, line, next);
    }
}

/**
 * This operation is not implemented.
 */
class NotImplementedException : Exception
{
    this(string message = null, string file = __FILE__, size_t line = __LINE__,
        Throwable next = null) @safe pure nothrow
    {
        super(message, file, line, next);
    }
}

class ResourcePool(T, TArgs...)
if (is(T == class))
{
    private size_t inUseCount;
    private Array!bool inUseFlags;
    private Array!T resources;

    private TArgs tArgs;

    this(TArgs tArgs)
    {
        this.tArgs = tArgs;
    }

    T acquire(TResetArgs...)(TResetArgs tResetArgs)
    out (result)
    {
        assert(result !is null);
    }
    body
    {
        auto count = inUseFlags[].countUntil!"!a";
        T result = null;

        if (count >= 0)
        {
            inUseFlags[count] = true;
            result = resources[count];
        }
        else
        {
            inUseFlags.insertBack(true);
            result = new T(tArgs);
            resources.insertBack(result);
        }

        static if (hasMember!(T, "reset"))
            result.reset(tResetArgs);

        ++inUseCount;
        return result;
    }

    void release(T t)
    {
        auto count = resources[].countUntil!(a => a is t);

        enforce(count >= 0, "Cannot release non-acquired resource");

        static if (hasMember!(T, "reset"))
            resources[count].reset;

        inUseFlags[count] = false;
        --inUseCount;
    }

    bool empty()
    {
        return inUseCount == 0;
    }

    override string toString() const
    {
        import std.format : format;

        return "%s(length: %s, capacity: %s)".format(typeid(this),
            inUseCount, inUseFlags.length);
    }
}
