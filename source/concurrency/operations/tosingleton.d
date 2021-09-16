module concurrency.operations.tosingleton;

import concurrency.operations.toshared : SharedSender, NullScheduler, ResetLogic;

/// `toSingleton` ensures there is only one underlying Sender running at one time, eventhough many receivers may be connected.
/// After the underlying Sender completed, the next connecting Receiver will start it again.
/// This is in contrast with `toShared` which requires an explicit `reset` before it restarts the underlying Sender, simply forwarding the last termination call until that time.
/// This operation is useful if multiple things in your program depend on one single (sub)task running.
auto toSingleton(Sender, Scheduler)(Sender sender, Scheduler scheduler) {
  return new SharedSender!(Sender, Scheduler, ResetLogic.alwaysReset)(sender, scheduler);
}

auto toSingleton(Sender)(Sender sender) {
  return new SharedSender!(Sender, NullScheduler, ResetLogic.alwaysReset)(sender, NullScheduler());
}
