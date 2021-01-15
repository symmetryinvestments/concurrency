module concurrency.utils;

/// A manually constructed closure, aimed at shared
struct Closure(Fun, Args...) {
  Fun fun;
  Args args;
  auto apply() shared @trusted {
    return fun((cast()this).args);
  }
}

auto closure(Args...)(void function(Args) @safe fun, Args args) @trusted {
  alias Fun = typeof(fun);
  auto cl = new Closure!(Fun, Args)(fun, args);
  /// need to cast to @safe because a @trusted delegate doesn't fit a @safe one...
  return cast(void delegate() shared @safe)&(cast(shared)cl).apply;
}

/// don't want vibe-d to overwrite the scheduler
void resetScheduler() @trusted {
  import std.concurrency : scheduler;
  if (scheduler !is null)
    scheduler = null;
}
