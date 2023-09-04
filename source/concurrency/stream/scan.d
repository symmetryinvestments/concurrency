module concurrency.stream.scan;

import concurrency.stream.stream;
import concurrency.sender : OpType;
import concepts;
import concurrency.utils : isThreadSafeFunction;

/// Applies an accumulator to each value from the source
auto scan(Stream, Fun, Seed)(Stream stream, scope Fun scanFn, Seed seed)
		if (models!(Stream, isStream)) {
	static assert(isThreadSafeFunction!Fun);
	alias Properties = StreamProperties!Stream;
	return fromStreamOp!(
		Seed, Properties.Value,
		ScanStreamOp!(Stream, Fun, Seed))(stream, scanFn, seed);
}

template ScanStreamOp(Stream, Fun, Seed) {
	static assert(isThreadSafeFunction!Fun);
	alias Properties = StreamProperties!Stream;
	alias DG = CollectDelegate!(Seed);
	struct ScanStreamOp(Receiver) {
		alias Op = OpType!(Properties.Sender, Receiver);
		Fun scanFn;
		Seed acc;
		DG dg;
		Op op;
		@disable
		this(ref return scope typeof(this) rhs);
		@disable
		this(this);
		this(Stream stream, Fun scanFn, Seed seed, DG dg,
		     Receiver receiver) @trusted {
			this.scanFn = scanFn;
			this.acc = seed;
			this.dg = dg;
			op = stream.collect(cast(Properties.DG) &item).connect(receiver);
		}

		static if (is(Properties.ElementType == void))
			void item() {
				acc = scanFn(acc);
				dg(acc);
			}

		else
			void item(Properties.ElementType t) {
				acc = scanFn(acc, t);
				dg(acc);
			}

		void start() nothrow @safe {
			op.start();
		}
	}
}
