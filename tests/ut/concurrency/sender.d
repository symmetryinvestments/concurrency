module ut.concurrency.sender;

import kaleidic.experimental.concurrency;
import kaleidic.experimental.concurrency.sender;
import kaleidic.experimental.concurrency.thread;
import kaleidic.experimental.concurrency.operations;
import kaleidic.experimental.concurrency.receiver;
import unit_threaded;

@("sync_wait.value")
@safe unittest {
  ValueSender!(int)(5).sync_wait().shouldEqual(5);
}

@("value.start.attributes.1")
@safe nothrow @nogc unittest {
  ValueSender!(int)(5).connect(NullReceiver!int()).start();
}

@("value.start.attributes.2")
@safe nothrow unittest {
  ValueSender!(int)(5).connect(ThrowingNullReceiver!int()).start();
}

@("sync_wait.thread")
@safe unittest {
  ThreadSender().sync_wait().shouldEqual(true);
}

@("sync_wait.thread.then.value")
@safe unittest {
  ThreadSender().then(() shared => 2*3).sync_wait().shouldEqual(6);
}

@("sync_wait.thread.then.exception")
@safe unittest {
  bool delegate() shared dg = () shared { throw new Exception("Exceptions are rethrown"); };
  ThreadSender()
    .then(dg)
    .sync_wait()
    .shouldThrow();
}
