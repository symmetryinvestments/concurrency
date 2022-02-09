module ut.concurrency.pressure;

import concurrency;
import concurrency.thread;
import concurrency.operations;
import unit_threaded;

@("100.threads")
unittest {
  foreach(i; 0..100) {
    ThreadSender().then(() shared => 2*3).syncWait().value.shouldEqual(6);
  }
}
