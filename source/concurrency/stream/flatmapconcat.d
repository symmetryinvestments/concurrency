module concurrency.stream.flatmapconcat;

import concurrency.stream.stream : isStream;

auto flatMapConcat(Stream, Fun)(Stream stream, Fun fun) {
	import concurrency.stream.stream : fromStreamOp, StreamProperties;
	import concurrency.utils : isThreadSafeFunction;
	import concurrency.stream.flatmapbase;
	import std.traits : ReturnType;

	static assert(isThreadSafeFunction!Fun);

	alias Properties = StreamProperties!Stream;

	return fromStreamOp!(
		ReturnType!Fun.Value, Properties.Value,
		FlatMapBaseStreamOp!(Stream, Fun, OnOverlap.wait))(stream, fun);
}
