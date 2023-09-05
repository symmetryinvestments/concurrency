module ut.concurrency.stream;

import concurrency.stream;
import concurrency;
import unit_threaded;
import concurrency.stoptoken;
import core.atomic;
import concurrency.thread : ThreadSender;
import std.typecons : nullable;

// TODO: it would be good if we can get the Sender .collect returns to be scoped if the delegates are.

@("arrayStream") @safe
unittest {
	shared int p = 0;
	[1, 2, 3].arrayStream().collect((int t) shared {
		p.atomicOp!"+="(t);
	}).syncWait().assumeOk;
	p.should == 6;
}

@("intervalStream") @safe
unittest {
	import core.time;
	import concurrency.operations : withScheduler, whenAll;
	import concurrency.sender : justFrom;
	import concurrency.scheduler : ManualTimeWorker;

	auto worker = new shared ManualTimeWorker();
	auto interval = 5.msecs.intervalStream().take(2).collect(() shared {})
	                 .withScheduler(worker.getScheduler);

	auto driver = justFrom(() shared {
		worker.timeUntilNextEvent().should == 5.msecs.nullable;
		worker.advance(5.msecs);

		worker.timeUntilNextEvent().should == 5.msecs.nullable;
		worker.advance(5.msecs);

		worker.timeUntilNextEvent().isNull.should == true;
	});

	whenAll(interval, driver).syncWait().assumeOk;
}

@("infiniteStream.stop") @safe
unittest {
	import concurrency.operations : withStopSource;
	shared int g = 0;
	auto source = new shared StopSource();
	infiniteStream(5).collect((int n) shared {
		if (g < 14)
			g.atomicOp!"+="(n);
		else
			source.stop();
	}).withStopSource(source).syncWait.isCancelled.should == true;
	g.should == 15;
}

;

@("infiniteStream.take") @safe
unittest {
	shared int g = 0;
	infiniteStream(4).take(5).collect((int n) shared {
		g.atomicOp!"+="(n);
	}).syncWait().assumeOk;
	g.should == 20;
}

@("iotaStream") @safe
unittest {
	import concurrency.stoptoken;
	shared int g = 0;
	iotaStream(0, 5).collect((int n) shared {
		g.atomicOp!"+="(n);
	}).syncWait().assumeOk;
	g.should == 10;
}

@("loopStream") @safe
unittest {
	struct Loop {
		size_t b, e;
		void loop(DG, StopToken)(DG emit, StopToken stopToken) {
			foreach (i; b .. e)
				emit(i);
		}
	}

	shared int g = 0;
	Loop(0, 4).loopStream!size_t.collect((size_t n) shared {
		g.atomicOp!"+="(n);
	}).syncWait().assumeOk;
	g.should == 6;
}

@("toStreamObject") @safe
unittest {
	import core.atomic : atomicOp;

	static StreamObjectBase!int getStream() {
		return [1, 2, 3].arrayStream().toStreamObject();
	}

	shared int p;

	getStream().collect((int i) @safe shared {
		p.atomicOp!"+="(i);
	}).syncWait().assumeOk;

	p.should == 6;
}

@("toStreamObject.take") @safe
unittest {
	static StreamObjectBase!int getStream() {
		return [1, 2, 3].arrayStream().toStreamObject();
	}

	shared int p;

	getStream().take(2).collect((int i) shared {
		p.atomicOp!"+="(i);
	}).syncWait().assumeOk;

	p.should == 3;
}

@("toStreamObject.void") @safe
unittest {
	import core.time : msecs;
	shared bool p = false;

	1.msecs.intervalStream().toStreamObject().take(1).collect(() shared {
		p = true;
	}).syncWait().assumeOk;

	p.should == true;
}

@("transform.int.double") @safe
unittest {
	shared int p = 0;
	[1, 2, 3].arrayStream().transform((int i) => i * 3).collect((int t) shared {
		p.atomicOp!"+="(t);
	}).syncWait().assumeOk;
	p.should == 18;
}

@("transform.int.bool") @safe
unittest {
	shared int p = 0;
	[1, 2, 3].arrayStream().transform((int i) => i % 2 == 0)
	         .collect((bool t) shared {
		         if (t)
			         p.atomicOp!"+="(1);
	         }).syncWait().assumeOk;
	p.should == 1;
}

@("scan") @safe
unittest {
	shared int p = 0;
	[1, 2, 3].arrayStream().scan((int acc, int i) => acc += i, 0)
	         .collect((int t) shared {
		         p.atomicOp!"+="(t);
	         }).syncWait().assumeOk;
	p.should == 10;
}

@("scan.void-value") @safe
unittest {
	import core.time;
	shared int p = 0;
	5.msecs.intervalStream.scan((int acc) => acc += 1, 0).take(3)
	 .collect((int t) shared {
		 p.atomicOp!"+="(t);
	 }).syncWait().assumeOk;
	p.should == 6;
}

@("take.enough") @safe
unittest {
	shared int p = 0;

	[1, 2, 3].arrayStream.take(2).collect((int i) shared {
		p.atomicOp!"+="(i);
	}).syncWait.assumeOk;
	p.should == 3;
}

@("take.too-few") @safe
unittest {
	shared int p = 0;

	[1, 2, 3].arrayStream.take(4).collect((int i) shared {
		p.atomicOp!"+="(i);
	}).syncWait.assumeOk;
	p.should == 6;
}

@("take.donestream") @safe
unittest {
	doneStream().take(1).collect(() shared {}).syncWait.isCancelled.should
		== true;
}

@("take.errorstream") @safe
unittest {
	errorStream(new Exception("Too bad"))
		.take(1).collect(() shared {}).syncWait.assumeOk
		.shouldThrowWithMessage("Too bad");
}

@("sample.trigger.stop") @safe
unittest {
	import core.time;
	7
		.msecs
		.intervalStream()
		.scan((int acc) => acc + 1, 0)
		.sample(10.msecs.intervalStream().take(3))
		.collect((int i) shared {})
		.syncWait()
		.assumeOk;
}

@("sample.slower") @safe
unittest {
	import core.time;
	import concurrency.operations : withScheduler, whenAll;
	import concurrency.sender : justFrom;

	shared int p = 0;
	import concurrency.scheduler : ManualTimeWorker;

	auto worker = new shared ManualTimeWorker();

	auto sampler =
		7.msecs.intervalStream().scan((int acc) => acc + 1, 0)
		 .sample(10.msecs.intervalStream()).take(3).collect((int i) shared {
			 p.atomicOp!"+="(i);
		 }).withScheduler(worker.getScheduler);

	auto driver = justFrom(() shared {
		worker.advance(7.msecs);
		p.atomicLoad.should == 0;
		worker.timeUntilNextEvent().should == 3.msecs.nullable;

		worker.advance(3.msecs);
		p.atomicLoad.should == 1;
		worker.timeUntilNextEvent().should == 4.msecs.nullable;

		worker.advance(4.msecs);
		p.atomicLoad.should == 1;
		worker.timeUntilNextEvent().should == 6.msecs.nullable;

		worker.advance(6.msecs);
		p.atomicLoad.should == 3;
		worker.timeUntilNextEvent().should == 1.msecs.nullable;

		worker.advance(1.msecs);
		p.atomicLoad.should == 3;
		worker.timeUntilNextEvent().should == 7.msecs.nullable;

		worker.advance(7.msecs);
		p.atomicLoad.should == 3;
		worker.timeUntilNextEvent().should == 2.msecs.nullable;

		worker.advance(2.msecs);
		p.atomicLoad.should == 7;
		worker.timeUntilNextEvent().isNull.should == true;
	});

	whenAll(sampler, driver).syncWait().assumeOk;

	p.should == 7;
}

@("sample.faster") @safe
unittest {
	import core.time;
	import concurrency.operations : withScheduler, whenAll;
	import concurrency.sender : justFrom;

	shared int p = 0;
	import concurrency.scheduler : ManualTimeWorker;

	auto worker = new shared ManualTimeWorker();

	auto sampler =
		7.msecs.intervalStream().scan((int acc) => acc + 1, 0)
		 .sample(3.msecs.intervalStream()).take(3).collect((int i) shared {
			 p.atomicOp!"+="(i);
		 }).withScheduler(worker.getScheduler);

	auto driver = justFrom(() shared {
		worker.advance(3.msecs);
		p.atomicLoad.should == 0;
		worker.timeUntilNextEvent().should == 3.msecs.nullable;

		worker.advance(3.msecs);
		p.atomicLoad.should == 0;
		worker.timeUntilNextEvent().should == 1.msecs.nullable;

		worker.advance(1.msecs);
		p.atomicLoad.should == 0;
		worker.timeUntilNextEvent().should == 2.msecs.nullable;

		worker.advance(2.msecs);
		p.atomicLoad.should == 1;
		worker.timeUntilNextEvent().should == 3.msecs.nullable;

		worker.advance(3.msecs);
		p.atomicLoad.should == 1;
		worker.timeUntilNextEvent().should == 2.msecs.nullable;

		worker.advance(2.msecs);
		p.atomicLoad.should == 1;
		worker.timeUntilNextEvent().should == 1.msecs.nullable;

		worker.advance(1.msecs);
		p.atomicLoad.should == 3;
		worker.timeUntilNextEvent().should == 3.msecs.nullable;

		worker.advance(3.msecs);
		p.atomicLoad.should == 3;
		worker.timeUntilNextEvent().should == 3.msecs.nullable;

		worker.advance(3.msecs);
		p.atomicLoad.should == 6;
		worker.timeUntilNextEvent().isNull.should == true;
	});

	whenAll(sampler, driver).syncWait().assumeOk;

	p.should == 6;
}

@("sharedStream") @safe
unittest {
	import concurrency.operations : then, race;

	auto source = sharedStream!int;

	shared int p = 0;

	auto emitter = ThreadSender().then(() shared {
		source.emit(6);
		source.emit(12);
	});
	auto collector = source.collect((int t) shared {
		p.atomicOp!"+="(t);
	});

	race(collector, emitter).syncWait().assumeOk;

	p.atomicLoad.should == 18;
}

@("throttling.throttleLast") @safe
unittest {
	import core.time;
	import concurrency.scheduler : ManualTimeWorker;
	import concurrency.operations : withScheduler, whenAll;
	import concurrency.sender : justFrom;

	shared int p = 0;
	auto worker = new shared ManualTimeWorker();

	auto throttled = 1.msecs.intervalStream(true).scan((int acc) => acc + 1, 0)
	                  .throttleLast(3.msecs).take(4).collect((int i) shared {
		                  p.atomicOp!"+="(i);
	                  }).withScheduler(worker.getScheduler);

	auto driver = justFrom(() shared {
		p.atomicLoad.should == 0;
		worker.timeUntilNextEvent().should == 1.msecs.nullable;

		foreach (expected; [0, 0, 3, 3, 3, 9, 9, 9, 18, 18, 18, 30]) {
			worker.advance(1.msecs);
			p.atomicLoad.should == expected;
		}

		worker.timeUntilNextEvent().isNull.should == true;
	});

	whenAll(throttled, driver).syncWait().assumeOk;

	p.atomicLoad.should == 30;
}

@("throttling.throttleLast.arrayStream") @safe
unittest {
	import core.time;

	shared int p = 0;

	[1, 2, 3].arrayStream().throttleLast(30.msecs).collect((int i) shared {
		p.atomicOp!"+="(i);
	}).syncWait().assumeOk;

	p.atomicLoad.should == 3;
}

@("throttling.throttleLast.exception") @safe
unittest {
	import core.time;

	1.msecs.intervalStream().throttleLast(10.msecs).collect(() shared {
		throw new Exception("Bla");
	}).syncWait.assumeOk.shouldThrowWithMessage("Bla");
}

@("throttling.throttleLast.thread.arrayStream") @safe
unittest {
	import core.time;

	shared int p = 0;

	[1, 2, 3].arrayStream().via(ThreadSender()).throttleLast(30.msecs)
	         .collect((int i) shared {
		         p.atomicOp!"+="(i);
	         }).syncWait().assumeOk;

	p.atomicLoad.should == 3;
}

@("throttling.throttleLast.thread.exception") @safe
unittest {
	import core.time;

	1.msecs.intervalStream().via(ThreadSender()).throttleLast(10.msecs)
	 .collect(() shared {
		 throw new Exception("Bla");
	 }).syncWait.assumeOk.shouldThrowWithMessage("Bla");
}

@("throttling.throttleFirst") @safe
unittest {
	import core.time;
	import concurrency.scheduler : ManualTimeWorker;
	import concurrency.operations : withScheduler, whenAll;
	import concurrency.sender : justFrom;

	shared int p = 0;
	auto worker = new shared ManualTimeWorker();

	auto throttled = 1.msecs.intervalStream().scan((int acc) => acc + 1, 0)
	                  .throttleFirst(3.msecs).take(2).collect((int i) shared {
		                  p.atomicOp!"+="(i);
	                  }).withScheduler(worker.getScheduler);

	auto driver = justFrom(() shared {
		p.atomicLoad.should == 0;

		worker.advance(1.msecs);
		p.atomicLoad.should == 1;

		worker.advance(1.msecs);
		p.atomicLoad.should == 1;

		worker.advance(1.msecs);
		p.atomicLoad.should == 1;

		worker.advance(1.msecs);
		p.atomicLoad.should == 5;

		worker.timeUntilNextEvent().isNull.should == true;
	});
	whenAll(throttled, driver).syncWait().assumeOk;

	p.should == 5;
}

@("throttling.debounce") @safe
unittest {
	import core.time;
	import concurrency.scheduler : ManualTimeWorker;
	import concurrency.operations : withScheduler, whenAll;
	import concurrency.sender : justFrom;

	shared int p = 0;
	auto worker = new shared ManualTimeWorker();
	auto source = sharedStream!int;

	auto throttled = source.debounce(3.msecs).take(2).collect((int i) shared {
		p.atomicOp!"+="(i);
	}).withScheduler(worker.getScheduler);

	auto driver = justFrom(() shared {
		source.emit(1);
		p.atomicLoad.should == 0;
		worker.timeUntilNextEvent().should == 3.msecs.nullable;

		worker.advance(3.msecs);
		p.atomicLoad.should == 1;

		source.emit(2);
		p.atomicLoad.should == 1;
		worker.timeUntilNextEvent().should == 3.msecs.nullable;

		source.emit(3);
		p.atomicLoad.should == 1;
		worker.timeUntilNextEvent().should == 3.msecs.nullable;

		worker.advance(1.msecs);
		p.atomicLoad.should == 1;
		worker.timeUntilNextEvent().should == 2.msecs.nullable;

		source.emit(4);
		p.atomicLoad.should == 1;
		worker.timeUntilNextEvent().should == 3.msecs.nullable;

		worker.advance(3.msecs);
		p.atomicLoad.should == 5;

		worker.timeUntilNextEvent().isNull.should == true;
	});
	whenAll(throttled, driver).syncWait().assumeOk;

	p.should == 5;
}

@("slide.basic") @safe
unittest {
	[1, 2, 3, 4, 5, 6, 7].arrayStream.slide(3).transform((int[] a) => a.dup)
		                     .toList.syncWait.value.should
		== [[1, 2, 3], [2, 3, 4], [3, 4, 5], [4, 5, 6], [5, 6, 7]];

	[1, 2].arrayStream.slide(3).toList.syncWait.value.length.should == 0;
}

@("slide.step") @safe
unittest {
	[1, 2, 3, 4, 5, 6, 7].arrayStream.slide(3, 2).transform((int[] a) => a.dup)
		                     .toList.syncWait.value.should
		== [[1, 2, 3], [3, 4, 5], [5, 6, 7]];

	[1, 2].arrayStream.slide(2, 2).transform((int[] a) => a.dup).toList.syncWait
	      .value.should == [[1, 2]];

	[1, 2, 3, 4, 5, 6, 7].arrayStream.slide(2, 2).transform((int[] a) => a.dup)
		                     .toList.syncWait.value.should
		== [[1, 2], [3, 4], [5, 6]];

	[1, 2, 3, 4, 5, 6, 7].arrayStream.slide(2, 3).transform((int[] a) => a.dup)
	                     .toList.syncWait.value.should == [[1, 2], [4, 5]];

	[1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
		.arrayStream.slide(2, 4).transform((int[] a) => a.dup).toList.syncWait
		.value.should == [[1, 2], [5, 6], [9, 10]];
}

@("toList.arrayStream") @safe
unittest {
	[1, 2, 3].arrayStream.toList.syncWait.value.should == [1, 2, 3];
}

@("toList.arrayStream.whenAll") @safe
unittest {
	import concurrency.operations : withScheduler, whenAll;
	import std.typecons : tuple;
	auto s1 = [1, 2, 3].arrayStream.toList;
	auto s2 = [2, 3, 4].arrayStream.toList;
	whenAll(s1, s2).syncWait.value.should == tuple([1, 2, 3], [2, 3, 4]);
}

@("filter")
unittest {
	[1, 2, 3, 4].arrayStream.filter((int i) => i % 2 == 0).toList.syncWait.value
	            .should == [2, 4];
}

@("cycle")
unittest {
	"-/|\\".cycleStream().take(6).toList.syncWait.value.should == "-/|\\-/";
}

@("flatmap.concat.just") @safe
unittest {
	import concurrency.sender : just;

	[1, 2, 3].arrayStream.flatMapConcat((int i) => just(i)).toList.syncWait
	         .value.should == [1, 2, 3];
}

@("flatmap.concat.thread") @safe
unittest {
	import concurrency.sender : just;
	import concurrency.operations : via;

	[1, 2, 3].arrayStream.flatMapConcat((int i) => just(i).via(ThreadSender()))
	         .toList.syncWait.value.should == [1, 2, 3];
}

@("flatmap.concat.error") @safe
unittest {
	import concurrency.sender : just, ErrorSender;
	import concurrency.operations : via;

	[1, 2, 3].arrayStream.flatMapConcat((int i) => ErrorSender())
	         .collect(() shared {}).syncWait.assumeOk.shouldThrow();
}

@("flatmap.concat.thread.on.thread") @safe
unittest {
	import concurrency.sender : just;
	import concurrency.operations : via;

	[1, 2, 3].arrayStream.flatMapConcat((int i) => just(i).via(ThreadSender()))
	         .toList.via(ThreadSender()).syncWait.value.should == [1, 2, 3];
}

@("flatmap.latest.just") @safe
unittest {
	import concurrency.sender : just;

	[1, 2, 3].arrayStream.flatMapLatest((int i) => just(i)).toList.syncWait
	         .value.should == [1, 2, 3];
}

@("flatmap.latest.delay") @safe
unittest {
	import concurrency.sender : just, delay;
	import concurrency.operations : via, onTermination;
	import core.time;

	import std.stdio;
	[1, 2, 3].arrayStream.flatMapLatest((int i) => just(i).via(delay(50.msecs)))
	         .toList.via(ThreadSender()).syncWait.value.should == [3];
}

@("flatmap.latest.error") @safe
unittest {
	import concurrency.sender : just, ErrorSender;
	import concurrency.operations : via;

	[1, 2, 3].arrayStream.flatMapLatest((int i) => ErrorSender())
	         .collect(() shared {}).syncWait.assumeOk.shouldThrow();
}

@("flatmap.latest.justfrom.exception") @safe
unittest {
	import concurrency.sender : justFrom;

	import core.time;

	1.msecs.intervalStream().flatMapLatest(() => justFrom(() {
		throw new Exception("oops");
	})).collect(() shared {}).syncWait.assumeOk.shouldThrow();
}

@("flatmap.latest.exception") @safe
unittest {
	import concurrency.sender : VoidSender;

	import core.time;

	1.msecs.intervalStream().flatMapLatest(function VoidSender() {
		throw new Exception("oops");
	}).collect(() shared {}).syncWait.assumeOk.shouldThrow();
}

@("flatmap.latest.intervalStream.overlap.delay") @safe
unittest {
	import concurrency.sender : delay;
	import core.time;

	1.msecs.intervalStream().take(2).flatMapLatest(() => 2.msecs.delay())
	 .collect(() shared {}).syncWait.assumeOk();
}

@("flatmap.latest.intervalStream.intervalStream.take") @safe
unittest {
	import concurrency.sender : delay;
	import concurrency.scheduler : ManualTimeWorker;
	import concurrency.operations : withScheduler, whenAll;
	import concurrency.sender : justFrom;
	import core.time;

	import core.atomic;
	shared int p;

	auto worker = new shared ManualTimeWorker();
	auto sender = 5.msecs.intervalStream().take(2).flatMapLatest(() shared {
		return 1.msecs.intervalStream(true).take(5).collect(() shared {
			p.atomicOp!"+="(1);
		});
	}).collect(() shared {}).withScheduler(worker.getScheduler);

	auto driver = justFrom(() shared {
		p.atomicLoad.should == 0;
		worker.timeUntilNextEvent().should == 5.msecs.nullable;

		worker.advance(5.msecs);
		p.atomicLoad.should == 1;
		worker.timeUntilNextEvent().should == 1.msecs.nullable;

		worker.advance(1.msecs);
		p.atomicLoad.should == 2;

		worker.advance(1.msecs);
		p.atomicLoad.should == 3;

		worker.advance(1.msecs);
		p.atomicLoad.should == 4;

		worker.advance(1.msecs);
		p.atomicLoad.should == 5;

		worker.advance(1.msecs);
		p.atomicLoad.should == 6;

		worker.advance(1.msecs);
		p.atomicLoad.should == 7;

		worker.advance(1.msecs);
		p.atomicLoad.should == 8;

		worker.advance(1.msecs);
		p.atomicLoad.should == 9;

		worker.advance(1.msecs);
		p.atomicLoad.should == 10;

		worker.timeUntilNextEvent().isNull.should == true;
	});
	whenAll(sender, driver).syncWait().assumeOk;

	p.atomicLoad.should == 10;
}

@("flatmap.latest.intervalStream.intervalStream.sample") @safe
unittest {
	import concurrency.sender : delay;
	import concurrency.scheduler : ManualTimeWorker;
	import concurrency.operations : withScheduler, whenAll;
	import concurrency.sender : justFrom;
	import core.time;

	import core.atomic;
	shared int p;

	auto worker = new shared ManualTimeWorker();
	auto sender = 5.msecs.intervalStream().take(2).flatMapLatest(() shared {
		return 1
			.msecs.intervalStream(true).scan((int i) => i + 1, 0)
			.sample(2.msecs.intervalStream()).take(10).collect((int i) shared {
				p.atomicOp!"+="(1);
			});
	}).collect(() shared {}).withScheduler(worker.getScheduler);

	auto driver = justFrom(() shared {
		p.atomicLoad.should == 0;
		worker.timeUntilNextEvent().should == 5.msecs.nullable;

		worker.advance(5.msecs);
		p.atomicLoad.should == 0;
		worker.timeUntilNextEvent().should == 1.msecs.nullable;

		worker.advance(1.msecs);
		p.atomicLoad.should == 0;

		worker.advance(1.msecs);
		p.atomicLoad.should == 1;

		worker.advance(1.msecs);
		p.atomicLoad.should == 1;

		worker.advance(1.msecs);
		p.atomicLoad.should == 2;

		worker.advance(1.msecs);
		p.atomicLoad.should == 2;

		worker.advance(2.msecs);
		p.atomicLoad.should == 3;

		worker.advance(2.msecs);
		p.atomicLoad.should == 4;

		worker.advance(2.msecs);
		p.atomicLoad.should == 5;

		worker.advance(2.msecs);
		p.atomicLoad.should == 6;

		worker.advance(2.msecs);
		p.atomicLoad.should == 7;

		worker.advance(2.msecs);
		p.atomicLoad.should == 8;

		worker.advance(2.msecs);
		p.atomicLoad.should == 9;

		worker.advance(2.msecs);
		p.atomicLoad.should == 10;

		worker.advance(2.msecs);
		p.atomicLoad.should == 11;

		worker.advance(2.msecs);
		p.atomicLoad.should == 12;

		worker.timeUntilNextEvent().isNull.should == true;
	});
	whenAll(sender, driver).syncWait().assumeOk;

	p.atomicLoad.should == 12;
}

@("deferStream.function") @safe
unittest {
	import concurrency.stream.defer;
	static auto getSender() @safe {
		import concurrency.sender;
		return just(1);
	}

	deferStream(&getSender).take(3).toList().syncWait().value.should
		== [1, 1, 1];
}

@("deferStream.callable") @safe
unittest {
	import concurrency.stream.defer;
	static struct S {
		auto opCall() shared @safe {
			import concurrency.sender;
			return just(1);
		}
	}

	shared S s;
	deferStream(s).take(3).toList().syncWait().value.should == [1, 1, 1];
}

@("cron.timeTillNextMinute.Always") @safe
unittest {
	import concurrency.stream.cron;
	import core.time;
	import std.datetime : SysTime, DateTime;

	auto spec = Always().Spec;
	spec.timeTillNextMinute(SysTime(DateTime(2018, 1, 1, 10, 30, 0))).should
		== 1.minutes;
	spec.timeTillNextMinute(SysTime(DateTime(2018, 1, 1, 10, 30, 59))).should
		== 1.seconds;
}

@("cron.timeTillNextMinute.Exact") @safe
unittest {
	import concurrency.stream.cron;
	import core.time;
	import std.datetime : SysTime, DateTime;

	auto spec = Exact(5).Spec;
	spec.timeTillNextMinute(SysTime(DateTime(2018, 1, 1, 10, 30, 0))).should
		== 35.minutes;
	spec.timeTillNextMinute(SysTime(DateTime(2018, 1, 1, 10, 30, 59))).should
		== 34.minutes + 1.seconds;
	spec.timeTillNextMinute(SysTime(DateTime(2018, 1, 1, 10, 0, 0))).should
		== 5.minutes;
	spec.timeTillNextMinute(SysTime(DateTime(2018, 1, 1, 10, 4, 59))).should
		== 1.seconds;
}

@("cron.timeTillNextMinute.Every.basic") @safe
unittest {
	import concurrency.stream.cron;
	import core.time;
	import std.datetime : SysTime, DateTime;

	auto spec = Every(5).Spec;
	spec.timeTillNextMinute(SysTime(DateTime(2018, 1, 1, 10, 30, 0))).should
		== 5.minutes;
	spec.timeTillNextMinute(SysTime(DateTime(2018, 1, 1, 10, 30, 59))).should
		== 4.minutes + 1.seconds;
	spec.timeTillNextMinute(SysTime(DateTime(2018, 1, 1, 10, 0, 0))).should
		== 5.minutes;
	spec.timeTillNextMinute(SysTime(DateTime(2018, 1, 1, 10, 4, 59))).should
		== 1.seconds;
}

@("cron.timeTillNextMinute.Every.offset") @safe
unittest {
	import concurrency.stream.cron;
	import core.time;
	import std.datetime : SysTime, DateTime;

	auto spec = Every(5, 3).Spec;
	spec.timeTillNextMinute(SysTime(DateTime(2018, 1, 1, 10, 30, 0))).should
		== 3.minutes;
	spec.timeTillNextMinute(SysTime(DateTime(2018, 1, 1, 10, 30, 59))).should
		== 2.minutes + 1.seconds;
	spec.timeTillNextMinute(SysTime(DateTime(2018, 1, 1, 10, 0, 0))).should
		== 3.minutes;
	spec.timeTillNextMinute(SysTime(DateTime(2018, 1, 1, 10, 4, 59))).should
		== 3.minutes + 1.seconds;
}

@("cron.timeTillNextMinute.Each") @safe
unittest {
	import concurrency.stream.cron;
	import core.time;
	import std.datetime : SysTime, DateTime;

	auto spec = Each([1, 15, 19, 44]).Spec;
	spec.timeTillNextMinute(SysTime(DateTime(2018, 1, 1, 10, 30, 0))).should
		== 14.minutes;
	spec.timeTillNextMinute(SysTime(DateTime(2018, 1, 1, 10, 30, 59))).should
		== 13.minutes + 1.seconds;
	spec.timeTillNextMinute(SysTime(DateTime(2018, 1, 1, 10, 0, 0))).should
		== 1.minutes;
	spec.timeTillNextMinute(SysTime(DateTime(2018, 1, 1, 10, 4, 59))).should
		== 10.minutes + 1.seconds;
}

@("cron.timeTillNextTrigger.Always") @safe
unittest {
	import concurrency.stream.cron;
	import core.time;
	import std.datetime : SysTime, DateTime;

	auto spec = CronSpec(Spec(Always()), Spec(Always()));
	spec.timeTillNextTrigger(SysTime(DateTime(2018, 1, 1, 10, 30, 0))).should
		== 1.minutes;
	spec.timeTillNextTrigger(SysTime(DateTime(2018, 1, 1, 10, 30, 59))).should
		== 1.seconds;
}

@("cron.timeTillNextTrigger.5.over.every.hour") @safe
unittest {
	import concurrency.stream.cron;
	import core.time;
	import std.datetime : SysTime, DateTime;

	auto spec = CronSpec(Spec(Always()), Spec(Exact(5)));
	spec.timeTillNextTrigger(SysTime(DateTime(2018, 1, 1, 10, 30, 0))).should
		== 35.minutes;
	spec.timeTillNextTrigger(SysTime(DateTime(2018, 1, 1, 10, 30, 59))).should
		== 34.minutes + 1.seconds;
}

@("cron.timeTillNextTrigger.5.over.5.hour") @safe
unittest {
	import concurrency.stream.cron;
	import core.time;
	import std.datetime : SysTime, DateTime;
	import std.datetime.timezone : UTC;

	auto spec = CronSpec(Spec(Exact(5)), Spec(Exact(5)));
	spec.timeTillNextTrigger(SysTime(DateTime(2018, 1, 1, 5, 5, 0), UTC()))
	    .should == 24.hours;
	spec.timeTillNextTrigger(SysTime(DateTime(2018, 1, 1, 10, 30, 0), UTC()))
	    .should == 18.hours + 35.minutes;
	spec.timeTillNextTrigger(SysTime(DateTime(2018, 1, 1, 10, 30, 59), UTC()))
	    .should == 18.hours + 34.minutes + 1.seconds;
}

@("cron.timeTillNextTrigger.5.over.every.2.hours") @safe
unittest {
	import concurrency.stream.cron;
	import core.time;
	import std.datetime : SysTime, DateTime;
	import std.datetime.timezone : UTC;

	auto spec = CronSpec(Spec(Every(2)), Spec(Exact(5)));
	spec.timeTillNextTrigger(SysTime(DateTime(2018, 1, 1, 6, 5, 0), UTC()))
	    .should == 2.hours;
	spec.timeTillNextTrigger(SysTime(DateTime(2018, 1, 1, 5, 5, 0), UTC()))
	    .should == 1.hours;
	spec.timeTillNextTrigger(SysTime(DateTime(2018, 1, 1, 10, 30, 0), UTC()))
	    .should == 1.hours + 35.minutes;
	spec.timeTillNextTrigger(SysTime(DateTime(2018, 1, 1, 10, 30, 59), UTC()))
	    .should == 1.hours + 34.minutes + 1.seconds;
}

@("cron.timeTillNextTrigger.every.5.over.every.2.hours") @safe
unittest {
	import concurrency.stream.cron;
	import core.time;
	import std.datetime : SysTime, DateTime;
	import std.datetime.timezone : UTC;

	auto spec = CronSpec(Spec(Every(2)), Spec(Every(5)));
	spec.timeTillNextTrigger(SysTime(DateTime(2018, 1, 1, 6, 5, 0), UTC()))
	    .should == 5.minutes;
	spec.timeTillNextTrigger(SysTime(DateTime(2018, 1, 1, 5, 5, 0), UTC()))
	    .should == 1.hours;
	spec.timeTillNextTrigger(SysTime(DateTime(2018, 1, 1, 10, 30, 0), UTC()))
	    .should == 5.minutes;
	spec.timeTillNextTrigger(SysTime(DateTime(2018, 1, 1, 10, 30, 59), UTC()))
	    .should == 4.minutes + 1.seconds;
	spec.timeTillNextTrigger(SysTime(DateTime(2018, 1, 1, 10, 59, 59), UTC()))
	    .should == 1.hours + 5.minutes + 1.seconds;
}
