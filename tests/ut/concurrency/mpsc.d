module ut.concurrency.mpsc;

import unit_threaded;
import concurrency.data.queue.mpsc;
import concurrency : syncWait;
import mir.algebraic : value = assumeOk;

struct Node {
  int payload;
  Node* next;
}

auto intProducer(Q)(Q q, int num) {
  import concurrency.sender : just;
  import concurrency.thread;
  import concurrency.operations;

  auto producer = q.producer();
  return just(producer, num).then((shared MPSCQueueProducer!Node producer, int num) shared {
      foreach(i; 0..num)
        producer.push(new Node(i+1));
    }).via(ThreadSender());
}

auto intSummer(Q)(Q q) {
  import concurrency.operations : withStopToken, via;
  import concurrency.thread;
  import concurrency.sender : justFrom, just;
  import concurrency.stoptoken : StopToken;
  import core.time : msecs;

  return just(q).withStopToken((StopToken stopToken, Q q) shared @safe {
      int sum = 0;
      while (!stopToken.isStopRequested()) {
        if (auto node = q.pop()) {
          sum += node.payload;
        }
      }
      while (true) {
        if (auto node = q.pop())
          sum += node.payload;
        else
          break;
      }
      return sum;
    }).via(ThreadSender());
}

@("single")
@safe unittest {
  import concurrency.operations : race, stopWhen;
  import core.time : msecs;

  auto q = new MPSCQueue!Node();
  q.intSummer.stopWhen(intProducer(q, 50000)).syncWait.value.should == 1250025000;
  q.empty.should == true;
}

@("race")
@safe unittest {
  import concurrency.operations : race, stopWhen, whenAll;

  auto q = new MPSCQueue!Node();
  q.intSummer.stopWhen(whenAll(intProducer(q, 10000),
                               intProducer(q, 10000),
                               intProducer(q, 10000),
                               intProducer(q, 10000),
                               )).syncWait.value.should == 200020000;
  q.empty.should == true;
}
