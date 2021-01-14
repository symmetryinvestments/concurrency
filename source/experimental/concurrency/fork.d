module concurrency.fork;

import concurrency.sender;
import concurrency.executor;

// TODO: fork is an scheduler :)
// therefor the Function fun could be a `then` continuation

version (Posix)
struct ForkSender {
  static struct Operation(Receiver) {
    private {
      Executor executor;
      VoidDelegate fun;
      Receiver receiver;
      void delegate(int) afterFork;
    }
    void start() {
      import core.sys.posix.sys.wait;
      import core.sys.posix.sys.select;
      import core.sys.posix.unistd;
      import core.stdc.errno;
      import core.stdc.stdlib;
      import core.stdc.string : strerror;
      import std.string : fromStringz;
      import std.format : format;

      auto token = receiver.getStopToken();
      executeInNewThread(() shared{
          auto pid = executor.executeAndWait((VoidDelegate fun) {
              auto r = fork();
              if (r != 0)
                return r;

              reinitThreadLocks();
              detachOtherThreads();
              drainMessageBox();
              try {
                (cast()fun)();
              } catch (Throwable t) {
                exit(1);
              }
              exit(0);
              assert(0);
            }, fun);

          if (pid == -1) {
            receiver.setError(new Exception("Failed to fork, %s".format(strerror(errno).fromStringz)));
            return;
          }
          import core.sys.posix.signal : kill, SIGINT;

          if (afterFork)
            afterFork(pid);
          auto cb = token.onStop(closure((int pid) @trusted shared nothrow => cast(void)kill(pid, SIGINT), pid));
          int status;
          auto ret = waitpid(pid, &status, 0);
          cb.dispose();
          if (ret == -1) {
            receiver.setError(new Exception("Failed to wait for child, %s".format(strerror(errno).fromStringz)));
          }
          else if (WIFSIGNALED(status)) {
            auto exitsignal = WTERMSIG(status);
            receiver.setError(new Exception("Child exited by signal %d".format(exitsignal)));
          }
          else if (WIFEXITED(status)) {
            auto exitstatus = WEXITSTATUS(status);
            if (exitstatus == 0)
              receiver.setValue();
            else
              receiver.setError(new Exception("Child exited with %d".format(exitstatus)));
          }
          else {
            receiver.setError(new Exception("Child unknown exit"));
          }
        });
    }
  }
  private Executor executor;
  private VoidDelegate fun;
  private void delegate(int) afterFork;
  this(Executor executor, VoidDelegate fun, void delegate(int) afterFork = null) {
    this.executor = executor;
    this.fun = fun;
    this.afterFork = afterFork;
  }
  Operation connect(Receiver)(Receiver receiver) {
    return Operation(executor, fun, receiver, afterFork);
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

    while(receiveTimeout(seconds(-1),(Variant v){})) {}
  }
}
