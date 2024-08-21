module ut.concurrency.operations;

import concurrency;
import concurrency.sender;
import concurrency.thread;
import concurrency.operations;
import concurrency.receiver;
import concurrency.stoptoken;
import concurrency.nursery;
import unit_threaded;
import core.time;
import core.thread;
import std.typecons;

/// Used to test that Senders keep the operational state alive until one receiver's terminal is called
struct OutOfBandValueSender(T) {
	alias Value = T;
	T value;
	struct Op(Receiver) {
		Receiver receiver;
		T value;
		@disable
		this(ref return scope typeof(this) rhs);
		@disable
		this(this);
		void run() {
			receiver.setValue(value);
		}

		void start() @trusted scope {
			auto value = new Thread(&this.run).start();
		}
	}

	auto connect(Receiver)(return Receiver receiver) @safe return scope {
		// ensure NRVO
		auto op = Op!(Receiver)(receiver, value);
		return op;
	}
}

@("ignoreErrors.syncWait.value") @safe
unittest {
	bool delegate() @safe shared dg = () shared {
		throw new Exception("Exceptions are rethrown");
	};
	ThreadSender().then(dg).ignoreError().syncWait.isCancelled.should == true;
}

@("oob") @safe
unittest {
	auto oob = OutOfBandValueSender!int(43);
	oob.syncWait.value.should == 43;
}

@("race") @safe
unittest {
	race(ValueSender!int(4), ValueSender!int(5)).syncWait.value.should == 4;
	auto fastThread = ThreadSender().then(() shared => 1);
	auto slowThread = ThreadSender().then(() @trusted shared {
		Thread.sleep(50.msecs);
		return 2;
	});
	race(fastThread, slowThread).syncWait.value.should == 1;
	race(slowThread, fastThread).syncWait.value.should == 1;
}

@("race.multiple") @safe
unittest {
	race(ValueSender!int(4), ValueSender!int(5), ValueSender!int(6))
		.syncWait.value.should == 4;
}

@("race.exception.single") @safe
unittest {
	import std.sumtype : tryMatch;
	race(ThrowingSender(), ValueSender!int(5)).syncWait.value.tryMatch!((int i) => i.should == 5);
	race(ThrowingSender(), ThrowingSender()).syncWait.assumeOk.shouldThrow();
}

@("race.exception.double") @safe
unittest {
	auto slow = ThreadSender().then(() @trusted shared {
		Thread.sleep(50.msecs);
		throw new Exception("Slow");
	});
	auto fast = ThreadSender().then(() shared {
		throw new Exception("Fast");
	});
	race(slow, fast).syncWait.assumeOk.shouldThrowWithMessage("Fast");
}

@("race.cancel-other") @safe
unittest {
	auto waiting = ThreadSender().withStopToken((shared StopToken token) @trusted {
		while (!token.isStopRequested) {
			Thread.yield();
		}
	});
	import std.sumtype : tryMatch;
	race(waiting, ValueSender!int(88)).syncWait.value.tryMatch!((int i) => i.should == 88);
}

@("race.cancel") @safe
unittest {
	auto waiting = ThreadSender().withStopToken((shared StopToken token) @trusted {
		while (!token.isStopRequested) {
			Thread.yield();
		}
	});
	auto nursery = new shared Nursery();
	nursery.run(race(waiting, waiting));
	nursery.run(ThreadSender().then(() @trusted shared {
		Thread.sleep(50.msecs);
		nursery.stop();
	}));
	nursery.syncWait.isCancelled.should == true;
}

@("race.array.just") @safe
unittest {
	race([just(4), just(5)]).syncWait.value.should == 4;
}

@("race.array.void") @safe
unittest {
	race([VoidSender(), VoidSender()]).syncWait.assumeOk;
}

@("via") @safe
unittest {
	import std.typecons : tuple;
	ValueSender!int(3).via(ValueSender!int(6)).syncWait.value.should
		== tuple(6, 3);
	ValueSender!int(5).via(VoidSender()).syncWait.value.should == 5;
	VoidSender().via(ValueSender!int(4)).syncWait.value.should == 4;
}

@("then.value.delegate") @safe
unittest {
	ValueSender!int(3).then((int i) shared => i * 3).syncWait.value
	                  .shouldEqual(9);
}

@("then.value.function") @safe
unittest {
	ValueSender!int(3).then((int i) => i * 3).syncWait.value.shouldEqual(9);
}

@("then.oob") @safe
unittest {
	OutOfBandValueSender!int(46).then((int i) shared => i * 3).syncWait.value
	                            .shouldEqual(138);
}

@("then.tuple") @safe
unittest {
	just(1, 2, 3).then((Tuple!(int, int, int) t) shared => t[0]).syncWait.value
	             .shouldEqual(1);
}

@("then.tuple.expand") @safe
unittest {
	just(1, 2, 3).then((int a, int b, int c) shared => a + b).syncWait.value
	             .shouldEqual(3);
}

@("whenAll.basic") @safe
unittest {
	whenAll(ValueSender!int(1), ValueSender!int(2)).syncWait.value.should
		== tuple(1, 2);
	whenAll(ValueSender!int(1), ValueSender!int(2), ValueSender!int(3))
		.syncWait.value.should == tuple(1, 2, 3);
	whenAll(VoidSender(), ValueSender!int(2)).syncWait.value.should == 2;
	whenAll(ValueSender!int(1), VoidSender()).syncWait.value.should == 1;
	whenAll(VoidSender(), VoidSender()).syncWait.assumeOk;
	whenAll(ValueSender!int(1), ThrowingSender())
		.syncWait.assumeOk.shouldThrowWithMessage("ThrowingSender");
	whenAll(ThrowingSender(), ValueSender!int(1))
		.syncWait.assumeOk.shouldThrowWithMessage("ThrowingSender");
	whenAll(ValueSender!int(1), DoneSender()).syncWait.isCancelled.should
		== true;
	whenAll(DoneSender(), ValueSender!int(1)).syncWait.isCancelled.should
		== true;
	whenAll(DoneSender(), ThrowingSender()).syncWait.isCancelled.should == true;
	whenAll(ThrowingSender(), DoneSender())
		.syncWait.assumeOk.shouldThrowWithMessage("ThrowingSender");
}

@("whenAll.cancel") @safe
unittest {
	auto waiting = ThreadSender().withStopToken((shared StopToken token) @trusted {
		while (!token.isStopRequested) {
			Thread.yield();
		}
	});
	whenAll(waiting, DoneSender()).syncWait.isCancelled.should == true;
	whenAll(ThrowingSender(), waiting).syncWait.assumeOk.shouldThrow;
	whenAll(waiting, ThrowingSender()).syncWait.assumeOk.shouldThrow;
	auto waitingInt = ThreadSender().withStopToken((shared StopToken token) @trusted {
		while (!token.isStopRequested) {
			Thread.yield();
		}

		return 42;
	});
	whenAll(waitingInt, DoneSender()).syncWait.isCancelled.should == true;
	whenAll(ThrowingSender(), waitingInt).syncWait.assumeOk.shouldThrow;
	whenAll(waitingInt, ThrowingSender()).syncWait.assumeOk.shouldThrow;
}

@("whenAll.stop") @safe
unittest {
	auto waiting = ThreadSender().withStopToken((shared StopToken token) @trusted {
		while (!token.isStopRequested) {
			Thread.yield();
		}
	});
	shared source = StopSource();
	auto stopper = justFrom(() shared => source.stop());
	whenAll(waiting, stopper).withStopSource(source).syncWait.isCancelled.should
		== true;
}

@("whenAll.array.just") @safe
unittest {
	whenAll([just(4), just(5)]).syncWait.value.should == [4, 5];
}

@("whenAll.array.void") @safe
unittest {
	whenAll([VoidSender(), VoidSender()]).syncWait.assumeOk;
}

@("retry") @safe
unittest {
	ValueSender!int(5).retry(Times(5)).syncWait.value.should == 5;
	int t = 3;
	int n = 0;
	struct Sender {
		alias Value = void;
		static struct Op(Receiver) {
			Receiver receiver;
			bool fail;
			@disable
			this(ref return scope typeof(this) rhs);
			@disable
			this(this);
			void start() @safe nothrow {
				if (fail)
					receiver.setError(new Exception("Fail fail fail"));
				else
					receiver.setValue();
			}
		}

		auto connect(Receiver)(return Receiver receiver) @safe return scope {
			// ensure NRVO
			auto op = Op!(Receiver)(receiver, n++ < t);
			return op;
		}
	}

	Sender().retry(Times(5)).syncWait.assumeOk;
	n.should == 4;
	n = 0;

	Sender().retry(Times(2)).syncWait.assumeOk
	        .shouldThrowWithMessage("Fail fail fail");
	n.should == 2;
	shared int p = 0;
	ThreadSender().then(() shared {
		import core.atomic;
		p.atomicOp!("+=")(1);
		throw new Exception("Failed");
	}).retry(Times(5)).syncWait.assumeOk.shouldThrowWithMessage("Failed");
	p.should == 5;
}

@("retryWhen.immediate.success") @safe
unittest {
	static struct Immediate {
		auto failure(Exception e) {
			return VoidSender();
		}
	}

	VoidSender().retryWhen(Immediate()).syncWait.assumeOk;
}

struct ConnectCounter {
	alias Value = int;
	int counter = 0;
	auto connect(Receiver)(return Receiver receiver) @safe return scope {
		// ensure NRVO
		auto op = ValueSender!int(counter++).connect(receiver);
		return op;
	}
}

@("retryWhen.immediate.retries") @safe
unittest {
	static struct Immediate {
		auto failure(Exception e) {
			return VoidSender();
		}
	}

	ConnectCounter().then((int c) {
		if (c < 3)
			throw new Exception("jada");
		return c;
	}).retryWhen(Immediate()).syncWait.value.should == 3;
}

@("retryWhen.wait.retries") @safe
unittest {
	import core.time : msecs;
	import concurrency.scheduler : ManualTimeWorker;

	static struct Wait {
		auto failure(Exception e) @safe {
			return delay(3.msecs);
		}
	}

	auto worker = new shared ManualTimeWorker();
	auto sender = ConnectCounter().then((int c) {
		if (c < 3)
			throw new Exception("jada");
		return c;
	}).retryWhen(Wait()).withScheduler(worker.getScheduler);

	auto driver = just(worker).then((shared ManualTimeWorker worker) {
		worker.timeUntilNextEvent().should == 3.msecs.nullable;
		worker.advance(3.msecs);
		worker.timeUntilNextEvent().should == 3.msecs.nullable;
		worker.advance(3.msecs);
		worker.timeUntilNextEvent().should == 3.msecs.nullable;
		worker.advance(3.msecs);
		worker.timeUntilNextEvent().isNull.should == true;
	});

	whenAll(sender, driver).syncWait.value.should == 3;
}

@("retryWhen.throw") @safe
unittest {
	static struct Throw {
		auto failure(Exception t) @safe {
			return ErrorSender(new Exception("inner"));
		}
	}

	ErrorSender(new Exception("outer")).retryWhen(Throw()).syncWait.assumeOk
	                                   .shouldThrowWithMessage("inner");
}

@("whenAll.oob") @safe
unittest {
	auto oob = OutOfBandValueSender!int(43);
	auto value = ValueSender!int(11);
	whenAll(oob, value).syncWait.value.should == tuple(43, 11);
}

@("withStopToken.oob") @safe
unittest {
	auto oob = OutOfBandValueSender!int(44);
	oob.withStopToken((shared StopToken stopToken, int t) => t).syncWait.value.should
		== 44;
}

@("withStopSource.oob") @safe
unittest {
	auto oob = OutOfBandValueSender!int(45);
	shared source = StopSource();
	oob.withStopSource(source).syncWait.value.should == 45;
}

@("withStopSource.tuple") @safe
unittest {
	just(14, 53).withStopToken((shared StopToken s, Tuple!(int, int) t) => t[0] * t[1])
	            .syncWait.value.should == 742;
}

@("value.withstoptoken.via.thread") @safe
unittest {
	ValueSender!int(4).withStopToken((shared StopToken s, int i) {
		throw new Exception("Badness");
	}).via(ThreadSender()).syncWait.assumeOk.shouldThrowWithMessage("Badness");
}

@("completewithcancellation") @safe
unittest {
	ValueSender!void().completeWithCancellation.syncWait.isCancelled.should
		== true;
}

@("raceAll") @safe
unittest {
	auto waiting = ThreadSender().withStopToken((shared StopToken token) @trusted {
		while (!token.isStopRequested) {
			Thread.yield();
		}
	});
	import std.sumtype : tryMatch;
	raceAll(waiting, DoneSender()).syncWait.isCancelled.should == true;
	raceAll(waiting, just(42)).syncWait.value.tryMatch!(i => i.should == 42);
	raceAll(waiting, ThrowingSender()).syncWait.isError.should == true;
}

@("on.ManualTimeWorker") @safe
unittest {
	import concurrency.scheduler : ManualTimeWorker;

	auto worker = new shared ManualTimeWorker();
	auto driver = just(worker).then((shared ManualTimeWorker worker) shared {
		worker.timeUntilNextEvent().should == 10.msecs.nullable;
		worker.advance(5.msecs);
		worker.timeUntilNextEvent().should == 5.msecs.nullable;
		worker.advance(5.msecs);
		worker.timeUntilNextEvent().isNull.should == true;
	});
	auto timer = DelaySender(10.msecs).withScheduler(worker.getScheduler);

	whenAll(timer, driver).syncWait().assumeOk;
}

@("on.ManualTimeWorker.cancel") @safe
unittest {
	import concurrency.scheduler : ManualTimeWorker;

	auto worker = new shared ManualTimeWorker();
	shared StopSource source;
	auto driver = justFrom(() shared {
		worker.timeUntilNextEvent().should == 10.msecs.nullable;
		source.stop();
		worker.timeUntilNextEvent().isNull.should == true;
	});
	auto timer = DelaySender(10.msecs).withScheduler(worker.getScheduler);

	whenAll(timer, driver).syncWait(source).isCancelled.should == true;
}

@("then.stack.no-leak") @safe
unittest {
	struct S {
		void fun(int i) shared {}
	}

	shared S s;
	// its perfectly ok to point to a function on the stack
	auto sender = just(42).then(&s.fun);

	sender.syncWait();

	void disappearSender(Sender)(Sender s) @safe;
	// but the sender can't leak now
	static assert(!__traits(compiles, disappearSender(sender)));
}

@("forwardOn") @safe
unittest {
	auto pool = stdTaskPool(2);

	VoidSender().forwardOn(pool.getScheduler).syncWait.assumeOk;
	ErrorSender(new Exception("bad news")).forwardOn(pool.getScheduler).syncWait
	                                      .isError.should == true;
	DoneSender().forwardOn(pool.getScheduler).syncWait.isCancelled.should
		== true;
	just(42).forwardOn(pool.getScheduler).syncWait.value.should == 42;
}

@("toSingleton") @safe
unittest {
	import std.typecons : tuple;
	import concurrency.scheduler : ManualTimeWorker;
	import core.atomic : atomicOp;

	shared int g;

	auto worker = new shared ManualTimeWorker();

	auto single = delay(2.msecs).then(() shared => g.atomicOp!"+="(1))
	                            .toSingleton(worker.getScheduler);

	auto driver = justFrom(() shared => worker.advance(2.msecs));

	whenAll(single, single, driver).syncWait.value.should == tuple(1, 1);
	whenAll(single, single, driver).syncWait.value.should == tuple(2, 2);
}

@("stopOn") @safe
unittest {
	shared sourceInner = StopSource();
	shared sourceOuter = StopSource();

	shared bool b;
	whenAll(
		delay(5.msecs).then(() shared => b = true)
		              .stopOn(sourceInner.token()),
		just(() => sourceOuter.stop())
	).syncWait(sourceOuter).assumeOk;
	b.should == true;

	shared bool d;
	whenAll(
		delay(5.msecs).then(() shared => b = true)
		              .stopOn(sourceInner.token()),
		just(() => sourceInner.stop())
	).syncWait(sourceOuter).assumeOk;
	d.should == false;
}

@("withChild") @safe
unittest {
	import core.atomic;

	class State {
		import core.sync.event : Event;
		bool parentAfterChild;
		Event childEvent, parentEvent;
		this() @trusted shared {
			(cast() childEvent).initialize(false, false);
			(cast() parentEvent).initialize(false, false);
		}

		void signalChild() @trusted shared {
			(cast() childEvent).setIfInitialized();
		}

		void waitChild() @trusted shared {
			(cast() childEvent).wait();
		}

		void signalParent() @trusted shared {
			(cast() parentEvent).setIfInitialized();
		}

		void waitParent() @trusted shared {
			(cast() parentEvent).wait();
		}
	}

	auto state = new shared State();
	shared source = StopSource();

	import std.stdio;
	auto child = just(state)
		.withStopToken((shared StopToken token, shared State state) @trusted {
			while (!token.isStopRequested) {}
			state.signalParent();
			state.waitChild();
		}).via(ThreadSender());

	auto parent =
		just(state).withStopToken((shared StopToken token, shared State state) {
			state.waitParent();
			state.parentAfterChild.atomicStore(token.isStopRequested == false);
			state.signalChild();
		}).via(ThreadSender());

	whenAll(
		parent.withChild(child).withStopSource(source),
		justFrom(() shared => source.stop())
	).syncWait.isCancelled.should == true;

	state.parentAfterChild.atomicLoad.should == true;
}

@("onTermination.value") @safe
unittest {
	import core.atomic : atomicOp;
	shared int g = 0;
	just(42).onTermination(() @safe shared => g.atomicOp!"+="(1)).syncWait
	        .assumeOk;
	g.should == 1;
}

@("onTermination.done") @safe
unittest {
	import core.atomic : atomicOp;
	shared int g = 0;
	DoneSender().onTermination(() @safe shared => g.atomicOp!"+="(1)).syncWait
	            .isCancelled.should == true;
	g.should == 1;
}

@("onTermination.error") @safe
unittest {
	import core.atomic : atomicOp;
	shared int g = 0;
	ThrowingSender().onTermination(() @safe shared => g.atomicOp!"+="(1))
	                .syncWait.isError.should == true;
	g.should == 1;
}

@("onError.value") @safe
unittest {
	import core.atomic : atomicOp;
	shared int g = 0;
	just(42).onError((Exception e) @safe shared => g.atomicOp!"+="(1)).syncWait
	        .assumeOk;
	g.should == 0;
}

@("onError.done") @safe
unittest {
	import core.atomic : atomicOp;
	shared int g = 0;
	DoneSender().onError((Exception e) @safe shared => g.atomicOp!"+="(1))
	            .syncWait.isCancelled.should == true;
	g.should == 0;
}

@("onError.error") @safe
unittest {
	import core.atomic : atomicOp;
	shared int g = 0;
	ThrowingSender().onError((Exception e) @safe shared => g.atomicOp!"+="(1))
	                .syncWait.isError.should == true;
	g.should == 1;
}

@("onError.throw") @safe
unittest {
	import core.exception : AssertError;
	auto err = ThrowingSender().onError((Exception e) @safe shared {
		throw new Exception("in onError");
	}).syncWait.get!Exception;
	err.msg.should == "in onError";
	err.next.msg.should == "ThrowingSender";
}

@("stopWhen.source.value") @safe
unittest {
	auto waiting = ThreadSender().withStopToken((shared StopToken token) @trusted {
		while (!token.isStopRequested) {
			Thread.yield();
		}

		return 43;
	});
	auto trigger = delay(1.msecs);
	waiting.stopWhen(trigger).syncWait().value.should == 43;
}

@("stopWhen.source.error") @safe
unittest {
	auto waiting = ThreadSender().withStopToken((shared StopToken token) @trusted {
		while (!token.isStopRequested) {
			Thread.yield();
		}

		throw new Exception("Upside down");
	});
	auto trigger = delay(1.msecs);
	waiting.stopWhen(trigger).syncWait().assumeOk
	       .shouldThrowWithMessage("Upside down");
}

@("stopWhen.source.cancelled") @safe
unittest {
	auto waiting = ThreadSender().withStopToken((shared StopToken token) @trusted {
		while (!token.isStopRequested) {
			Thread.yield();
		}
	}).completeWithCancellation;
	auto trigger = delay(1.msecs);
	waiting.stopWhen(trigger).syncWait().isCancelled.should == true;
}

@("stopWhen.trigger.error") @safe
unittest {
	auto waiting = ThreadSender().withStopToken((shared StopToken token) @trusted {
		while (!token.isStopRequested) {
			Thread.yield();
		}

		throw new Exception(
			"This occurres later, so the other one gets propagated");
	});
	auto trigger = ThrowingSender();
	waiting.stopWhen(trigger).syncWait().assumeOk
	       .shouldThrowWithMessage("ThrowingSender");
}

@("stopWhen.trigger.cancelled.value") @safe
unittest {
	auto waiting = ThreadSender().withStopToken((shared StopToken token) @trusted {
		while (!token.isStopRequested) {
			Thread.yield();
		}

		return 42;
	});
	auto trigger = delay(1.msecs).completeWithCancellation;
	waiting.stopWhen(trigger).syncWait().isCancelled.should == true;
}

@("completewitherror.basic") @safe
unittest {
	ValueSender!void().completeWithError(new Exception("hello")).syncWait
	                  .assumeOk.shouldThrowWithMessage("hello");
}

@("completewitherror.exception.base") @safe
unittest {
	ErrorSender(new Exception("not you"))
		.completeWithError(new Exception("overridden")).syncWait.assumeOk
		.shouldThrowWithMessage!Throwable("overridden");
}

@("completewitherror.throwable.base") @safe
unittest {
	ErrorSender(new Throwable("precedence"))
		.completeWithError(new Exception("hello")).syncWait.assumeOk
		.shouldThrowWithMessage!Throwable("precedence");
}

@("completewitherror.error.base") @safe
unittest {
	ErrorSender(new Error("precedence"))
		.completeWithError(new Exception("hello")).syncWait.assumeOk
		.shouldThrowWithMessage!Error("precedence");
}

@("onCompletion.value") @safe
unittest {
	import core.atomic : atomicOp;
	shared int g = 0;
	just(42).onCompletion(() @safe shared => g.atomicOp!"+="(1)).syncWait
	        .assumeOk;
	g.should == 1;
}

@("onCompletion.done") @safe
unittest {
	import core.atomic : atomicOp;
	shared int g = 0;
	DoneSender().onCompletion(() @safe shared => g.atomicOp!"+="(1)).syncWait
	            .isCancelled.should == true;
	g.should == 1;
}

@("onCompletion.error") @safe
unittest {
	import core.atomic : atomicOp;
	shared int g = 0;
	ThrowingSender().onCompletion(() @safe shared => g.atomicOp!"+="(1))
	                .syncWait.isError.should == true;
	g.should == 0;
}

@("onResult.value") @safe
unittest {
	import core.atomic : atomicOp;
	shared int g = 0;
	just(42).onResult((Result!int r) @safe shared => g.atomicOp!"+="(1))
	        .syncWait.assumeOk;
	just(42).tee((Result!int r) @safe shared => g.atomicOp!"+="(1)).syncWait
	        .assumeOk;
	g.should == 2;
}

@("onResult.done") @safe
unittest {
	import core.atomic : atomicOp;
	shared int g = 0;
	DoneSender().onResult((Result!void r) @safe shared => g.atomicOp!"+="(1))
	            .syncWait.isCancelled.should == true;
	DoneSender().tee((Result!void r) @safe shared => g.atomicOp!"+="(1))
	            .syncWait.isCancelled.should == true;
	g.should == 2;
}

@("onResult.error") @safe
unittest {
	import core.atomic : atomicOp;
	shared int g = 0;
	ThrowingSender()
		.onResult((Result!void r) @safe shared => g.atomicOp!"+="(1)).syncWait
		.isError.should == true;
	ThrowingSender().tee((Result!void r) @safe shared => g.atomicOp!"+="(1))
	                .syncWait.isError.should == true;
	g.should == 2;
}

@("repeat.race") @safe
unittest {
	import core.atomic : atomicOp;
	import concurrency.scheduler : ManualTimeWorker;
	shared int p = 0;

	auto worker = new shared ManualTimeWorker();

	auto base = delay(1.msecs).then(() shared => cast(void) p.atomicOp!"+="(1))
	                          .repeat();

	auto driver = just(worker).then((shared ManualTimeWorker worker) {
		worker.timeUntilNextEvent().should == 1.msecs.nullable;
		worker.advance(1.msecs);
		worker.timeUntilNextEvent().should == 1.msecs.nullable;
		worker.advance(1.msecs);
		worker.timeUntilNextEvent().should == 1.msecs.nullable;
	});

	race(base, driver).withScheduler(worker.getScheduler).syncWait().assumeOk;
	p.should == 2;
}

@("repeat.error") @safe
unittest {
	static struct CountdownOp(Receiver) {
		Receiver receiver;
		bool fail;
		@disable
		this(ref return scope typeof(this) rhs);
		@disable
		this(this);
		void start() @safe nothrow {
			if (fail)
				receiver.setError(new Exception("Bye!"));
			else
				receiver.setValueOrError();
		}
	}

	static struct Countdown {
		alias Value = void;
		int countdown;
		auto connect(Receiver)(return Receiver receiver) @safe return scope {
			// ensure NRVO
			auto op = CountdownOp!(Receiver)(receiver, countdown-- == 0);
			return op;
		}
	}

	Countdown(3).syncWait().assumeOk();
	Countdown(3).repeat().syncWait().isError.should == true;
}

@("ignorevalue.happy") @safe
unittest {
	just(42).ignoreValue().syncWait.get!Completed.should == Completed();
}

@("doFinally.value") @safe
unittest {
	import core.atomic : atomicOp;
	shared int g = 0;
	just(42).doFinally(() @safe shared => g.atomicOp!"+="(1)).syncWait
	        .assumeOk;
	g.should == 1;
}

@("doFinally.done") @safe
unittest {
	import core.atomic : atomicOp;
	shared int g = 0;
	DoneSender().doFinally(() @safe shared => g.atomicOp!"+="(1)).syncWait
	            .isCancelled.should == true;
	g.should == 1;
}

@("doFinally.error") @safe
unittest {
	import core.atomic : atomicOp;
	shared int g = 0;
	ThrowingSender().doFinally(() @safe shared => g.atomicOp!"+="(1))
	                .syncWait.isError.should == true;
	g.should == 1;
}
