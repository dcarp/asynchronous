module asynchronous.tasks;

import core.thread;
import std.algorithm;
import std.array;
import std.exception;
import std.traits;
import asynchronous.events;
import asynchronous.futures;
import asynchronous.types;

package class TaskRepository
{
    private static __gshared TaskHandle[EventLoop] currentTasks;

    private static __gshared TaskHandle[][EventLoop] tasks;

    private static __gshared ResourcePool!(Fiber, void function()) fibers;

    static this()
    {
        fibers = new ResourcePool!(Fiber, void function())({});
    }

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

    static void resetCurrentTask(EventLoop eventLoop, TaskHandle task = null)
    in
    {
        assert(eventLoop !is null);
    }
    body
    {
        currentTasks[eventLoop] = task;
    }

    package static void registerTask(EventLoop eventLoop, TaskHandle task, void delegate() dg)
    in
    {
        assert(eventLoop !is null);
        assert(task !is null);
        assert(task.fiber is null);
    }
    out
    {
        assert(task.fiber.state == Fiber.State.HOLD);
    }
    body
    {
        task.fiber = fibers.acquire;
        task.fiber.reset(dg);

        tasks[eventLoop] ~= task;
    }

    package static void unregisterTask(EventLoop eventLoop, TaskHandle task)
    in
    {
        assert(eventLoop !is null);
        assert(task !is null);
        assert(task.fiber.state == Fiber.State.TERM);
    }
    body
    {
        task.fiber.reset;
        fibers.release(task.fiber);
        task.fiber = null;

        tasks[eventLoop].remove!(a => a is task);
    }
}

interface TaskHandle : FutureHandle
{
    protected @property Fiber fiber();
    protected @property Fiber fiber(Fiber fiber_);

    protected @property Throwable injectException();

    protected void step(Throwable throwable = null);

    protected void scheduleStep();

    /**
     * Returns: a set of all tasks for an event loop.
     *
     * By default all tasks for the current event loop are returned.
     */
    public static TaskHandle[] allTasks(EventLoop eventLoop = null)
    {
        if (eventLoop is null)
            eventLoop = getEventLoop;

        return TaskRepository.allTasks(eventLoop);
    }

    /**
     * Returns: the currently running task in an event loop or $(D_KEYWORD null).
     *
     * By default the current task for the current event loop is returned.
     *
     * $(D_KEYWORD null) is returned when called not in the context of a Task.
     */
    public static TaskHandle currentTask(EventLoop eventLoop = null)
    {
        if (eventLoop is null)
            eventLoop = getEventLoop;

        return TaskRepository.currentTask(eventLoop);
    }
}

/**
 * Schedule the execution of a fiber: wrap it in a future. A task is a subclass of Future.
 *
 * A task is responsible for executing a fiber object in an event loop. If the wrapped fiber yields from a future, the
 * task suspends the execution of the wrapped fiber and waits for the completion of the future. When the future is
 * done, the execution of the wrapped fiber restarts with the result or the exception of the fiber.
 *
 * Event loops use cooperative scheduling: an event loop only runs one task at a time. Other tasks may run in parallel
 * if other event loops are running in different threads. While a task waits for the completion of a future, the event
 * loop executes a new task.
 *
 * The cancellation of a task is different from the cancelation of a future. Calling $(D_PSYMBOL cancel()) will throw a
 * $(D_PSYMBOL CancelledException) to the wrapped fiber. $(D_PSYMBOL cancelled()) only returns $(D_KEYWORD true) if the
 * wrapped fiber did not catch the $(D_PSYMBOL CancelledException), or raised a $(D_PSYMBOL CancelledException).
 *
 * If a pending task is destroyed, the execution of its wrapped fiber did not complete. It is probably a bug and a
 * warning is logged: see Pending task destroyed.
 *
 * Don’t directly create $(D_PSYMBOL Task) instances: use the $(D_PSYMBOL async()) function or the
 * $(D_PSYMBOL EventLoop.create_task()) method.
 */
class Task(Coroutine, Args...) : Future!(ReturnType!Coroutine), TaskHandle
    if (isDelegate!Coroutine)
{
    alias ResultType = ReturnType!Coroutine;

    private Fiber fiber_;

    protected override @property Fiber fiber()
    {
        return this.fiber_;
    }

    protected override @property Fiber fiber(Fiber fiber_)
    {
        enforce(this.fiber_ is null && fiber_ !is null || this.fiber_.state == Fiber.State.TERM && fiber_ is null);
        return this.fiber_ = fiber_;
    }

    private Throwable injectException_;

    protected override @property Throwable injectException()
    {
        return this.injectException_;
    }

    public this(EventLoop eventLoop, Coroutine coroutine, Args args)
    {
        super(eventLoop);

        TaskRepository.registerTask(this.eventLoop, this, {
            static if (is(ResultType : void))
            {
                coroutine(args);
                setResult;
            }
            else
            {
                setResult(coroutine(args));
            }
        });
        this.eventLoop.callSoon(&step, null);
    }

    /**
     * Request that this task cancel itself.
     *
     * This arranges for a $(D_PSYMBOL CancelledException) to be thrown into the wrapped coroutine on the next cycle
     * through the event loop. The coroutine then has a chance to clean up or even deny the request using
     * try/catch/finally.
     *
     * Unlike $(D_PSYMBOL Future.cancel()), this does not guarantee that the task will be cancelled: the exception
     * might be caught and acted upon, delaying cancellation of the task or preventing cancellation completely. The
     * task may also return a value or raise a different exception.
     *
     * Immediately after this method is called, $(D_PSYMBOL cancelled()) will not return $(D_KEYWORD true) (unless the
     * task was already cancelled). A task will be marked as cancelled when the wrapped coroutine terminates with a
     * $(D_PSYMBOL CancelledException) (even if cancel() was not called).
     */
    override public bool cancel()
    {
        if (done)
            return false;

        this.injectException_ = new CancelledException;
        return true;
    }

    protected override void step(Throwable throwable = null)
    {
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
                    eventLoop.callSoon(&step, null);

                TaskRepository.resetCurrentTask(this.eventLoop);
                break;
            case Fiber.State.EXEC:
                assert(0, "Internal error");
            case Fiber.State.TERM:
                assert(done);
                TaskRepository.unregisterTask(this.eventLoop, this);
                break;
        }
    }

    protected override void scheduleStep()
    {
        this.eventLoop.callSoon(&step, null);
    }

    override string toString()
    {
        import std.string;

        return "%s(done: %s, cancelled: %s)".format(typeid(this), done, cancelled);
    }
}

@Coroutine
auto sleep(EventLoop eventLoop, Duration delay)
{
    if (eventLoop is null)
        eventLoop = getEventLoop;

    auto thisTask = TaskRepository.currentTask(eventLoop);

    assert(thisTask !is null);
    eventLoop.callLater(delay, &thisTask.scheduleStep);

    eventLoop.yield;
}

auto async(Coroutine, Args...)(EventLoop eventLoop, Coroutine coroutine, Args args)
{
    return new Task!(Coroutine, Args)(eventLoop, coroutine, args);
}

unittest
{
    import std.functional;

    auto task = async(null, toDelegate({
        return 3 + 39;
    }));

    assert(!task.done);
    assert(!task.cancelled);

    task.cancel;
    assert(!task.cancelled);

    auto result = getEventLoop.runUntilComplete(task);

    assert(task.done);
    assert(!task.cancelled);
    assert(result == 42);
}

package void resume(TaskHandle task)
{
    task.scheduleStep;
}

/**
 * Forces a context switch to occur away from the calling task.
 *
 * Params:
 *  eventLoop = event loop, $(D_PSYMBOL getEventLoop) if not specified.
 */
package void yield(EventLoop eventLoop)
{
    Fiber.yield;

    if (eventLoop is null)
        eventLoop = getEventLoop;

    auto currentTask = TaskRepository.currentTask(eventLoop);

    enforce(currentTask !is null, "'yield' can be used in a task only");
    assert(currentTask.fiber.state == Fiber.State.EXEC);

    if (currentTask.injectException !is null)
        throw currentTask.injectException;
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
 *  eventLoop  = event loop, $(D_PSYMBOL getEventLoop) if not specified.
 *  futures    = futures to wait for.
 *  timeout    = can be used to control the maximum number of seconds to wait before returning. If $(PARAM timeout) is
 *               0 or negative there is no limit to the wait time.
 *  returnWhen = indicates when this function should return. It must be one of the following constants:
 *               FIRST_COMPLETED  The function will return when any future finishes or is cancelled.
 *               FIRST_EXCEPTION  The function will return when any future finishes by raising an exception. If no
 *                                future raises an exception then it is equivalent to ALL_COMPLETED.
 *               ALL_COMPLETED    The function will return when all futures finish or are cancelled.
 *
 * Returns: a named 2-tuple of sets. The first set, named $(D_PSYMBOL done), contains the futures that completed
 *          (finished or were cancelled) before the wait completed. The second set, named $(D_PSYMBOL notDone),
 *          contains uncompleted futures.
 */
@Coroutine
auto wait(Future)(EventLoop eventLoop, Future[] futures, Duration timeout = 0.seconds,
        ReturnWhen returnWhen = ReturnWhen.ALL_COMPLETED)
    if (is(Future : FutureHandle))
{
    if (eventLoop is null)
        eventLoop = getEventLoop;

    auto thisTask = TaskRepository.currentTask(eventLoop);

    assert(thisTask !is null);
    if (futures.empty)
    {
        eventLoop.callSoon(&thisTask.scheduleStep);
        eventLoop.yield;

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

    if (timeout > 0.seconds)
    {
        timeoutCallback = eventLoop.callLater(timeout, {
            completed = true;
            eventLoop.callSoon(&thisTask.scheduleStep);
        });
    }

    while (!completed)
    {
        eventLoop.yield;

        if (completed)
            break;

        final switch (returnWhen)
        {
            case ReturnWhen.FIRST_COMPLETED:
                completed = futures.any!"a.done";
                break;
            case ReturnWhen.FIRST_EXCEPTION:
                completed = futures.any!"a.exception !is null" || futures.all!"a.done";
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

    assert(result.done == tasks[0..2]);
    assert(result.notDone == tasks[2..$]);
}


/**
 * Wait for the single Future to complete with timeout. If timeout is None, block until the future completes.
 *
 * Params:
 *  eventLoop = event loop, $(D_PSYMBOL getEventLoop) if not specified.
 *  future    = future to wait for.
 *  timeout   = can be used to control the maximum number of seconds to wait before returning. If $(PARAM timeout) is
 *               0 or negative, block until the future completes.
 *
 * Returns: result of the future. When a timeout occurs, it cancels the task and raises $(D_PSYMBOL TimeoutException).
 *          To avoid the task cancellation, wrap it in $(D_SYMBOL shield().
 */
@Coroutine
auto waitFor(Future)(EventLoop eventLoop, Future future, Duration timeout = 0.seconds)
    if (is(Future : FutureHandle))
{
    if (eventLoop is null)
        eventLoop = getEventLoop;

    auto thisTask = TaskRepository.currentTask(eventLoop);

    assert(thisTask !is null);

    future.addDoneCallback(&thisTask.scheduleStep);

    scope (exit)
    {
        future.removeDoneCallback(&thisTask.scheduleStep);
    }

    bool cancelFuture = false;
    CallbackHandle timeoutCallback;

    if (timeout > 0.seconds)
    {
        timeoutCallback = eventLoop.callLater(timeout, {
            cancelFuture = true;
            eventLoop.callSoon(&thisTask.scheduleStep);
        });
    }

    while (true)
    {
        eventLoop.yield;

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

    static if (is(future.result))
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
        eventLoop.sleep(50.msecs);
        return add(10, 11);
    });

    auto waitTask = eventLoop.createTask({
        eventLoop.waitFor(task1, 20.msecs);
        assert(task1.done);
        assert(task1.result == 21);
        try
        {
            eventLoop.waitFor(task2, 10.msecs);
            assert(0, "Should not get hier");
        }
        catch (TimeoutException timeoutException)
        {
            eventLoop.sleep(40.msecs);
            assert(task2.done);
            assert(task2.cancelled);
        }
    });

    eventLoop.runUntilComplete(waitTask);
}
