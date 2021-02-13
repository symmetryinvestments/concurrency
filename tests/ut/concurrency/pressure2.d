module ut.concurrency.pressure2;

import concurrency;
import concurrency.thread;
import concurrency.operations;
import unit_threaded;

@("100.threads")
unittest {
  foreach(i; 0..100) {
    ThreadSender().then(() shared => 2*3).sync_wait().shouldEqual(6);
  }
}
