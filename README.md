[![Build Status](https://travis-ci.org/dcarp/asynchronous.png?branch=master)](https://travis-ci.org/dcarp/asynchronous)

# `asynchronous`
This library provides infrastructure for writing concurrent code using coroutines, multiplexing I/O access over sockets and other resources, running network clients and servers, and other related primitives.

*It implements most of the python 3 [asyncio API](https://docs.python.org/3/library/asyncio.html).*

#### API Reference
Can be found at: http://dcarp.github.io/asynchronous/index.html

#### Implementation status
* Timers (done)
* Futures, Tasks (done)
* Sockets (done)
* Streams (done)
* Subprocesses (not implemented)
* Locks and semaphores (done)
* Queues (done)

#### Why yet another async library? What is wrong with vibe.d?
* `asynchronous` is a library and not a framework
* it is not web-oriented, compatible with `std.socket`
* arguably nicer API
* event loop start/stop control
* uses `@Coroutine` UDA to mark functions that could trigger a task (fiber) switch, although this is not enforced yet by the compiler.

#### Examples and tutorials
Some small examples can be found in the test directory or as unittests. For larger examples please use the Python/asyncio resources.

Please keep in mind that, in contrast with Python/asyncio, in D a coroutine MUST be called from within a Task, otherwise it causes a run-time error on the fiber switch. Basic rule: if not called from another coroutine, any coroutine call need to be wrapped by `ensureFuture` or `EventLoop.createTask`.
