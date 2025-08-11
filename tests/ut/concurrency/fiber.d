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

@("yield.delay.single")
@safe unittest {
    auto fiber = FiberSender().then(() @trusted shared {
        delay(1.msecs).yield();
    });
    fiber.syncWait().assumeOk;
}

@("yield.delay.double")
@safe unittest {
    auto fiber = FiberSender().then(() @trusted shared {
        delay(1.msecs).yield();
    });
    whenAll(fiber, fiber).syncWait().assumeOk;
}

@("yield.error.basic")
@safe unittest {
    FiberSender().then(() @trusted shared {
        try {
            ThrowingSender().yield();
        } catch (Exception e) {
            return;
        }
        throw new Exception("Too far");
    }).syncWait().assumeOk;
}

@("yield.error.propagate")
@safe unittest {
    FiberSender().then(() @trusted shared {
        ThrowingSender().yield();
    }).syncWait().isError.should == true;
}

@("yield.cancel.basic")
@safe unittest {
    FiberSender().then(() @trusted shared {
        try {
            DoneSender().yield();
        } catch (CancelledException e) {
            return;
        }
        throw new Exception("Too far");
    }).syncWait().assumeOk;
}

@("yield.cancel.propagate")
@safe unittest {
    FiberSender().then(() @trusted shared {
        DoneSender().yield();
    }).syncWait().isCancelled.should == true;
}
