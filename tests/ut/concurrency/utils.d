module ut.concurrency.utils;

import concurrency.utils;

@("isThreadSafeFunction")
@safe unittest {
  auto local = (int i) => i*2;
  static assert(isThreadSafeFunction!local);

  int j = 42;
  auto unsharedClosure = (int i) => i*j;
  static assert(!isThreadSafeFunction!unsharedClosure);

  shared int k = 13;
  auto sharedClosure = (int i) shared => i*k;
  static assert(isThreadSafeFunction!sharedClosure);

  static int system() @system { return 42; }
  auto systemLocal = (int i) => i * system();
  static assert(!isThreadSafeFunction!systemLocal);

  auto systemSharedClosure = (int i) shared => i * system() * k;
  static assert(!isThreadSafeFunction!systemSharedClosure);

  auto trustedSharedClosure = (int i) shared @trusted => i * system() * k;
  static assert(isThreadSafeFunction!trustedSharedClosure);
}

@("isThreadSafeCallable.no.safe")
@safe unittest {
  static struct S {
    void opCall() shared @system {
    }
  }
  static assert(!isThreadSafeCallable!S);
}

@("isThreadSafeCallable.no.shared")
@safe unittest {
  static struct S {
    void opCall() @safe {
    }
  }
  static assert(!isThreadSafeCallable!S);
}

@("isThreadSafeCallable.yes")
@safe unittest {
  static struct S {
    void opCall() @safe shared {
    }
  }
  static assert(isThreadSafeCallable!(shared S));
}
