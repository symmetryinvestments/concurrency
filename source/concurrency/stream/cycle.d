module concurrency.stream.cycle;

import concurrency.stream.stream;
import concurrency.stoptoken : StopToken;
import std.range : ElementType;

struct Cycle(Range) {
	alias T = ElementType!Range;
	alias DG = CollectDelegate!(T);
	Range range;
	void loop(DG emit, shared StopToken stopToken) @safe {
		for (; !stopToken.isStopRequested;) {
			foreach (item; range) {
				emit(item);
				if (stopToken.isStopRequested)
					return;
			}
		}
	}
}

/// Stream that cycles through a Range until cancelled
auto cycleStream(Range)(Range range) {
	alias T = ElementType!Range;
	return Cycle!Range(range).loopStream!T;
}
