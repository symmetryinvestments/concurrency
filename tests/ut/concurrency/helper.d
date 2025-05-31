module ut.concurrency.helper;

struct Uncopyable {
    int p;
    @disable
    this(ref return scope typeof(this) rhs);
    @disable
    this(this);
}
