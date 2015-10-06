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
