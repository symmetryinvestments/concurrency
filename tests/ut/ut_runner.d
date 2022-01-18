import unit_threaded;

int main(string[] args)
{
  return args.runTests!(
                        // "ut.concurrency.fork",
                        "ut.concurrency.sender",
                        "ut.concurrency.nursery",
                        "ut.concurrency.operations",
                        "ut.concurrency.pressure",
                        "ut.concurrency.pressure2",
                        "ut.concurrency.stream",
                        "ut.concurrency.slist",
                        "ut.concurrency.scheduler",
                        "ut.concurrency.thread",
                        "ut.concurrency.utils",
                        "ut.concurrency.mpsc",
                        "ut.concurrency.waitable",
                        "ut.concurrency.asyncscope",
                        );
}
