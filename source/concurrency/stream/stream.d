module concurrency.stream.stream;

import concurrency.stoptoken;
import concurrency.receiver;
import concurrency.sender : isSender, OpType;
import concepts;
import std.traits : hasFunctionAttributes;

/// A Stream is anything that has a `.collect` function that accepts a callable and returns a Sender.
/// Once the Sender is connected and started the Stream will call the callable zero or more times before one of the three terminal functions of the Receiver is called.

template CollectDelegate(ElementType) {
	static if (is(ElementType == void)) {
		alias CollectDelegate = void delegate() @safe shared;
	} else {
		alias CollectDelegate = void delegate(ElementType) @safe shared;
	}
}

/// checks that T is a Stream
void checkStream(T)() {
	import std.traits : ReturnType;
	alias DG = CollectDelegate!(T.ElementType);
	static if (is(typeof(T.collect!DG)))
		alias Sender = ReturnType!(T.collect!(DG));
	else
		alias Sender = ReturnType!(T.collect);
	static assert(models!(Sender, isSender));
}

enum isStream(T) = is(typeof(checkStream!T));

/// A polymorphic stream with elements of type T
interface StreamObjectBase(T) {
	import concurrency.sender : SenderObjectBase;
	alias ElementType = T;
	static assert(models!(typeof(this), isStream));
	alias DG = CollectDelegate!(ElementType);

	SenderObjectBase!void collect(DG dg) @safe;
}

/// A class extending from StreamObjectBase that wraps any Stream
class StreamObjectImpl(Stream) : StreamObjectBase!(Stream.ElementType)
		if (models!(Stream, isStream)) {
	import concurrency.receiver : ReceiverObjectBase;
	static assert(models!(typeof(this), isStream));
	private Stream stream;
	this(Stream stream) {
		this.stream = stream;
	}

	alias DG = CollectDelegate!(Stream.ElementType);

	SenderObjectBase!void collect(DG dg) @safe {
		import concurrency.sender : toSenderObject;
		return stream.collect(dg).toSenderObject();
	}
}

/// Converts any Stream to a polymorphic StreamObject
StreamObjectBase!(Stream.ElementType) toStreamObject(Stream)(Stream stream)
		if (models!(Stream, isStream)) {
	return new StreamObjectImpl!(Stream)(stream);
}

template StreamProperties(Stream) {
	import std.traits : ReturnType;
	alias ElementType = Stream.ElementType;
	alias DG = CollectDelegate!(ElementType);
	alias Sender = ReturnType!(Stream.collect);
	alias Value = Sender.Value;
}

auto fromStreamOp(StreamElementType, SenderValue, alias Op,
                  Args...)(Args args) {
	alias DG = CollectDelegate!(StreamElementType);
	static struct FromStreamSender {
		alias Value = SenderValue;
		Args args;
		DG dg;
		auto connect(Receiver)(return Receiver receiver) @safe return scope {
			// ensure NRVO
			auto op = Op!(Receiver)(args, dg, receiver);
			return op;
		}
	}

	static struct FromStream {
		static assert(models!(typeof(this), isStream));
		alias ElementType = StreamElementType;
		Args args;
		auto collect(DG dg) @safe {
			return FromStreamSender(args, dg);
		}
	}

	return FromStream(args);
}

template SchedulerType(Receiver) {
	import std.traits : ReturnType;
	alias SchedulerType = ReturnType!(Receiver.getScheduler);
}

/// Helper to construct a Stream, useful if the Stream you are modeling has a blocking loop
template loopStream(E) {
	alias DG = CollectDelegate!(E);
	auto loopStream(T)(T t) {
		static struct LoopStream {
			static assert(models!(typeof(this), isStream));
			alias ElementType = E;
			static struct LoopOp(Receiver) {
				T t;
				DG dg;
				Receiver receiver;
				@disable
				this(ref return scope typeof(this) rhs);
				@disable
				this(this);

				@disable void opAssign(typeof(this) rhs) nothrow @safe @nogc;
				@disable void opAssign(ref typeof(this) rhs) nothrow @safe @nogc;

				this(T t, DG dg, Receiver receiver) {
					this.t = t;
					this.dg = dg;
					this.receiver = receiver;
				}

				void start() @trusted nothrow scope {
					try {
						t.loop(dg, receiver.getStopToken);
					} catch (Exception e) {
						receiver.setError(e);
					}

					if (receiver.getStopToken().isStopRequested)
						receiver.setDone();
					else
						receiver.setValueOrError();
				}
			}

			static struct LoopSender {
				alias Value = void;
				T t;
				DG dg;
				auto connect(Receiver)(
					return Receiver receiver
				) @safe return scope {
					// ensure NRVO
					auto op = LoopOp!(Receiver)(t, dg, receiver);
					return op;
				}
			}

			T t;
			auto collect(DG dg) @safe {
				return LoopSender(t, dg);
			}
		}

		return LoopStream(t);
	}
}
