module concurrency.operations.via;

import concurrency;
import concurrency.receiver;
import concurrency.sender;
import concurrency.stoptoken;
import concepts;
import std.traits;

auto via(SenderA, SenderB)(SenderA a, SenderB b) {
  return ViaSender!(SenderA, SenderB)(a,b);
}

private enum NoVoid(T) = !is(T == void);

private struct ViaAReceiver(ValueB, ValueA, Receiver) {
  ValueB valueB;
  Receiver receiver;
  static if (!is(ValueA == void))
    void setValue(ValueA valueA) {
      import std.typecons : tuple;
      receiver.setValue(tuple(valueB, valueA));
    }
  else
    void setValue() {
      receiver.setValue(valueB);
    }
  void setDone() {
    receiver.setDone();
  }
  void setError(Exception e) {
    receiver.setError(e);
  }
  mixin ForwardExtensionPoints!receiver;
}
private struct ViaBReceiver(SenderA, ValueB, Receiver) {
  SenderA senderA;
  Receiver receiver;
  static if (!is(ValueB == void))
    void setValue(ValueB val) {
      senderA.connect(ViaAReceiver!(ValueB, SenderA.Value, Receiver)(val, receiver)).start();
    }
  else
    void setValue() {
      senderA.connect(receiver).start();
    }
  void setDone() {
    receiver.setDone();
  }
  void setError(Exception e) {
    receiver.setError(e);
  }
  mixin ForwardExtensionPoints!receiver;
}
private struct ViaSender(SenderA, SenderB) {
  import std.meta : Filter, AliasSeq;
  SenderA senderA;
  SenderB senderB;
  alias Values = Filter!(NoVoid, AliasSeq!(SenderA.Value, SenderB.Value));
  static if (Values.length == 0)
    alias Value = void;
  else static if (Values.length == 1)
    alias Value = Values[0];
  else {
    import std.typecons : Tuple;
    alias Value = Tuple!Values;
  }
  auto connect(Receiver)(Receiver receiver) {
    return senderB.connect(ViaBReceiver!(SenderA, SenderB.Value, Receiver)(senderA, receiver));
  }
}

