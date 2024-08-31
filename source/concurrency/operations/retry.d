module concurrency.operations.retry;

import concurrency;
import concurrency.receiver;
import concurrency.sender;
import concurrency.stoptoken;
import concepts;
import std.traits;

struct Times {
	int max = 5;
	int n = 0;
	bool failure(Throwable e) @safe nothrow {
		n++;
		return n >= max;
	}
}

// Checks T is retry logic
void checkRetryLogic(T)() {
	T t = T.init;
	alias Ret = typeof((() nothrow => t.failure(Throwable.init))());
	static assert(
		is(Ret == bool),
		T.stringof
			~ ".failure(Throwable) should return a bool, but it returns a "
			~ Ret.stringof
	);
}

enum isRetryLogic(T) = is(typeof(checkRetryLogic!T));

auto retry(Sender, Logic)(Sender sender, Logic logic) {
	return RetrySender!(Sender, Logic)(sender, logic);
}

private struct RetryReceiver(Receiver, Sender, Logic) {
	private {
		Sender sender;
		Receiver receiver;
		Logic logic;
		alias Value = Sender.Value;
	}

	static if (is(Value == void)) {
		void setValue() @safe {
			receiver.setValueOrError();
		}
	} else {
		void setValue(Value value) @safe {
			receiver.setValueOrError(value);
		}
	}

	void setDone() @safe nothrow {
		receiver.setDone();
	}

	void setError(Throwable e) @safe nothrow {
		if (logic.failure(e))
			receiver.setError(e);
		else {
			try {
				// TODO: we connect on the heap here but we can probably do something smart...
				// Maybe we can store the new Op in the RetryOp struct
				// From what I gathered that is what libunifex does
				sender.connectHeap(this).start();
			} catch (Exception e) {
				receiver.setError(e);
			}
		}
	}

	mixin ForwardExtensionPoints!receiver;
}

private struct RetryOp(Receiver, Sender, Logic) {
	alias Op = OpType!(Sender, RetryReceiver!(Receiver, Sender, Logic));
	Op op;
	@disable
	this(ref return scope typeof(this) rhs);
	@disable
	this(this);

    @disable void opAssign(typeof(this) rhs) nothrow @safe @nogc;
    @disable void opAssign(ref typeof(this) rhs) nothrow @safe @nogc;

	this(
		Sender sender,
		return RetryReceiver!(Receiver, Sender, Logic) receiver
	) @trusted scope {
		op = sender.connect(receiver);
	}

	void start() @trusted nothrow scope {
		op.start();
	}
}

struct RetrySender(Sender, Logic)
		if (models!(Sender, isSender) && models!(Logic, isRetryLogic)) {
	alias Value = Sender.Value;
	Sender sender;
	Logic logic;
	auto connect(Receiver)(return Receiver receiver) @safe return scope {
		// ensure NRVO
		auto op = RetryOp!(Receiver, Sender, Logic)(
			sender,
			RetryReceiver!(Receiver, Sender, Logic)(sender, receiver, logic)
		);
		return op;
	}
}
