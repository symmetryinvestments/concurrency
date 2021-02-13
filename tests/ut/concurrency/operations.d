module ut.concurrency.operations;

import concurrency;
import concurrency.sender;
import concurrency.thread;
import concurrency.operations;
import concurrency.receiver;
import unit_threaded;

@("ignoreErrorssync_wait.value")
@safe unittest {
  bool delegate() shared dg = () shared { throw new Exception("Exceptions are rethrown"); };
  ThreadSender()
    .then(dg)
    .ignoreError()
    .sync_wait()
    .shouldThrowWithMessage("Canceled");
}
