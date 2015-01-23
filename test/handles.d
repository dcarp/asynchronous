module asynchronous.handles;

import std.datetime;
import std.string;


abstract class AbstractHandle
{
    public void cancel()
    {
        assert(0, "Not implemented");
    }

    public void run(Args...)(Args args)
    {
        assert(0, "Not implemented");
    }
}

/**
 * Object returned by callback registration methods.
 */
class Handle(alias callback, Args...) : AbstractHandle
{
    private bool cancelled;

    private Args args;

    alias ReturnType = typeof(callback(args));

    static if(!is(ReturnType == void))
    {
        static if(is(typeof(&calback(args))))
        {
            // Return reference.
            ReturnType* returnValue;

            ref ReturnType fixRef(ReturnType* val)
            {
                return *val;
            }
        }
        else
        {
            ReturnType returnValue;

            ref ReturnType fixRef(ref ReturnType val)
            {
                return val;
            }
        }
    }

    private this(Args args)
    {
        this.cancelled = false;
        static if(args.length > 0)
        {
            this.args = args;
        }
    }

    public void cancel()
    {
        this.cancelled = true;
    }

    override public void run(Args...)(Args args)
    {
        static assert (args.length <= this.args.length);

        if (this.cancelled)
        {
            return;
        }

        static if (args.length > 0)
        {
            import std.typecons;

            auto arguments = tuple(args, this.args[args.length .. $]).expand;
        }
        else
        {
            alias arguments = this.args;
        }

        static if(is(ReturnType == void))
        {
            callback(arguments);
        }
        else static if(is(typeof(addressOf(callback(arguments)))))
        {
            this.returnValue = addressOf(callback(arguments));
        }
        else
        {
            this.returnValue = callback(arguments);
        }
    }

    override public string toString()
    {
        string res = "Handle(%s)".format(__traits(identifier, callback));
        if (cancelled)
        {
            res ~= "<cancelled>";
        }
        return res;
    }
}

auto handle(alias callback, Args...)(Args args)
{
    return new Handle!(callback, Args)(args);
}

/**
 * Object returned by timed callback registration methods.
 */
class TimerHandle(alias callback, Args...) : Handle!(callback, Args)
{
    private SysTime when;

    private this(SysTime when, Args args)
    {
        super(args);
        this.when = when;
    }

    override public string toString()
    {
        string res = "TimerHandle(%s, %s)".format(when, __traits(identifier, callback));
        if (this.cancelled)
        {
            res ~= "<cancelled>";
        }
        return res;
    }

}

auto timerHandle(alias callback, Args...)(SysTime when, Args args)
{
    return new TimerHandle!(callback, Args)(when, args);
}

unittest
{
    int add(int i, int j)
    {
        return i + j;
    }

    auto h1 = handle!add(3, 5);
    auto h2 = handle!add(10, 17);
    auto h3 = timerHandle!add(Clock.currTime(), 1, 2);
    auto h4 = handle!add(0, 17);

    h4.run(2);
    h3.run;
    h2.run;
    h1.run;
    assert(h1.returnValue == 8);
    assert(h2.returnValue == 27);
    assert(h3.returnValue == 3);
    assert(h4.returnValue == 19);
}
