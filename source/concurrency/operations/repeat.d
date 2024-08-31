module concurrency.operations.repeat;

import concurrency;
import concurrency.receiver;
import concurrency.sender;
import concurrency.stoptoken;
import concepts;
import std.traits;

auto repeat(Sender)(Sender sender) {
	static assert(is(Sender.Value : void),
				  "Can only repeat effectful Senders.");
	return RepeatSender!(Sender)(sender);
}

private struct RepeatReceiver(Receiver) {
	private Receiver receiver;
	private void delegate() @safe scope reset;
	void setValue() @safe {
		reset();
	}

	void setDone() @safe nothrow {
		receiver.setDone();
	}

	void setError(Throwable e) @safe nothrow {
		receiver.setError(e);
	}

	mixin ForwardExtensionPoints!receiver;
}

private struct RepeatOp(Receiver, Sender) {
	alias Op = OpType!(Sender, RepeatReceiver!(Receiver));
	Sender sender;
	Receiver receiver;
	Op op;
	@disable
	this(ref return scope typeof(this) rhs);
	@disable
	this(this);

	@disable void opAssign(typeof(this) rhs) nothrow @safe @nogc;
	@disable void opAssign(ref typeof(this) rhs) nothrow @safe @nogc;

	this(Sender sender, Receiver receiver) @trusted scope {
		this.sender = sender;
		this.receiver = receiver;
	}

	void start() @trusted nothrow scope {
		try {
			reset();
		} catch (Exception e) {
			receiver.setError(e);
		}
	}

	private void reset() @trusted scope {
		import concurrency.sender : emplaceOperationalState;
		op.emplaceOperationalState(sender, RepeatReceiver!(Receiver)(receiver, &reset));
		op.start();
	}
}

struct RepeatSender(Sender) if (models!(Sender, isSender)) {
	alias Value = Sender.Value;
	Sender sender;
	auto connect(Receiver)(return Receiver receiver) @safe return scope {
		// ensure NRVO
		auto op = RepeatOp!(Receiver, Sender)(sender, receiver);
		return op;
	}
}
