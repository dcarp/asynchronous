/**
 * Support for tasks, coroutines and the scheduler.
 */
module asynchronous.tasks;

import core.thread;
import std.algorithm;
import std.array;
import std.exception;
import std.traits;
import std.typecons;
import asynchronous.events;
import asynchronous.futures;
import asynchronous.types;

package class TaskRepository
{
    private static __gshared TaskHandle[EventLoop] currentTasks;

    private static __gshared TaskHandle[][EventLoop] tasks;

    static TaskHandle[] allTasks(EventLoop eventLoop)
    in
    {
        assert(eventLoop !is null);
    }
    body
    {
        return tasks.get(eventLoop, null).dup;
    }

    static TaskHandle currentTask(EventLoop eventLoop)
    in
    {
        assert(eventLoop !is null);
    }
    body
    {
        return currentTasks.get(eventLoop, null);
    }

    static void resetCurrentTask(EventLoop eventLoop,
        TaskHandle taskHandle = null)
    in
    {
        assert(eventLoop !is null);
    }
    body
    {
        currentTasks[eventLoop] = taskHandle;
    }

    package static void registerTask(EventLoop eventLoop, TaskHandle taskHandle)
    in
    {
        assert(eventLoop !is null);
        assert(taskHandle !is null);
    }
    body
    {
        tasks[eventLoop] ~= taskHandle;
    }

    package static void unregisterTask(EventLoop eventLoop,
        TaskHandle taskHandle)
    in
    {
        assert(eventLoop !is null);
        assert(taskHandle !is null);
    }
    body
    {
        tasks[eventLoop] = tasks[eventLoop].remove!(a => a is taskHandle);
    }
}

interface TaskHandle : FutureHandle
{
    protected @property Throwable injectException();

    protected void run();

    protected void scheduleStep();
    protected void scheduleStep(Throwable throwable);

    /**
     * Returns: a set of all tasks for an event loop.
     *
     * By default all tasks for the current event loop are returned.
     */
    static TaskHandle[] allTasks(EventLoop eventLoop = null)
    {
        if (eventLoop is null)
            eventLoop = getEventLoop;

        return TaskRepository.allTasks(eventLoop);
    }

    /**
     * Returns: the currently running task in an event loop or
     *          $(D_KEYWORD null).
     *
     * By default the current task for the current event loop is returned.
     *
     * $(D_KEYWORD null) is returned when called not in the context of a Task.
     */
    static TaskHandle currentTask(EventLoop eventLoop = null)
    {
        if (eventLoop is null)
            eventLoop = getEventLoop;

        return TaskRepository.currentTask(eventLoop);
    }

    static TaskHandle getThis()
    {
        auto taskFiber = TaskFiber.getThis;

        return taskFiber is null ? null : taskFiber.taskHandle;
    }

    /**
     * Forces a context switch to occur away from the calling task.
     *
     * Params:
     *  eventLoop = event loop, $(D_PSYMBOL getEventLoop) if not specified.
     */
    @Coroutine
    package static void yield()
    {
        Fiber.yield;

        auto thisTask = getThis;
        enforce(thisTask !is null,
            "'TaskHandle.yield' called outside of a task.");

        if (thisTask.injectException !is null)
            throw thisTask.injectException;
    }    
}

private class TaskFiber : Fiber
{
    private TaskHandle task_ = null;

    this()
    {
        super({ });
    }

    @property TaskHandle taskHandle()
    {
        return task_;
    }

    void reset(TaskHandle task = null)
    in
    {
        assert(state == (task is null ? Fiber.State.TERM : Fiber.State.HOLD));
    }
    body
    {
        task_ = task;
        if (task is null)
            super.reset;
        else
            super.reset(&(task.run));
    }

    static TaskFiber getThis()
    {
        return cast(TaskFiber) Fiber.getThis;
    }
}


private static __gshared ResourcePool!TaskFiber taskFibers;

static this()
{
    taskFibers = new ResourcePool!TaskFiber;
}

/**
 * Schedule the execution of a fiber: wrap it in a future. A task is a
 * subclass of Future.
 *
 * A task is responsible for executing a fiber object in an event loop. If the
 * wrapped fiber yields from a future, the task suspends the execution of the
 * wrapped fiber and waits for the completion of the future. When the future
 * is done, the execution of the wrapped fiber restarts with the result or the
 * exception of the fiber.
 *
 * Event loops use cooperative scheduling: an event loop only runs one task at
 * a time. Other tasks may run in parallel if other event loops are running in
 * different threads. While a task waits for the completion of a future, the
 * event loop executes a new task.
 *
 * The cancellation of a task is different from the cancelation of a future.
 * Calling $(D_PSYMBOL cancel()) will throw a $(D_PSYMBOL CancelledException)
 * to the wrapped fiber. $(D_PSYMBOL cancelled()) only returns $(D_KEYWORD
 * true) if the wrapped fiber did not catch the $(D_PSYMBOL
 * CancelledException), or raised a $(D_PSYMBOL CancelledException).
 *
 * If a pending task is destroyed, the execution of its wrapped fiber did not
 * complete. It is probably a bug and a warning is logged: see Pending task
 * destroyed.
 *
 * Don’t directly create $(D_PSYMBOL Task) instances: use the $(D_PSYMBOL
 * task()) function or the $(D_PSYMBOL EventLoop.create_task()) method.
 */
class Task(Coroutine, Args...) : Future!(ReturnType!Coroutine), TaskHandle
if (isDelegate!Coroutine)
{
    alias ResultType = ReturnType!Coroutine;

    package TaskFiber fiber;

    private Coroutine coroutine;
    private Args args;

    private Throwable injectException_;

    protected override @property Throwable injectException()
    {
        return this.injectException_;
    }

    debug (tasks)
        package string id()
        {
            return (cast(void*) cast(TaskHandle) this).toString;
        }

    this(EventLoop eventLoop, Coroutine coroutine, Args args)
    {
        super(eventLoop);

        this.coroutine = coroutine;
        static if (args.length > 0)
        {
            this.args = args;
        }

        this.fiber = taskFibers.acquire(this);
        TaskRepository.registerTask(this.eventLoop, this);
        this.eventLoop.callSoon(&step, null);

        debug (tasks)
            std.stdio.writeln("Create task ", id);
    }

    override protected void run()
    {
        debug (tasks)
            std.stdio.writeln("Start task ", id);

        static if (is(ResultType : void))
        {
            coroutine(args);
            setResult;
        }
        else
        {
            setResult(coroutine(args));
        }

        debug (tasks)
            std.stdio.writeln("End task ", id);
    }

    /**
     * Request that this task cancel itself.
     *
     * This arranges for a $(D_PSYMBOL CancelledException) to be thrown into
     * the wrapped coroutine on the next cycle through the event loop. The
     * coroutine then has a chance to clean up or even deny the request using
     * try/catch/finally.
     *
     * Unlike $(D_PSYMBOL Future.cancel()), this does not guarantee that the
     * task will be cancelled: the exception might be caught and acted upon,
     * delaying cancellation of the task or preventing cancellation completely.
     * The task may also return a value or raise a different exception.
     *
     * Immediately after this method is called, $(D_PSYMBOL cancelled()) will
     * not return $(D_KEYWORD true) (unless the task was already cancelled). A
     * task will be marked as cancelled when the wrapped coroutine terminates
     * with a $(D_PSYMBOL CancelledException) (even if cancel() was not
     * called).
     */
    override bool cancel()
    {
        if (done)
            return false;

        this.injectException_ = new CancelledException;
        return true;
    }

    private void step(Throwable throwable = null)
    {
        debug (tasks)
            std.stdio.writeln("Resume task ", id);

        final switch (this.fiber.state)
        {
        case Fiber.State.HOLD:
            TaskRepository.resetCurrentTask(this.eventLoop, this);

            if (throwable !is null)
                this.injectException_ = throwable;

            try
            {
                this.fiber.call;
            }
            catch (CancelledException cancelledException)
            {
                assert(this.fiber.state == Fiber.State.TERM);
                super.cancel;
            }
            catch (Throwable throwable)
            {
                assert(this.fiber.state == Fiber.State.TERM);
                setException(throwable);
            }

            if (this.fiber.state == Fiber.State.TERM)
                scheduleStep;

            TaskRepository.resetCurrentTask(this.eventLoop);
            break;
        case Fiber.State.EXEC:
            assert(0, "Internal error");
        case Fiber.State.TERM:
            assert(done);
            TaskRepository.unregisterTask(this.eventLoop, this);
            taskFibers.release(this.fiber);
            this.fiber = null;
            break;
        }

        debug (tasks)
            std.stdio.writeln("Suspend task ", id);
    }

    protected override void scheduleStep()
    {
        scheduleStep(null);
    }

    protected override void scheduleStep(Throwable throwable)
    {
        debug (tasks)
        {
            if (throwable is null)
                std.stdio.writeln("Schedule task ", id);
            else
                std.stdio.writeln("Schedule task ", id, " to throw ",
                    throwable);
        }

        if (TaskFiber.getThis is null)
            step(throwable);
        else
            this.eventLoop.callSoon(&step, throwable);
    }

    override string toString()
    {
        import std.string;

        return "%s(done: %s, cancelled: %s)".format(typeid(this), done,
            cancelled);
    }
}

/**
 * Return an generator whose values, when waited for, are Future instances in
 * the order in which and as soon as they complete.
 *
 * Raises $(D_PSYMBOL TimeoutException) if the timeout occurs before all futures
 * are done.
 *
 * Example:
 *
 *  foreach (f; getEventLoop.asCompleted(fs))
 *       // use f.result
 *
 * Note: The futures $(D_PSYMBOL f) are not necessarily members of $(D_PSYMBOL
 *       fs).
 */
auto asCompleted(EventLoop eventLoop, FutureHandle[] futures,
    Duration timeout = Duration.zero)
in
{
    futures.all!"a !is null";
}
body
{
    if (eventLoop is null)
        eventLoop = getEventLoop;

    import asynchronous.queues : Queue;
    auto done = new Queue!FutureHandle;
    CallbackHandle timeoutCallback = null;
    Tuple!(FutureHandle, void delegate())[] todo;

    foreach (future; futures)
    {
        void delegate() doneCallback = (f => {
            if (todo.empty)
                return; // timeoutCallback was here first
            todo = todo.remove!(a => a[0] is f);
            done.putNowait(f);
            if (todo.empty && timeoutCallback !is null)
                timeoutCallback.cancel;
        })(future); // workaround bug #2043

        todo ~= tuple(future, doneCallback);
        future.addDoneCallback(doneCallback);
    }

    if (!todo.empty && timeout > Duration.zero)
    {
        timeoutCallback = eventLoop.callLater(timeout, {
            foreach (future_callback; todo)
            {
                future_callback[0].removeDoneCallback(future_callback[1]);
                future_callback[0].cancel;
            }
            if (!todo.empty)
                done.putNowait(null);
            todo = null;
        });
    }

    return new GeneratorTask!FutureHandle(eventLoop, {
        while (!todo.empty || !done.empty)
        {
            auto f = done.get;
            if (f is null)
                throw new TimeoutException;
            yieldValue(f);
        }
    });
}

unittest
{
    auto eventLoop = getEventLoop;

    auto task1 = eventLoop.createTask({
        eventLoop.sleep(3.msecs);
    });
    auto task2 = eventLoop.createTask({
        eventLoop.sleep(2.msecs);
    });
    auto testTask = eventLoop.createTask({
        auto tasks = asCompleted(eventLoop, [task1, task2]).array;

        assert(tasks[0] is cast(FutureHandle) task2);
        assert(tasks[1] is cast(FutureHandle) task1);
    });
    eventLoop.runUntilComplete(testTask);

    task1 = eventLoop.createTask({
        eventLoop.sleep(10.msecs);
    });
    task2 = eventLoop.createTask({
        eventLoop.sleep(2.msecs);
    });
    testTask = eventLoop.createTask({
        auto tasks = asCompleted(eventLoop, [task1, task2], 5.msecs).array;

        assert(tasks.length == 1);
        assert(tasks[0] is cast(FutureHandle) task2);
    });
    eventLoop.runUntilComplete(testTask);
}

/**
 * Schedule the execution of a coroutine: wrap it in a future. Return a
 * $(D_PSYMBOL Task) object.
 *
 * If the argument is a $(D_PSYMBOL Future), it is returned directly.
 */
auto ensureFuture(Coroutine, Args...)(EventLoop eventLoop, Coroutine coroutine,
    Args args)
{
    static if (is(typeof(coroutine) : FutureHandle))
    {
        static assert(args.length == 0);

        return coroutine;
    }
    else
    {
        return new Task!(Coroutine, Args)(eventLoop, coroutine, args);
    }
}

unittest
{
    import std.functional;

    auto task1 = ensureFuture(null, toDelegate({
        return 3 + 39;
    }));

    assert(!task1.done);
    assert(!task1.cancelled);

    task1.cancel;
    assert(!task1.cancelled);

    auto result = getEventLoop.runUntilComplete(task1);

    assert(task1.done);
    assert(!task1.cancelled);
    assert(result == 42);

    assert(task1 == ensureFuture(null, task1));
}

/**
 * Create a coroutine that completes after a given time. If $(D_PSYMBOL result)
 * is provided, it is produced to the caller when the coroutine completes.
 *
 * The resolution of the sleep depends on the granularity of the event loop.
 */
@Coroutine
auto sleep(Result...)(EventLoop eventLoop, Duration delay, Result result)
if (result.length <= 1)
{
    if (eventLoop is null)
        eventLoop = getEventLoop;

    static if (result.length == 0)
    {
        auto future = new Future!void(eventLoop);
        auto handle = eventLoop.callLater(delay,
            &future.setResultUnlessCancelled);
    }
    else
    {
        auto future = new Future!Result(eventLoop);
        auto handle = eventLoop.callLater(delay,
            &future.setResultUnlessCancelled, result);
    }
    scope (exit) handle.cancel;

    return eventLoop.waitFor(future);
}

unittest
{
    auto eventLoop = getEventLoop;
    auto task1 = eventLoop.ensureFuture({
        return eventLoop.sleep(5.msecs, "foo");
    });

    eventLoop.runUntilComplete(task1);
    assert(task1.result == "foo");
}

/**
 * Wait for a future, shielding it from cancellation.
 *
 * The statement
 *
 *   $(D_CODE res = shield(something());)
 *
 * is exactly equivalent to the statement
 *
 *   $(D_CODE res = something();)
 *
 * $(I except) that if the coroutine containing it is cancelled, the task
 * running in $(D_PSYMBOL something()) is not cancelled. From the point of view
 * of $(D_PSYMBOL something()), the cancellation did not happen. But its caller
 * is still cancelled, so the call still raises $(D_PSYMBOL CancelledException).
 * Note: If $(D_PSYMBOL something()) is cancelled by other means this will still
 * cancel $(D_PSYMBOL shield()).
 *
 * If you want to completely ignore cancellation (not recommended) you can
 * combine $(D_PSYMBOL shield()) with a try/except clause, as follows:
 *
 * $(D_CODE
 *   try
 *       res = shield(something());
 *   catch (CancelledException)
 *       res = null;
 * )
 */
auto shield(Coroutine, Args...)(EventLoop eventLoop, Coroutine coroutine,
    Args args)
{
    auto inner = ensureFuture(eventLoop, coroutine, args);
    if (inner.done())
        return inner;

    auto outer = new Future!(inner.ResultType)(eventLoop);

    void doneCallback()
    {
        if (outer.cancelled())
        {
            if (!inner.cancelled())
                inner.exception(); // Mark inner's result as retrieved.
            return;
        }

        if (inner.cancelled())
        {
            outer.cancel();
        }
        else
        {
            auto exception = inner.exception();
            if (exception !is null)
            {
                outer.setException(exception);
            }
            else
            {
                static if (!is(T == void))
                {
                    outer.setResult(inner.result);
                }
                else
                {
                    outer.setResult;
                }
            }
        }
    }

    inner.addDoneCallback(&doneCallback);
    return outer;
}

unittest
{
    int add(int a, int b)
    {
        return a + b;
    }

    auto eventLoop = getEventLoop;

    auto task1 = eventLoop.ensureFuture(&add, 3, 4);
    auto future1 = eventLoop.shield(task1);

    eventLoop.runUntilComplete(future1);
    assert(future1.result == 7);

    task1 = eventLoop.ensureFuture(&add, 3, 4);
    future1 = eventLoop.shield(task1);
    future1.cancel;

    eventLoop.runUntilComplete(task1);
    assert(future1.cancelled);
    assert(task1.result == 7);
}


enum ReturnWhen
{
    FIRST_COMPLETED,
    FIRST_EXCEPTION,
    ALL_COMPLETED,
}

/**
 * Wait for the Future instances given by $(PARAM futures) to complete.
 *
 * Params:
 *  eventLoop = event loop, $(D_PSYMBOL getEventLoop) if not specified.
 *
 *  futures = futures to wait for.
 *
 *  timeout = can be used to control the maximum number of seconds to wait
 *      before returning. If $(PARAM timeout) is 0 or negative there is no limit
 *      to the wait time.
 *
 *  returnWhen = indicates when this function should return. It must be one of
 *      the following constants:
 *          FIRST_COMPLETED The function will return when any future finishes or
 *              is cancelled.
 *          FIRST_EXCEPTION The function will return when any future finishes by
 *              raising an exception. If no future raises an exception then it
 *              is equivalent to ALL_COMPLETED.
 *          ALL_COMPLETED The function will return when all futures finish or
 *              are cancelled.
 *
 * Returns: a named 2-tuple of arrays. The first array, named $(D_PSYMBOL done),
 *      contains the futures that completed (finished or were cancelled) before
 *      the wait completed. The second array, named $(D_PSYMBOL notDone),
 *      contains uncompleted futures.
 */
@Coroutine
auto wait(Future)(EventLoop eventLoop, Future[] futures,
    Duration timeout = Duration.zero,
    ReturnWhen returnWhen = ReturnWhen.ALL_COMPLETED)
if (is(Future : FutureHandle))
{
    if (eventLoop is null)
        eventLoop = getEventLoop;

    auto thisTask = TaskHandle.getThis;

    assert(thisTask !is null);
    if (futures.empty)
    {
        thisTask.scheduleStep;
        TaskHandle.yield;

        return Tuple!(Future[], "done", Future[], "notDone")(null, null);
    }

    foreach (future; futures)
    {
        future.addDoneCallback(&thisTask.scheduleStep);
    }

    scope (exit)
    {
        foreach (future; futures)
        {
            future.removeDoneCallback(&thisTask.scheduleStep);
        }
    }

    bool completed = false;
    CallbackHandle timeoutCallback;

    if (timeout > Duration.zero)
    {
        timeoutCallback = eventLoop.callLater(timeout, {
            completed = true;
            thisTask.scheduleStep;
        });
    }

    while (!completed)
    {
        TaskHandle.yield;

        if (completed)
            break;

        final switch (returnWhen)
        {
        case ReturnWhen.FIRST_COMPLETED:
            completed = futures.any!"a.done";
            break;
        case ReturnWhen.FIRST_EXCEPTION:
            completed = futures.any!"a.exception !is null" ||
                futures.all!"a.done";
            break;
        case ReturnWhen.ALL_COMPLETED:
            completed = futures.all!"a.done";
            break;
        }
    }

    if (timeoutCallback !is null)
        timeoutCallback.cancel;

    Tuple!(Future[], "done", Future[], "notDone") result;

    result.done = futures.filter!"a.done".array;
    result.notDone = futures.filter!"!a.done".array;

    return result;
}

unittest
{
    auto eventLoop = getEventLoop;

    int add(int a, int b)
    {
        return a + b;
    }

    auto tasks = [
        eventLoop.createTask({
            eventLoop.sleep(10.msecs);
            return add(10, 11);
        }),
        eventLoop.createTask({
            eventLoop.sleep(20.msecs);
            return add(11, 12);
        }),
        eventLoop.createTask({
            eventLoop.sleep(60.msecs);
            return add(12, 13);
        }),
    ];

    auto waitTask = eventLoop.createTask({
        return eventLoop.wait(tasks, 50.msecs);
    });

    auto result = eventLoop.runUntilComplete(waitTask);

    assert(tasks[0].done);
    assert(tasks[1].done);
    assert(!tasks[2].done);

    assert(tasks[0].result == 21);
    assert(tasks[1].result == 23);

    assert(result.done == tasks[0 .. 2]);
    assert(result.notDone == tasks[2 .. $]);
}


/**
 * Wait for the single Future to complete with timeout. If timeout is 0 or
 * negative, block until the future completes.
 *
 * Params:
 *  eventLoop = event loop, $(D_PSYMBOL getEventLoop) if not specified.
 *
 *  future = future to wait for.
 *
 *  timeout = can be used to control the maximum number of seconds to wait
 *      before returning. If $(PARAM timeout) is 0 or negative, block until the
 *      future completes.
 *
 * Returns: result of the future. When a timeout occurs, it cancels the task
 *      and raises $(D_PSYMBOL TimeoutException). To avoid the task
 *      cancellation, wrap it in $(D_SYMBOL shield()).
 */
@Coroutine
auto waitFor(Future)(EventLoop eventLoop, Future future,
    Duration timeout = Duration.zero)
if (is(Future : FutureHandle))
{
    if (eventLoop is null)
        eventLoop = getEventLoop;

    auto thisTask = TaskHandle.getThis;

    assert(thisTask !is null);

    future.addDoneCallback(&thisTask.scheduleStep);

    scope (exit)
    {
        future.removeDoneCallback(&thisTask.scheduleStep);
    }

    bool cancelFuture = false;
    CallbackHandle timeoutCallback;

    if (timeout > Duration.zero)
    {
        timeoutCallback = eventLoop.callLater(timeout, {
            cancelFuture = true;
            thisTask.scheduleStep;
        });
    }

    while (true)
    {
        TaskHandle.yield;

        if (cancelFuture)
        {
            future.cancel;
            throw new TimeoutException;
        }

        if (future.done)
            break;
    }

    if (timeoutCallback !is null)
        timeoutCallback.cancel;

    static if (!is(Future.ResultType == void))
    {
        return future.result;
    }
}

unittest
{
    auto eventLoop = getEventLoop;

    int add(int a, int b)
    {
        return a + b;
    }

    auto task1 = eventLoop.createTask({
        eventLoop.sleep(10.msecs);
        return add(10, 11);
    });

    auto task2 = eventLoop.createTask({
        eventLoop.sleep(40.msecs);
        return add(10, 11);
    });

    auto waitTask = eventLoop.createTask({
        eventLoop.waitFor(task1, 20.msecs);
        assert(task1.done);
        assert(task1.result == 21);
        assert(!task2.done);
        try
        {
            eventLoop.waitFor(task2, 10.msecs);
            assert(0, "Should not get here");
        }
        catch (TimeoutException timeoutException)
        {
            eventLoop.sleep(20.msecs);
            assert(task2.done);
            assert(task2.cancelled);
        }
    });

    eventLoop.runUntilComplete(waitTask);
}

/**
 * A $(D_PSYMBOL GeneratorTask) is a $(D_PSYMBOL Task) that periodically returns
 * values of type $(D_PSYMBOL T) to the caller via $(D_PSYMBOL yieldValue). This
 * is represented as an $(D_PSYMBOL InputRange).
 */
class GeneratorTask(T) : Task!(void delegate())
{
    private T* frontValue = null;
    private TaskHandle waitingTask = null;

    this(EventLoop eventLoop, void delegate() coroutine)
    {
        super(eventLoop, coroutine);
        addDoneCallback({
            if (waitingTask)
            {
                waitingTask.scheduleStep;
                waitingTask = null;
            }
        });
    }

    package void setFrontValue(ref T value)
    {
        frontValue = &value;
        if (waitingTask)
        {
            waitingTask.scheduleStep;
            waitingTask = null;
        }
    }

    @Coroutine
    @property bool empty()
    {
        if (done)
            return true;

        if (frontValue !is null)
            return false;

        auto thisTask = TaskHandle.getThis;

        assert(thisTask !is null);
        assert(thisTask !is this, "empty() called in the task routine");

        if (eventLoop is null)
            eventLoop = getEventLoop;

        assert(waitingTask is null, "another Task is already waiting");
        waitingTask = thisTask;
        TaskHandle.yield;
        assert(done || frontValue !is null);

        return empty;
    }

    @property ref T front()
    {
        assert(frontValue !is null);
        return *frontValue;
    }

    void popFront()
    {
        assert(frontValue !is null);
        frontValue = null;
        scheduleStep;
    }
}

/**
 * Yield a value to the caller of the currently executing generator task. The
 * type of the yielded value and of type of the generator must be the same;
 */
@Coroutine
void yieldValue(T)(auto ref T value)
{
    auto generatorTask = cast(GeneratorTask!T) TaskHandle.getThis;
    enforce(generatorTask !is null,
        "'TaskHandle.yieldValue' called outside of a generator task.");

    generatorTask.setFrontValue(value);

    TaskHandle.yield;
}

unittest
{
    import std.functional : toDelegate;

    auto eventLoop = getEventLoop;
    auto task1 = new GeneratorTask!int(eventLoop, {}.toDelegate);
    auto testTask = eventLoop.createTask({
        assert(task1.empty);
    });

    eventLoop.runUntilComplete(testTask);

    auto task2 = new GeneratorTask!int(eventLoop, {
        yieldValue(8);
        yieldValue(10);
    }.toDelegate);

    auto testTask2 = eventLoop.createTask({
        int[] array1 = task2.array;

        assert(array1 == [8, 10]);
        assert(task2.empty);
    });

    eventLoop.runUntilComplete(testTask2);
}
