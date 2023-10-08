module concurrency.stoptoken;

// originally this code is from https://github.com/josuttis/jthread by Nicolai Josuttis
// it is licensed under the Creative Commons Attribution 4.0 Internation License http://creativecommons.org/licenses/by/4.0

struct InPlaceStopSource {
	@disable this(ref return scope typeof(this) rhs);
	private shared StopState state;
	bool stop() nothrow @safe shared {
		return state.request_stop();
	}

	bool stop() nothrow @safe {
		with (assumeSafeShared) {
			return stop();
		}
	}

	bool isStopRequested() nothrow @safe @nogc shared {
		return state.is_stop_requested();
	}

	bool isStopRequested() nothrow @safe @nogc {
		with (assumeSafeShared) {
			return isStopRequested();
		}
	}

	/// resets the internal state, only do this if you are sure nothing else is looking at this...
	void reset(this t)() @system @nogc shared {
		this.state = StopState();
	}

	private ref assumeSafeShared() @trusted @nogc nothrow {
		return cast(shared)this;
	}

	void assertNoCallbacks() @safe shared {
		state.assertNoCallbacks();
	}

	void assertNoCallbacks() @safe {
		with (assumeSafeShared)
			assertNoCallbacks();
	}
}

class StopSource {
	package(concurrency) shared InPlaceStopSource source;

	bool stop() nothrow @safe {
		return source.stop();
	}

	bool stop() nothrow @trusted shared {
		return source.stop();
	}

	bool isStopRequested() nothrow @safe @nogc {
		return source.isStopRequested;
	}

	bool isStopRequested() nothrow @trusted @nogc shared {
		return source.isStopRequested;
	}

	/// resets the internal state, only do this if you are sure nothing else is looking at this...
	void reset(this t)() @system @nogc {
		return (cast(shared)source).reset();
	}

	void assertNoCallbacks() @safe shared {
		source.assertNoCallbacks();
	}
}

struct StopToken {
	package(concurrency) shared StopState* state;
	this(StopSource source) nothrow @safe @nogc {
		if (source !is null) {
			this.state = &source.source.state;
			isStopPossible = true;
		}
	}

	this(shared StopSource source) nothrow @trusted @nogc {
		this(cast()source);
	}

	this(ref shared StopState state) nothrow @trusted @nogc {
		isStopPossible = true;
		this.state = &state;
	}

	this (ref shared InPlaceStopSource stopSource) nothrow @trusted @nogc {
		this(stopSource.state);
	}

	this (shared InPlaceStopSource* stopSource) nothrow @trusted @nogc {
		if (stopSource !is null) {
			isStopPossible = true;
			this.state = &stopSource.state;
		}
	}

	bool isStopRequested() nothrow @safe @nogc {
		return isStopPossible && state.is_stop_requested();
	}

	const bool isStopPossible;
}

struct NeverStopToken {
	enum isStopRequested = false;
	enum isStopPossible = false;
}

StopCallback onStop(
	StopSource stopSource,
	void delegate() nothrow @safe shared callback
) nothrow @safe {
	auto cb = new StopCallback(callback);
	return onStop(stopSource, cb);
}

StopCallback onStop(StopSource stopSource,
                    void function() nothrow @safe callback) nothrow @trusted {
	import std.functional : toDelegate;
	return stopSource
		.onStop(cast(void delegate() nothrow @safe shared) callback.toDelegate);
}

StopCallback onStop(
	ref shared InPlaceStopSource stopSource,
	void delegate() nothrow @safe shared callback
) nothrow @safe {
	auto cb = new StopCallback(callback);
	stopSource.state.onStop(cb.callback);
	return cb;
}

StopCallback onStop(StopToken)(
	StopToken stopToken,
	void delegate() nothrow @safe shared callback
) nothrow @safe {
	auto cb = new StopCallback(callback);

	onStop(stopToken, cb);

	return cb;
}

StopCallback onStop(StopToken)(
	StopToken stopToken,
	void function() nothrow @safe callback
) nothrow @trusted {
	import std.functional : toDelegate;
	return stopToken
		.onStop(cast(void delegate() nothrow @safe shared) callback.toDelegate);
}

StopCallback onStop(StopToken)(StopToken stopToken,
                               StopCallback cb) nothrow @safe {
	if (stopToken.isStopPossible) {
		stopToken.onStop(cb.callback);
	}
	return cb;
}

void onStop(StopToken)(StopToken stopToken,
                       ref InPlaceStopCallback cb) nothrow @safe {
	if (stopToken.isStopPossible) {
		(*stopToken.state).onStop(cb);
	}
}

StopCallback onStop(StopSource stopSource, StopCallback cb) nothrow @safe {
	onStop(stopSource.source.state, cb.callback);
	return cb;
}

void onStop(StopSource stopSource, ref InPlaceStopCallback cb) nothrow @safe {
	onStop(stopSource.source.state, cb);
}

void onStop(ref shared StopState state, ref InPlaceStopCallback cb) nothrow @trusted { // TODO: @safe
	// TODO: shared
	if (state.try_add_callback(cast(shared)cb, true))
		cb.state = &state;
}

struct InPlaceStopCallback {
	@disable this(ref return scope typeof(this) rhs);

	void dispose() nothrow @trusted @nogc {
		import core.atomic : cas;

		if (state is null)
			return;
		auto local = state;
		static if (__traits(compiles, cas(&state, local, null))) {
			if (!cas(&state, local, null)) {
				assert(state is null);
				return;
			}
		} else {
			if (!cas(cast(shared) &state, cast(shared) local, null)) {
				assert(state is null);
				return;
			}
		}

		local.remove_callback(this);
	}

	void dispose() shared nothrow @trusted @nogc {
		(cast() this).dispose();
	}

	this(void delegate() nothrow shared @safe callback) nothrow @safe @nogc {
		this.callback = callback;
	}

private:

	void delegate() nothrow shared @safe callback;
	shared StopState* state;

	shared InPlaceStopCallback* next_ = null;
	shared InPlaceStopCallback** prev_ = null;
	shared bool* isRemoved_ = null;
	shared bool callbackFinishedExecuting = false;

	void execute() nothrow @safe shared {
		callback();
	}
}

class StopCallback {
	this(void delegate() nothrow shared @safe callback) nothrow @safe @nogc {
		this.callback = InPlaceStopCallback(callback);
	}

	void dispose() nothrow @trusted @nogc {
		callback.dispose();
	}

	void dispose() shared nothrow @trusted @nogc {
		callback.dispose();
	}
private:

	InPlaceStopCallback callback;
}

private void spin_yield() nothrow @trusted @nogc {
	// TODO: could use the pause asm instruction
	// it is available in LDC as intrinsic... but not in DMD
	import core.thread : Thread;

	Thread.yield();
}

private struct StopState {
	import core.thread : Thread;
	import core.atomic : atomicStore, atomicLoad, MemoryOrder, atomicOp, atomicFetchAdd, atomicFetchSub;

	static if (__traits(compiles, () {
		           import core.atomic : casWeak;
	           }) && __traits(compiles, () {
		           import core.internal.atomic
			           : atomicCompareExchangeWeakNoResult;
	           }))
		import core.atomic : casWeak;
	else
		auto casWeak(MemoryOrder M1, MemoryOrder M2, T, V1, V2)(
			T* here,
			V1 ifThis,
			V2 writeThis
		) pure nothrow @nogc @safe {
			import core.atomic : cas;

			static if (__traits(compiles,
			                    cas!(M1, M2)(here, ifThis, writeThis)))
				return cas!(M1, M2)(here, ifThis, writeThis);
			else
				return cas(here, ifThis, writeThis);
		}

public:
	void add_token_reference() nothrow @safe @nogc shared {
		state_.atomicFetchAdd!(MemoryOrder.raw)(token_ref_increment);
	}

	void remove_token_reference() nothrow @safe @nogc shared {
		state_.atomicFetchSub!(MemoryOrder.acq_rel)(token_ref_increment);
	}

	void add_source_reference() nothrow @safe @nogc shared {
		state_.atomicFetchAdd!(MemoryOrder.raw)(source_ref_increment);
	}

	void remove_source_reference() nothrow @safe @nogc shared {
		state_.atomicFetchSub!(MemoryOrder.acq_rel)(source_ref_increment);
	}

	bool request_stop() nothrow @safe shared {
		if (!try_lock_and_signal_until_signalled()) {
			// Stop has already been requested.
			return false;
		}

		// Set the 'stop_requested' signal and acquired the lock.

		assumeThreadSafe.signallingThread_ = Thread.getThis();

		while (head_ !is null) {
			// Dequeue the head of the queue
			auto cb = head_;
			head_ = cb.next_;
			const bool anyMore = head_ !is null;
			if (anyMore) {
				(() @trusted => head_.prev_ =
					&head_)(); // compiler 2.091.1 complains "address of variable this assigned to this with longer lifetime". But this is this, how can it have a longer lifetime...
			}

			// Mark this item as removed from the list.
			cb.prev_ = null;

			// Don't hold lock while executing callback
			// so we don't block other threads from deregistering callbacks.
			unlock();

			// TRICKY: Need to store a flag on the stack here that the callback
			// can use to signal that the destructor was executed inline
			// during the call. If the destructor was executed inline then
			// it's not safe to dereference cb after execute() returns.
			// If the destructor runs on some other thread then the other
			// thread will block waiting for this thread to signal that the
			// callback has finished executing.
			shared bool isRemoved = false;
			(() @trusted => cb.isRemoved_ =
				&isRemoved)(); // the pointer to the stack here is removed 3 lines down.

			cb.execute();

			if (!isRemoved) {
				cb.isRemoved_ = null;
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

	bool is_stop_requested() nothrow @safe @nogc shared {
		return is_stop_requested(state_.atomicLoad!(MemoryOrder.acq));
	}

	bool is_stop_requestable() nothrow @safe @nogc shared {
		return is_stop_requestable(state_.atomicLoad!(MemoryOrder.acq));
	}

	bool try_add_callback(ref shared InPlaceStopCallback cb,
	                      bool incrementRefCountIfSuccessful) nothrow @trusted shared {
		ulong oldState;
		do {
			goto load_state;
			do {
				spin_yield();

			load_state:
				oldState = state_.atomicLoad!(MemoryOrder.acq);
				if (is_stop_requested(oldState)) {
					cb.execute();
					return false;
				} else if (!is_stop_requestable(oldState)) {
					return false;
				}
			} while (is_locked(oldState));
		} while (!casWeak!(MemoryOrder.acq, MemoryOrder.acq)(
			         &state_, oldState, oldState | locked_flag));

		// Push callback onto callback list.
		cb.next_ = head_;
		if (cb.next_ !is null) {
			cb.next_.prev_ = &cb.next_;
		}

		() @trusted {
			cb.prev_ = &head_;
		}();
		head_ = &cb;

		if (incrementRefCountIfSuccessful) {
			unlock_and_increment_token_ref_count();
		} else {
			unlock();
		}

		// Successfully added the callback.
		return true;
	}

	void remove_callback(ref InPlaceStopCallback cb) nothrow @safe @nogc shared {
		lock();

		if (cb.prev_ !is null) {
			// Still registered, not yet executed
			// Just remove from the list.
			*cb.prev_ = cb.next_;
			if (cb.next_ !is null) {
				cb.next_.prev_ = cb.prev_;
			}

			unlock_and_decrement_token_ref_count();

			return;
		}

		unlock();

		// Callback has either already executed or is executing
		// concurrently on another thread.

		if (assumeThreadSafe.signallingThread_ is Thread.getThis()) {
			// Callback executed on this thread or is still currently executing
			// and is deregistering itself from within the callback.
			if (cb.isRemoved_ !is null) {
				// Currently inside the callback, let the request_stop() method
				// know the object is about to be destructed and that it should
				// not try to access the object when the callback returns.
				*cb.isRemoved_ = true;
			}
		} else {
			// Callback is currently executing on another thread,
			// block until it finishes executing.
			while (!cb.callbackFinishedExecuting.atomicLoad!(MemoryOrder.acq)) {
				spin_yield();
			}
		}

		remove_token_reference();
	}

private:
	void assertNoCallbacks() @safe shared {
		lock();
		auto empty = head_ is null;
		unlock();
		assert(empty, "StopSource has lingering callbacks");
	}

	static bool is_locked(ulong state) nothrow @safe @nogc {
		return (state & locked_flag) != 0;
	}

	static bool is_stop_requested(ulong state) nothrow @safe @nogc {
		return (state & stop_requested_flag) != 0;
	}

	static bool is_stop_requestable(ulong state) nothrow @safe @nogc {
		// Interruptible if it has already been interrupted or if there are
		// still interrupt_source instances in existence.
		return is_stop_requested(state) || (state >= source_ref_increment);
	}

	bool try_lock_and_signal_until_signalled() nothrow @safe @nogc shared {
		ulong oldState;
		do {
			oldState = state_.atomicLoad!(MemoryOrder.acq);
			if (is_stop_requested(oldState))
				return false;
			while (is_locked(oldState)) {
				spin_yield();
				oldState = state_.atomicLoad!(MemoryOrder.acq);
				if (is_stop_requested(oldState))
					return false;
			}
		} while (!casWeak!(MemoryOrder.seq, MemoryOrder.acq)(
			         &state_, oldState,
			         oldState | stop_requested_flag | locked_flag));

		return true;
	}

	void lock() nothrow @safe @nogc shared {
		ulong oldState;
		do {
			oldState = state_.atomicLoad!(MemoryOrder.raw);
			while (is_locked(oldState)) {
				spin_yield();
				oldState = state_.atomicLoad!(MemoryOrder.raw);
			}
		} while (!casWeak!(MemoryOrder.acq, MemoryOrder.raw)(
			         (&state_), oldState, oldState | locked_flag));
	}

	void unlock() nothrow @safe @nogc shared {
		state_.atomicFetchSub!(MemoryOrder.rel)(locked_flag);
	}

	void unlock_and_increment_token_ref_count() nothrow @safe @nogc shared {
		state_.atomicFetchSub!(MemoryOrder.rel)(locked_flag - token_ref_increment);
	}

	void unlock_and_decrement_token_ref_count() nothrow @safe @nogc shared {
		state_.atomicFetchSub!(MemoryOrder.acq_rel)(locked_flag + token_ref_increment);
	}

	enum stop_requested_flag = 1L;
	enum locked_flag = 2L;
	enum token_ref_increment = 4L;
	enum source_ref_increment = 1L << 33u;

	// bit 0 - stop-requested
	// bit 1 - locked
	// bits 2-32 - token ref count (31 bits)
	// bits 33-63 - source ref count (31 bits)
	shared ulong state_ = source_ref_increment;
	InPlaceStopCallback* head_ = null;
	Thread signallingThread_;

	ref assumeThreadSafe() @trusted nothrow @nogc shared {
		return cast()this;
	}
}
