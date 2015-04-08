import std.array;
import std.conv;
import std.functional;
import std.string;

import asynchronous;

Appender!(string[]) actualEvents;

class ServerProtocol : Protocol
{
    void connectionMade(BaseTransport transport)
    {
        actualEvents.put("server: client connected");
    }

    void connectionLost(Exception exception)
    {
        actualEvents.put("server: client disconnected");
    }

    void pauseWriting()
    {
        actualEvents.put("server: pause writing");
    }

    void resumeWriting()
    {
        actualEvents.put("server: resume writing");
    }

    void dataReceived(const(void)[] data)
    {
        actualEvents.put("server: dataReceived '%s'".format(data.to!string));
    }

    bool eofReceived()
    {
        actualEvents.put("server: eof received");
        return false;
    }
}

class ClientProtocol : Protocol
{
    void connectionMade(BaseTransport transport)
    {
        actualEvents.put("client: connected to server");
    }

    void connectionLost(Exception exception)
    {
        actualEvents.put("client: disconnected from server");
    }

    void pauseWriting()
    {
        actualEvents.put("client: pause writing");
    }

    void resumeWriting()
    {
        actualEvents.put("client: resume writing");
    }

    void dataReceived(const(void)[] data)
    {
        actualEvents.put("client: dataReceived '%s'".format(data.to!string));
    }

    bool eofReceived()
    {
        actualEvents.put("client: eof received");
        return false;
    }
}


@Coroutine
Server createServer()
{
    return getEventLoop.createServer(() => new ServerProtocol(), "localhost", "8038");
}

auto connectClient()
{
    return getEventLoop.createConnection(() => new ClientProtocol(), "localhost", "8038");
}


unittest
{
    // setup
    auto eventLoop = getEventLoop;
    actualEvents.clear;
    string[] expectedEvents = [
        "client: connected to server",
        "server: client connected",
    ];

    // execute
    auto server = eventLoop.async(toDelegate(&createServer));
    eventLoop.runUntilComplete(server);

    auto client = eventLoop.async(toDelegate(&connectClient));
    eventLoop.runUntilComplete(client);

    // verify
    assert(actualEvents.data == expectedEvents);
}
