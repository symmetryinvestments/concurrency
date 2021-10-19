module ut.concurrency.stream;

import concurrency.stream;
import concurrency;
import unit_threaded;
import concurrency.stoptoken;
import core.atomic;
import concurrency.thread : ThreadSender;

// TODO: it would be good if we can get the Sender .collect returns to be scoped if the delegates are.

@("arrayStream")
@safe unittest {
  shared int p = 0;
  [1,2,3].arrayStream().collect((int t) shared { p.atomicOp!"+="(t); }).syncWait().isOk.should == true;
  p.should == 6;
}

@("intervalStream")
@safe unittest {
  import core.time;
  import concurrency.operations : withScheduler, whenAll;
  import concurrency.sender : justFrom;
  import concurrency.scheduler : ManualTimeWorker;

  auto worker = new shared ManualTimeWorker();
  auto interval = 5.msecs.intervalStream()
    .take(2)
    .collect(() shared {})
    .withScheduler(worker.getScheduler);

  auto driver = justFrom(() shared {
      worker.timeUntilNextEvent().should == 5.msecs;
      worker.advance(5.msecs);

      worker.timeUntilNextEvent().should == 5.msecs;
      worker.advance(5.msecs);

      worker.timeUntilNextEvent().should == null;
    });

  whenAll(interval, driver).syncWait().isOk.should == true;
}


@("infiniteStream.stop")
@safe unittest {
  import concurrency.operations : withStopSource;
  shared int g = 0;
  auto source = new shared StopSource();
  infiniteStream(5).collect((int n) shared {
      if (g < 14)
        g.atomicOp!"+="(n);
      else
        source.stop();
    })
    .withStopSource(source).syncWait.isCancelled.should == true;
  g.should == 15;
};

@("infiniteStream.take")
@safe unittest {
  shared int g = 0;
  infiniteStream(4).take(5).collect((int n) shared { g.atomicOp!"+="(n); }).syncWait().isOk.should == true;
  g.should == 20;
}

@("iotaStream")
@safe unittest {
  import concurrency.stoptoken;
  shared int g = 0;
  iotaStream(0, 5).collect((int n) shared { g.atomicOp!"+="(n); }).syncWait().isOk.should == true;
  g.should == 10;
}

@("loopStream")
@safe unittest {
  struct Loop {
    size_t b,e;
    void loop(DG, StopToken)(DG emit, StopToken stopToken) {
      foreach(i; b..e)
        emit(i);
    }
  }
  shared int g = 0;
  Loop(0,4).loopStream!size_t.collect((size_t n) shared { g.atomicOp!"+="(n); }).syncWait().isOk.should == true;
  g.should == 6;
}

@("toStreamObject")
@safe unittest {
  import core.atomic : atomicOp;

  static StreamObjectBase!int getStream() {
    return [1,2,3].arrayStream().toStreamObject();
  }
  shared int p;

  getStream().collect((int i) @safe shared { p.atomicOp!"+="(i); }).syncWait().isOk.should == true;

  p.should == 6;
}


@("toStreamObject.take")
@safe unittest {
  static StreamObjectBase!int getStream() {
    return [1,2,3].arrayStream().toStreamObject();
  }
  shared int p;

  getStream().take(2).collect((int i) shared { p.atomicOp!"+="(i); }).syncWait().isOk.should == true;

  p.should == 3;
}

@("toStreamObject.void")
@safe unittest {
  import core.time : msecs;
  shared bool p = false;

  1.msecs.intervalStream().toStreamObject().take(1).collect(() shared { p = true; }).syncWait().isOk.should == true;

  p.should == true;
}

@("transform.int.double")
@safe unittest {
  shared int p = 0;
  [1,2,3].arrayStream().transform((int i) => i * 3).collect((int t) shared { p.atomicOp!"+="(t); }).syncWait().isOk.should == true;
  p.should == 18;
}

@("transform.int.bool")
@safe unittest {
  shared int p = 0;
  [1,2,3].arrayStream().transform((int i) => i % 2 == 0).collect((bool t) shared { if (t) p.atomicOp!"+="(1); }).syncWait().isOk.should == true;
  p.should == 1;
}

@("scan")
@safe unittest {
  shared int p = 0;
  [1,2,3].arrayStream().scan((int acc, int i) => acc += i, 0).collect((int t) shared { p.atomicOp!"+="(t); }).syncWait().isOk.should == true;
  p.should == 10;
}

@("scan.void-value")
@safe unittest {
  import core.time;
  shared int p = 0;
  5.msecs.intervalStream.scan((int acc) => acc += 1, 0).take(3).collect((int t) shared { p.atomicOp!"+="(t); }).syncWait().isOk.should == true;
  p.should == 6;
}

@("take.enough")
@safe unittest {
  shared int p = 0;

  [1,2,3].arrayStream.take(2).collect((int i) shared { p.atomicOp!"+="(i); }).syncWait.isOk.should == true;
  p.should == 3;
}

@("take.too-few")
@safe unittest {
  shared int p = 0;

  [1,2,3].arrayStream.take(4).collect((int i) shared { p.atomicOp!"+="(i); }).syncWait.isOk.should == true;
  p.should == 6;
}

@("take.donestream")
@safe unittest {
  doneStream().take(1).collect(()shared{}).syncWait.isCancelled.should == true;
}

@("take.errorstream")
@safe unittest {
  errorStream(new Exception("Too bad")).take(1).collect(()shared{}).syncWait.assumeOk.shouldThrowWithMessage("Too bad");
}

@("sample.trigger.stop")
@safe unittest {
  import core.time;
  auto sampler = 7.msecs.intervalStream()
    .scan((int acc) => acc+1, 0)
    .sample(10.msecs.intervalStream().take(3))
    .collect((int i) shared {})
    .syncWait().isOk.should == true;
}

@("sample.slower")
@safe unittest {
  import core.time;
  import concurrency.operations : withScheduler, whenAll;
  import concurrency.sender : justFrom;

  shared int p = 0;
  import concurrency.scheduler : ManualTimeWorker;

  auto worker = new shared ManualTimeWorker();

  auto sampler = 7.msecs
    .intervalStream()
    .scan((int acc) => acc+1, 0)
    .sample(10.msecs.intervalStream())
    .take(3)
    .collect((int i) shared { p.atomicOp!"+="(i); })
    .withScheduler(worker.getScheduler);

  auto driver = justFrom(() shared {
      worker.advance(7.msecs);
      p.atomicLoad.should == 0;
      worker.timeUntilNextEvent().should == 3.msecs;

      worker.advance(3.msecs);
      p.atomicLoad.should == 1;
      worker.timeUntilNextEvent().should == 4.msecs;

      worker.advance(4.msecs);
      p.atomicLoad.should == 1;
      worker.timeUntilNextEvent().should == 6.msecs;

      worker.advance(6.msecs);
      p.atomicLoad.should == 3;
      worker.timeUntilNextEvent().should == 1.msecs;

      worker.advance(1.msecs);
      p.atomicLoad.should == 3;
      worker.timeUntilNextEvent().should == 7.msecs;

      worker.advance(7.msecs);
      p.atomicLoad.should == 3;
      worker.timeUntilNextEvent().should == 2.msecs;

      worker.advance(2.msecs);
      p.atomicLoad.should == 7;
      worker.timeUntilNextEvent().should == null;
    });

  whenAll(sampler, driver).syncWait().isOk.should == true;

  p.should == 7;
}

@("sample.faster")
@safe unittest {
  import core.time;
  import concurrency.operations : withScheduler, whenAll;
  import concurrency.sender : justFrom;

  shared int p = 0;
  import concurrency.scheduler : ManualTimeWorker;

  auto worker = new shared ManualTimeWorker();

  auto sampler = 7.msecs
    .intervalStream()
    .scan((int acc) => acc+1, 0)
    .sample(3.msecs.intervalStream())
    .take(3)
    .collect((int i) shared { p.atomicOp!"+="(i); })
    .withScheduler(worker.getScheduler);

  auto driver = justFrom(() shared {
      worker.advance(3.msecs);
      p.atomicLoad.should == 0;
      worker.timeUntilNextEvent().should == 3.msecs;

      worker.advance(3.msecs);
      p.atomicLoad.should == 0;
      worker.timeUntilNextEvent().should == 1.msecs;

      worker.advance(1.msecs);
      p.atomicLoad.should == 0;
      worker.timeUntilNextEvent().should == 2.msecs;

      worker.advance(2.msecs);
      p.atomicLoad.should == 1;
      worker.timeUntilNextEvent().should == 3.msecs;

      worker.advance(3.msecs);
      p.atomicLoad.should == 1;
      worker.timeUntilNextEvent().should == 2.msecs;

      worker.advance(2.msecs);
      p.atomicLoad.should == 1;
      worker.timeUntilNextEvent().should == 1.msecs;

      worker.advance(1.msecs);
      p.atomicLoad.should == 3;
      worker.timeUntilNextEvent().should == 3.msecs;

      worker.advance(3.msecs);
      p.atomicLoad.should == 3;
      worker.timeUntilNextEvent().should == 3.msecs;

      worker.advance(3.msecs);
      // NOTE: normally `p` ought to be 6 since 3*7 msecs have already elapsed.
      // but due to the way slots work in the timingwheels implementation
      // timers that are added later are executed earlier.
      // see https://github.com/symmetryinvestments/concurrency/issues/35
      p.atomicLoad.should == 3;
      worker.timeUntilNextEvent().should == 3.msecs;

      worker.advance(3.msecs);
      p.atomicLoad.should == 6;
      worker.timeUntilNextEvent().should == null;
    });

  whenAll(sampler, driver).syncWait().assumeOk;

  p.should == 6;
}

@("sharedStream")
@safe unittest {
  import concurrency.operations : then, race;

  auto source = sharedStream!int;

  shared int p = 0;

  auto emitter = ThreadSender().then(() shared {
      source.emit(6);
      source.emit(12);
    });
  auto collector = source.collect((int t) shared { p.atomicOp!"+="(t); });

  race(collector, emitter).syncWait().isOk.should == true;

  p.atomicLoad.should == 18;
}

@("throttling.throttleLast")
@safe unittest {
  import core.time;

  shared int p = 0;

  1.msecs
    .intervalStream()
    .scan((int acc) => acc+1, 0)
    .throttleLast(3.msecs)
    .take(6)
    .collect((int i) shared { p.atomicOp!"+="(i); })
    .syncWait().isOk.should == true;

  p.atomicLoad.shouldBeGreaterThan(40);
}

@("throttling.throttleLast.arrayStream")
@safe unittest {
  import core.time;

  shared int p = 0;

  [1,2,3].arrayStream()
    .throttleLast(30.msecs)
    .collect((int i) shared { p.atomicOp!"+="(i); })
    .syncWait().isOk.should == true;

  p.atomicLoad.should == 3;
}

@("throttling.throttleLast.exception")
@safe unittest {
  import core.time;

  1.msecs
    .intervalStream()
    .throttleLast(10.msecs)
    .collect(() shared { throw new Exception("Bla"); })
    .syncWait.assumeOk.shouldThrowWithMessage("Bla");
}

@("throttling.throttleLast.thread")
@safe unittest {
  import core.time;

  shared int p = 0;

  1.msecs
    .intervalStream()
    .via(ThreadSender())
    .scan((int acc) => acc+1, 0)
    .throttleLast(3.msecs)
    .take(6)
    .collect((int i) shared { p.atomicOp!"+="(i); })
    .syncWait().isOk.should == true;

  p.atomicLoad.shouldBeGreaterThan(40);
}

@("throttling.throttleLast.thread.arrayStream")
@safe unittest {
  import core.time;

  shared int p = 0;

  [1,2,3].arrayStream()
    .via(ThreadSender())
    .throttleLast(30.msecs)
    .collect((int i) shared { p.atomicOp!"+="(i); })
    .syncWait().isOk.should == true;

  p.atomicLoad.should == 3;
}

@("throttling.throttleLast.thread.exception")
@safe unittest {
  import core.time;

  1.msecs
    .intervalStream()
    .via(ThreadSender())
    .throttleLast(10.msecs)
    .collect(() shared { throw new Exception("Bla"); })
    .syncWait.assumeOk.shouldThrowWithMessage("Bla");
}

@("throttling.throttleFirst")
@safe unittest {
  import core.time;
  import concurrency.scheduler : ManualTimeWorker;
  import concurrency.operations : withScheduler, whenAll;
  import concurrency.sender : justFrom;

  shared int p = 0;
  auto worker = new shared ManualTimeWorker();

  auto throttled = 1.msecs
    .intervalStream()
    .scan((int acc) => acc+1, 0)
    .throttleFirst(3.msecs)
    .take(2)
    .collect((int i) shared { p.atomicOp!"+="(i); })
    .withScheduler(worker.getScheduler);

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

      worker.timeUntilNextEvent().should == null;
    });
  whenAll(throttled, driver).syncWait().isOk.should == true;

  p.should == 5;
}

@("throttling.debounce")
@safe unittest {
  import core.time;
  import concurrency.scheduler : ManualTimeWorker;
  import concurrency.operations : withScheduler, whenAll;
  import concurrency.sender : justFrom;

  shared int p = 0;
  auto worker = new shared ManualTimeWorker();
  auto source = sharedStream!int;

  auto throttled = source
    .debounce(3.msecs)
    .take(2)
    .collect((int i) shared { p.atomicOp!"+="(i); })
    .withScheduler(worker.getScheduler);

  auto driver = justFrom(() shared {
      source.emit(1);
      p.atomicLoad.should == 0;
      worker.timeUntilNextEvent().should == 3.msecs;

      worker.advance(3.msecs);
      p.atomicLoad.should == 1;

      source.emit(2);
      p.atomicLoad.should == 1;
      worker.timeUntilNextEvent().should == 3.msecs;

      source.emit(3);
      p.atomicLoad.should == 1;
      worker.timeUntilNextEvent().should == 3.msecs;

      worker.advance(1.msecs);
      p.atomicLoad.should == 1;
      worker.timeUntilNextEvent().should == 2.msecs;

      source.emit(4);
      p.atomicLoad.should == 1;
      worker.timeUntilNextEvent().should == 3.msecs;

      worker.advance(3.msecs);
      p.atomicLoad.should == 5;

      worker.timeUntilNextEvent().should == null;
    });
  whenAll(throttled, driver).syncWait().isOk.should == true;

  p.should == 5;
}

@("slide")
@safe unittest {
  import std.stdio;
  import std.functional : toDelegate;
  import std.algorithm : sum;
  shared int p;

  [1,2,3,4,5,6,7].arrayStream
    .slide(3)
    .collect((int[] a) @safe shared { p.atomicOp!"+="(a.sum); })
    .syncWait.isOk.should == true;

  p.should == 60;

  [1,2].arrayStream
    .slide(3)
    .collect((int[] a) @safe shared { p.atomicOp!"+="(a.sum); })
    .syncWait.isOk.should == true;

  p.should == 60;
}

@("slide.step")
@safe unittest {
  import std.stdio;
  import std.functional : toDelegate;
  import std.algorithm : sum;
  shared int p;

  [1,2,3,4,5,6,7].arrayStream
    .slide(3, 2)
    .collect((int[] a) @safe shared { p.atomicOp!"+="(a.sum); })
    .syncWait.isOk.should == true;

  p.should == 36;

  [1,2].arrayStream
    .slide(2, 2)
    .collect((int[] a) @safe shared { p.atomicOp!"+="(a.sum); })
    .syncWait.isOk.should == true;

  p.should == 39;
}

@("toList.arrayStream")
@safe unittest {
  [1,2,3].arrayStream.toList.syncWait.value.should == [1,2,3];
}

@("toList.arrayStream.whenAll")
@safe unittest {
  import concurrency.operations : withScheduler, whenAll;
  import std.typecons : tuple;
  auto s1 = [1,2,3].arrayStream.toList;
  auto s2 = [2,3,4].arrayStream.toList;
  whenAll(s1,s2).syncWait.value.should == tuple([1,2,3],[2,3,4]);
}

@("filter")
unittest {
  [1,2,3,4].arrayStream
    .filter((int i) => i % 2 == 0)
    .toList
    .syncWait
    .value.should == [2,4];
}
