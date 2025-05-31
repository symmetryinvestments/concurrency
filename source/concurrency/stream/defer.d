module concurrency.stream.defer;

import concurrency.sender : isSender;
import concurrency.stream.stream;
import std.traits : ReturnType;

// Creates a stream of the values resulted by the Senders returned by Fun.
auto deferStream(Fun)(Fun fun) {
	import concurrency.utils : isThreadSafeCallable;
	static assert(isThreadSafeCallable!Fun);
	alias Sender = ReturnType!Fun;
	return fromStreamOp!(Sender.Value, void, DeferStreamOp!(Fun))(fun);
}

template DeferStreamOp(Fun) {
	import concurrency.sender : OpType;
	alias Sender = ReturnType!Fun;
	alias DG = CollectDelegate!(Sender.Value);

	struct DeferStreamOp(Receiver) {
		alias Op = OpType!(Sender, DeferReceiver!(Sender.Value, Receiver));
		Fun fun;
		DG dg;
		Receiver receiver;
		Op op;
		@disable
		this(ref return scope inout typeof(this) rhs);
		@disable
		this(this);

		@disable void opAssign(typeof(this) rhs) nothrow @safe @nogc;
		@disable void opAssign(ref typeof(this) rhs) nothrow @safe @nogc;

		this(Fun fun, DG dg, return Receiver receiver) @trusted scope {
			this.fun = fun;
			this.dg = dg;
			this.receiver = receiver;
		}

		void start() @trusted nothrow scope {
       		import concurrency.sender : emplaceOperationalState;
			op.emplaceOperationalState(
				fun(),
				DeferReceiver!(Sender.Value, Receiver)(dg, receiver, &start)
			);
			op.start();
		}
	}
}

struct DeferReceiver(Value, Receiver) {
	import concurrency.receiver;
	alias DG = CollectDelegate!(Value);
	DG dg;
	Receiver receiver;
	void delegate() @safe nothrow reset;
	static if (!is(Value : void)) {
		void setValue(Value value) @safe {
			dg(value);
			if (!receiver.getStopToken.isStopRequested)
				reset();
			else
				setDone();
		}
	} else {
		void setValue() @safe {
			dg();
			if (!receiver.getStopToken.isStopRequested)
				reset();
			else
				setDone();
		}
	}

	void setError(Throwable t) @safe nothrow {
		receiver.setError(t);
	}

	void setDone() @safe nothrow {
		receiver.setDone();
	}

	mixin ForwardExtensionPoints!(receiver);
}
