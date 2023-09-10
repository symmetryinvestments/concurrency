module concurrency.stream.take;

import concurrency.stream.stream;
import concurrency.sender : OpType;
import concurrency.receiver : ForwardExtensionPoints;
import concurrency.stoptoken : InPlaceStopSource;
import concepts;

/// takes the first n values from a stream or until cancelled
auto take(Stream)(Stream stream, size_t n) if (models!(Stream, isStream)) {
	alias Properties = StreamProperties!Stream;
	import std.exception : enforce;
	enforce(n > 0, "cannot take 0");
	return fromStreamOp!(Properties.ElementType, Properties.Value,
	                     TakeOp!Stream)(stream, n);
}

struct TakeReceiver(Receiver, Value) {
	Receiver receiver;
	InPlaceStopSource* stopSource;
	static if (is(Value == void))
		void setValue() @safe {
			receiver.setValue();
		}

	else
		void setValue(Value e) @safe {
			receiver.setValue(e);
		}

	void setDone() nothrow @safe {
		import concurrency.receiver : setValueOrError;
		static if (is(Value == void)) {
			if (stopSource.isStopRequested)
				receiver.setValueOrError();
			else
				receiver.setDone();
		} else
			receiver.setDone();
	}

	void setError(Throwable t) nothrow @safe {
		receiver.setError(t);
	}

	mixin ForwardExtensionPoints!receiver;
}

template TakeOp(Stream) {
	alias Properties = StreamProperties!Stream;
	struct TakeOp(Receiver) {
		import concurrency.operations : withStopSource, SSSender;
		import std.traits : ReturnType;
		alias SS = SSSender!(Properties.Sender, InPlaceStopSource*);
		alias Op =
			OpType!(SS, TakeReceiver!(Receiver, Properties.Sender.Value));
		size_t n;
		Properties.DG dg;
		InPlaceStopSource stopSource;
		Op op;
		@disable
		this(ref return scope typeof(this) rhs);
		@disable
		this(this);
		this(return Stream stream, size_t n, Properties.DG dg,
		     return Receiver receiver) @trusted scope {
			this.dg = dg;
			this.n = n;
			op = stream.collect(cast(Properties.DG) &item)
			           .withStopSource(stopSource).connect(TakeReceiver!(
				           Receiver,
				           Properties.Sender.Value
			           )(receiver, &stopSource));
		}

		static if (is(Properties.ElementType == void)) {
			private void item() {
				dg();
				/// TODO: this implies the stream will only call emit from a single execution context, we might need to enforce that
				n--;
				if (n == 0)
					stopSource.stop();
			}
		} else {
			private void item(Properties.ElementType t) {
				dg(t);
				n--;
				if (n == 0)
					stopSource.stop();
			}
		}

		void start() nothrow @trusted scope {
			op.start();
		}
	}
}
