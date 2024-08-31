module concurrency.operations.whenall;

import concurrency;
import concurrency.receiver;
import concurrency.sender;
import concurrency.stoptoken;
import concepts;
import std.traits;
import concurrency.utils : spin_yield, casWeak;

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
			void setValue(T)(T t, size_t index) @trusted {
				switch (index) {
					foreach (idx, I; Indexes) {
						case idx:
							static if (ValueTypes.length == 1)
								values = t;
							else static if (is(typeof(values[I - 1]) == T))
								values[I - 1] = t;
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

alias ArrayElement(T : P[], P) = P;

private template WhenAllResult(Senders...) if (Senders.length == 1) {
	alias Element = ArrayElement!(Senders).Value;
	static if (is(Element : void)) {
		struct WhenAllResult {}
	} else {
		struct WhenAllResult {
			Element[] values;
			void setValue(Element)(Element elem, size_t index) {
				values[index] = elem;
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
			WhenAllReceiver!(Receiver, ArrayElement!(Senders).Value, R);
		alias Ops = OpType!(ArrayElement!(Senders), ElementReceiver)[];
	}

	Receiver receiver;
	WhenAllState!R state;
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
		static if (Senders.length > 1) {
			foreach (i, Sender; Senders) {
				ops[i] = senders[i].connect(
					WhenAllReceiver!(Receiver, Sender.Value,
									 R)(receiver, &state, i, Senders.length));
			}
		} else {
			static if (!is(ArrayElement!(Senders).Value : void))
				state.value.values.length = senders[0].length;
			ops.length = senders[0].length;
			import concurrency.sender : emplaceOperationalState;
			foreach (i; 0 .. senders[0].length) {
				ops[i].emplaceOperationalState(senders[0][i],
					WhenAllReceiver!(Receiver, ArrayElement!(Senders).Value,
									 R)(receiver, &state, i, senders[0].length));
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

struct WhenAllSender(Senders...)
		if ((Senders.length > 1
				    && allSatisfy!(ApplyRight!(models, isSender), Senders)
					)
			    || (models!(ArrayElement!(Senders[0]), isSender))) {
	alias Result = WhenAllResult!(Senders);
	static if (hasMember!(Result, "values"))
		alias Value = typeof(Result.values);
	else
		alias Value = void;
	Senders senders;
	auto connect(Receiver)(return Receiver receiver) @safe return scope {
		// ensure NRVO
		auto op = WhenAllOp!(Receiver, Senders)(receiver, senders);
		return op;
	}
}

private struct WhenAllState(Value) {
	import concurrency.bitfield;
	shared StopSource stopSource;
	shared StopCallback cb;
	static if (is(typeof(Value.values)))
		Value value;
	Throwable exception;
	shared SharedBitField!Flags bitfield;
}

private struct WhenAllReceiver(Receiver, InnerValue, Value) {
	import core.atomic : atomicOp, atomicLoad, MemoryOrder;
	Receiver receiver;
	WhenAllState!(Value)* state;
	size_t senderIndex;
	size_t senderCount;
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
		return (state >> 3) == atomicLoad(senderCount);
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

		if (receiver.getStopToken().isStopRequested)
			receiver.setDone();
		else if (isDoneOrErrorProduced(newState)) {
			if (state.exception)
				receiver.setError(state.exception);
			else
				receiver.setDone();
		} else {
			import concurrency.receiver : setValueOrError;
			static if (is(typeof(Value.values)))
				receiver.setValueOrError(state.value.values);
			else
				receiver.setValueOrError();
		}
	}

	mixin ForwardExtensionPoints!receiver;
}
