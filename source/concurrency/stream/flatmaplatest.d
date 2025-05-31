module concurrency.stream.flatmaplatest;

import concurrency.stream.stream : isStream;

auto flatMapLatest(Stream, Fun)(Stream stream, Fun fun) {
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
