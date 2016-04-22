[![Build Status](https://travis-ci.org/dcarp/asynchronous.png?branch=master)](https://travis-ci.org/dcarp/asynchronous)

#`asynchronous`#
This library provides infrastructure for writing concurrent code using coroutines, multiplexing I/O access over sockets and other resources, running network clients and servers, and other related primitives.

*It implements most of the python 3 [asyncio API](https://docs.python.org/3/library/asyncio.html).*

####API Reference###
Can be found at: http://dcarp.github.io/asynchronous/index.html

####Implementation status####
* Timers (done)
* Futures, Tasks (done)
* Sockets (done)
* Streams (done)
* Subprocesses (not implemented)
* Locks and semaphores (done)
* Queues (done)

####Why yet another async library? What is wrong with vibe.d?####
* `asynchronous` is a library and not a framework
* it is not web-oriented, compatible with `std.socket`
* arguably nicer API
* event loop start/stop control
* uses @Coroutine UDA to mark functions that could trigger a task (fiber) switch, although this is not enforced by the compiler yet.

####Examples and tutorials####
Some small examples can be found in the test directory or as unittests.
For larger examples please use the python resources. Just keep in mind that in contrast with Python in D a coroutine MUST NOT be called from outside of a task (it causes a run-time error on fiber switch). So you may need to add `ensureFuture` or `EventLoop.createTask` on the first calling level.
