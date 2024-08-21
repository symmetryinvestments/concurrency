module concurrency.data.queue.mpsc;

struct MPSCQueueProducer(Node) {
	private MPSCQueue!(Node) q;
	void push(Node* node) @trusted shared {
		(cast() q).push(node);
	}
}

final class MPSCQueue(Node) {
	import std.traits : hasUnsharedAliasing;
	alias ElementType = Node*;
	private Node* head, tail;
	private Node stub;

	static if (hasUnsharedAliasing!Node) {
		// TODO: next version add deprecated("Node has unshared aliasing")
		this() @safe nothrow @nogc {
			head = tail = &stub;
			stub.next = null;
		}
	} else {
		this() @safe nothrow @nogc {
			head = tail = &stub;
			stub.next = null;
		}
	}

	shared(MPSCQueueProducer!Node) producer() @trusted nothrow @nogc {
		return shared MPSCQueueProducer!Node(cast(shared) this);
	}

	bool push(Node* n) @trusted nothrow @nogc shared {
		return (cast() this).push(n);
	}

	/// returns true if first to push
	bool push(Node* n) @safe nothrow @nogc {
		import core.atomic : atomicExchange;
		n.next = null;
		Node* prev = atomicExchange(&head, n);
		prev.next = toShared(n);
		return prev is &stub;
	}

	bool empty() @safe nothrow @nogc {
		import core.atomic : atomicLoad;
		return head.atomicLoad is &stub;
	}

	/// returns chain with head and tail
	Chain!Node popAll() @safe nothrow @nogc {
		import core.atomic : atomicExchange;

		Node* first = atomicExchange(&head, &stub);
		Node* last = tail;
		tail = &stub;
		if (last is &stub)
			last = last.next.toUnshared();
		if (first is &stub) {
			first = null;
			last = null;
		}
		return Chain!Node(first, last);
	}

	// pushed list of items, can only be done by consumer
	bool push(Chain!Node chain) @safe nothrow @nogc {
		if (chain.head is null || chain.tail is null)
			return false;

		import core.atomic : atomicExchange;
		chain.head.next = null;
		Node* prev = atomicExchange(&head, chain.head);
		prev.next = toShared(chain.tail);
		return prev is &stub;
	}

	/// returns node or null if none
	Node* pop() @safe nothrow @nogc {
		import core.atomic : atomicLoad, MemoryOrder;
		while (true) {
			Node* end = this.tail;
			shared
			Node* next = tail.next.atomicLoad!(MemoryOrder.raw).toShared();
			if (end is &stub) { // still pointing to stub
				if (null is next) // no new nodes
					return null;
				this.tail = next
					.toUnshared(); // at least one node was added and stub.next points to the first one
				end = next.toUnshared();
				next = next.next.atomicLoad!(MemoryOrder.raw);
			}

			if (next) { // if there is at least another node
				this.tail = toUnshared(next);
				return end;
			}

			Node* start = this.head.atomicLoad!(MemoryOrder.acq);
			if (end is start) {
				push(&stub);
				next = end.next.atomicLoad!(MemoryOrder.raw).toShared();
				if (next) {
					this.tail = toUnshared(next);
					return end;
				}
			}
		}
	}

	auto opSlice() @safe nothrow @nogc {
		import core.atomic : atomicLoad, MemoryOrder;
		auto current = atomicLoad(tail);
		if (current is &stub)
			current = current.next.atomicLoad!(MemoryOrder.raw).toUnshared();
		return Iterator!(Node)(current);
	}
}

struct Chain(Node) {
	Node* head;
	Node* tail;
}

struct Iterator(Node) {
	Node* head;
	this(Node* head) @safe nothrow @nogc {
		this.head = head;
	}

	bool empty() @safe nothrow @nogc {
		return head is null;
	}

	Node* front() @safe nothrow @nogc {
		return head;
	}

	void popFront() @safe nothrow @nogc {
		import core.atomic : atomicLoad, MemoryOrder;
		head = head.next.atomicLoad!(MemoryOrder.raw).toUnshared();
	}

	Iterator!(Node) safe() {
		return Iterator!(Node)(head);
	}
}

private shared(Node*) toShared(Node)(Node* node) @trusted nothrow @nogc {
	return cast(shared) node;
}

private auto toUnshared(Node)(Node* node) @trusted nothrow @nogc {
	static if (is(Node : shared(T), T))
		return cast(T*) node;
	else
		return node;
}
