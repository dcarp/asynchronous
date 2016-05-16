/**
 * Miscellaneous types.
 *
 * Copyright: © 2015-2016 Dragos Carp
 * License: Boost Software License - Version 1.0
 * Authors: Dragos Carp
 */
module asynchronous.types;

import std.algorithm;
import std.container.array;
import std.exception;
import std.traits;
import std.socket;

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
    private Array!ubyte inUseFlags;
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
            result = new T(tArgs);
            inUseFlags.insertBack(true);
            resources.insertBack(result);
        }

        static if (hasMember!(T, "reset"))
            result.reset(tResetArgs);

        return result;
    }

    void release(T t)
    {
        auto count = resources[].countUntil!(a => a is t);

        enforce(count >= 0, "Cannot release non-acquired resource");
        enforce(inUseFlags[count], "Resource is already released");

        inUseFlags[count] = false;

        static if (hasMember!(T, "reset"))
            resources[count].reset;
    }

    @property size_t length() const
    {
        return inUseFlags[].count!(a => !!a);
    }

    @property size_t capacity() const
    {
        return inUseFlags.length;
    }

    override string toString() const
    {
        import std.format : format;

        return "%s(length: %s, capacity: %s)".format(typeid(this), length,
            capacity);
    }
}

unittest
{
    import std.algorithm : each, equal, map;
    import std.range : array, drop, iota, take;

    static class Foo
    {
        int bar;
        int baz;

        this(int baz)
        {
            this.baz = baz;
        }

        void reset(int bar = 0)
        {
            this.bar = bar;
        }
    }

    auto fooPool = new ResourcePool!(Foo, int)(10);

    auto foo = fooPool.acquire(100);
    assert(foo.bar == 100);
    assert(foo.baz == 10);
    fooPool.release(foo);
    assert(foo.bar == 0);
    assert(foo.baz == 10);

    auto foos1 = iota(100).map!(a => fooPool.acquire(a)).array;
    assert(fooPool.length == 100);
    assert(fooPool.capacity == 100);
    assert(foos1.map!(a => a.bar).equal(iota(100)));

    foos1.take(20).each!(a => fooPool.release(a));
    foos1 = foos1.drop(20);
    assert(fooPool.length == 80);
    assert(fooPool.capacity == 100);

    auto foos2 = iota(10).map!(a => fooPool.acquire(a)).array;
    assert(fooPool.length == 90);
    assert(fooPool.capacity == 100);

    auto foos3 = iota(20).map!(a => fooPool.acquire(a)).array;
    assert(fooPool.length == 110);
    assert(fooPool.capacity == 110);

    foos1.each!(a => fooPool.release(a));
    assert(fooPool.length == 30);
    assert(fooPool.capacity == 110);

    foos2.each!(a => fooPool.release(a));
    assert(fooPool.length == 20);
    assert(fooPool.capacity == 110);

    foos3.each!(a => fooPool.release(a));
    assert(fooPool.length == 0);
    assert(fooPool.capacity == 110);
}

/**
 * Similar to tuple but all fields should be named. The individual fields are
 * accessible as struct members.
 *
 * Params:
 *     TList = A list of types (or default values) and member names that the
 *             $(D_PSYMBOL NamedTuple!(TList)) contains.
 */
template NamedTuple(TList...)
{
    import std.format : format;

    static assert(TList.length % 2 == 0, "Insufficient number of names given.");

    string injectFields()
    {
        string members;

        foreach (i, name; TList)
        {
            static if (is(typeof(name) : string) && i % 2 == 1 && is(TList[i - 1]))
            {
                members ~= format("%s %s;", TList[i - 1].stringof, name);
            }
            else static if (is(typeof(name) : string) && i % 2 == 1)
            {
                members ~= format("%s %s = %s;",
                                  typeof(TList[i - 1]).stringof,
                                  name,
                                  TList[i - 1].stringof);
            }
            else
            {
                static assert(i % 2 == 0 || is(typeof(name) : string),
                              "Wrong name order.");
            }
        }
        return members;
    }

    struct NamedTuple
    {
        /**
         * Sets multiple members at once. Not mentioned members keep their
         * values.
         *
         * Params:
         *     Names = A list of strings naming each successive field of the
         *             $(D_PSYMBOL NamedTuple). Each name matches up with the
         *             corresponding field given by $(D_PARAM Args).
         *             Fields can be skipped and can be provided in any order.
         *     args  = Values to initialize the $(D_PSYMBOL NamedTuple)` fields.
         *
         * Returns: The $(D_PSYMBOL NamedTuple) itself after modification.
         */
        template opCall(Names...)
        {
            ref NamedTuple opCall(Args...)(Args args)
            {
                static assert(Names.length == Args.length && Names.length > 0,
                              "Insufficient number of names given.");

                foreach (i, arg; args)
                {
                    auto value = arg;
                    mixin(format("%s = value;", Names[i]));
                }
                return this;
            }

            ///
            unittest
            {
                NamedTuple!(int, "num", string, "str") ei1;
                ei1!("string", "num")("8", 9);
                assert(ei1.str == "8");
                assert(ei1.num == 9);
            }
        }

        mixin(injectFields);
    }
}

///
unittest
{
        NamedTuple!(8, "defVal", int, "num") ei1;
        assert(ei1.defVal == 8);
        assert(ei1.num == 0);
}

alias ExtraInfo = NamedTuple!(string, "peername",
                              Socket, "socket",
                              string, "sockname");
