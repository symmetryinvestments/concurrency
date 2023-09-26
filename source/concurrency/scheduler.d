module concurrency.scheduler;

import concurrency.sender : SenderObjectBase, isSender;
import core.time : Duration;
import concepts;
import std.typecons : Nullable, nullable;

void checkScheduler(T)() {
	import concurrency.sender : checkSender;
	import core.time : msecs;
	T t = T.init;
	alias Sender = typeof(t.schedule());
	checkSender!Sender();
	alias AfterSender = typeof(t.scheduleAfter(10.msecs));
	checkSender!AfterSender();
}

enum isScheduler(T) = is(typeof(checkScheduler!T));

/// polymorphic Scheduler
interface SchedulerObjectBase {
	SenderObjectBase!void schedule() @safe;
	SenderObjectBase!void scheduleAfter(Duration d) @safe;
}


// We can pull the LocalThreadExecutor (and its schedule/scheduleAfter) out into a specialized context.
// Just like we did with the iouring context

// The interesting bit is that the syncWait algorithm then might be inferred as @nogc

// The question remains how we would want to integrate these.
// With iouring we created a runner that would take a sender and would inject the scheduler and allow itself to steal the current thread.

// That last part is important, we don't want to spawn a thread just to run timers, we can do it perfectly fine on the current thread.
// Same with iouring or other event loops.

// That said, we can, if we want to, move the event loop to another thread.

// The only thing we can't do is cross schedule timers from one thread to another.
// Well, that is not true, we can create two context objects that expose a Scheduler 






// Guess we just have to write it and see....

// Dietmar Kuhl used a iocontext with a run function that allows running it on the current thread.
// In rant I had the iocontext's runner return a sender so you could await that.

class SchedulerObject(S) : SchedulerObjectBase {
	import concurrency.sender : toSenderObject;
	S scheduler;
	this(S scheduler) {
		this.scheduler = scheduler;
	}

	SenderObjectBase!void schedule() @safe {
		return scheduler.schedule().toSenderObject();
	}

	SenderObjectBase!void scheduleAfter(Duration d) @safe {
		return scheduler.scheduleAfter(d).toSenderObject();
	}
}

SchedulerObjectBase toSchedulerObject(S)(S scheduler) {
	return new SchedulerObject!(S)(scheduler);
}

struct NullScheduler {}

enum TimerTrigger {
	trigger,
	cancel
}

alias TimerDelegate = void delegate(TimerTrigger) @safe shared;

import concurrency.timingwheels : ListElement;
alias Timer = ListElement!(TimerDelegate);

auto localThreadScheduler() {
	import concurrency.thread : LocalThreadWorker, getLocalThreadExecutor;
	return SchedulerAdapter!LocalThreadWorker(
		LocalThreadWorker(getLocalThreadExecutor));
}

alias LocalThreadScheduler = typeof(localThreadScheduler());

struct SchedulerAdapter(Worker) {
	static assert(models!(typeof(this), isScheduler));
	import concurrency.receiver : setValueOrError;
	import concurrency.executor : VoidDelegate;
	import core.time : Duration;
	Worker worker;
	auto schedule() {
		static struct ScheduleOp(Receiver) {
			Worker worker;
			Receiver receiver;
			@disable
			this(ref return scope typeof(this) rhs);
			@disable
			this(this);
			void start() @trusted nothrow {
				try {
					worker.schedule(
						cast(VoidDelegate) () => receiver.setValueOrError());
				} catch (Exception e) {
					receiver.setError(e);
				}
			}
		}

		static struct ScheduleSender {
			alias Value = void;
			Worker worker;
			auto connect(Receiver)(
				return Receiver receiver
			) @safe return scope {
				// ensure NRVO
				auto op = ScheduleOp!(Receiver)(worker, receiver);
				return op;
			}
		}

		return ScheduleSender(worker);
	}

	auto schedule() @trusted shared {
		return (cast() this).schedule();
	}

	auto scheduleAfter(Duration dur) @safe {
		return ScheduleAfterSender!(Worker)(worker, dur);
	}

	auto scheduleAfter(Duration dur) @trusted shared {
		return (cast() this).scheduleAfter(dur);
	}
}

struct ScheduleAfterOp(Worker, Receiver) {
	import std.traits : ReturnType;
	import concurrency.bitfield : SharedBitField;
	import concurrency.stoptoken : StopCallback;
	import concurrency.receiver : setValueOrError;

	enum Flags {
		locked = 0x0,
		stop = 0x1,
		triggered = 0x2,
		setup = 0x4,
	}

	Worker worker;
	Duration dur;
	Receiver receiver;
	Timer timer;
	shared StopCallback stopCb;
	shared SharedBitField!Flags flags;
	@disable
	this(ref return scope typeof(this) rhs);
	@disable
	this(this);
	// ~this() @safe scope {}
	void start() @trusted scope nothrow {
		if (receiver.getStopToken().isStopRequested) {
			receiver.setDone();
			return;
		}

		auto token = receiver.getStopToken();
		stopCb.register(token, cast(void delegate() nothrow @safe shared) &stop);

		try {
			timer.userdata = cast(void delegate(TimerTrigger) @safe shared) &trigger;
			worker.addTimer(timer, dur);
		} catch (Exception e) {
			receiver.setError(e);
			return;
		}

		with (flags.add(Flags.setup)) {
			if (has(Flags.stop)) {
				try {
					worker.cancelTimer(timer);
				} catch (Exception e) {} // TODO: what to do here?
			}

			if (has(Flags.triggered)) {
				receiver.setValueOrError();
			}
		}
	}

	private void trigger(TimerTrigger cause) @trusted nothrow {
		with (flags.add(Flags.triggered)) {
			if (!has(Flags.setup))
				return;
			stopCb.dispose();
			final switch (cause) {
				case TimerTrigger.cancel:
					receiver.setDone();
					break;
				case TimerTrigger.trigger:
					receiver.setValueOrError();
					break;
			}
		}
	}

	private void stop() @trusted nothrow {
		with (flags.add(Flags.stop)) {
			if (!has(Flags.setup)) {
				return;
			}

			if (!has(Flags.triggered)) {
				try {
					worker.cancelTimer(timer);
				} catch (Exception e) {} // TODO: what to do here?
			}
		}
	}
}

struct ScheduleAfterSender(Worker) {
	alias Value = void;
	Worker worker;
	Duration dur;
	auto connect(Receiver)(return Receiver receiver) @safe return scope {
		// ensure NRVO
		auto op = ScheduleAfterOp!(Worker, Receiver)(worker, dur, receiver);
		return op;
	}
}

struct ManualTimeScheduler {
	shared ManualTimeWorker worker;
	auto schedule() {
		import core.time : msecs;
		return scheduleAfter(0.msecs);
	}

	auto scheduleAfter(Duration dur) {
		return ScheduleAfterSender!(shared ManualTimeWorker)(worker, dur);
	}
}

class ManualTimeWorker {
	import concurrency.timingwheels : TimingWheels;
	import concurrency.executor : VoidDelegate;
	import core.sync.mutex : Mutex;
	import core.sync.condition : Condition;
	import core.time : msecs, hnsecs;
	import std.array : Appender;
	private {
		TimingWheels!TimerDelegate wheels;
		Condition condition;
		size_t time = 1;
		shared ulong nextTimerId;
	}

	auto lock() @trusted shared {
		import concurrency.utils : SharedGuard;
		return SharedGuard!(ManualTimeWorker)
			.acquire(this, cast() condition.mutex);
	}

	this() @trusted shared {
		condition = cast(shared) new Condition(new Mutex());
		(cast() wheels).initialize(time);
	}

	ManualTimeScheduler getScheduler() @safe shared {
		return ManualTimeScheduler(this);
	}

	void addTimer(ref Timer timer, Duration dur) @trusted shared {
		import core.atomic : atomicOp;
		with (lock()) {
			auto real_now = time;
			auto tw_now = wheels.currStdTime(1.msecs);
			auto delay = (real_now - tw_now).hnsecs;
			auto at = (dur + delay) / 1.msecs;
			wheels.schedule(&timer, at);
			condition.notifyAll();
		}
	}

	void wait() @trusted shared {
		with (lock()) {
			condition.wait();
		}
	}

	void cancelTimer(ref Timer timer) @trusted shared {
		with (lock()) {
			wheels.cancel(&timer);
		}

		timer.userdata(TimerTrigger.cancel);
	}

	Nullable!Duration timeUntilNextEvent() @trusted shared {
		with (lock()) {
			return wheels.timeUntilNextEvent(1.msecs, time);
		}
	}

	void advance(Duration dur) @trusted shared {
		import std.range : retro;
		import core.time : msecs;
		with (lock()) {
			time += dur.total!"hnsecs";
			int incr = wheels.ticksToCatchUp(1.msecs, time);
			if (incr > 0) {
				Timer* t;
				wheels.advance(incr, t);
				while (t !is null) {
					auto next = t.next;
					t.userdata(TimerTrigger.trigger);
					t = next;
				}
			}
		}
	}
}

auto withBaseScheduler(T, P)(auto ref T t, auto ref P p) {
	static if (isScheduler!T)
		return t;
	else static if (isScheduler!P)
		return ProxyScheduler!(T, P)(t, p);
	else
		static assert(
			false,
			"Neither " ~ T.stringof ~ " nor " ~ P.stringof
				~ " are full schedulers. Chain the sender with a .withScheduler"
				~ " and ensure the Scheduler passes the isScheduler check."
		);
}

private struct ProxyScheduler(T, P) {
	import std.parallelism : TaskPool;
	import core.time : Duration;
	T front;
	P back;
	auto schedule() {
		return front.schedule();
	}

	auto scheduleAfter(Duration run) {
		import concurrency.operations : via;
		return schedule().via(back.scheduleAfter(run));
	}
}

struct ScheduleAfter {
	static assert(models!(typeof(this), isSender));
	alias Value = void;
	Duration duration;
	auto connect(Receiver)(return Receiver receiver) @safe return scope {
		// ensure NRVO
		auto op =
			receiver.getScheduler.scheduleAfter(duration).connect(receiver);
		return op;
	}
}

struct Schedule {
	static assert(models!(typeof(this), isSender));
	alias Value = void;
	auto connect(Receiver)(return Receiver receiver) @safe return scope {
		// ensure NRVO
		auto op = receiver.getScheduler.schedule().connect(receiver);
		return op;
	}
}
