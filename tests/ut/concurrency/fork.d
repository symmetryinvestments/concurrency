module ut.concurrency.fork;

version (Posix):

import concurrency;
import concurrency.fork;
import concurrency.thread;
import concurrency.operations;
import concurrency.receiver;
import unit_threaded;

@("sync_wait.fork")
@trusted unittest {
  ForkSender(getLocalThreadExecutor(), () shared {}).syncWait.isOk.shouldEqual(true);
}

@("sync_wait.fork.exception")
@trusted unittest {
  import core.stdc.stdlib;
  ForkSender(getLocalThreadExecutor(), () shared @trusted { exit(1); }).syncWait.assumeOk.shouldThrow();
}
