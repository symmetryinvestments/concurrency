module concurrency.stream.slide;

import concurrency.stream.stream;
import concurrency.sender : OpType;
import concepts;

/// slides a window over a stream, emitting all items in the window as an array. The array is reused so you must duplicate if you want to access it beyond the stream.
auto slide(Stream)(Stream stream, size_t window, size_t step = 1)
		if (models!(Stream, isStream)) {
	import std.traits : ReturnType;
	alias Properties = StreamProperties!Stream;
	static assert(!is(Properties.ElementType == void),
	              "Need ElementType to be able to slide, void wont do.");
	import std.exception : enforce;
	enforce(window > 0, "window must be greater than 0.");
	enforce(step > 0, "step must be greated than 0.");
	return fromStreamOp!(Properties.ElementType[], Properties.Value,
	                     SlideStreamOp!Stream)(stream, window, step);
}

template SlideStreamOp(Stream) {
	alias Properties = StreamProperties!Stream;
	alias DG = CollectDelegate!(Properties.ElementType[]);
	struct SlideStreamOp(Receiver) {
		alias Op = OpType!(Properties.Sender, Receiver);
		size_t window, step, skip;
		Properties.ElementType[] arr;
		DG dg;
		Op op;
		@disable
		this(ref return scope typeof(this) rhs);
		@disable
		this(this);
		this(Stream stream, size_t window, size_t step, DG dg,
		     Receiver receiver) @trusted {
			this.window = window;
			this.step = step;
			this.arr.reserve(window);
			this.dg = dg;
			op = stream.collect(cast(Properties.DG) &item).connect(receiver);
		}

		void item(Properties.ElementType t) {
			if (skip > 0) {
				skip--;
				return;
			}

			import std.algorithm : moveAll;
			if (arr.length == window) {
				arr[window - 1] = t;
			} else {
				arr ~= t;
				if (arr.length < window)
					return;
			}

			dg(arr);
			if (step < window) {
				moveAll(arr[step .. $], arr[0 .. $ - step]);
				if (step > 1)
					arr.length -= step;
			} else {
				arr.length = 0;
				skip = step - window;
			}
		}

		void start() nothrow @safe {
			op.start();
		}
	}
}
