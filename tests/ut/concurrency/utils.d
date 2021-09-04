module ut.concurrency.utils;

@("isThreadSafeFunction")
unittest {
  import concurrency.utils : isThreadSafeFunction;

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
