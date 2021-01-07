module kaleidic.experimental.concurrency.executor;

alias VoidFunction = void function() @safe;
alias VoidDelegate = void delegate() shared @safe;

interface Executor {
  void execute(VoidFunction fn) @safe;
  void execute(VoidDelegate fn) @safe;
  bool isInContext() @safe;
}
