module concurrency.operations.withchild;

import concurrency;
import concurrency.receiver;
import concurrency.sender;
import concurrency.stoptoken;
import concepts;
import std.traits;
import concurrency.utils : spin_yield, casWeak;

WithChildSender!(SenderParent, SenderChild) withChild(
	SenderParent, SenderChild
)(SenderParent a, SenderChild b) {
	return WithChildSender!(SenderParent, SenderChild)(a, b);
}

struct WithChildSender(SenderParent, SenderChild)
		if (models!(SenderParent, isSender) && models!(SenderChild, isSender)) {
	import concurrency.operations.whenall;
	alias Value = WhenAllSender!(SenderChild, SenderParent).Value;
	SenderParent a;
	SenderChild b;
	auto connect(Receiver)(return Receiver receiver) @safe return scope {
		import concurrency.operations.stopon;
		// ensure NRVO
		auto op =
			whenAll(b.stopOn(receiver.getStopToken), a).stopOn(StopToken())
			                                           .connect(receiver);
		return op;
	}
}
