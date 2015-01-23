import std.datetime;
import std.functional;
import std.stdio;
import asynchronous;

//unittest
//{
//    assert(getEventLoop !is null);
//}

//unittest
//{
//    auto loop = getEventLoop;

//    auto add = (int a, int b) => a + b;

//    auto future1 = loop.callLater(10.msecs, add, 10, 11);
//    auto future2 = loop.callLater(20.msecs, add, 11, 12);
//    auto future3 = loop.callLater(60.msecs, add, 12, 13);

//    auto result = wait([future1, future2, future3], loop, 50.msecs);

//    assert(future1.done);
//    assert(future2.done);
//    assert(!future3.done);

//    assert(future1.result == 21);
//    assert(future2.result == 23);

//    assert(result.done == [future1, future2]);
//    assert(result.notDone == [future3]);
//}



class MyProtocol : Protocol
{
    void connectionMade(BaseTransport transport)
    {
        writeln("connectionMade");
    }

    void connectionLost(Exception exception)
    {
        writeln("connectionLost");
    }

    void pauseWriting()
    {
        writeln("pauseWriting");
    }

    void resumeWriting()
    {
        writeln("resumeWriting");
    }

    void dataReceived(const(void)[] data)
    {
        writeln("dataReceived");
    }

    bool eofReceived()
    {
        writeln("eofReceived");
        return false;
    }
}


int add(int i, int j)
{
    writefln("%s add %s %s", getEventLoop.time, i, j);
    return i + j;
}

Protocol protocolFactory()
{
    return new MyProtocol;
}

void myTask()
{
    auto loop = getEventLoop;

    auto result = loop.createConnection(&protocolFactory, "127.0.0.1", "50000");
}

void main()
{
    auto task = new Task!void(&myTask, getEventLoop);
    getEventLoop.runUntilComplete(task);
}
