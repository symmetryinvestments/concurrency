module ut.concurrency.fork;

import concurrency;
import concurrency.fork;
import concurrency.thread;
import concurrency.operations;
import concurrency.receiver;
import unit_threaded;

@("sync_wait.fork")
@trusted unittest {
  ForkSender(getLocalThreadExecutor(), () shared {}).sync_wait().shouldEqual(true);
}

@("sync_wait.fork.exception")
@trusted unittest {
  import core.stdc.stdlib;
  ForkSender(getLocalThreadExecutor(), () shared @trusted { exit(1); }).sync_wait().shouldThrow();
}
