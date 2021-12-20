module concurrency.data.queue.mpsc;

struct MPSCQueueProducer(Node) {
  private MPSCQueue!(Node) q;
  void push(Node* node) shared @trusted {
    (cast()q).push(node);
  }
}

class MPSCQueue(Node) {
  alias ElementType = Node*;
  private Node* head, tail;
  private Node stub;

  this() @safe nothrow @nogc {
    head = tail = &stub;
    stub.next = null;
  }

  shared(MPSCQueueProducer!Node) producer() @trusted nothrow @nogc {
    return shared MPSCQueueProducer!Node(cast(shared)this);
  }

  /// returns true if first to push
  bool push(Node* n) @safe nothrow @nogc {
    import core.atomic : atomicExchange;
    n.next = null;
    Node* prev = atomicExchange(&head, n);
    prev.next = n;
    return prev is &stub;
  }

  bool empty() @safe nothrow @nogc {
    import core.atomic : atomicLoad;
    return head.atomicLoad is &stub;
  }

  /// returns node or null if none
  Node* pop() @safe nothrow @nogc {
    import core.atomic : atomicLoad, MemoryOrder;
    while(true) {
      Node* end = this.tail;
      Node* next = tail.next.atomicLoad!(MemoryOrder.raw);
      if (end is &stub) { // still pointing to stub
        if (null is next) // no new nodes
          return null;
        this.tail = next; // at least one node was added and stub.next points to the first one
        end = next;
        next = next.next.atomicLoad!(MemoryOrder.raw);
      }
      if (next) { // if there is at least another node
        this.tail = next;
        return end;
      }
      Node* start = this.head.atomicLoad!(MemoryOrder.raw);
      if (end !is start)
        return null;
      push(&stub);
      next = end.next.atomicLoad!(MemoryOrder.raw);
      if (next) {
        this.tail = next;
        return end;
      }
    }
  }
}
