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

alias TimerDelegate = void delegate(TimerTrigger) @safe shared nothrow;

import concurrency.timingwheels : ListElement;
static import concurrency.timingwheels;
alias Timer = ListElement!(TimerDelegate);
alias TimingWheels = concurrency.timingwheels.TimingWheels!(TimerDelegate);
public import concurrency.timingwheels : TimerCommand, TimerCommandNode;

auto localThreadScheduler() {
	import concurrency.thread : LocalThreadWorker, getLocalThreadExecutor;
	return SchedulerAdapter!LocalThreadWorker(
		LocalThreadWorker(getLocalThreadExecutor));
}

alias LocalThreadScheduler = typeof(localThreadScheduler());

struct SchedulerAdapter(Worker) {
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
				} catch (Throwable e) {
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
	import concurrency.stoptoken : StopCallback;
	import concurrency.receiver : setValueOrError;
	import core.atomic : cas, atomicLoad, MemoryOrder;

	enum Terminal : size_t {
		pending,
		triggered,
		canceled,
		stopped,
		error,
		completed,
	}
	enum size_t terminalMask = 0x7;
	enum size_t setupBit = 0x8;
	enum size_t addedBit = 0x10;

	Worker worker;
	Receiver receiver;
	Timer timer;
	shared StopCallback stopCb;
	shared size_t state;
	static assert(typeof(state).sizeof == size_t.sizeof);
	@disable
	this(ref return scope typeof(this) rhs);
	@disable
	this(this);
	@disable void opAssign(typeof(this) rhs) nothrow @safe @nogc;
	@disable void opAssign(ref typeof(this) rhs) nothrow @safe @nogc;

	this(return Worker worker, Duration dur, return Receiver receiver) @trusted scope {
		this.worker = worker;
		this.receiver = receiver;
		this.timer.setScheduledAt(dur);
	}

	void start() @trusted scope nothrow {
		if (receiver.getStopToken().isStopRequested) {
			claim(Terminal.stopped);
			publishSetup(false, null);
			return;
		}

		auto token = receiver.getStopToken();
		stopCb.register(token, cast(void delegate() nothrow @safe shared) &stop);

		bool added;
		Throwable failure;
		try {
			timer.userdata = cast(void delegate(TimerTrigger) @safe shared nothrow) &trigger;
			worker.addTimer(timer);
			added = true;
		} catch (Throwable e) {
			failure = e;
			claim(Terminal.error);
		}

		publishSetup(added, failure);
	}

	private bool claim(Terminal cause) @trusted nothrow {
		auto expected = state.atomicLoad!(MemoryOrder.acq);
		while (terminal(expected) == Terminal.pending) {
			auto desired = withTerminal(expected, cause);
			if ((&state).cas!(MemoryOrder.acq_rel, MemoryOrder.acq)(expected, desired))
				return true;
		}
		return false;
	}

	private void publishSetup(bool timerAdded, Throwable failure) @trusted nothrow {
		auto expected = state.atomicLoad!(MemoryOrder.acq);
		size_t desired;
		do {
			desired = expected | setupBit | (timerAdded ? addedBit : 0);
		} while (!(&state).cas!(MemoryOrder.acq_rel, MemoryOrder.acq)(expected, desired));

		auto cause = terminal(state.atomicLoad!(MemoryOrder.acq));
		if (cause == Terminal.stopped && timerAdded) {
			try {
				worker.cancelTimer(timer);
			} catch (Throwable e) {}
		}
		complete(cause, failure);
	}

	private void trigger(TimerTrigger cause) @trusted nothrow {
		final switch (cause) {
			case TimerTrigger.trigger:
				if (!claim(Terminal.triggered))
					return;
				break;
			case TimerTrigger.cancel:
				if (!claim(Terminal.canceled))
					return;
				break;
		}
		auto snapshot = state.atomicLoad!(MemoryOrder.acq);
		if (snapshot & setupBit)
			complete(terminal(snapshot), null);
	}

	private void stop() @trusted nothrow {
		if (!claim(Terminal.stopped))
			return;
		auto snapshot = state.atomicLoad!(MemoryOrder.acq);
		if (snapshot & setupBit) {
			if (snapshot & addedBit) {
				try {
					worker.cancelTimer(timer);
				} catch (Throwable e) {}
			}
			complete(Terminal.stopped, null);
		}
	}

	private void complete(Terminal cause, Throwable failure) @trusted nothrow {
		if (cause == Terminal.pending || cause == Terminal.completed)
			return;
		auto expected = state.atomicLoad!(MemoryOrder.acq);
		while (terminal(expected) == cause) {
			auto desired = withTerminal(expected, Terminal.completed);
			if ((&state).cas!(MemoryOrder.acq_rel, MemoryOrder.acq)(expected, desired))
				goto won;
		}
		return;

	won:
		stopCb.dispose();
		final switch (cause) {
			case Terminal.triggered:
				receiver.setValueOrError();
				break;
			case Terminal.canceled:
			case Terminal.stopped:
				receiver.setDone();
				break;
			case Terminal.error:
				assert(failure !is null);
				receiver.setError(failure);
				break;
			case Terminal.pending:
			case Terminal.completed:
				assert(false);
		}
	}

	private static Terminal terminal(size_t value) pure nothrow @safe @nogc {
		return cast(Terminal)(value & terminalMask);
	}

	private static size_t withTerminal(size_t value, Terminal cause)
		pure nothrow @safe @nogc {
		return (value & ~terminalMask) | cause;
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
	import concurrency.executor : VoidDelegate;
	import core.sync.mutex : Mutex;
	import core.sync.condition : Condition;
	import core.time : msecs, hnsecs;
	import std.array : Appender;
	private {
		TimingWheels wheels;
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

	void addTimer(ref Timer timer) @trusted shared {
		import core.time : hnsecs;
		addTimer(timer, timer.scheduled_at.hnsecs);
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
	alias Value = void;
	auto connect(Receiver)(return Receiver receiver) @safe return scope {
		// ensure NRVO
		auto op = receiver.getScheduler.schedule().connect(receiver);
		return op;
	}
}
