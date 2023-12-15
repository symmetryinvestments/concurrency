module concurrency.executor;

alias VoidFunction = void function() @safe;
alias VoidDelegate = void delegate() @safe shared;

interface Executor {
	void execute(VoidFunction fn) @safe;
	void execute(VoidDelegate fn) @safe;
	bool isInContext() @safe;
}
