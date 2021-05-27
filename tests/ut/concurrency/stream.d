module ut.concurrency.stream;

import concurrency.stream;
import concurrency;
import unit_threaded;
import concurrency.stoptoken;
import core.atomic;

// TODO: it would be good if we can get the Sender .collect returns to be scoped if the delegates are.

@("arrayStream")
@safe unittest {
  shared int p = 0;
  [1,2,3].arrayStream().collect((int t) shared { p.atomicOp!"+="(t); }).sync_wait();
  p.should == 6;
}

@("timerStream")
@safe unittest {
  import concurrency.operations : withStopSource, whenAll, via;
  import concurrency.thread : ThreadSender;
  import core.time : msecs;
  shared int s = 0, f = 0;
  auto source = new shared StopSource();
  auto slow = 10.msecs.intervalStream().collect(() shared { s.atomicOp!"+="(1); source.stop(); }).withStopSource(source).via(ThreadSender());
  auto fast = 3.msecs.intervalStream().collect(() shared { f.atomicOp!"+="(1); });
  whenAll(slow, fast).sync_wait(source);
  s.should == 1;
  f.shouldBeGreaterThan(1);
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
    .withStopSource(source).sync_wait();
  g.should == 15;
};

@("infiniteStream.take")
@safe unittest {
  shared int g = 0;
  infiniteStream(4).take(5).collect((int n) shared { g.atomicOp!"+="(n); }).sync_wait().should == true;
  g.should == 20;
}

@("iotaStream")
@safe unittest {
  import concurrency.stoptoken;
  shared int g = 0;
  iotaStream(0, 5).collect((int n) shared { g.atomicOp!"+="(n); }).sync_wait();
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
  Loop(0,4).loopStream!size_t.collect((size_t n) shared { g.atomicOp!"+="(n); }).sync_wait();
  g.should == 6;
}

@("startStop")
unittest {
  static struct StartStop {
    import core.thread : Thread;
    import core.atomic : atomicStore, atomicLoad;
    import concurrency.utils : closure;
    shared bool running;
    Thread t;
    void start(DG, StopToken)(DG emit, StopToken stopToken) @trusted {
      running = true;
      t = new Thread(cast(void delegate())closure((shared bool* running, DG emit) @trusted {
            int i = 1;
            while((*running).atomicLoad()) {
              emit(i++);
            }
          }, &running, emit)).start();
    }
    void stop() {
      running.atomicStore(false);
      t.join();
    }
  }
  shared int p;

  auto stream = StartStop().startStopStream!int;
  stream.take(2).collect((int i) shared { p.atomicOp!"+="(i); }).sync_wait().should == true;

  p.should == 3;
}

@("toStreamObject")
@safe unittest {
  import core.atomic : atomicOp;

  static StreamObjectBase!int getStream() {
    return [1,2,3].arrayStream().toStreamObject();
  }
  shared int p;

  getStream().collect((int i) @safe shared { p.atomicOp!"+="(i); }).sync_wait();

  p.should == 6;
}


@("toStreamObject.take")
@safe unittest {
  static StreamObjectBase!int getStream() {
    return [1,2,3].arrayStream().toStreamObject();
  }
  shared int p;

  getStream().take(2).collect((int i) shared { p.atomicOp!"+="(i); }).sync_wait().should == true;

  p.should == 3;
}

@("toStreamObject.void")
@safe unittest {
  import core.time : msecs;
  shared bool p = false;

  1.msecs.intervalStream().toStreamObject().take(1).collect(() shared { p = true; }).sync_wait().should == true;

  p.should == true;
}

@("transform.int.double")
@safe unittest {
  shared int p = 0;
  [1,2,3].arrayStream().transform((int i) => i * 3).collect((int t) shared { p.atomicOp!"+="(t); }).sync_wait();
  p.should == 18;
}

@("transform.int.bool")
@safe unittest {
  shared int p = 0;
  [1,2,3].arrayStream().transform((int i) => i % 2 == 0).collect((bool t) shared { if (t) p.atomicOp!"+="(1); }).sync_wait();
  p.should == 1;
}
@("take.enough")
@safe unittest {
  shared int p = 0;

  [1,2,3].arrayStream.take(2).collect((int i) shared { p.atomicOp!"+="(i); }).sync_wait.should == true;
  p.should == 3;
}

@("take.too-few")
@safe unittest {
  shared int p = 0;

  [1,2,3].arrayStream.take(4).collect((int i) shared { p.atomicOp!"+="(i); }).sync_wait.should == true;
  p.should == 6;
}

@("take.donestream")
@safe unittest {
  doneStream().take(1).collect(()shared{}).sync_wait().should == false;
}

@("take.errorstream")
@safe unittest {
  errorStream(new Exception("Too bad")).take(1).collect(()shared{}).sync_wait().shouldThrowWithMessage("Too bad");
}

