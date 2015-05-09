module asynchronous.types;

import std.algorithm;
import std.array;
import std.exception;
import std.typecons;

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
{
    alias ResourceStatus = Tuple!(T, T.stringof, bool, "inUse");

    private TArgs tArgs;

    private ResourceStatus[] resources;

    this(TArgs tArgs)
    {
        this.tArgs = tArgs;
    }

    T acquire()
    {
        auto found = resources.find!"a.inUse == false";

        if (!found.empty)
        {
            found[0].inUse = true;
            return found[0][0];
        }

        auto t = new T(tArgs);
        resources ~= ResourceStatus(t, true);
        return t;
    }

    void release(T t)
    {
        auto found = resources.find!(a => a[0] is t);

        enforce(!found.empty, "Cannot release non-acquired resource");

        found[0].inUse = false;
    }

    //ptrdiff_t idOf(T t)
    //{
    //    auto result = resource.countUntil!(a => a[0] is t);
    //    return resouces[result].inUse ? result : -1;
    //}

    bool empty()
    {
        return !resources.canFind!"a.inUse";
    }
}
