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

@("deferSequence.function")
@safe unittest {
    deferSequence(() => just(42)).take(2).toList().syncWait.value.should == [42,42];
}

@("deferSequence.callable")
@safe unittest {
    static struct S {
        int i;
        this(int i) {
            this.i = i;
        }
        auto opCall() @safe shared {
            return just(i);
        }
    }
    deferSequence(shared S(27)).take(2).toList().syncWait.value.should == [27,27];
}


@("deferSequence.timer")
@safe unittest {
    import core.time : msecs;
    deferSequence(() => ScheduleAfter(1.msecs)).take(4).toList().syncWait.isOk.should == true;
}

