import unit_threaded;

int main(string[] args)
{
  return args.runTests!(
                        "ut.concurrency.sender",
                        "ut.concurrency.nursery"
                        );
}
