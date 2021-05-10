module concurrency.utils;

import std.traits;

/// Helper used in with() to easily access `shared` methods of a class
struct SharedGuard(T) if (is(T == class)) {
  import core.sync.mutex : Mutex;
private:
  Mutex mutex;
public:
  T reg;
  alias reg this;
  @disable this();
  @disable this(this);
  static SharedGuard acquire(shared T reg, Mutex mutex) {
    mutex.lock_nothrow();
    auto instance = SharedGuard.init;
    instance.reg = (cast() reg);
    instance.mutex = mutex;
    return instance;
  }
  ~this() {
    mutex.unlock_nothrow();
  }
}

/// A manually constructed closure, aimed at shared
struct Closure(Fun, Args...) {
  Fun fun;
  Args args;
  auto apply() shared {
    return fun((cast()this).args);
  }
}

/// This is a terrible workaround for closure bugs in D. When a local is used in a delegate D is supposed to move it to the heap. I haven't seen that happen in all cases so we have this manual workaround.
auto closure(Fun, Args...)(Fun fun, Args args) @trusted if (isFunctionPointer!Fun) {
  static assert(!hasFunctionAttributes!(Fun, "@system"), "no @system functions please");
  auto cl = cast(shared)new Closure!(Fun, Args)(fun, args);
  /// need to cast to @safe because a @trusted delegate doesn't fit a @safe one...
  static if (hasFunctionAttributes!(Fun, "nothrow"))
    alias ResultType = void delegate() nothrow shared @safe;
  else
    alias ResultType = void delegate() shared @safe;
  return cast(ResultType)&cl.apply;
}

/// don't want vibe-d to overwrite the scheduler
void resetScheduler() @trusted {
  import std.concurrency : scheduler;
  if (scheduler !is null)
    scheduler = null;
}

enum NoVoid(T) = !is(T == void);

void spin_yield() nothrow @trusted @nogc {
  // TODO: could use the pause asm instruction
  // it is available in LDC as intrinsic... but not in DMD
  import core.thread : Thread;

  Thread.yield();
}

/// ugly ugly
static if (__traits(compiles, () { import core.atomic : casWeak; }) && __traits(compiles, () {
      import core.internal.atomic : atomicCompareExchangeWeakNoResult;
    }))
  public import core.atomic : casWeak;
 else {
   import core.atomic : MemoryOrder;
   auto casWeak(MemoryOrder M1, MemoryOrder M2, T, V1, V2)(T* here, V1 ifThis, V2 writeThis) pure nothrow @nogc @safe {
     import core.atomic : cas;

     static if (__traits(compiles, cas!(M1, M2)(here, ifThis, writeThis)))
       return cas!(M1, M2)(here, ifThis, writeThis);
     else
       return cas(here, ifThis, writeThis);
   }
 }
