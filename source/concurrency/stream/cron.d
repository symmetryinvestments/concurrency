module concurrency.stream.cron;

import mir.algebraic;
import std.datetime.systime : SysTime;

struct Always {
}

struct Exact {
  uint value;
}

struct Every {
  uint step;
  uint starting;
}

struct Each {
  uint[] values;
}

alias Spec = Algebraic!(Always, Exact, Every, Each);

struct CronSpec {
  import std.datetime.timezone : TimeZone, UTC;
  Spec hours;
  Spec minutes;
  immutable(TimeZone) timezone = UTC();
}

struct Deferrer {
  CronSpec schedule;
  shared bool emitAtStart;
  this(CronSpec schedule, bool emitAtStart) @safe shared {
    this.schedule = schedule;
  }
  auto opCall() @safe shared {
    import std.datetime.systime : Clock;
    import concurrency.sender : delay;
    if (emitAtStart) {
      import core.time : msecs;
      emitAtStart = false;
      return delay(0.msecs);
    }
    auto sleep = timeTillNextTrigger(schedule, Clock.currTime());
    return delay(sleep);
  }
}

auto cronStream(CronSpec schedule, bool emitAtStart) @safe {
  auto d = shared Deferrer(schedule, emitAtStart);
  import concurrency.stream.defer;
  return deferStream(d);
}

auto timeTillNextTrigger(CronSpec schedule, SysTime time) {
  import core.time;
  auto now = time.toOtherTZ(schedule.timezone);
  Duration dur;
  while (true) {
    auto m = timeTillNextMinute(schedule.minutes, now);
    now += m;
    dur += m;
    if (!now.hour.matches(schedule.hours)) {
      auto h = timeTillNextHour(schedule.hours, now);
      now += h;
      dur += h;
      continue;
    }
    return dur;
  }
}

auto matches(uint value, Spec spec) {
  import std.algorithm;
  return spec.match!((Always a) => true,
                     (Exact e) => value == e.value,
                     (Every e) => (value - e.starting) % e.step == 0,
                     (Each e) => e.values.any!(v => v == value));
}

auto timeTillNext(alias unit, uint cycle, alias selector)(Spec spec, SysTime now) {
  import std.range : iota, empty, front;
  import std.algorithm : find;
  return spec.match!((Always a) {
      return unit(1);
    }, (Exact e) {
      if (selector(now) >= e.value)
        return unit(e.value + cycle - selector(now));
      return unit(e.value - selector(now));
    }, (Every e) {
      auto next = iota(e.starting, uint.max, e.step).find!(v => v > selector(now));
      return unit(next.front() - selector(now));
    }, (Each e) {
      auto next = e.values.find!(v => v > selector(now));
      if (next.empty)
        return unit(e.values.front + cycle - selector(now));
      return unit(next.front() - selector(now));
    });
}

auto timeTillNextMinute(Spec spec, SysTime now) {
  import core.time;
  return timeTillNext!(minutes, 60, i => i.minute)(spec, now) - seconds(now.second);
}

auto timeTillNextHour(Spec spec, SysTime now) {
  import core.time;
  return timeTillNext!(hours, 24, i => i.hour)(spec, now) - minutes(now.minute) - seconds(now.second);
}
