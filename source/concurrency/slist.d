module concurrency.slist;

import core.atomic : atomicLoad, atomicExchange;
import concurrency.utils : casWeak;

/// A lock-free single linked list
shared struct SList(T) {
  struct Node {
    shared(Node*) next;
    T payload;
  }
  Node* head;

  void pushFront(T payload) @trusted {
    auto node = new shared Node(atomicLoad(head), cast(shared(T))payload);
    while (!casWeak(&head, node.next, node))
      node.next = atomicLoad(head);
  }

  void pushBack(T payload) @trusted {
    auto node = new shared Node(null, cast(shared(T))payload);
    while (true) {
      auto last = getLast();
      if (last is null) {
        if (casWeak(&head, cast(shared(Node*))null, node))
          return;
      } else {
        auto lastNext = atomicLoad(last.next);
        if (!isMarked(lastNext) && casWeak(&last.next, cast(shared(Node*))null, node))
          return;
      }
    }
  }

  auto release() @safe {
    auto old = atomicExchange(&head, cast(shared(Node*))null);
    return Iterator!T(old);
  }

  private shared(Node)* getLast() @trusted {
    auto current = atomicLoad(head);
    if (current is null)
      return null;
    while (true) {
      auto next = clearMark(atomicLoad(current.next));
      if (next is null)
        break;
      current = next;
    }
    return current;
  }

  auto opSlice() return @safe {
    return Iterator!T(head);
  }

  bool remove(T payload) @trusted {
    auto iter = this[];
    while (!iter.empty) {
      if (iter.front == cast(shared(T))payload) {
        if (remove(iter.node))
          return true;
      }
      iter.popFront();
    }
    return false;
  }

  private bool remove(shared(Node*) node) @trusted {
    // step 1, mark the next ptr to signify this one is logically deleted
    shared(Node*) ptr;
    shared(Node*)* currentNext;
    do {
      ptr = atomicLoad(node.next);
      if (isMarked(ptr))
        return false;
    } while (!casWeak(&node.next, ptr, mark(ptr)));
    // step 2, iterate until next points to node, then cas
  retry:
    currentNext = &head;
    while (true) {
      ptr = atomicLoad(*currentNext);
      if (clearMark(ptr) is null)
        return false;
      if (clearMark(ptr) is node) {
        if (isMarked(ptr))
          goto retry;

        if (casWeak(currentNext, ptr, clearMark(node.next)))
          return true;
        goto retry;
      }
      currentNext = &clearMark(ptr).next;
    }
    assert(0);
  }
}

static bool isMarked(T)(T* p)
{
  return (cast(size_t)p & 1) != 0;
}

static T* mark(T)(T* p)
{
  return cast(T*)(cast(size_t)p | 1);
}

static T* clearMark(T)(T* p)
{
  return cast(T*)(cast(size_t)p & ~1);
}

struct Iterator(T) {
  alias Node = SList!T.Node;
  shared(Node*) current;
  this(shared(Node*) head) @safe nothrow {
    current = head;
  }
  bool empty() @trusted nothrow {
    if (current is null)
      return true;
    while (isMarked(current.next)) {
      current = clearMark(atomicLoad(current.next));
      if (current is null)
        return true;
    }
    return false;
  }
  shared(T) front() @safe nothrow {
    return current.payload;
  }
  shared(Node*) node() @safe nothrow {
    return current;
  }
  void popFront() @trusted nothrow {
    current = clearMark(atomicLoad(current.next));
  }
}
