module concurrency.bitfield;

import core.atomic : atomicOp, atomicLoad, MemoryOrder;

struct Guard(Flags) {
  private SharedBitField!(Flags)* obj;
  size_t oldState, newState;
  ~this() {
    release();
  }
  void release(size_t sub = 0) {
    if (obj !is null) {
      // TODO: want to use atomicFetchSub but (proper) support is only recent
      // obj.store.atomicFetchSub!(MemoryOrder.rel)(sub | Flags.locked);
      obj.store.atomicOp!"-="(sub | Flags.locked);
    }
    obj = null;
  }
  bool was(Flags flags) {
    return (oldState & flags) == flags;
  }
}

shared struct SharedBitField(Flags) {
  static assert(__traits(compiles, Flags.locked), "Must have a 'locked' flag");
  private shared size_t store;
  static if (Flags.locked > 0) {
    Guard!Flags lock(size_t or = 0, size_t add = 0, size_t sub = 0) return scope @safe @nogc nothrow {
        return Guard!Flags(&this, update(Flags.locked | or, add, sub).expand);
      }
  }
  auto update(size_t or, size_t add = 0, size_t sub = 0) nothrow {
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
      newState = (oldState + add - sub) | or;
    } while (!casWeak!(MemoryOrder.acq, MemoryOrder.acq)(&store, oldState, newState));
    return tuple!("oldState", "newState")(oldState, newState);
  }
  auto add(size_t add) nothrow {
    return Result!Flags(store.atomicOp!"+="(add));
  }
  auto sub(size_t sub) nothrow {
    return Result!Flags(store.atomicOp!"-="(sub));
  }
  size_t load(MemoryOrder ms)() {
    return store.atomicLoad!ms;
  }
}

struct Result(Flags) {
  size_t state;
  alias state this;
  bool has(Flags flags) {
    return (state & flags) == flags;
  }
}
