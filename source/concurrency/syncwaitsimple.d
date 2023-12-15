module concurrency.syncwaitsimple;

import concurrency.stoptoken;
import concurrency.sender;
import concurrency.thread;
import concepts;
import std.sumtype;
import concurrency.syncwait : Result;

/** 
 * 

We can simply assume that the Sender that runs in syncWait is blocking, why? Because if it isn't then it needs to run
async, and where does it run if syncWait didn't give it a execution context to run in?

Ergo, it runs on the main thread.

Currently we have ThreadSender and FiberSender. For ThreadSender we probably want to do this differently and instead
have something that owns the Thread, like a pool (even a pool for one), and now we have something that owns the threads
and needs to join on them, thus blocking the main thread.

For FiberSender the situation is different. The Fiber can be considered blocking as well though, since if it yields it
always yields *to* something. By default the syncWait doens't expose additional execution contexts, so where can it run?
Only on the main thread.


The question then becomes, how do we inject these SingleThreadTimers, ThreadPools and EventLoops in the async graph, and
have them block until syncWait completes?

As we saw with iouring, the EventLoop itself can be modelled as a Sender.


In C++ they model the executors as separate entities.

This has the benefit that one can easily schedule (parts of) the async graph onto a specific scheduler.

For instance, while the parsing of an HTTP request can happen mostly on the io scheduler, the handling might
be best moved to a thread pool, until the request is done and is about to start on the response, at which point
rescheduling it on the io scheduler could happen.

Such a thread pool is created somewhere and then passed to sub async computations.


However, do note that such a thread pool can be gotton by using letValue, and then has its lifetime constrained.
The extra nesting isn't nice, and it might best be done with an immovable, non-copyable stack item.



{
	timer_single_thread context;
	
	context.run(just(...)).syncWait();
}

{
	auto context = thread_pool(4);

	context.run(just(...)).syncWait();
}

{
	auto context = iouring(512);

	context.run(just(...)).syncWait();
}

Now, run iouring, with a thread_pool for tasks and a timer_single_thread

{
	timer_single_thread timer;
	auto pool = thread_pool(4);
	auto context = iouring(512);

	auto scheduler = pool.getScheduler();

	timer.run(context.run(server(pool)).on(scheduler)).syncWait;
}

Here timer and context by default block the thread, but because we run the
iouring on the thread_pool scheduler only timer blocks the thread.


A timer/iouring is something that outlives the sender it runs while providing
scheduling.

If something provides a NullScheduler it means it isn't scheduling things on the
current thread.


 */


/*

Lets say we accept the semaphore thing

*/

import concurrency.syncwait : Cancelled, Completed;

private struct State(Value) {
	static if (!is(Value == void))
		alias Store = SumType!(Value, Cancelled, Throwable);
	else
		alias Store = SumType!(Completed, Cancelled, Throwable);

	shared StopSource* stopSource;
	import core.sync.semaphore;
	Store result;
	InPlaceSemaphore semaphore;

	this(shared ref StopSource stopSource) {
		import core.lifetime;

		this.stopSource = &stopSource;
		semaphore = InPlaceSemaphore(0);
	}

	private void notify() nothrow @trusted @nogc {
		semaphore.notify();
	}

	private void wait() nothrow @trusted @nogc {
		semaphore.wait();
	}
}

package struct SyncWaitReceiver(Value) {
	private State!(Value)* state;
	void setDone() nothrow @trusted {
		state.result = Cancelled();
		state.notify();
	}

	void setError(Throwable e) nothrow @trusted {
		state.result = e;
		state.notify();
	}

	static if (is(Value == void))
		void setValue() nothrow @trusted {
			state.result = Completed();
			state.notify();
		}

	else
		void setValue(Value value) nothrow @trusted {
			state.result = value;
			state.notify();
		}

	auto getStopToken() nothrow @safe @nogc {
		return state.stopSource.token();
	}

	auto getScheduler() nothrow @trusted {
		import concurrency.scheduler : NullScheduler;

		return NullScheduler();
	}
}

/// Start the Sender and waits until it completes, cancels, or has an error.
auto syncWaitSimple(Sender)(auto ref Sender sender,
					  shared ref StopSource stopSource) {
	return syncWaitImpl(sender, stopSource);
}

auto syncWaitSimple(Sender)(auto scope ref Sender sender) @trusted {
	import concurrency.signal : globalStopSource;
	shared StopSource childStopSource;
	auto cb = shared StopCallback(() shared {
		childStopSource.stop();
	});
	shared parentStopToken = StopToken(globalStopSource);
    cb.onStop(paentStopToken);

	try {
		auto result = syncWaitImpl(sender, childStopSource);

		version (unittest) childStopSource.assertNoCallbacks;
		// detach stopSource
		cb.dispose();
		return result;
	} catch (Throwable t) { // @suppress(dscanner.suspicious.catch_em_all)
		cb.dispose();
		throw t;
	}
}

private
Result!(Sender.Value) syncWaitImpl(Sender)(auto scope ref Sender sender,
                                           ref shared StopSource stopSource) @trusted {
	static assert(models!(Sender, isSender));

	alias Value = Sender.Value;
	auto state = State!Value(stopSource);

	scope receiver = SyncWaitReceiver!(Value)(&state);
	auto op = sender.connect(receiver);
	op.start();

	state.wait();

	return state.result.match!((Throwable exception) {
		if (auto e = cast(Exception) exception)
			return Result!Value(e);
		throw exception;
	},
		(r) => Result!Value(r));
}

import core.sync.exception;
import core.time;

version (OSX)
    version = Darwin;
else version (iOS)
    version = Darwin;
else version (TVOS)
    version = Darwin;
else version (WatchOS)
    version = Darwin;

version (Windows)
{
    import core.sys.windows.basetsd /+: HANDLE+/;
    import core.sys.windows.winbase /+: CloseHandle, CreateSemaphoreA, INFINITE,
        ReleaseSemaphore, WAIT_OBJECT_0, WaitForSingleObject+/;
    import core.sys.windows.windef /+: BOOL, DWORD+/;
    import core.sys.windows.winerror /+: WAIT_TIMEOUT+/;
}
else version (Darwin)
{
    import core.sync.config;
    import core.stdc.errno;
    import core.sys.posix.time;
    import core.sys.darwin.mach.semaphore;
}
else version (Posix)
{
    import core.sync.config;
    import core.stdc.errno;
    import core.sys.posix.pthread;
    import core.sys.posix.semaphore;
}
else
{
    static assert(false, "Platform not supported");
}


////////////////////////////////////////////////////////////////////////////////
// Semaphore
//
// void wait();
// void notify();
////////////////////////////////////////////////////////////////////////////////


/**
 * This class represents a general counting semaphore as concieved by Edsger
 * Dijkstra.  As per Mesa type monitors however, "signal" has been replaced
 * with "notify" to indicate that control is not transferred to the waiter when
 * a notification is sent.
 */
struct InPlaceSemaphore {
    ////////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////////


    /**
     * Initializes a semaphore object with the specified initial count.
     *
     * Params:
     *  count = The initial count for the semaphore.
     *
     * Throws:
     *  SyncError on error.
     */
    this( uint count ) @nogc nothrow @trusted
    {
        version (Windows)
        {
            m_hndl = CreateSemaphoreA( null, count, int.max, null );
            assert( m_hndl != m_hndl.init, "Unable to create semaphore" );
        }
        else version (Darwin)
        {
            auto rc = semaphore_create( mach_task_self(), &m_hndl, SYNC_POLICY_FIFO, count );
            assert( rc == 0, "Unable to create semaphore" );
        }
        else version (Posix)
        {
            int rc = sem_init( &m_hndl, 0, count );
            assert( rc == 0, "Unable to create semaphore" );
        }
    }


    ~this() @nogc nothrow @trusted
    {
        version (Windows)
        {
            BOOL rc = CloseHandle( m_hndl );
            assert( rc, "Unable to destroy semaphore" );
        }
        else version (Darwin)
        {
            auto rc = semaphore_destroy( mach_task_self(), m_hndl );
            assert( !rc, "Unable to destroy semaphore" );
        }
        else version (Posix)
        {
            int rc = sem_destroy( &m_hndl );
            assert( !rc, "Unable to destroy semaphore" );
        }
    }


    ////////////////////////////////////////////////////////////////////////////
    // General Actions
    ////////////////////////////////////////////////////////////////////////////


    /**
     * Wait until the current count is above zero, then atomically decrement
     * the count by one and return.
     *
     * Returns:
     *  false on error.
     */
    bool wait() nothrow @nogc @trusted
    {
        version (Windows)
        {
            DWORD rc = WaitForSingleObject( m_hndl, INFINITE );
            return rc == WAIT_OBJECT_0;
        }
        else version (Darwin)
        {
            while ( true )
            {
                auto rc = semaphore_wait( m_hndl );
                if ( !rc )
                    return true;
                if ( rc == KERN_ABORTED && errno == EINTR )
                    continue;
                return false;
            }
        }
        else version (Posix)
        {
            while ( true )
            {
                if ( !sem_wait( &m_hndl ) )
                    return true;
                if ( errno != EINTR )
                    return false;
            }
        }
    }

    /**
     * Atomically increment the current count by one.  This will notify one
     * waiter, if there are any in the queue.
     *
     * Returns:
	 *  false on error.
     */
    bool notify() nothrow @nogc @trusted
    {
        version (Windows)
        {
            if ( !ReleaseSemaphore( m_hndl, 1, null ) )
                return false;
        }
        else version (Darwin)
        {
            if ( semaphore_signal( m_hndl ) )
                return false;
        }
        else version (Posix)
        {
            if ( sem_post( &m_hndl ) )
                return false;
        }
		return true;
    }

    /// Aliases the operating-system-specific semaphore type.
    version (Windows)        alias Handle = HANDLE;
    /// ditto
    else version (Darwin)    alias Handle = semaphore_t;
    /// ditto
    else version (Posix)     alias Handle = sem_t;

    /// Handle to the system-specific semaphore.
    private Handle m_hndl;
}
