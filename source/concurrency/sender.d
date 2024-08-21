module concurrency.sender;

import concepts;
import std.traits : ReturnType, isCallable;
import core.time : Duration;

// A Sender represents something that completes with either:
// 1. a value (which can be void)
// 2. completion, in response to cancellation
// 3. an Throwable
//
// Many things can be represented as a Sender.
// Threads, Fibers, coroutines, etc. In general, any async operation.
//
// A Sender is lazy. Work it represents is only started when
// the sender is connected to a receiver and explicitly started.
//
// Senders and Receivers go hand in hand. Senders send a value,
// Receivers receive one.
//
// Senders are useful because many Tasks can be represented as them,
// and any operation on top of senders then works on any one of those
// Tasks.
//
// The most common operation is `sync_wait`. It blocks the current
// execution context to await the Sender.
//
// There are many others as well. Like `when_all`, `retry`, `when_any`,
// etc. These algorithms can be used on any sender.
//
// Cancellation happens through StopTokens. A Sender can ask a Receiver
// for a StopToken. Default is a NeverStopToken but Receiver's can
// customize this.
//
// The StopToken can be polled or a callback can be registered with one.
//
// Senders enforce Structured Concurrency because work cannot be
// started unless it is awaited.
//
// These concepts are heavily inspired by several C++ proposals
// starting with http://www.open-std.org/jtc1/sc22/wg21/docs/papers/2020/p0443r14.html

/// checks that T is a Sender
void checkSender(T)() @safe {
	import concurrency.scheduler : SchedulerObjectBase;
	import concurrency.stoptoken : StopToken;
	T t = T.init;
	struct Scheduler {
		import core.time : Duration;
		auto schedule() @safe {
			return VoidSender();
		}

		auto scheduleAfter(Duration) @safe {
			return VoidSender();
		}
	}

	static struct Receiver {
		int* i; // force it scope
		static if (is(T.Value == void))
			void setValue() @safe {}

		else
			void setValue(T.Value) @safe {}

		void setDone() @safe nothrow {}

		void setError(Throwable e) @safe nothrow {}

		shared(StopToken) getStopToken() @safe nothrow {
			return shared(StopToken).init;
		}

		Scheduler getScheduler() @safe nothrow {
			return Scheduler.init;
		}
	}

	scope receiver = Receiver.init;
	OpType!(T, Receiver) op = t.connect(receiver);
	static if (!isValidOp!(T, Receiver))
		pragma(msg, "Warning: ", T,
		       "'s operation state is not returned via the stack");
}

enum isSender(T) = is(typeof(checkSender!T));

/// It is ok for the operation state to be on the heap, but if it is on the stack we need to ensure any copies are elided. We can't be 100% sure (the compiler may still blit), but this is the best we can do.
template isValidOp(Sender, Receiver) {
	import std.traits : isPointer;
	import std.meta : allSatisfy;
	alias overloads = __traits(getOverloads, Sender, "connect", true);
	template isRVO(alias connect) {
		static if (__traits(isTemplate, connect))
			enum isRVO = __traits(isReturnOnStack, connect!Receiver);
		else
			enum isRVO = __traits(isReturnOnStack, connect);
	}

	alias Op = OpType!(Sender, Receiver);
	enum isValidOp = isPointer!Op || is(Op == OperationObject)
		|| is(Op == class)
		|| (allSatisfy!(isRVO, overloads) && !__traits(isPOD, Op));
}

/// A Sender that sends a single value of type T
struct ValueSender(T) {
	static assert(models!(typeof(this), isSender));
	alias Value = T;
	static struct Op(Receiver) {
		Receiver receiver;
		static if (!is(T == void))
			T value;
		@disable
		this(ref return scope typeof(this) rhs);
		@disable
		this(this);
		void start() nothrow @trusted scope {
			import concurrency.receiver : setValueOrError;
			static if (!is(T == void))
				receiver.setValueOrError(value);
			else
				receiver.setValueOrError();
		}
	}

	static if (!is(T == void))
		T value;
	Op!Receiver connect(Receiver)(return Receiver receiver) @safe {
		// ensure NRVO
		static if (!is(T == void))
			auto op = Op!(Receiver)(receiver, value);
		else
			auto op = Op!(Receiver)(receiver);
		return op;
	}
}

auto just(T...)(T t) {
	import std.typecons : tuple, Tuple;
	static if (T.length == 1)
		return ValueSender!(T[0])(t);
	else
		return ValueSender!(Tuple!T)(tuple(t));
}

struct JustFromSender(Fun) {
	static assert(models!(typeof(this), isSender));
	alias Value = ReturnType!fun;
	static struct Op(Receiver) {
		Receiver receiver;
		Fun fun;
		@disable
		this(ref return scope typeof(this) rhs);
		@disable
		this(this);
		void start() @trusted nothrow {
			import std.traits : hasFunctionAttributes;
			static if (hasFunctionAttributes!(Fun, "nothrow")) {
				set();
			} else {
				try {
					set();
				} catch (Exception e) {
					receiver.setError(e);
				}
			}
		}

		private void set() @safe {
			import concurrency.receiver : setValueOrError;
			static if (is(Value == void)) {
				fun();
				if (receiver.getStopToken.isStopRequested)
					receiver.setDone();
				else
					receiver.setValue();
			} else {
				auto r = fun();
				if (receiver.getStopToken.isStopRequested)
					receiver.setDone();
				else
					receiver.setValue(r);
			}
		}
	}

	Fun fun;
	Op!Receiver connect(Receiver)(return Receiver receiver) @safe return scope {
		// ensure NRVO
		auto op = Op!(Receiver)(receiver, fun);
		return op;
	}
}

JustFromSender!(Fun) justFrom(Fun)(Fun fun) if (isCallable!Fun) {
	import std.traits : hasFunctionAttributes, isFunction, isFunctionPointer;
	import concurrency.utils : isThreadSafeFunction;
	static assert(isThreadSafeFunction!Fun);
	return JustFromSender!Fun(fun);
}

/// A polymorphic sender of type T
interface SenderObjectBase(T) {
	import concurrency.receiver;
	import concurrency.scheduler : SchedulerObjectBase;
	import concurrency.stoptoken : StopToken;
	static assert(models!(typeof(this), isSender));
	alias Value = T;
	alias Op = OperationObject;
	OperationObject connect(return ReceiverObjectBase!(T) receiver) @safe scope;
	OperationObject connect(Receiver)(return Receiver receiver) @trusted scope {
		return connect(receiver.toReceiverObject!(T)());
	}
}

template toReceiverObject(T) {
	auto toReceiverObject(Receiver)(return Receiver receiver) @trusted {
		import concurrency.receiver;
		import concurrency.stoptoken : StopToken;
		import concurrency.scheduler : SchedulerObjectBase;

		return new class(receiver) ReceiverObjectBase!T {
			Receiver receiver;
			SchedulerObjectBase scheduler;
			this(Receiver receiver) {
				this.receiver = receiver;
			}

			static if (is(T == void)) {
				void setValue() {
					receiver.setValueOrError();
				}
			} else {
				void setValue(T value) {
					receiver.setValueOrError(value);
				}
			}

			void setDone() nothrow {
				receiver.setDone();
			}

			void setError(Throwable e) nothrow {
				receiver.setError(e);
			}

			shared(StopToken) getStopToken() nothrow {
				return receiver.getStopToken();
			}

			SchedulerObjectBase getScheduler() nothrow @safe scope {
				import concurrency.scheduler : toSchedulerObject;
				if (scheduler is null) {
					scheduler = receiver.getScheduler().toSchedulerObject;
				}
				return scheduler;
			}
		};
	}
}

/// Type-erased operational state object
/// used in polymorphic senders
struct OperationObject {
	private void delegate() nothrow shared _start;
	void start() scope nothrow @trusted {
		_start();
	}
}

interface OperationalStateBase {
	void start() @safe nothrow;
}

/// calls connect on the Sender but stores the OperationState on the heap
OperationalStateBase connectHeap(Sender, Receiver)(Sender sender,
                                                   Receiver receiver) @safe {
	alias State = typeof(sender.connect(ConnectHeapReceiver!(Receiver, Sender.Value).init));
	return new class(sender, receiver) OperationalStateBase {
		State state;
		// TODO: this is unsafe and allows returning an object with
		// unlimited lifetime containing scoped senders and receivers.
		// This object can consequently be returned and it would violate
		// all kinds of guarantees by dip1000 and @safe
		this(return Sender sender, return Receiver receiver) @trusted {
			state = sender.connect(ConnectHeapReceiver!(Receiver, Sender.Value)(&kill, receiver));
		}

		void start() @safe nothrow {
			state.start();
		}

		void kill() @safe nothrow {
			state.destroy();
		}
	};
}

// NOTE the destroy state is necessary in order to clean up
// any potential resources therein

// Although the question does pose itself
// how was I able to circumvent the typesystem
// The Sender that I am connecting with in connectHeap
// was able to produce an operational state that held
// on to the stopstate longer than said stopstate

// !!! Its because of the @trusted on the this of the connectHeap !!!
struct ConnectHeapReceiver(Receiver, Value) {
	void delegate() @safe nothrow destroyState;
	Receiver receiver;

	static if (is(Value == void)) {
		void setValue() @safe {
			Receiver local = receiver;
			local.setValue();
			destroyState();
		}
	} else { 
		void setValue(Value v) @safe {
			Receiver local = receiver;
			local.setValue(v);
			destroyState();
		}
	}

	void setDone() nothrow @safe {
		Receiver local = receiver;
		local.setDone();
		destroyState();
	}

	void setError(Throwable e) nothrow @safe {
		Receiver local = receiver;
		local.setError(e);
		destroyState();
	}

    import concurrency.receiver : ForwardExtensionPoints;
    mixin ForwardExtensionPoints!receiver;
}

/// A class extending from SenderObjectBase that wraps any Sender
class SenderObjectImpl(Sender) : SenderObjectBase!(Sender.Value) {
	import concurrency.receiver : ReceiverObjectBase;
	static assert(models!(typeof(this), isSender));
	private Sender sender;
	this(Sender sender) {
		this.sender = sender;
	}

	OperationObject connect(
		return ReceiverObjectBase!(Sender.Value) receiver
	) @trusted scope {
		auto state = sender.connectHeap(receiver);
		return
			OperationObject(
				cast(typeof(OperationObject._start)) &state.start,
			);
	}

	OperationObject connect(Receiver)(return Receiver receiver) @safe scope {
		auto base = cast(SenderObjectBase!(Sender.Value)) this;
		return base.connect(receiver);
	}
}

/// Converts any Sender to a polymorphic SenderObject
auto toSenderObject(Sender)(Sender sender) {
	static assert(models!(Sender, isSender));
	static if (is(Sender : SenderObjectBase!(Sender.Value))) {
		return sender;
	} else
		return cast(SenderObjectBase!(Sender.Value))
			new SenderObjectImpl!(Sender)(sender);
}

/// A sender that always sets an error
struct ThrowingSender {
	alias Value = void;
	static struct Op(Receiver) {
		Receiver receiver;
		@disable
		this(ref return scope typeof(this) rhs);
		@disable
		this(this);
		void start() {
			receiver.setError(new Exception("ThrowingSender"));
		}
	}

	auto connect(Receiver)(return Receiver receiver) @safe return scope {
		// ensure NRVO
		auto op = Op!Receiver(receiver);
		return op;
	}
}

/// A sender that always calls setDone
struct DoneSender {
	static assert(models!(typeof(this), isSender));
	alias Value = void;

	auto connect(Receiver)(return Receiver receiver) @safe return scope {
		// ensure NRVO
		auto op = TypedDoneSender!(void)().connect(receiver);
		return op;
	}
}

struct TypedDoneSender(T) {
	static assert(models!(typeof(this), isSender));
	alias Value = T;

	auto connect(Receiver)(return Receiver receiver) @safe return scope {
		// ensure NRVO
		auto op = TypedDoneOp!(Receiver)(receiver);
		return op;
	}
}

struct TypedDoneOp(Receiver) {
	Receiver receiver;
	@disable
	this(ref return scope typeof(this) rhs);
	@disable
	this(this);
	void start() nothrow @trusted scope {
		receiver.setDone();
	}
}

/// A sender that always calls setValue with no args
struct VoidSender {
	static assert(models!(typeof(this), isSender));
	alias Value = void;
	struct VoidOp(Receiver) {
		Receiver receiver;
		@disable
		this(ref return scope typeof(this) rhs);
		@disable
		this(this);
		void start() nothrow @safe {
			import concurrency.receiver : setValueOrError;
			receiver.setValueOrError();
		}
	}

	auto connect(Receiver)(return Receiver receiver) @safe return scope {
		// ensure NRVO
		auto op = VoidOp!Receiver(receiver);
		return op;
	}
}

/// A sender that always calls setError
struct ErrorSender {
	static assert(models!(typeof(this), isSender));
	alias Value = void;
	Throwable exception;

	auto connect(Receiver)(return Receiver receiver) @safe return scope {
		// ensure NRVO
		auto op = TypedErrorSender!(void)(exception).connect(receiver);
		return op;
	}
}

/// A sender that always calls setError
struct TypedErrorSender(T) {
	static assert(models!(typeof(this), isSender));
	alias Value = T;
	Throwable exception;
	auto connect(Receiver)(return Receiver receiver) @safe return scope {
		// ensure NRVO
		auto op = TypedErrorOp!(Receiver)(receiver, exception);
		return op;
	}
}

struct TypedErrorOp(Receiver) {
	Receiver receiver;
	Throwable exception;
	@disable
	this(ref return scope typeof(this) rhs);
	@disable
	this(this);
	void start() nothrow @trusted scope {
		receiver.setError(exception);
	}
}

template OpType(Sender, Receiver) {
	static if (is(Sender.Op)) {
		alias OpType = Sender.Op;
	} else {
		import std.traits : ReturnType;
		import std.meta : staticMap;
		template GetOpType(alias connect) {
			static if (__traits(isTemplate, connect)) {
				alias GetOpType =
					ReturnType!(connect!Receiver);//(Receiver.init));
			} else {
				alias GetOpType = ReturnType!(connect);//(Receiver.init));
			}
		}

		alias overloads = __traits(getOverloads, Sender, "connect", true);
		alias opTypes = staticMap!(GetOpType, overloads);
		alias OpType = opTypes[0];
	}
}

/// A sender that delays before calling setValue
struct DelaySender {
	alias Value = void;
	Duration dur;
	auto connect(Receiver)(return Receiver receiver) @safe return scope {
		// ensure NRVO
		auto op = receiver.getScheduler().scheduleAfter(dur).connect(receiver);
		return op;
	}
}

auto delay(Duration dur) {
	return DelaySender(dur);
}

struct PromiseSenderOp(T, Receiver) {
	import concurrency.stoptoken;
	import concurrency.bitfield;
	private enum Flags : size_t {
		locked = 0x0,
		setup = 0x1,
		value = 0x2,
		stop = 0x4
	}

	alias Sender = Promise!T;
	alias InternalValue = Sender.InternalValue;
	shared Sender parent;
	Receiver receiver;
	shared StopCallback cb;
	shared SharedBitField!Flags bitfield;
	@disable	
	this(ref return scope typeof(this) rhs);
	@disable
	this(this);
	void start() nothrow @trusted scope {
		// if already completed we can optimize
		if (parent.isCompleted) {
			bitfield.add(Flags.setup);
			parent.add(&(cast(shared) this).onValue);
			return;
		}

		// Otherwise we have to be a bit careful here,
		// both the onStop and the onValue we register
		// can be called from possibly different contexts.
		// We can't atomically connect both, so we have to
		// devise a scheme to handle one or both being called
		// before we are done here.

		// we use a simple atomic bitfield that we set after setup
		// is done. If `onValue` or `onStop` trigger before setup
		// is complete, they update the bitfield and return early.
		// After we setup both, we flip the setup bit and check
		// if any of the callbacks triggered in the meantime,
		// if they did we know we have to perform some cleanup
		// if they didn't the callbacks themselves will handle it

		bool triggeredInline = parent.add(&(cast(shared) this).onValue);
		// if triggeredInline there is no point in setting up the stop callback
		if (!triggeredInline) {
			auto stopToken = receiver.getStopToken;
			cb.register(stopToken, &(cast(shared) this).onStop);
		}

		with (bitfield.add(Flags.setup)) {
			if (has(Flags.stop)) {
				// it stopped before we finished setup
				parent.remove(&(cast(shared) this).onValue);
				receiver.setDone();
			}

			if (has(Flags.value)) {
				// it fired before we finished setup
				// just add it again, it will fire again
				parent.add(&(cast(shared) this).onValue);
			}
		}
	}

	void onStop() nothrow @trusted shared {
		// we toggle the stop bit and return early if setup bit isn't set
		with (bitfield.add(Flags.stop)) if (!has(Flags.setup))
			return;
		with (unshared) {
			// If `parent.remove` returns true, onValue will never be called,
			// so we can call setDone ourselves.
			// If it returns false onStop and onValue are in a race, and we
			// let onValue pass.
			if (parent.remove(&(cast(shared) this).onValue))
				receiver.setDone();
		}
	}

	void onValue(InternalValue value) nothrow @safe shared {
		import std.sumtype : match;
		// we toggle the stop bit and return early if setup bit isn't set
		with (bitfield.add(Flags.value)) if (!has(Flags.setup))
			return;
		with (unshared) {
			// `cb.dispose` will ensure onStop will never be called
			// after it returns. It will also block if it is currently
			// being executed.
			// This means that when it completes we are the only one
			// calling the receiver's termination functions.
			cb.dispose();
			value.match!((Sender.ValueRep v) {
				try {
					static if (is(Sender.Value == void))
						receiver.setValue();
					else
						receiver.setValue(v);
				} catch (Exception e) {
					receiver.setError(e);
				}
			}, (Throwable e) {
				receiver.setError(e);
			}, (Sender.Done d) {
				receiver.setDone();
			});
		}
	}

	private auto ref unshared() @trusted nothrow shared {
		return cast() this;
	}
}

class Promise(T) {
	import std.traits : ReturnType;
	import concurrency.slist;
	import concurrency.bitfield;
	import std.sumtype;
	alias Value = T;
	static if (is(Value == void)) {
		static struct ValueRep {}
	} else
		alias ValueRep = Value;
	static struct Done {}

	alias InternalValue = SumType!(Throwable, ValueRep, Done);
	alias DG = void delegate(InternalValue) nothrow @safe shared;
	private {
		shared SList!DG dgs;
		SumType!(typeof(null), InternalValue) value;
		enum Flags {
			locked = 0x1,
			completed = 0x2
		}

		SharedBitField!Flags counter;
		bool add(DG dg) @trusted nothrow shared {
			with(counter.lock()) {
				if (was(Flags.completed)) {
					auto val = ((cast()this).value).match!((typeof(null)) => assert(0, "not happening"), v => v);
					release(); // release early
					dg(val);
					return true;
				} else {
					dgs.pushBack(dg);
					return false;
				}
			}
		}

		bool remove(DG dg) @safe nothrow shared {
			with (counter.lock()) {
				if (was(Flags.completed)) {
					release(); // release early
					return false;
				} else {
					dgs.remove(dg);
					return true;
				}
			}
		}
	}

	private bool pushImpl(P)(P t) @safe shared nothrow {
		import std.exception : enforce;
		with (counter.lock(Flags.completed)) {
			if (was(Flags.completed))
				return false;
			InternalValue val = InternalValue(t);
			(cast() value) = val;
			auto localDgs = dgs.release();
			release();
			foreach (dg; localDgs)
				dg(val);
			return true;
		}
	}

	bool cancel() @safe shared nothrow {
		return pushImpl(Done());
	}

	bool error(Throwable e) @safe shared nothrow {
		return pushImpl(e);
	}

	static if (is(Value == void)) {
		bool fulfill() @safe shared nothrow {
			return pushImpl(ValueRep());
		}
	} else {
		bool fulfill(T t) @safe shared nothrow {
			return pushImpl(t);
		}
	}

	bool isCompleted() @trusted shared nothrow {
		import core.atomic : MemoryOrder;
		return (counter.load!(MemoryOrder.acq) & Flags.completed) > 0;
	}

	this() {
		this.dgs = new shared SList!DG;
	}

	auto sender() @safe shared nothrow {
		return shared PromiseSender!T(this);
	}
}

shared(Promise!T) promise(T)() {
	return new shared Promise!T();
}

struct PromiseSender(T) {
	alias Value = T;
	static assert(models!(typeof(this), isSender));
	private shared Promise!T promise;

	auto connect(Receiver)(return Receiver receiver) @safe return scope {
		// ensure NRVO
		auto op = asShared.connect(receiver);
		return op;
	}

	auto connect(Receiver)(return Receiver receiver) @safe shared return scope {
		// ensure NRVO
		auto op = PromiseSenderOp!(T, Receiver)(promise, receiver);
		return op;
	}

	private auto asShared() @trusted return scope {
		return cast(shared) this;
	}
}

struct Defer(Fun) {
	import concurrency.utils;
	static assert(isThreadSafeCallable!Fun);
	alias Sender = typeof(fun());
	static assert(models!(Sender, isSender));
	alias Value = Sender.Value;
	Fun fun;
	auto connect(Receiver)(return Receiver receiver) @safe {
		// ensure NRVO
		auto op = fun().connect(receiver);
		return op;
	}
}

auto defer(Fun)(Fun fun) {
	return Defer!(Fun)(fun);
}
