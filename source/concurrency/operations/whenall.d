module concurrency.operations.whenall;

import concurrency;
import concurrency.receiver;
import concurrency.sender;
import concurrency.stoptoken;
import std.traits;
import concurrency.utils : spin_yield, casWeak, copyOrMove;

WhenAllSender!(Senders) whenAll(Senders...)(Senders senders) {
	return WhenAllSender!(Senders)(senders);
}

private enum Flags : size_t {
	locked = 0x1,
	value_produced = 0x2,
	doneOrError_produced = 0x4
}

private enum Counter : size_t {
	tick = 0x8
}

template GetSenderValues(Senders...) {
	import std.meta;
	alias SenderValue(T) = T.Value;
	alias GetSenderValues = staticMap!(SenderValue, Senders);
}

private template WhenAllResult(Senders...) if (Senders.length > 1) {
	import std.meta;
	import std.typecons;
	import concurrency.utils : NoVoid;
	template Cummulative(size_t count, Ts...) {
		static if (Ts.length > 0) {
			enum head = count + Ts[0];
			static if (Ts.length == 1)
				alias Cummulative = AliasSeq!(head);
			else static if (Ts.length > 1)
				alias Cummulative =
					AliasSeq!(head, Cummulative!(head, Ts[1 .. $]));
		} else {
			alias Cummulative = AliasSeq!();
		}
	}

	alias SenderValues = GetSenderValues!(Senders);
	alias ValueTypes = Filter!(NoVoid, SenderValues);
	static if (ValueTypes.length > 1)
		alias Values = Tuple!(Filter!(NoVoid, SenderValues));
	else static if (ValueTypes.length == 1)
		alias Values = ValueTypes[0];
	alias Indexes = Cummulative!(0, staticMap!(NoVoid, SenderValues));

	static if (ValueTypes.length > 0) {
		struct WhenAllResult {
			Values values;
			void setValue(T)(ref T t, size_t index) @trusted {
				switch (index) {
					foreach (idx, I; Indexes) {
						case idx:
							static if (ValueTypes.length == 1)
								values = t.copyOrMove;
							else static if (is(typeof(values[I - 1]) == T)) {
								static if (__traits(isScalar, T))
									values[I - 1] = t;
								else
									values[I - 1] = t.copyOrMove;
							}
							return;
					}

					default:
						assert(false, "out of bounds");
				}
			}
		}
	} else {
		struct WhenAllResult {}
	}
}

// alias ElementType(T : P[], P) = P;
import std.range : ElementType;

private template WhenAllResult(Senders...) if (Senders.length == 1) {
	alias Element = ElementType!(Senders).Value;
	static if (is(Element : void)) {
		struct WhenAllResult {}
	} else {
		struct WhenAllResult {
			Element[] values;
			void setValue(Element)(ref Element elem, size_t index) {
				values[index] = elem.copyOrMove;
			}
		}
	}
}

private struct WhenAllOp(Receiver, Senders...) {
	import std.meta : staticMap;
	alias R = WhenAllResult!(Senders);
	static if (Senders.length > 1) {
		alias ElementReceiver(Sender) =
			WhenAllReceiver!(Receiver, Sender.Value, R);
		alias ConnectResult(Sender) = OpType!(Sender, ElementReceiver!Sender);
		alias Ops = staticMap!(ConnectResult, Senders);
	} else {
		alias ElementReceiver =
			WhenAllReceiver!(Receiver, ElementType!(Senders).Value, R);
		alias Ops = OpType!(ElementType!(Senders), ElementReceiver)[];
	}

	Receiver receiver;
	WhenAllState!(Receiver, R) state;
	Ops ops;
	@disable
	this(this);
	@disable
	this(ref return scope typeof(this) rhs);

	@disable void opAssign(typeof(this) rhs) nothrow @safe @nogc;
	@disable void opAssign(ref typeof(this) rhs) nothrow @safe @nogc;

	this(return Receiver receiver,
		 return Senders senders) @trusted scope return {
		this.receiver = receiver;
		state.receiver = receiver;
		static if (Senders.length > 1) {
			state.senderCount = Senders.length;
			foreach (i, Sender; Senders) {
				ops[i] = senders[i].connect(
					WhenAllReceiver!(Receiver, Sender.Value,
									 R)(&state, i));
			}
		} else {
			state.senderCount = senders[0].length;
			static if (!is(ElementType!(Senders).Value : void))
				state.value.values.length = senders[0].length;
			ops.length = senders[0].length;
			import concurrency.sender : emplaceOperationalState;
			size_t i;
			foreach (ref s; senders[0]) {
				ops[i].emplaceOperationalState(s,
					WhenAllReceiver!(Receiver, ElementType!(Senders).Value,
									 R)(&state, i));
				i++;
			}
		}
	}

	void start() @trusted nothrow scope {
		if (receiver.getStopToken().isStopRequested) {
			receiver.setDone();
			return;
		}

		auto token = receiver.getStopToken();
		// butt ugly cast, but it won't take the second overload
		state.cb.register(token, cast(void delegate() nothrow @safe shared) &state.stopSource.stop);

		static if (Senders.length > 1) {
			foreach (i, _; Senders) {
				ops[i].start();
			}
		} else {
			foreach (i; 0 .. ops.length) {
				ops[i].start();
			}
		}
	}
}

import std.meta : allSatisfy, ApplyRight;

struct WhenAllSender(Senders...) {
	alias Result = WhenAllResult!(Senders);
	static if (hasMember!(Result, "values"))
		alias Value = typeof(Result.values);
	else
		alias Value = void;
	Senders senders;
	auto connect(Receiver)(return Receiver receiver) @trusted return scope {
		// ensure NRVO
		auto op = WhenAllOp!(Receiver, Senders)(receiver, senders);
		return op;
	}
}

private struct WhenAllState(Receiver, Value) {
	import concurrency.bitfield;
	shared StopSource stopSource;
	shared StopCallback cb;
	Receiver receiver;
	static if (is(typeof(Value.values)))
		Value value;
	size_t senderCount;
	Throwable exception;
	shared SharedBitField!Flags bitfield;
}

private struct WhenAllReceiver(Receiver, InnerValue, Value) {
	import core.atomic : atomicOp, atomicLoad, MemoryOrder;
	WhenAllState!(Receiver,Value)* state;
	size_t senderIndex;
	auto getStopToken() {
		return state.stopSource.token();
	}

	private bool isValueProduced(size_t state) {
		return (state & Flags.value_produced) > 0;
	}

	private bool isDoneOrErrorProduced(size_t state) {
		return (state & Flags.doneOrError_produced) > 0;
	}

	private bool isLast(size_t state) {
		return (state >> 3) == atomicLoad(this.state.senderCount);
	}

	static if (!is(InnerValue == void))
		void setValue(InnerValue value) @safe {
			with (state.bitfield.lock(Flags.value_produced, Counter.tick)) {
				bool last = isLast(newState);
				state.value.setValue(value, senderIndex);
				release();
				if (last)
					process(newState);
			}
		}

	else
		void setValue() @safe {
			with (state.bitfield.update(Flags.value_produced, Counter.tick)) {
				bool last = isLast(newState);
				if (last)
					process(newState);
			}
		}

	void setDone() @safe nothrow {
		with (state.bitfield.update(Flags.doneOrError_produced, Counter.tick)) {
			bool last = isLast(newState);
			if (!isDoneOrErrorProduced(oldState))
				state.stopSource.stop();
			if (last)
				process(newState);
		}
	}

	void setError(Throwable exception) @safe nothrow {
		with (state.bitfield.lock(Flags.doneOrError_produced, Counter.tick)) {
			bool last = isLast(newState);
			if (!isDoneOrErrorProduced(oldState)) {
				state.exception = exception;
				release(); // must release before calling .stop
				state.stopSource.stop();
			} else
				release();
			if (last)
				process(newState);
		}
	}

	private void process(size_t newState) {
		state.cb.dispose();

		if (state.receiver.getStopToken().isStopRequested)
			state.receiver.setDone();
		else if (isDoneOrErrorProduced(newState)) {
			if (state.exception)
				state.receiver.setError(state.exception);
			else
				state.receiver.setDone();
		} else {
			import concurrency.receiver : setValueOrError;
			static if (is(typeof(Value.values)))
				state.receiver.setValueOrError(state.value.values);
			else
				state.receiver.setValueOrError();
		}
	}

	ref Receiver receiver() {
		return state.receiver;
	}

	mixin ForwardExtensionPoints!receiver;
}
