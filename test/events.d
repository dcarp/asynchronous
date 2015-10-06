import asynchronous;

unittest
{
    auto loop = getEventLoop;
    bool fooCalled = false;

    void foo()
    {
        fooCalled = true;
        loop.stop;
    }

    loop.callSoon(&foo);
    loop.runForever;

    assert(fooCalled);
}

unittest
{
    auto loop = getEventLoop;
    int bar = 0;

    void foo(int i)
    {
        bar = i;
        loop.stop;
    }

    loop.callSoon(&foo, 10);
    assert(bar == 0);
    loop.runForever;
    assert(bar == 10);
}

unittest
{
    auto loop = getEventLoop;
    int bar = 0;

    void foo(int i)
    {
        bar += i;
        loop.stop;
    }

    auto h1 = loop.callSoon(&foo, 10);
    auto h2 = loop.callSoon(&foo, 15);
    assert(bar == 0);
    h1.cancel;
    loop.runForever;
    assert(bar == 15);
}

unittest
{
    import std.datetime : msecs;

    auto loop = getEventLoop;
    auto t1 = loop.time;
    bool fooCalled = false;

    void foo()
    {
        fooCalled = true;
        loop.stop;
    }

    loop.callLater(5.msecs, &foo);
    loop.runForever;

    assert(fooCalled);

    auto t2 = loop.time;

    assert(t2 - t1 >= 5.msecs);
}

unittest
{
    import std.datetime : msecs, Clock;

    auto loop = getEventLoop;
    auto t1 = loop.time;
    bool fooCalled = false;

    void foo()
    {
        fooCalled = true;
        loop.stop;
    }

    loop.callAt(t1 + 5.msecs, &foo);
    loop.runForever;

    assert(fooCalled);

    auto t2 = loop.time;

    assert(t2 - t1 >= 5.msecs);
}
