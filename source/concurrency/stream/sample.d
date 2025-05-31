module concurrency.stream.sample;

import concurrency.stream.stream;
import concurrency.sender : OpType;

/// Forwards the latest value from the base stream every time the trigger stream produces a value. If the base stream hasn't produces a (new) value the trigger is ignored
auto sample(StreamBase, StreamTrigger)(StreamBase base, StreamTrigger trigger) {
	alias PropertiesBase = StreamProperties!StreamBase;
	alias PropertiesTrigger = StreamProperties!StreamTrigger;
	static assert(
		!is(PropertiesBase.ElementType == void),
		"No point in sampling a stream that procudes no values. Might as well use trigger directly"
	);
	alias DG = PropertiesBase.DG;
	return fromStreamOp!(
		PropertiesBase.ElementType, PropertiesBase.Value,
		SampleStreamOp!(StreamBase, StreamTrigger))(base, trigger);
}

template SampleStreamOp(StreamBase, StreamTrigger) {
	import concurrency.operations.raceall;
	import concurrency.bitfield : SharedBitField;
	enum Flags : size_t {
		locked = 0x1,
		valid = 0x2
	}

	alias PropertiesBase = StreamProperties!StreamBase;
	alias PropertiesTrigger = StreamProperties!StreamTrigger;
	alias DG = PropertiesBase.DG;
	struct SampleStreamOp(Receiver) {
		import std.traits : ReturnType;
		alias RaceAllSender = ReturnType!(
			raceAll!(PropertiesBase.Sender, PropertiesTrigger.Sender));
		alias Op = OpType!(RaceAllSender, Receiver);
		DG dg;
		Op op;
		PropertiesBase.ElementType element;
		shared SharedBitField!Flags state;
		shared size_t sampleState;
		@disable
		this(ref return scope inout typeof(this) rhs);
		@disable
		this(this);

		@disable void opAssign(typeof(this) rhs) nothrow @safe @nogc;
		@disable void opAssign(ref typeof(this) rhs) nothrow @safe @nogc;

		this(StreamBase base, StreamTrigger trigger, DG dg,
		     return Receiver receiver) @trusted scope {
			this.dg = dg;
			op = raceAll(
				base.collect(cast(PropertiesBase.DG) &item),
				trigger.collect(cast(PropertiesTrigger.DG) &this.trigger)
			).connect(receiver);
		}

		void item(PropertiesBase.ElementType t) {
			import core.atomic : atomicOp;
			with (state.lock(Flags.valid)) {
				element = t;
			}
		}

		void trigger() {
			import core.atomic : atomicOp;
			with (state.lock()) {
				if (was(Flags.valid)) {
					auto localElement = element;
					release(Flags.valid);
					dg(localElement);
				}
			}
		}

		void start() {
			op.start();
		}
	}
}
