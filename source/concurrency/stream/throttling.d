module concurrency.stream.throttling;

import concurrency.stream.stream;
import concurrency.sender : OpType;
import concurrency.stoptoken;
import concepts;
import core.time : Duration;
import core.atomic : MemoryOrder;

private enum ThrottleFlags : size_t {
	locked = 0x1,
	value_produced = 0x2,
	doneOrError_produced = 0x4,
	timerArmed = 0x8,
	timerRearming = 0x10,
	counter = 0x20
}

enum ThrottleEmitLogic : uint {
	first, // emit the first item in the window
	last // emit the last item in the window
}

;
enum ThrottleTimerLogic : uint {
	noop, // don't reset the timer on new items
	rearm // reset the timer on new items
}

;

/// throttleFirst forwards one item and then enters a cooldown period during which it ignores items
auto throttleFirst(Stream)(Stream s, Duration d) {
	return throttling!(Stream, ThrottleEmitLogic.first,
	                   ThrottleTimerLogic.noop)(s, d);
}

/// throttleLast starts a cooldown period when it receives an item, after which it forwards the lastest value from the cooldown period
auto throttleLast(Stream)(Stream s, Duration d) {
	return throttling!(Stream, ThrottleEmitLogic.last,
	                   ThrottleTimerLogic.noop)(s, d);
}

/// debounce skips all items which are succeeded by another within the duration. Effectively it only emits items after a duration of silence
auto debounce(Stream)(Stream s, Duration d) {
	return throttling!(Stream, ThrottleEmitLogic.last,
	                   ThrottleTimerLogic.rearm)(s, d);
}

auto throttling(
	Stream,
	ThrottleEmitLogic emitLogic,
	ThrottleTimerLogic timerLogic
)(Stream stream, Duration dur) if (models!(Stream, isStream)) {
	alias Properties = StreamProperties!Stream;
	return fromStreamOp!(
		Properties.ElementType, Properties.Value,
		ThrottleStreamOp!(Stream, emitLogic, timerLogic))(stream, dur);
}

template ThrottleStreamOp(Stream, ThrottleEmitLogic emitLogic,
                          ThrottleTimerLogic timerLogic) {
	import std.traits : ReturnType;
	import concurrency.bitfield : SharedBitField;
	alias Properties = StreamProperties!Stream;
	alias DG = Properties.DG;
	struct ThrottleStreamOp(Receiver) {
		Duration dur;
		DG dg;
		Receiver receiver;
		static if (emitLogic == ThrottleEmitLogic.last)
			static if (!is(Properties.ElementType == void))
				Properties.ElementType item;
		static if (!is(Properties.Value == void))
			Properties.Value value;
		alias SchedulerAfterSender =
			ReturnType!(SchedulerType!(Receiver).scheduleAfter);
		alias InnerReceiver =
			TimerReceiver!(typeof(this), Properties.ElementType, emitLogic,
			               timerLogic);
		StopSource stopSource;
		StopSource timerStopSource;
		StopCallback cb;
		Throwable throwable;
		alias Op = OpType!(Properties.Sender,
		                   SenderReceiver!(typeof(this), Properties.Value));
		alias TimerOp = OpType!(SchedulerAfterSender, InnerReceiver);
		Op op;
		TimerOp timerOp;
		shared SharedBitField!ThrottleFlags flags;
		@disable
		this(ref return scope inout typeof(this) rhs);
		@disable
		this(this);
		this(return Stream stream, Duration dur, DG dg,
		     Receiver receiver) @trusted scope {
			this.dur = dur;
			this.dg = dg;
			this.receiver = receiver;
			stopSource = new StopSource();
			timerStopSource = new StopSource();
			op = stream.collect(cast(Properties.DG) &onItem).connect(
				SenderReceiver!(typeof(this), Properties.Value)(&this));
		}

		static if (is(Properties.ElementType == void)) {
			private void onItem() {
				with (flags.update(ThrottleFlags.timerArmed)) {
					if ((oldState & ThrottleFlags.timerArmed) == 0) {
						static if (emitLogic == ThrottleEmitLogic.first) {
							if (!push(t))
								return;
						}

						armTimer();
					} else {
						static if (timerLogic == ThrottleTimerLogic.rearm) {
							// release();
							rearmTimer();
						}
					}
				}
			}

			private bool push() {
				try {
					dg();
					return true;
				} catch (Exception e) {
					with (flags.lock(ThrottleFlags.doneOrError_produced)) {
						if ((oldState & ThrottleFlags.doneOrError_produced)
							    == 0) {
							throwable = e;
						}

						release();
						process(newState);
					}

					return false;
				}
			}
		} else {
			private void onItem(Properties.ElementType t) {
				with (flags.lock(ThrottleFlags.timerArmed)) {
					static if (emitLogic == ThrottleEmitLogic.last)
						item = t;
					release();
					if ((oldState & ThrottleFlags.timerArmed) == 0) {
						static if (emitLogic == ThrottleEmitLogic.first) {
							if (!push(t))
								return;
						}

						armTimer();
					} else {
						static if (timerLogic == ThrottleTimerLogic.rearm) {
							rearmTimer();
						}
					}
				}
			}

			private bool push(Properties.ElementType t) {
				try {
					dg(t);
					return true;
				} catch (Exception e) {
					with (flags.lock(ThrottleFlags.doneOrError_produced)) {
						if ((oldState & ThrottleFlags.doneOrError_produced)
							    == 0) {
							throwable = e;
						}

						release();
						process(newState);
					}

					return false;
				}
			}
		}

		private void setError(Throwable e) {
			with (flags.lock(ThrottleFlags.doneOrError_produced,
			                 ThrottleFlags.counter)) {
				if ((oldState & ThrottleFlags.doneOrError_produced) == 0) {
					throwable = e;
				}

				release();
				process(newState);
			}
		}

		void armTimer() {
			timerOp = receiver.getScheduler().scheduleAfter(dur)
			                  .connect(InnerReceiver(&this));
			timerOp.start();
		}

		void rearmTimer() @trusted {
			flags.update(ThrottleFlags.timerRearming);
			timerStopSource.stop();

			auto localFlags = flags.load!(MemoryOrder.acq);
			// if old timer happens to trigger anyway (or the source is done) we can stop
			if ((localFlags & ThrottleFlags.timerArmed) == 0
				    || (localFlags / ThrottleFlags.counter) > 0)
				return;

			timerStopSource.reset();

			flags.update(0, 0, ThrottleFlags.timerRearming);
			timerOp = receiver.getScheduler().scheduleAfter(dur)
			                  .connect(InnerReceiver(&this));
			timerOp.start();
		}

		void process(size_t newState) {
			auto count = newState / ThrottleFlags.counter;
			bool isDone = count == 2
				|| (count == 1 && (newState & ThrottleFlags.timerArmed) == 0);

			if (!isDone) {
				stopSource.stop();
				timerStopSource.stop();
				return;
			}

			cb.dispose();

			if (receiver.getStopToken().isStopRequested)
				receiver.setDone();
			else if ((newState & ThrottleFlags.value_produced) > 0) {
				static if (emitLogic == ThrottleEmitLogic.last) {
					if ((newState & ThrottleFlags.timerArmed) > 0) {
						try {
							static if (!is(Properties.ElementType == void))
								dg(item);
							else
								dg();
						} catch (Exception e) {
							receiver.setError(e);
							return;
						}
					}
				}

				import concurrency.receiver : setValueOrError;
				static if (is(Properties.Value == void))
					receiver.setValueOrError();
				else
					receiver.setValueOrError(value);
			} else if ((newState & ThrottleFlags.doneOrError_produced) > 0) {
				if (throwable)
					receiver.setError(throwable);
				else
					receiver.setDone();
			}
		}

		private void stop() @trusted nothrow {
			stopSource.stop();
			timerStopSource.stop();
		}

		void start() @trusted nothrow scope {
			cb = receiver.getStopToken().onStop(
				cast(void delegate() nothrow @safe shared) &this.stop
			); // butt ugly cast, but it won't take the second overload
			op.start();
		}
	}
}

struct TimerReceiver(Op, ElementType, ThrottleEmitLogic emitLogic,
                     ThrottleTimerLogic timerLogic) {
	Op* state;
	void setValue() @safe {
		with (state.flags.lock()) {
			if (was(ThrottleFlags.timerRearming))
				return;

			static if (!is(ElementType == void)
				           && emitLogic == ThrottleEmitLogic.last)
				auto item = state.item;
			release(ThrottleFlags.timerArmed);
			static if (emitLogic == ThrottleEmitLogic.last) {
				static if (!is(ElementType == void))
					state.push(item);
				else
					state.push();
			}
		}
	}

	void setDone() @safe nothrow {
		// TODO: would be nice if we can merge in next update...
		if ((state.flags.load!(MemoryOrder.acq) & ThrottleFlags.timerRearming)
			    > 0)
			return;
		with (state.flags.update(ThrottleFlags.doneOrError_produced,
		                         ThrottleFlags.counter)) {
			state.process(newState);
		}
	}

	void setError(Throwable e) nothrow @safe {
		// TODO: would be nice if we can merge in next lock...
		if ((state.flags.load!(MemoryOrder.acq) & ThrottleFlags.timerRearming)
			    > 0)
			return;
		state.setError(e);
	}

	auto getStopToken() {
		return StopToken(state.timerStopSource);
	}

	auto getScheduler() {
		return state.receiver.getScheduler();
	}
}

struct SenderReceiver(Op, Value) {
	Op* state;
	static if (is(Value == void))
		void setValue() {
			with (state.flags.update(ThrottleFlags.value_produced,
			                         ThrottleFlags.counter)) {
				state.process(newState);
			}
		}

	else
		void setValue(Value value) {
			with (state.flags.lock(ThrottleFlags.value_produced,
			                       ThrottleFlags.counter)) {
				state.value = value;
				release();
				state.process(newState);
			}
		}

	void setDone() {
		with (state.flags.update(ThrottleFlags.doneOrError_produced,
		                         ThrottleFlags.counter)) {
			state.process(newState);
		}
	}

	void setError(Throwable e) nothrow @safe {
		state.setError(e);
	}

	auto getStopToken() {
		return StopToken(state.stopSource);
	}

	auto getScheduler() {
		return state.receiver.getScheduler();
	}
}
