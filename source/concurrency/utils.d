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
	@disable
	this();
	@disable
	this(this);
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
		return fun((cast() this).args);
	}
}

/// This is a terrible workaround for closure bugs in D. When a local is used in a delegate D is supposed to move it to the heap. I haven't seen that happen in all cases so we have this manual workaround.
auto closure(Fun, Args...)(Fun fun, Args args) @trusted
		if (isFunctionPointer!Fun) {
	static assert(!hasFunctionAttributes!(Fun, "@system"),
	              "no @system functions please");
	auto cl = cast(shared) new Closure!(Fun, Args)(fun, args);
	/// need to cast to @safe because a @trusted delegate doesn't fit a @safe one...
	static if (hasFunctionAttributes!(Fun, "nothrow"))
		alias ResultType = void delegate() nothrow @safe shared;
	else
		alias ResultType = void delegate() @safe shared;
	return cast(ResultType) &cl.apply;
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
static if (__traits(compiles, () {
	           import core.atomic : casWeak;
           }) && __traits(compiles, () {
	           import core.internal.atomic : atomicCompareExchangeWeakNoResult;
           }))
	public import core.atomic : casWeak;
else {
	import core.atomic : MemoryOrder;
	auto casWeak(
		MemoryOrder M1 = MemoryOrder.seq,
		MemoryOrder M2 = MemoryOrder.seq,
		T,
		V1,
		V2
	)(T* here, V1 ifThis, V2 writeThis) pure nothrow @nogc @safe {
		import core.atomic : cas;

		static if (__traits(compiles, cas!(M1, M2)(here, ifThis, writeThis)))
			return cas!(M1, M2)(here, ifThis, writeThis);
		else
			return cas(here, ifThis, writeThis);
	}
}

enum isThreadSafeFunction(alias Fun) = !hasFunctionAttributes!(Fun, "@system")
	&& (isFunction!Fun || isFunctionPointer!Fun
		|| hasFunctionAttributes!(Fun, "shared"));

enum isThreadSafeCallable(alias Fun) =
	(isAggregateType!Fun && isCallable!Fun && __traits(compiles, () @safe {
		shared Fun f;
		f();
	})) || (isSomeFunction!Fun && isThreadSafeFunction!Fun);

// Loads a function from the main process.
// When using dynamic libraries globals and TLS variables are duplicated.
// We need a way to ensure globals used across dynamic libraries and the host
// are all pointing to the same instance.
// We do this by exporting accessors functions which a dynamic library can
// call to get access to the global.
auto dynamicLoad(alias fun)() nothrow @trusted @nogc {
	alias Fn = typeof(&fun);
	__gshared Fn fn;

	if (fn is null)
		fn = dynamicLoadRaw!fun;

	// If dynamic loading fails we just pick the local function.
	// This serves two purposes, 1) if users aren't using dynamic
	// libraries and the application isn't compiled with the proper linker
	// flags for exporting functions, it won't be found, and 2) it will
	// reference the function so it won't be compiled away.
	if (fn is null)
		fn = &fun;

	return fn;
}

auto dynamicLoadRaw(alias fun)() nothrow @trusted @nogc {
	alias Fn = typeof(&fun);
	version(Windows) {
		import core.sys.windows.windows;
		return cast(Fn) GetProcAddress(GetModuleHandle(null), fun.mangleof);
	} else version(Posix) {
		import core.sys.posix.dlfcn : dlopen, dlsym, dlerror, RTLD_LAZY;
		auto parent = dlopen(null, RTLD_LAZY);
		return cast(Fn) dlsym(parent, fun.mangleof);
	} else
		static assert(false, "platform not supported");
}
