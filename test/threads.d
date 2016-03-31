import core.thread;
import std.datetime : msecs;
import asynchronous;

unittest
{
    auto loop = getEventLoop;
    auto future = new Future!int;

    void stopLoop()
    {
        future.setResult(10);
    }

    auto thread1 = new Thread({
        Thread.sleep(2.msecs);
        loop.callSoonThreadSafe(&stopLoop);
    });
    thread1.start;

    loop.runUntilComplete(future);
    assert(future.done);
    assert(future.result == 10);
}
