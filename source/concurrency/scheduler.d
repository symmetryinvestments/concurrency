module concurrency.scheduler;

import concurrency.sender : SenderObjectBase;
import core.time : Duration;
import concepts;
import mir.algebraic : Nullable, nullable;

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

enum TimerTrigger {
  trigger,
  cancel
}

alias TimerDelegate = void delegate(TimerTrigger) shared @safe;

struct Timer {
  TimerDelegate dg;
  ulong id_;
  ulong id() { return id_; }
}

auto localThreadScheduler() {
  import concurrency.thread : LocalThreadWorker, getLocalThreadExecutor;
  return SchedulerAdapter!LocalThreadWorker(LocalThreadWorker(getLocalThreadExecutor));
}

struct SchedulerAdapter(Worker) {
  import concurrency.receiver : setValueOrError;
  import concurrency.executor : VoidDelegate;
  import core.time : Duration;
  Worker worker;
  auto schedule() {
    static struct ScheduleOp(Receiver) {
      Worker worker;
      Receiver receiver;
      void start() @trusted nothrow {
        try {
          worker.schedule(cast(VoidDelegate)()=>receiver.setValueOrError());
        } catch (Exception e) {
          receiver.setError(e);
        }
      }
    }
    static struct ScheduleSender {
      alias Value = void;
      Worker worker;
      auto connect(Receiver)(return Receiver receiver) @safe scope return {
        // ensure NRVO
        auto op = ScheduleOp!(Receiver)(worker, receiver);
        return op;
      }
    }
    return ScheduleSender(worker);
  }
  auto scheduleAfter(Duration dur) {
    return ScheduleAfterSender!(Worker)(worker, dur);
  }
}

struct ScheduleAfterOp(Worker, Receiver) {
  import std.traits : ReturnType;
  import concurrency.bitfield : SharedBitField;
  import concurrency.stoptoken : StopCallback, onStop;
  import concurrency.receiver : setValueOrError;

  enum Flags {
    locked = 0x1,
    terminated = 0x2
  }
  alias Timer = ReturnType!(Worker.addTimer);
  Worker worker;
  Duration dur;
  Receiver receiver;
  Timer timer;
  StopCallback stopCb;
  shared SharedBitField!Flags flags;
  void start() @trusted nothrow {
    with(flags.lock()) {
      if (receiver.getStopToken().isStopRequested) {
        receiver.setDone();
        return;
      }
      stopCb = receiver.getStopToken().onStop(cast(void delegate() nothrow @safe shared)&stop);
      try {
        timer = worker.addTimer(cast(void delegate(TimerTrigger) @safe shared)&trigger, dur);
      } catch (Exception e) {
        receiver.setError(e);
      }
    }
  }
  private void trigger(TimerTrigger cause) @trusted nothrow {
    stopCb.dispose();
    final switch (cause) {
    case TimerTrigger.cancel:
      receiver.setDone();
      break;
    case TimerTrigger.trigger:
      with(flags.update(Flags.terminated)) {
        if ((oldState & Flags.terminated) == 0)
          receiver.setValueOrError();
      }
      break;
    }
  }
  private void stop() @trusted nothrow {
    with(flags.update(Flags.terminated)) {
      if ((oldState & Flags.terminated) == 0) {
        try { worker.cancelTimer(timer); } catch (Exception e) {} // TODO: what to do here?
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
  import core.time : msecs, hnsecs;
  import std.array : Appender;
  private {
    TimingWheels!Timer wheels;
    Appender!(Timer[]) expiredTimers;
    Mutex mutex;
    size_t time = 1;
    shared ulong nextTimerId;
  }
  auto lock() @trusted shared {
    import concurrency.utils : SharedGuard;
    return SharedGuard!(ManualTimeWorker).acquire(this, cast()mutex);
  }
  this() @trusted shared {
    mutex = cast(shared)new Mutex();
    (cast()wheels).init(time);
  }
  ManualTimeScheduler getScheduler() @safe shared {
    return ManualTimeScheduler(this);
  }
  Timer addTimer(TimerDelegate dg, Duration dur) @trusted shared {
    import core.atomic : atomicOp;
    with(lock()) {
      auto real_now = time;
      auto tw_now = wheels.currStdTime(1.msecs);
      auto delay = (real_now - tw_now).hnsecs;
      auto at = (dur + delay)/1.msecs;
      auto timer = Timer(dg, nextTimerId.atomicOp!("+=")(1));
      wheels.schedule(timer, at);
      return timer;
    }
  }
  void cancelTimer(Timer timer) @trusted shared {
    with(lock()) {
      wheels.cancel(timer);
    }
    timer.dg(TimerTrigger.cancel);
  }
  Nullable!Duration timeUntilNextEvent() @trusted shared {
    with(lock()) {
      return wheels.timeUntilNextEvent(1.msecs, time);
    }
  }
  void advance(Duration dur) @trusted shared {
    import std.range : retro;
    import core.time : msecs;
    with(lock()) {
      time += dur.total!"hnsecs";
      int incr = wheels.ticksToCatchUp(1.msecs, time);
      if (incr > 0) {
        wheels.advance(incr, expiredTimers);
        // NOTE timingwheels keeps the timers in reverse order, so we iterate in reverse
        foreach(t; expiredTimers.data.retro) {
          t.dg(TimerTrigger.trigger);
        }
        expiredTimers.shrinkTo(0);
      }
    }
  }
}

T withBaseScheduler(T, P)(auto ref T t, auto ref P p) {
  static if (isScheduler!T)
    return t;
  else static if (isScheduler!P)
    return ProxyScheduler!(T, P)(t,p);
  else
    static assert(false, "Neither "~T.stringof~" nor "~P.stringof~" are full schedulers. Chain the sender with a .withScheduler and ensure the Scheduler passes the isScheduler check.");
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
