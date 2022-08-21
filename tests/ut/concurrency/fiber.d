module ut.concurrency.fiber;

import concurrency.fiber;
import concurrency.operations : then, whenAll;
import concurrency;
import concurrency.sender;
import core.time;

import unit_threaded;

@("yield.basic")
@safe unittest {
  auto fiber = FiberSender().then(() @trusted shared {
      yield();
    });
  whenAll(fiber, fiber).syncWait().assumeOk;
}

@("yield.delay")
@safe unittest {
  auto fiber = FiberSender().then(() @trusted shared {
      delay(100.msecs).yield();
    });
  whenAll(fiber, fiber).syncWait().assumeOk;
}

@("yield.error")
@safe unittest {
  FiberSender().then(() @trusted shared {
      ThrowingSender().yield();
    }).syncWait().isError.should == true;
}

@("yield.cancel")
@safe unittest {
  FiberSender().then(() @trusted shared {
      DoneSender().yield();
    }).syncWait().isCancelled.should == true;
}
