module concurrency.utils;

import std.traits;

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
