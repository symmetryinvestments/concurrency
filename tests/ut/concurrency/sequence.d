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
    [1,2,3,4].sequence.transform((int i){}).toList().syncWait.isOk.should == true;
}

@("filter")
@safe unittest {
    [1,2,3,4].sequence.filter((int i) => i%2 == 0).toList().syncWait.value.should == [2,4];
}

@("take")
@safe unittest {
    [1,2,3,4].sequence.take(3).toList().syncWait.value.should == [1,2,3];
    [1,2,3,4].sequence.take(3).transform((int i) => i*2).toList().syncWait.value.should == [2,4,6];
    [1,2,3,4].sequence.transform((int i) => i*2).take(3).toList().syncWait.value.should == [2,4,6];
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

@("trampolineScheduler")
@safe unittest {
    import core.time : msecs;
    import concurrency.operations : on;
    TrampolineScheduler s;
    ScheduleAfter(1.msecs).on(s).syncWait().isOk.should == true;
}

@("deferSequence.timer")
@safe unittest {
    import core.time : msecs;
    deferSequence(() => ScheduleAfter(1.msecs)).take(4).toList().syncWait.isOk.should == true;
}

@("interval")
@safe unittest {
    import core.time : msecs;
    interval(1.msecs, false).take(1).toList.syncWait.isOk.should == true;
}

@("flatten.sender.just")
@safe unittest {
    just(just(77)).flatten.syncWait.value.should == 77;
}

@("flatten.sender.ScheduleAfter")
@safe unittest {
    import core.time : msecs;

    just(ScheduleAfter(1.msecs)).flatten.syncWait.isOk.should == true;
}

@("flatten.sender.sequence")
@safe unittest {
    import core.time : msecs;

    just([1,2,3,4].sequence).flatten.toList().syncWait.value.should == [1,2,3,4];
}

@("flatten.sequence.sender")
@safe unittest {
    import core.time : msecs;
    import std.algorithm : map;

    [just(1),just(2)].sequence.flatten.toList().syncWait.value.should == [1,2];
    [1,2,3,4].map!(i => just(i)).sequence.flatten.toList().syncWait.value.should == [1,2,3,4];
}

@("flatten.sequence.sequence")
@safe unittest {
    import core.time : msecs;
    import std.algorithm : map;

    [[1,2].sequence, [2,3].sequence].sequence.flatten.toList().syncWait.value.should == [1,2,2,3];
}

@("flatten.sequence.VoidSender")
@safe unittest {
    import core.time : msecs;

    [VoidSender()].sequence.flatten.toList().syncWait.isOk.should == true;
}

@("flatMap.just")
@safe unittest {
    import core.time : msecs;
    [1,2,3].sequence.flatMap((int i) => just(i*3)).toList().syncWait.value.should == [3,6,9];
}

@("nextTransform")
@safe unittest {
    static struct Transformer {
        auto setNext(Sender)(Sender s) {
            return s;
        }
    }
    just([1,2].sequence).flatten.nextTransform(Transformer()).toList.syncWait.value.should == [1,2];
}

@("scan.value")
@safe unittest {
    [1,1,1,1].sequence.scan((int i, int acc) => acc + i, 0).toList().syncWait.value.should == [1,2,3,4];
}

@("scan.void")
@safe unittest {
    import core.time : msecs;
    interval(1.msecs, false).scan((int acc) => acc + 1, 0).take(4).toList.syncWait.value.should == [1,2,3,4];
    interval(1.msecs, false).take(4).scan((int acc) => acc + 1, 0).toList.syncWait.value.should == [1,2,3,4];
}

@("iotaSequence.basic")
@safe unittest {
    iotaSequence(5, 10).toList().syncWait.value.should == [5,6,7,8,9];
}

@("filterMap.int")
@safe unittest {
    import std.typecons : Nullable;
    [1,2,3,4].sequence.filterMap((int i) {
        if (i > 2)
            return Nullable!(int)(i*3);
        else
            return Nullable!(int).init;
    }).toList().syncWait.value.should == [9,12];
}

@("filterMap.void")
@safe unittest {
    import core.time : msecs;
    import std.typecons : Nullable;
    interval(1.msecs, false).filterMap(() {
        return Nullable!int(1);
    }).take(4).toList().syncWait.value.should == [1,1,1,1];
}
