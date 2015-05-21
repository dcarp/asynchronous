import std.algorithm;
import std.array;
import std.conv;
import std.datetime;
import std.functional;
import std.string;

import asynchronous;

@Coroutine
void echoSession(StreamReader reader, StreamWriter writer)
{
    debug (tasks) std.stdio.writefln("Server session task %s",
        cast(void*) TaskHandle.currentTask);

    while (true)
    {
        auto data = reader.read(1024);

        if (data.empty)
            break;
        writer.write(data);
    }
}

unittest
{
    auto loop = getEventLoop;

    void asyncTest()
    {
        debug (tasks) std.stdio.writefln("Client task %s",
            cast(void*) TaskHandle.currentTask);

        // setup
        auto server = loop.startServer((&echoSession).toDelegate, "localhost", "8038");
        auto session = loop.openConnection("localhost", "8038");
        string expected = "foo";

        // execute
        session.writer.write(expected);
        string actual = cast(string) session.reader.read(1024);

        // verify
        assert(actual == expected);

        // tear down
        session.writer.writeEof;
        server.close;
        server.waitClosed;
    }

    loop.runUntilComplete(loop.createTask(&asyncTest));
}
