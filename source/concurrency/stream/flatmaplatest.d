module concurrency.stream.flatmaplatest;

import concurrency.stream.stream : isStream;
import concepts;

auto flatMapLatest(Stream, Fun)(Stream stream, Fun fun)
		if (models!(Stream, isStream)) {
	import concurrency.stream.stream : fromStreamOp, StreamProperties;
	import concurrency.utils : isThreadSafeFunction;
	import concurrency.stream.flatmapbase;
	import std.traits : ReturnType;

	static assert(isThreadSafeFunction!Fun);

	alias Properties = StreamProperties!Stream;

	return fromStreamOp!(
		ReturnType!Fun.Value, Properties.Value,
		FlatMapBaseStreamOp!(Stream, Fun, OnOverlap.latest))(stream, fun);
}
