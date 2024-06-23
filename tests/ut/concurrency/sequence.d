module ut.concurrency.sequence;

import concurrency.sequence;
import concurrency;
import unit_threaded;

@("sequence.trampoline")
@safe unittest {
    import std.range : iota;
    iota(0,100).sequence.toList.syncWait.value.length.should == 100;
    iota(0,100).sequence.toList.syncWait.value.length.should == 100;
}

@("collect")
@safe unittest {
    [1,2,3,4].sequence.collect((int i) {}).syncWait.isOk.should == true;
}

@("toList")
@safe unittest {
    [1,2,3,4].sequence.toList().syncWait.value.should == [1,2,3,4];
}

@("transform")
@safe unittest {
    [1,2,3,4].sequence.transform((int i) => i*2).toList().syncWait.value.should == [2,4,6,8];
}

@("filter")
@safe unittest {
    [1,2,3,4].sequence.filter((int i) => i%2 == 0).toList().syncWait.value.should == [2,4];
}

@("take")
@safe unittest {
    [1,2,3,4].sequence.take(3).toList().syncWait.value.should == [1,2,3];
}
