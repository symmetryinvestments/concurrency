module kaleidic.experimental.concurrency.stoptoken;

// originally this code is from https://github.com/josuttis/jthread by Nicolai Josuttis
// it is licensed under the Creative Commons Attribution 4.0 Internation License http://creativecommons.org/licenses/by/4.0

class StopSource {
  private stop_state state;
  bool stop() nothrow @safe {
    return state.request_stop();
  }

  bool stop() nothrow @trusted shared {
    return (cast(StopSource)this).state.request_stop();
  }

  bool isStopRequested() nothrow @safe @nogc {
    return state.is_stop_requested();
  }

  bool isStopRequested() nothrow @trusted @nogc shared {
    return (cast(StopSource)this).isStopRequested();
  }
}

struct StopToken {
  private StopSource source;
  this(StopSource source) nothrow @safe @nogc {
    this.source = source;
  }

  bool isStopRequested() nothrow @safe @nogc {
    return source.isStopRequested();
  }

  enum isStopPossible = true;
}

struct NeverStopToken {
  enum isStopRequested = false;
  enum isStopPossible = false;
}

enum isStopToken(T) = true; // TODO:

StopCallback onStop(StopToken)(auto ref StopToken stopToken, void delegate() nothrow @safe shared callback) nothrow @safe if (isStopToken!StopToken) {
  import std.traits : hasMember;
  auto cb = new StopCallback(callback);
  static if (stopToken.isStopPossible && hasMember!(StopToken, "source")) {
    if (stopToken.source.state.try_add_callback(cb, true))
      cb.source = stopToken.source;
  }
  return cb;
}

class StopCallback {
  void dispose() nothrow @trusted @nogc {
    import core.atomic : cas;

    if (source is null)
      return;
    auto local = source;
    static if (__traits(compiles, cas(&source, local, null))) {
      if (!cas(&source, local, null)) {
        assert(source is null);
        return;
      }
    } else {
      if (!cas(cast(shared)&source, cast(shared)local, null)) {
        assert(source is null);
        return;
      }
    }
    local.state.remove_callback(this);
  }

private:
  this(void delegate() nothrow shared @safe callback) nothrow @safe @nogc {
    this.callback = callback;
  }

  void delegate() nothrow shared @safe callback;
  StopSource source;

  StopCallback next_ = null;
  StopCallback* prev_ = null;
  bool* isRemoved_ = null;
  shared bool callbackFinishedExecuting = false;

  void execute() nothrow @safe {
    callback();
  }
}

void spin_yield() nothrow @trusted @nogc {
  // TODO: could use the pause asm instruction
  // it is available in LDC as intrinsic... but not in DMD
  import core.thread : Thread;

  Thread.yield();
}

private struct stop_state {
  import core.thread : Thread;
  import core.atomic : atomicOp, atomicStore, atomicLoad, MemoryOrder;

  static if (__traits(compiles, () { import core.atomic : casWeak; }) && __traits(compiles, () {
      import core.internal.atomic : atomicCompareExchangeWeakNoResult;
    }))
    import core.atomic : casWeak;
  else
    auto casWeak(MemoryOrder M1, MemoryOrder M2, T, V1, V2)(T* here, V1 ifThis, V2 writeThis) pure nothrow @nogc @safe {
      import core.atomic : cas;

      static if (__traits(compiles, cas!(M1, M2)(here, ifThis, writeThis)))
        return cas!(M1, M2)(here, ifThis, writeThis);
      else
        return cas(here, ifThis, writeThis);
    }

public:
  void add_token_reference() nothrow @safe @nogc {
    state_.atomicOp!"+="(token_ref_increment);
  }

  void remove_token_reference() nothrow @safe @nogc {
    auto newState = state_.atomicOp!"-="(token_ref_increment);
    if (newState < (token_ref_increment)) {
      // delete this;
    }
  }

  void add_source_reference() nothrow @safe @nogc {
    state_.atomicOp!"+="(source_ref_increment);
  }

  void remove_source_reference() nothrow @safe @nogc {
    auto newState = state_.atomicOp!"-="(source_ref_increment);
    if (newState < (token_ref_increment)) {
      // delete this;
    }
  }

  bool request_stop() nothrow @safe {

    if (!try_lock_and_signal_until_signalled()) {
      // Stop has already been requested.
      return false;
    }

    // Set the 'stop_requested' signal and acquired the lock.

    signallingThread_ = Thread.getThis();

    while (head_ !is null) {
      // Dequeue the head of the queue
      auto cb = head_;
      head_ = cb.next_;
      const bool anyMore = head_ !is null;
      if (anyMore) {
        (() @trusted => head_.prev_ = &head_)(); // compiler 2.091.1 complains "address of variable this assigned to this with longer lifetime". But this is this, how can it have a longer lifetime...
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
      bool isRemoved = false;
      (() @trusted => cb.isRemoved_ = &isRemoved)(); // the pointer to the stack here is removed 3 lines down.

      cb.execute();

      if (!isRemoved) {
        cb.isRemoved_ = null;
        cb.callbackFinishedExecuting.atomicStore!(MemoryOrder.rel)(true);
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

  bool is_stop_requested() nothrow @safe @nogc {
    return is_stop_requested(state_.atomicLoad!(MemoryOrder.acq));
  }

  bool is_stop_requestable() nothrow @safe @nogc {
    return is_stop_requestable(state_.atomicLoad!(MemoryOrder.acq));
  }

  bool try_add_callback(StopCallback cb, bool incrementRefCountIfSuccessful) nothrow @safe {
    ulong oldState;
    goto load_state;
    do {
      goto check_state;
      do {
        spin_yield();
      load_state:
        oldState = state_.atomicLoad!(MemoryOrder.acq);
      check_state:
        if (is_stop_requested(oldState)) {
          cb.execute();
          return false;
        }
        else if (!is_stop_requestable(oldState)) {
          return false;
        }
      }
      while (is_locked(oldState));
    }
    while (!casWeak!(MemoryOrder.acq, MemoryOrder.acq)(&state_, oldState, oldState | locked_flag));

    // Push callback onto callback list.
    cb.next_ = head_;
    if (cb.next_ !is null) {
      cb.next_.prev_ = &cb.next_;
    }
    cb.prev_ = &head_;
    head_ = cb;

    if (incrementRefCountIfSuccessful) {
      unlock_and_increment_token_ref_count();
    }
    else {
      unlock();
    }

    // Successfully added the callback.
    return true;
  }

  void remove_callback(StopCallback cb) nothrow @safe @nogc {
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

    if (signallingThread_ is Thread.getThis()) {
      // Callback executed on this thread or is still currently executing
      // and is deregistering itself from within the callback.
      if (cb.isRemoved_ !is null) {
        // Currently inside the callback, let the request_stop() method
        // know the object is about to be destructed and that it should
        // not try to access the object when the callback returns.
        *cb.isRemoved_ = true;
      }
    }
    else {
      // Callback is currently executing on another thread,
      // block until it finishes executing.
      while (!cb.callbackFinishedExecuting.atomicLoad!(MemoryOrder.acq)) {
        spin_yield();
      }
    }

    remove_token_reference();
  }

private:
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

  bool try_lock_and_signal_until_signalled() nothrow @safe @nogc {
    ulong oldState = state_.atomicLoad!(MemoryOrder.acq);
    do {
      if (is_stop_requested(oldState))
        return false;
      while (is_locked(oldState)) {
        spin_yield();
        oldState = state_.atomicLoad!(MemoryOrder.acq);
        if (is_stop_requested(oldState))
          return false;
      }
    }
    while (!casWeak!(MemoryOrder.seq, MemoryOrder.acq)(&state_, oldState,
        oldState | stop_requested_flag | locked_flag));
    return true;
  }

  void lock() nothrow @safe @nogc {
    auto oldState = state_.atomicLoad!(MemoryOrder.raw);
    do {
      while (is_locked(oldState)) {
        spin_yield();
        oldState = state_.atomicLoad!(MemoryOrder.raw);
      }
    }
    while (!casWeak!(MemoryOrder.acq, MemoryOrder.raw)((&state_), oldState,
        oldState | locked_flag));
  }

  void unlock() nothrow @safe @nogc {
    state_.atomicOp!"-="(locked_flag);
  }

  void unlock_and_increment_token_ref_count() nothrow @safe @nogc {
    state_.atomicOp!"-="(locked_flag - token_ref_increment);
  }

  void unlock_and_decrement_token_ref_count() nothrow @safe @nogc {
    auto newState = state_.atomicOp!"-="(locked_flag + token_ref_increment);
    // Check if new state is less than token_ref_increment which would
    // indicate that this was the last reference.
    if (newState < (locked_flag + token_ref_increment)) {
      // delete this;
    }
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
  StopCallback head_ = null;
  Thread signallingThread_;
}
