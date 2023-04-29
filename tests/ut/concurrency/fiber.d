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
      delay(100.msecs).yield().assumeOk;
    });
  whenAll(fiber, fiber).syncWait().assumeOk;
}

@("yield.error.basic")
@safe unittest {
  FiberSender().then(() @trusted shared {
      ThrowingSender().yield().isError.should == true;
    }).syncWait();
}

@("yield.error.propagate")
@safe unittest {
  FiberSender().then(() @trusted shared {
      ThrowingSender().yield().assumeOk;
    }).syncWait().isError.should == true;
}

@("yield.cancel.basic")
@safe unittest {
  FiberSender().then(() @trusted shared {
      DoneSender().yield().isCancelled.should == true;
    }).syncWait().assumeOk;
}

@("yield.cancel.propagate")
@safe unittest {
  FiberSender().then(() @trusted shared {
      DoneSender().yield().assumeOk;
    }).syncWait().isCancelled.should == true;
}
