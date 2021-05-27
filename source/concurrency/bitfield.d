module concurrency.bitfield;

shared struct SharedBitField(Flags) {
  static assert(__traits(compiles, Flags.locked), "Must has a non-zero 'locked' flag");
  static assert(Flags.locked != 0, "Must has a non-zero 'locked' flag");
  struct Guard {
    private SharedBitField!(Flags)* obj;
    size_t oldState, newState;
    ~this() {
      release();
    }
    void release(Flags flags = cast(Flags)0) {
      import core.atomic : atomicOp;
      if (obj !is null)
        obj.store.atomicOp!"-="(Flags.locked | flags);
      obj = null;
    }
    bool was(Flags flags) {
      return (oldState & flags) == flags;
    }
  }
  private shared size_t store;
  Guard lock(size_t or = 0, size_t add = 0) return scope @safe @nogc nothrow {
    return Guard(&this, update(Flags.locked | or, add).expand);
  }
  auto update(size_t or, size_t add = 0) nothrow {
    import core.atomic : atomicLoad, MemoryOrder;
    import concurrency.utils : spin_yield, casWeak;
    import std.typecons : tuple;
    size_t oldState, newState;
    do {
      goto load_state;
      do {
        spin_yield();
      load_state:
        oldState = store.atomicLoad!(MemoryOrder.acq);
      } while ((oldState & Flags.locked) > 0);
      newState = (oldState + add) | or;
    } while (!casWeak!(MemoryOrder.acq, MemoryOrder.acq)(&store, oldState, newState));
    return tuple!("oldState", "newState")(oldState, newState);
  }
}

