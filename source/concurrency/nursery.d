module concurrency.nursery;

import concurrency.stoptoken : StopSource, StopToken, StopCallback;
import concurrency.thread : LocalThreadExecutor;
// import concurrency.receiver : getStopToken;
import concurrency.scheduler : SchedulerObjectBase;
import std.typecons : Nullable;

/// A Nursery is a place for senders to be ran in, while being a Sender itself.
/// Stopping the Nursery cancels all senders.
/// When any Sender completes with an Error all Senders are canceled as well.
/// Cancellation is signaled with a StopToken.
/// Senders themselves bare the responsibility to respond to stop requests.
/// When cancellation happens all Senders are waited on for completion.
/// Senders can be added to the Nursery at any time.
/// Senders are only started when the Nursery itself is being awaited on.
class Nursery {
	import concurrency.sender : isSender, OperationalStateBase;
	import core.sync.mutex : Mutex;
	import concepts;
	static assert(models!(typeof(this), isSender));

	alias Value = void;
	private {
		shared StopSource stopSource;
		Node[] operations;
		struct Node {
			OperationalStateBase state;
			void start() @safe nothrow {
				state.start();
			}

			size_t id;
		}

		Mutex mutex;
		shared size_t busy =
			1; // we start at 1 to denote the Nursery is open for tasks
		shared size_t counter = 0;
		Throwable throwable; // first throwable from sender, if any
		ReceiverObject receiver;
		shared StopCallback stopCallback;
		Nursery assumeThreadSafe() @trusted shared nothrow {
			return cast(Nursery) this;
		}
	}

	this() @safe shared {
		import concurrency.utils : resetScheduler;
		resetScheduler();
		with (assumeThreadSafe) mutex = new Mutex();
	}

	bool stop() nothrow @trusted {
		auto result = stopSource.stop();

		if (result)
			(cast(shared) this).done(-1);

		return result;
	}

	bool stop() nothrow @trusted shared {
		return (cast(Nursery) this).stop();
	}

	shared(StopToken) getStopToken() nothrow @safe shared {
		return stopSource.token();
		// return shared StopToken(stopSource);
	}

	private auto getScheduler() nothrow @trusted shared {
		return (cast() receiver).getScheduler();
	}

	private void setError(Throwable e, size_t id) nothrow @safe shared {
		import core.atomic : cas;
		with (assumeThreadSafe) cas(&throwable, cast(Throwable) null,
		                            e); // store throwable if not already
		done(id);
		stop();
	}

	private void done(size_t id) nothrow @trusted shared {
		import std.algorithm : countUntil, remove;
		import core.atomic : atomicOp;

		with (assumeThreadSafe) {
			mutex.lock_nothrow();
			auto idx = operations.countUntil!(o => o.id == id);
			if (idx != -1)
				operations = operations.remove(idx);
			bool isDone = atomicOp!"-="(busy, 1) == 0 || operations.length == 0;
			auto localReceiver = receiver;
			auto localThrowable = throwable;
			if (isDone) {
				throwable = null;
				receiver = null;
				// if (stopCallback)
				stopCallback.dispose();
				// stopCallback = null;
			}

			mutex.unlock_nothrow();

			if (isDone && localReceiver !is null) {
				if (localThrowable !is null) {
					localReceiver.setError(localThrowable);
				} else if (stopSource.isStopRequested()) {
					localReceiver.setDone();
				} else {
					try {
						localReceiver.setValue();
					} catch (Exception e) {
						localReceiver.setError(e);
					}
				}
			}
		}
	}

	void run(Sender)(Nullable!Sender sender) shared if (isSender!Sender) {
		if (!sender.isNull)
			run(sender.get());
	}

	void run(Sender)(Sender sender) @trusted shared {
		import concepts;
		static assert(models!(Sender, isSender));
		import std.typecons : Nullable;
		import core.atomic : atomicOp, atomicLoad;
		import concurrency.sender : connectHeap;

		static if (is(Sender == class) || is(Sender == interface))
			if (sender is null)
				return;

		if (busy.atomicLoad() == 0)
			throw new Exception(
				"This nursery is already stopped, it cannot accept more work.");

		size_t id = atomicOp!"+="(counter, 1);
		auto op = sender.connectHeap(NurseryReceiver!(Sender.Value)(this, id));

		mutex.lock_nothrow();

		operations ~= cast(shared) Node(op, id);
		atomicOp!"+="(busy, 1);
		bool hasStarted = this.receiver !is null;
		mutex.unlock_nothrow();

		if (hasStarted)
			op.start();
	}

	auto connect(Receiver)(return Receiver receiver) @safe return scope {
		return asShared.connect(receiver);
	}

	private shared(Nursery) asShared() @trusted return scope {
		return cast(shared) this;
	}

	auto connect(Receiver)(
		return Receiver receiver
	) @trusted shared return scope {
		final class ReceiverImpl : ReceiverObject {
			Receiver receiver;
			SchedulerObjectBase scheduler;
			this(return Receiver receiver) @trusted {
				this.receiver = receiver;
			}

			void setValue() @safe {
				receiver.setValue();
			}

			void setDone() nothrow @safe {
				receiver.setDone();
			}

			void setError(Throwable e) nothrow @safe {
				receiver.setError(e);
			}

			SchedulerObjectBase getScheduler() nothrow @safe {
				import concurrency.scheduler : toSchedulerObject;
				if (scheduler is null)
					scheduler = receiver.getScheduler().toSchedulerObject();
				return scheduler;
			}

			shared(StopToken) getStopToken() nothrow @safe {
				return receiver.getStopToken();
			}
		}

		return NurseryOp(this, new ReceiverImpl(receiver));
	}

	private
	void setReceiver(ReceiverObject r) nothrow @trusted shared {
		with (assumeThreadSafe) {
			mutex.lock_nothrow();
			assert(this.receiver is null, "Cannot await a nursery twice.");
			receiver = r;
			auto dg = () nothrow @safe shared => cast(void) this.stop();
			auto stopToken = r.getStopToken;
			stopCallback.register(stopToken, dg);
			auto ops = operations.dup();
			mutex.unlock_nothrow();

			// start all work
			foreach (op; ops)
				op.start();
		}
	}
}

private interface ReceiverObject {
	void setValue() @safe;
	void setDone() nothrow @safe;
	void setError(Throwable e) nothrow @safe;
	SchedulerObjectBase getScheduler() nothrow @safe;
	shared(StopToken) getStopToken() nothrow @safe;
}

private struct NurseryReceiver(Value) {
	shared Nursery nursery;
	size_t id;
	this(shared Nursery nursery, size_t id) {
		this.nursery = nursery;
		this.id = id;
	}

	static if (is(Value == void)) {
		void setValue() @safe shared {
			(cast() this).setDone();
		}

		void setValue() @safe {
			(cast() this).setDone();
		}
	} else {
		void setValue(Value val) @trusted shared {
			(cast() this).setDone();
		}

		void setValue(Value val) @safe {
			nursery.done(id);
		}
	}

	void setDone() nothrow @safe {
		nursery.done(id);
	}

	void setError(Throwable e) nothrow @safe {
		nursery.setError(e, id);
	}

	auto getStopToken() @safe {
		return nursery.getStopToken();
	}

	auto getScheduler() @safe {
		return nursery.getScheduler();
	}
}

private struct NurseryOp {
	shared Nursery nursery;
	ReceiverObject receiver;
	@disable
	this(ref return scope typeof(this) rhs);
	@disable
	this(this);
	this(shared Nursery n,
	     ReceiverObject r) @safe {
		nursery = n;
		// this.cb = cb;
		receiver = r;
	}

	void start() nothrow scope @trusted {
		import core.atomic : atomicLoad;
		if (nursery.busy.atomicLoad == 0) {
			// cb.dispose();
			receiver.setDone();
		} else
			nursery.setReceiver(receiver);//, cb);
	}
}
