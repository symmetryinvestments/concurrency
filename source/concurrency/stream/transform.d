module concurrency.stream.transform;

import concurrency.stream.stream;
import concurrency.sender : OpType;
import concurrency.receiver : ForwardExtensionPoints;
import concurrency.stoptoken : StopSource;
import std.traits : ReturnType;
import concurrency.utils : isThreadSafeFunction;
import concepts;

auto transform(Stream, Fun)(Stream stream, Fun fun) if (models!(Stream, isStream)) {
  static assert(isThreadSafeFunction!Fun);
  alias Properties = StreamProperties!Stream;
  return fromStreamOp!(ReturnType!Fun, Properties.Value, TransformStreamOp!(Stream, Fun))(stream, fun);
}

template TransformStreamOp(Stream, Fun) {
  static assert(isThreadSafeFunction!Fun);
  alias Properties = StreamProperties!Stream;
  alias InnerElementType = ReturnType!Fun;
  alias DG = CollectDelegate!(InnerElementType);
  struct TransformStreamOp(Receiver) {
    alias Op = OpType!(Properties.Sender, Receiver);
    Fun fun;
    DG dg;
    Op op;
    @disable this(ref return scope typeof(this) rhs);
    @disable this(this);
    this(Stream stream, Fun fun, DG dg, Receiver receiver) @trusted {
      this.fun = fun;
      this.dg = dg;
      op = stream.collect(cast(Properties.DG)&item).connect(receiver);
    }
    static if (is(Properties.ElementType == void))
      void item() {
        static if (is(InnerElementType == void)) {
          fun();
          dg();
        } else
          dg(fun());
      }
    else
      void item(Properties.ElementType t) {
        static if (is(InnerElementType == void)) {
          fun(t);
          dg();
        } else
          dg(fun(t));
      }
    void start() nothrow @safe {
      op.start();
    }
  }
}
