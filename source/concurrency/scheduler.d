module concurrency.scheduler;

import concepts;

void checkScheduler(T)() {
  import concurrency.sender : checkSender;
  T t = T.init;
  alias Sender = typeof(t.schedule());
  checkSender!Sender();
}
enum isScheduler(T) = is(typeof(checkScheduler!T));
