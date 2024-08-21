module concurrency.stoptoken;

// Cancellation is an important concept when running asynchronous tasks.
// When an asynchronous operation is no longer needed it is desirable to
// cancel it to avoid doing unnecessary work, potentionally freeing system
// resources and maintaining responsiveness in the process.

// There are several reasons why an asynchronous operation might become
// irrelevant, including:

// - An error in one part of an application might render the results of
// other ongoing asynchronous tasks irrelevant.

// - Clients or end-users might want to abort an earlier request they made.

// - Outstanding work might need to be cancelled due to stale data.

// - Work might become irrelevant due to errors in external systems.

// - As part of control flow in an asynchronous algorithm. Similar to how
// you might have an `break` or early `return` in a synchronous piece of
// code.

// This module implements cooperative cancellation by providing a StopSource,
// StopToken and StopCallback.

// - the StopSource represents the source of a cancellation request.
// - the StopToken is used to determine if a cancellation request has been
//   initiated.
// - the StopCallback is invoked when a cancellation request has been
//   initiated.

// Implementation details:

// Allocations can have a non-neglible overhead when running many short-lived
// asynchronous tasks. For this reason these objects are designed to be used
// in-place on the stack.

// To ensure program safety and correctness we need to uphold that a
// `StopSource` outlives any associated `StopToken` or `StopCallback`,
// otherwise we might open ourselves to use-after-free errors.

// We achieve that by:

// - having a StopCallback deregister itself from a StopSource on destruction
// - having a StopSource deregister any StopCallbacks still registered on
// destruction
// - relying on `scope` StopTokens to ensure they don't outlive the
// StopSource
// - disabling copy and assignment constructors for the StopSource and
// StopToken
// - relying on dip1000

/// A StopSource represents the source of a cancellation request. You can think
/// of it as the entity that initiates the request for cancellation.
/// Once a stop is requested, it cannot be withdrawn. Additional stop requests
/// have no effect.
struct StopSource {
	@disable this(ref return scope StopSource rhs) @safe;
	@disable this(ref return scope shared StopSource rhs) shared @safe;
	public shared StopState state;

	~this() nothrow @safe @nogc shared scope {
		assertNoCallbacks();
	}

	/// Returns an associated StopToken
	shared(StopToken) token() nothrow @safe @nogc shared return {
		return shared StopToken(this);
	}

	/// Trigger a cancellation request. This will trigger any StopCallback that was
	/// registered through a StopToken associated with this StopSource.
	/// Additionally any calls to the `isStopRequested` method on an associated
	/// StopToken will return true.
	///
	/// Returns true if this is the first cancellation request.
	bool stop() nothrow @safe shared scope {
		return state.requestStop();
	}

	/// Returns true if a cancellation request has been triggered.
	bool isStopRequested() nothrow @safe @nogc shared scope {
		return state.isStopRequested();
	}

	/// Resets the internal state. To ensure no dangling state it will first trigger
	/// any registered StopCallbacks.
	void reset() nothrow @safe shared scope {
		stop();
		this.state = StopState();
	}

	/// Primarily used in unittests or debug builds to ensure there are no
	/// dangling callbacks.
	/// Because both the StopSource and StopCallbacks are to be placed
	/// on the stack, a programming error can result in hard to debug
	/// use-after-free errors.
	/// This method allows to catch those errors before they becomes
	/// much harder to debug.
	void assertNoCallbacks() nothrow @safe @nogc shared scope {
		state.assertEmpty();
	}

	@disable void opAssign(shared StopSource rhs) nothrow @safe @nogc shared;
	@disable void opAssign(ref shared StopSource rhs) nothrow @safe @nogc shared;
}

/// A StopToken is associated with a StopSource and is used to determine
/// whether a cancellation request has been initiated.
/// It is up to the task to check this token and react accordingly.
///
/// Cancellation can be checked either by calling `isStopRequested` or
/// registering a StopCallback. The StopCallback will be called when the
/// underlying StopSource is triggered.
///
/// A StopToken can be obtained by calling the `token` method on a StopSource.
struct StopToken {
	private shared StopState* state;

	private this(return ref shared StopSource stopSource) nothrow @safe @nogc shared {
		this.state = &stopSource.state;
	}

	/// Returns true if a cancellation request has been initiated with the associated StopSource
	bool isStopRequested() nothrow @safe @nogc scope shared {
		return state && state.isStopRequested();
	}
}

/// A StopCallback can be associated with a StopToken, and contains a callback
/// that will be invoked when a stop request in the underlying StopSource's
/// is triggered.
///
/// There is no guarantee which execution context the callback is invoked on.
struct StopCallback {
	@disable this(ref return scope shared StopCallback rhs);
	@disable this(ref return scope StopCallback rhs);

	~this() @safe scope @nogc nothrow shared {
		dispose();
	}

	/// Register the StopCallback with a StopToken and a specified callback.
	/// 
	/// The supplied callback will be invoked exactly once when the StopToken
	/// is triggered. That invocation might happen before this function returns.
	///
	/// A subsequent call to `register` will first ensure any existing registered
	/// callback is unregistered. Note that the existing callback might still get
	/// invoked if the existing StopToken is triggered at the same time.
	///
	/// In cases where this is unwanted you can call `dispose` yourself before
	/// registering a new callback.
	void register(return ref shared StopToken token, void delegate() nothrow @safe shared callback) nothrow @safe scope return shared {
		dispose();

		/// TODO: before we continue here we need to be 100% sure the previous callback
		/// isn't invoked, or ensure we wait until it is done.
		
		this.callback = callback;

		if (token.state && token.state.tryAddCallback(cast(shared)this))
			this.state = token.state;
	}

	/// Dispose the stopcallback, deregistering it from an associated StopToken,
	/// if any.
	///
	/// The registered callback could still be triggered while this function is
	/// executing, but it will have been ran to completion before it returns.
	void dispose() shared nothrow @trusted @nogc scope {
		import core.atomic : cas;

		// TODO: might have to reset prev or next if state is null
		if (state is null)
			return;
		auto local = state;
		if (!cas(&state, local, null)) {
			assert(state is null);
			return;
		}
		local.removeCallback(this);
	}

	@disable void opAssign(ref shared StopCallback rhs) nothrow @safe @nogc shared;
	@disable void opAssign(shared StopCallback rhs) nothrow @safe @nogc shared;
private:
	void delegate() nothrow @safe shared callback;
	shared StopState* state;

	shared StopCallback* next = null;
	shared StopCallback** prev = null;
	shared bool* isRemoved = null;
	shared bool callbackFinishedExecuting = false;
}

private void spinYield() nothrow @trusted @nogc {
	// TODO: could use the pause asm instruction
	// it is available in LDC as intrinsic... but not in DMD
	import core.thread : Thread;

	Thread.yield();
}

/// The StopState is the internal state object used in the StopSource.
/// It contains the linked list of StopCallbacks and the methods to
/// add, remove and trigger the callbacks in a thread-safe manner.
///
/// It is based on the code from https://github.com/josuttis/jthread
/// by Nicolai Josuttis, licensed under the Creative Commons Attribution
/// 4.0 Internation License http://creativecommons.org/licenses/by/4.0
private struct StopState {
	import core.thread : Thread;
	import core.atomic : atomicStore, atomicLoad, MemoryOrder, atomicOp, atomicFetchAdd, atomicFetchSub;
	import core.atomic : casWeak;

	bool requestStop() nothrow @safe shared scope {
		if (!tryLockAndSignalUntilSignalled()) {
			// Stop has already been requested.
			return false;
		}

		// Set the 'stop_requested' signal and acquired the lock.
		storeSignallingThread();

		while (head !is null) {
			// Dequeue the head of the queue
			auto cb = head;
			head = cb.next;
			const bool anyMore = head !is null;
			if (anyMore) {
				// @trusted due to error "`scope` applies to first indirection only"
				(() @trusted => head.prev = &head)();
			}

			// Mark this item as removed from the list.
			cb.prev = null;

			// Don't hold lock while executing callback
			// so we don't block other threads from deregistering callbacks.
			unlock();

			// TRICKY: Need to store a flag on the stack here that the callback
			// can use to signal that the destructor was executed inline
			// during the call. If the destructor was executed inline then
			// it's not safe to dereference cb after callback() returns.
			// If the destructor runs on some other thread then the other
			// thread will block waiting for this thread to signal that the
			// callback has finished executing.
			shared bool isRemoved = false;
			(() @trusted => cb.isRemoved =
				&isRemoved)(); // the pointer to the stack here is removed 3 lines down.

			cb.callback();

			if (!isRemoved) {
				cb.isRemoved = null;
				cb.callbackFinishedExecuting
				  .atomicStore!(MemoryOrder.rel)(true);
			}

			if (!anyMore) {
				// This was the last item in the queue when we dequeued it.
				// No more items should be added to the queue after we have
				// marked the state as interrupted, only removed from the queue.
				// Avoid acquring/releasing the lock in this case.
				return true;
			}

			lock();
		}

		unlock();

		return true;
	}

	bool isStopRequested() nothrow @safe @nogc shared scope {
		return isStopRequested(state.atomicLoad!(MemoryOrder.acq));
	}

	bool tryAddCallback(ref return scope shared StopCallback cb) nothrow @trusted shared {
		ulong oldState;
		do {
			goto load_state;
			do {
				spinYield();

			load_state:
				oldState = state.atomicLoad!(MemoryOrder.acq);
				if (isStopRequested(oldState)) {
					cb.callback();
					return false;
				}
			} while (isLocked(oldState));
		} while (!casWeak!(MemoryOrder.acq, MemoryOrder.acq)(
			         &state, oldState, oldState | lockedFlag));

		// Push callback onto callback list.
		cb.next = head;
		if (cb.next !is null) {
			cb.next.prev = &cb.next;
		}

		() @trusted {
			cb.prev = &head;
		}();
		head = &cb;

		unlock();

		// Successfully added the callback.
		return true;
	}

	void removeCallback(ref shared StopCallback cb) nothrow @safe @nogc shared {
		lock();

		if (cb.prev !is null) {
			// Still registered, not yet executed
			// Just remove from the list.
			*cb.prev = cb.next;
			if (cb.next !is null) {
				cb.next.prev = cb.prev;
			}

			unlock();

			return;
		}

		unlock();

		// Callback has either already executed or is executing
		// concurrently on another thread.

		if (isSignallingThread()) {
			// Callback executed on this thread or is still currently executing
			// and is deregistering itself from within the callback.
			if (cb.isRemoved !is null) {
				// Currently inside the callback, let the requestStop() method
				// know the object is about to be destructed and that it should
				// not try to access the object when the callback returns.
				*cb.isRemoved = true;
			}
		} else {
			// Callback is currently executing on another thread,
			// block until it finishes executing.
			while (!cb.callbackFinishedExecuting.atomicLoad!(MemoryOrder.acq)) {
				spinYield();
			}
		}
	}

	bool isFinished(ref shared StopCallback cb) nothrow @safe @nogc shared {
		return cb.callbackFinishedExecuting.atomicLoad!(MemoryOrder.acq);
	}

	void assertEmpty() @safe shared @nogc nothrow scope {
		// Return early if head is zero.
		if (head.atomicLoad!(MemoryOrder.acq) is null) {
			return;
		}

		// Otherwise we have to do a bit of cleanup before asserting.
		// `assertEmpty` is typically called during tests or debug builds only,
		// right before destroying the StopSource and its StopState.
		//
		// In case it is violated we can't just assert however. Both StopCallbacks
		// and StopSources sit on the stack and callbacks must be deregistered
		// before either one is deconstructed, otherwise the callback might try
		// to deregister itself from a dangling StopSource, potentially from
		// another thread or fiber.
		//
		// This can result in complex to debug use-after-free errors.
		// In order to reduce that we clean up those callbacks before asserting.
		//
		// There is no guarantee other callbacks won't be registered concurrently,
		// either in between unlock and assert, or even afterwards, but this is
		// primarily to be used for detecting errors to aid throubleshooting,
		// not as a failsafe mechanism.
		lock();
		shared StopState* blank = null;
		while (head !is null) {
			// Go through all pointers and dispose, this is to
			// avoid a segfault when doing the assert.
			auto next = head.next;
			atomicStore(head.state, blank);
			head = next;
		}
		atomicStore(head, null);
		unlock();
		assert(false, "StopSource has lingering callbacks");
	}

	static bool isLocked(ulong state) nothrow @safe @nogc {
		return (state & lockedFlag) != 0;
	}

	static bool isStopRequested(ulong state) nothrow @safe @nogc {
		return (state & stopRequestedFlag) != 0;
	}

	bool tryLockAndSignalUntilSignalled() nothrow @safe @nogc shared scope {
		ulong oldState;
		do {
			oldState = state.atomicLoad!(MemoryOrder.acq);
			if (isStopRequested(oldState))
				return false;
			while (isLocked(oldState)) {
				spinYield();
				oldState = state.atomicLoad!(MemoryOrder.acq);
				if (isStopRequested(oldState))
					return false;
			}
		} while (!casWeak!(MemoryOrder.seq, MemoryOrder.acq)(
			         &state, oldState,
			         oldState | stopRequestedFlag | lockedFlag));

		return true;
	}

	void lock() nothrow @safe @nogc shared scope {
		ulong oldState;
		do {
			oldState = state.atomicLoad!(MemoryOrder.raw);
			while (isLocked(oldState)) {
				spinYield();
				oldState = state.atomicLoad!(MemoryOrder.raw);
			}
		} while (!casWeak!(MemoryOrder.acq, MemoryOrder.raw)(
			         (&state), oldState, oldState | lockedFlag));
	}

	void unlock() nothrow @safe @nogc shared scope {
		state.atomicFetchSub!(MemoryOrder.rel)(lockedFlag);
	}

	enum stopRequestedFlag = 1L;
	enum lockedFlag = 2L;

	shared ulong state = 0;
	StopCallback* head = null;
	Thread signallingThread;

	private void storeSignallingThread() @nogc nothrow @trusted shared scope {
		(cast()signallingThread) = Thread.getThis();
	}

	private bool isSignallingThread() @nogc nothrow @trusted shared scope {
		return (cast()signallingThread) is Thread.getThis();
	}
}
