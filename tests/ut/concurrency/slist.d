module ut.concurrency.slist;

import concurrency.slist;
import concurrency.sender;
import concurrency.operations.whenall;
import concurrency.operations.then;
import concurrency.operations.via;
import concurrency.thread : ThreadSender;
import concurrency : syncWait;
import std.range : walkLength;
import unit_threaded;

@("pushFront.race")
@safe unittest {
  auto list = new shared SList!int;

  auto filler = just(list).then((shared SList!int list) @safe shared {
      foreach(i; 0..100) {
        list.pushFront(i);
      }
    }).via(ThreadSender());

  whenAll(filler, filler).syncWait();

  list[].walkLength.should == 200;
}

@("pushBack.race")
@safe unittest {
  auto list = new shared SList!int;

  auto filler = just(list).then((shared SList!int list) @safe shared {
      foreach(i; 0..100) {
        list.pushBack(i);
      }
    }).via(ThreadSender());

  whenAll(filler, filler).syncWait();

  list[].walkLength.should == 200;
}

@("pushFront.adversary")
@safe unittest {
  auto list = new shared SList!int;

  foreach(i; 0..50)
    list.pushFront(1);

  auto filler = just(list).then((shared SList!int list) @safe shared {
      foreach(i; 0..50) {
        list.pushFront(1);
      }
    }).via(ThreadSender());
  auto remover = just(list).then((shared SList!int list) @safe shared {
      foreach(i; 0..50) {
        list.remove(1);
      }
    }).via(ThreadSender());

  whenAll(filler, remover).syncWait();

  list[].walkLength.should == 50;
}

@("pushBack.adversary")
@safe unittest {
  auto list = new shared SList!int;

  auto filler = just(list).then((shared SList!int list) @safe shared {
      foreach(i; 0..100) {
        list.pushBack(1);
      }
    }).via(ThreadSender());
  auto remover = just(list).then((shared SList!int list) @safe shared {
      int n = 0;
      while(n < 99)
        if (list.remove(1))
          n++;
    }).via(ThreadSender());

  whenAll(filler, remover).syncWait();

  list[].walkLength.should == 1;
}

@("remove.race")
@safe unittest {
  auto list = new shared SList!int;

  foreach(i; 0..100)
    list.pushFront(i);

  auto remover = just(list).then((shared SList!int list) @safe shared {
      foreach(i; 0..100) {
        if (i % 10 > 4)
          list.remove(i);
      }
    }).via(ThreadSender());

  whenAll(remover, remover).syncWait();

  list[].walkLength.should == 50;
}

@("remove.adjacent")
@safe unittest {
  auto list = new shared SList!int;

  foreach(_; 0..2)
    foreach(i; 0..100)
      list.pushFront(i);

  auto remover1 = just(list).then((shared SList!int list) @safe shared {
      foreach(i; 0..100) {
        if (i % 2 == 0)
          list.remove(i);
      }
    }).via(ThreadSender());
  auto remover2 = just(list).then((shared SList!int list) @safe shared {
      foreach(i; 0..100) {
        if (i % 2 == 1)
          list.remove(i);
      }
    }).via(ThreadSender());

  whenAll(remover1, remover2, remover1, remover2).syncWait();

  list[].walkLength.should == 0;
}
