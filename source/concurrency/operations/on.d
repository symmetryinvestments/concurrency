module concurrency.operations.on;

import concurrency;
import concurrency.receiver;
import concurrency.sender;
import concurrency.stoptoken;
import std.traits;

auto on(Sender, Scheduler)(Sender sender, Scheduler scheduler) {
	import concurrency.operations : via, withScheduler;
	return sender.via(scheduler.schedule()).withScheduler(scheduler);
}
