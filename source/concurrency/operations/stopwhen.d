module concurrency.operations.stopwhen;

import concurrency;
import concurrency.receiver;
import concurrency.sender;
import concurrency.stoptoken;
import concurrency.utils : spin_yield, casWeak;
import concepts;
import std.traits;

/// stopWhen cancels the source when the trigger completes normally. If the either source or trigger completes with cancellation or with an error, the first one is propagates after both are completed.
StopWhenSender!(Sender, Trigger) stopWhen(Sender, Trigger)(Sender source,
                                                           Trigger trigger) {
	return StopWhenSender!(Sender, Trigger)(source, trigger);
}

private struct StopWhenOp(Receiver, Sender, Trigger) {
	alias SenderOp = OpType!(Sender, SourceReceiver!(Receiver, Sender.Value));
	alias TriggerOp =
		OpType!(Trigger, TriggerReceiver!(Receiver, Sender.Value));
	Receiver receiver;
	State!(Sender.Value) state;
	SenderOp sourceOp;
	TriggerOp triggerOp;
	@disable
	this(this);
	@disable
	this(ref return scope typeof(this) rhs);
	this(Receiver receiver, return Sender source,
	     return Trigger trigger) @trusted scope {
		this.receiver = receiver;
		sourceOp = source
			.connect(SourceReceiver!(Receiver, Sender.Value)(receiver, &state));
		triggerOp = trigger
			.connect(TriggerReceiver!(Receiver, Sender.Value)(receiver, &state));
	}

	void start() @trusted nothrow scope {
		if (receiver.getStopToken().isStopRequested) {
			receiver.setDone();
			return;
		}

		auto token = receiver.getStopToken();
		// butt ugly cast, but it won't take the second overload
		state.cb.register(token, cast(void delegate() nothrow @safe shared) &state.stopSource.stop);

		sourceOp.start;
		triggerOp.start;
	}
}

struct StopWhenSender(Sender, Trigger)
		if (models!(Sender, isSender) && models!(Trigger, isSender)) {
	static assert(models!(typeof(this), isSender));
	alias Value = Sender.Value;
	Sender sender;
	Trigger trigger;
	auto connect(Receiver)(return Receiver receiver) @safe return scope {
		// ensure NRVO
		auto op =
			StopWhenOp!(Receiver, Sender, Trigger)(receiver, sender, trigger);
		return op;
	}
}

// refactor to use StopSource
private struct State(Value) {
	import concurrency.bitfield;
	shared StopSource stopSource;
	shared StopCallback cb;
	shared SharedBitField!Flags bitfield;
	static if (!is(Value == void))
		Value value;
	Throwable exception;
}

private enum Flags : size_t {
	locked = 0x1,
	value_produced = 0x2,
	doneOrError_produced = 0x4,
	tick = 0x8
}

private enum Counter : size_t {
	tick = 0x8
}

private
void process(State, Receiver)(State state, Receiver receiver, size_t newState) {
	import concurrency.receiver : setValueOrError;

	state.cb.dispose();
	if (receiver.getStopToken().isStopRequested)
		receiver.setDone();
	else if (isValueProduced(newState)) {
		static if (__traits(compiles, state.value))
			receiver.setValueOrError(state.value);
		else
			receiver.setValueOrError();
	} else if (state.exception)
		receiver.setError(state.exception);
	else
		receiver.setDone();
}

private bool isValueProduced(size_t state) @safe nothrow pure {
	return (state & Flags.value_produced) > 0;
}

private bool isDoneOrErrorProduced(size_t state) @safe nothrow pure {
	return (state & Flags.doneOrError_produced) > 0;
}

private bool isLast(size_t state) @safe nothrow pure {
	return (state & Flags.tick) > 0;
}

private struct TriggerReceiver(Receiver, Value) {
	Receiver receiver;
	State!(Value)* state;
	auto getStopToken() {
		return state.stopSource.token();
	}

	void setValue() @safe nothrow {
		with (state.bitfield.update(Flags.tick)) {
			if (!isLast(oldState))
				state.stopSource.stop();
			else
				state.process(receiver, newState);
		}
	}

	void setDone() @safe nothrow {
		with (state.bitfield.update(Flags.doneOrError_produced, Flags.tick)) {
			if (!isLast(oldState))
				state.stopSource.stop();
			else
				state.process(receiver, newState);
		}
	}

	void setError(Throwable exception) @safe nothrow {
		with (state.bitfield.lock(Flags.doneOrError_produced, Counter.tick)) {
			bool last = isLast(oldState);
			if (!isDoneOrErrorProduced(oldState)) {
				state.exception = exception;
				release(); // release before stop
				state.stopSource.stop();
			} else {
				release();
				if (last)
					state.process(receiver, newState);
			}
		}
	}

	mixin ForwardExtensionPoints!receiver;
}

private struct SourceReceiver(Receiver, Value) {
	import core.atomic : atomicOp, atomicLoad, MemoryOrder;
	Receiver receiver;
	State!(Value)* state;
	auto getStopToken() {
		return state.stopSource.token();
	}

	static if (!is(Value == void))
		void setValue(Value value) @safe nothrow {
			with (state.bitfield.lock(Flags.value_produced | Flags.tick)) {
				bool last = isLast(oldState);
				state.value = value;
				
				release();
				if (!last)
					state.stopSource.stop();
				else if (isDoneOrErrorProduced(oldState))
					state.process(receiver, oldState);
				else
					state.process(receiver, newState);
			}
		}

	else
		void setValue() @safe nothrow {
			with (state.bitfield.update(Flags.value_produced | Flags.tick)) {
				bool last = isLast(oldState);
				if (!last)
					state.stopSource.stop();
				else if (isDoneOrErrorProduced(oldState))
					state.process(receiver, oldState);
				else
					state.process(receiver, newState);
			}
		}

	void setDone() @safe nothrow {
		with (state.bitfield.update(Flags.doneOrError_produced | Flags.tick)) {
			bool last = isLast(oldState);
			if (!last)
				state.stopSource.stop();
			else
				state.process(receiver, newState);
		}
	}

	void setError(Throwable exception) @safe nothrow {
		with (state.bitfield.lock(Flags.doneOrError_produced | Flags.tick)) {
			bool last = isLast(oldState);
			if (!isDoneOrErrorProduced(oldState)) {
				state.exception = exception;
			}

			release();
			if (!last)
				state.stopSource.stop();
			else
				state.process(receiver, newState);
		}
	}

	mixin ForwardExtensionPoints!receiver;
}
