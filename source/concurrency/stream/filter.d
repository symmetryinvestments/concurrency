module concurrency.stream.filter;

import concurrency.stream.stream;
import concurrency.sender : OpType;

auto filter(Stream, Fun)(Stream stream, Fun fun) {
	alias Properties = StreamProperties!Stream;
	return fromStreamOp!(Properties.ElementType, Properties.Value,
	                     FilterStreamOp!(Stream, Fun))(stream, fun);
}

template FilterStreamOp(Stream, Fun) {
	import concurrency.utils : isThreadSafeFunction;
	static assert(isThreadSafeFunction!Fun);
	struct FilterStreamOp(Receiver) {
		alias Properties = StreamProperties!Stream;
		alias DG = Properties.DG;
		alias Op = OpType!(Properties.Sender, Receiver);
		Fun fun;
		DG dg;
		Op op;
		@disable
		this(ref return scope typeof(this) rhs);
		@disable
		this(this);

		@disable void opAssign(typeof(this) rhs) nothrow @safe @nogc;
		@disable void opAssign(ref typeof(this) rhs) nothrow @safe @nogc;

		this(Stream stream, Fun fun, DG dg, Receiver receiver) @trusted {
			this.fun = fun;
			this.dg = dg;
			op = stream.collect(cast(Properties.DG) &item).connect(receiver);
		}

		static if (is(Properties.ElementType == void))
			void item() {
				if (fun())
					dg();
			}

		else
			void item(Properties.ElementType t) {
				if (fun(t))
					dg(t);
			}

		void start() nothrow @safe {
			op.start();
		}
	}
}
