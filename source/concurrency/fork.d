module concurrency.fork;

import concurrency.sender;
import concurrency.executor;
import concepts;

// TODO: fork is an scheduler :)
// therefor the Function fun could be a `then` continuation

version(Posix)
	struct ForkSender {
		alias Value = void;
		static assert(models!(typeof(this), isSender));
		alias Fun = void delegate() shared;
		alias AfterFork = void delegate(int);
		static struct Operation(Receiver) {
			private {
				Executor executor;
				void delegate() shared fun;
				Receiver receiver;
				void delegate(int) afterFork;
				void run() {
					import concurrency.thread : executeInNewThread,
					                            executeAndWait;
					import concurrency.stoptoken;
					import core.sys.posix.sys.wait;
					import core.sys.posix.sys.select;
					import core.sys.posix.unistd;
					import core.stdc.errno;
					import core.stdc.stdlib;
					import core.stdc.string : strerror;
					import std.string : fromStringz;
					import std.format : format;

					auto token = receiver.getStopToken();
					shared pid =
						executor.executeAndWait((void delegate() shared fun) {
							auto r = fork();
							if (r != 0)
								return r;

							reinitThreadLocks();
							detachOtherThreads();
							drainMessageBox();
							setMainThread();
							try {
								(cast() fun)();
							} catch (Throwable t) {
								exit(1);
							}

							exit(0);
							assert(0);
						}, fun);

					if (pid == -1) {
						receiver.setError(new Exception("Failed to fork, %s"
							.format(strerror(errno).fromStringz)));
						return;
					}

					import core.sys.posix.signal : kill, SIGINT;

					if (afterFork)
						afterFork(pid);
					shared StopCallback cb;
					cb.register(token, () @trusted shared nothrow =>
						cast(void) kill(pid, SIGINT));
					int status;
					auto ret = waitpid(pid, &status, 0);
					cb.dispose();
					if (ret == -1) {
						receiver.setError(new Exception(
							"Failed to wait for child, %s"
								.format(strerror(errno).fromStringz)));
					} else if (WIFSIGNALED(status)) {
						auto exitsignal = WTERMSIG(status);
						receiver.setError(new Exception(
							"Child exited by signal %d".format(exitsignal)));
					} else if (WIFEXITED(status)) {
						auto exitstatus = WEXITSTATUS(status);
						if (exitstatus == 0)
							receiver.setValue();
						else
							receiver.setError(new Exception(
								"Child exited with %d".format(exitstatus)));
					} else {
						receiver.setError(new Exception("Child unknown exit"));
					}
				}
			}

			this(Executor executor, Fun fun, Receiver receiver,
			     AfterFork afterFork) {
				this.executor = executor;
				this.fun = fun;
				this.receiver = receiver;
				this.afterFork = afterFork;
			}

			void start() @trusted nothrow {
				import concurrency.thread : executeInNewThread, executeAndWait;
				import concurrency.utils : closure;

				executeInNewThread(
					cast(void delegate() @safe shared) &this.run);
			}
		}

		private Executor executor;
		private void delegate() shared fun;
		private void delegate(int) afterFork;
		this(
			Executor executor,
			void delegate() shared fun,
			void delegate(int) afterFork = null
		) @system { // forking is dangerous so this is @system
			this.executor = executor;
			this.fun = fun;
			this.afterFork = afterFork;
		}

		auto connect(Receiver)(return Receiver receiver) @safe return scope {
			return new Operation!Receiver(executor, fun, receiver, afterFork);
		}

		static void reinitThreadLocks() {
			import core.thread : Thread;

			__traits(getMember, Thread, "initLocks")();
		}

		// After forking there is only one thread left, but others (if any) are still registered, we need to detach them else the GC will fail suspending them during a GC cycle
		static private void detachOtherThreads() {
			import core.thread : Thread, thread_detachInstance;
			import core.memory : GC;

			GC.disable();
			auto threads = Thread.getAll();
			auto thisThread = Thread.getThis();
			foreach (t; threads) {
				if (t != thisThread)
					thread_detachInstance(t);
			}

			GC.enable();
		}

		static private void drainMessageBox() {
			import std.concurrency : receiveTimeout;
			import std.variant : Variant;
			import core.time : seconds;
			import std.concurrency : thisTid;
			thisTid(); // need to call otherwise the messagebox might be empty and receiveTimeout will assert

			while (receiveTimeout(seconds(-1), (Variant v) {})) {}
		}

		// after fork there is only one thread left, it is possible
		// that wasn't the main thread in the 'old' program, so
		// we overwrite the global to point to the only thread left
		// in the (forked) process
		static private void setMainThread() {
			import core.thread : Thread;

			__traits(getMember, Thread, "sm_main") = Thread.getThis();
		}
	}
