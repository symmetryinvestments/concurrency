module ut.concurrency.sender;

import concurrency;
import concurrency.sender;
import concurrency.thread;
import concurrency.operations;
import concurrency.receiver;
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

@("value.void")
@safe unittest {
  ValueSender!void().sync_wait().should == true;
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

@("toSenderObject.value")
@safe unittest {
  ValueSender!(int)(4).toSenderObject.sync_wait().shouldEqual(4);
}

@("toSenderObject.thread")
@safe unittest {
  ThreadSender().then(() shared => 2*3+1).toSenderObject.sync_wait().shouldEqual(7);
}

@("via.threadsender.error")
@safe unittest {
  ThrowingSender().via(ThreadSender()).sync_wait().shouldThrow();
}
