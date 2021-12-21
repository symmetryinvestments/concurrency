module concurrency.data.queue.waitable;

class WaitableQueue(Q) {
  import core.sync.semaphore : Semaphore;
  import core.time : Duration;
  import mir.algebraic : Nullable;

  private Q q;
  private Semaphore sema;

  this() @trusted {
    q = new Q();
    sema = new Semaphore();
  }

  bool push(Q.ElementType t) @trusted {
    bool r = q.push(t);
    if (r)
      sema.notify();
    return r;
  }

  Q.ElementType pop() @trusted {
    auto r = q.pop();
    if (r !is null)
      return r;

    sema.wait();
    return q.pop();
  }

  bool empty() @safe @nogc nothrow {
    return q.empty();
  }

  Q.ElementType pop(Duration max) @trusted {
    auto r = q.pop();
    if (r !is null)
      return r;

    if (!sema.wait(max))
      return null;

    return q.pop();
  }

  static if (__traits(compiles, q.producer)) {
    shared(WaitableQueueProducer!Q) producer() @trusted nothrow @nogc {
      return shared WaitableQueueProducer!Q(cast(shared)q, cast(shared)sema);
    }
  }
}

struct WaitableQueueProducer(Q) {
  import core.sync.semaphore : Semaphore;

  private shared Q q;
  private shared Semaphore sema;

  bool push(Q.ElementType t) shared @trusted {
    bool r = (cast()q).push(t);
    if (r)
      (cast()sema).notify();
    return r;
  }
}
