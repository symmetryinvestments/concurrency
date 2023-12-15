module ut.concurrency.stoptoken;

import concurrency.stoptoken;
import unit_threaded;
import std.encoding;

@("stopsource.isStopRequested.stop") @safe
unittest {
	auto source = shared StopSource();
    source.isStopRequested.should == false;
    source.stop();
    source.isStopRequested.should == true;
}

@("stopsource.isStopRequested.reset") @safe
unittest {
	auto source = shared StopSource();
    source.stop();
    source.isStopRequested.should == true;
    source.reset();
    source.isStopRequested.should == false;
}

@("stopsource.reset") @safe
unittest {
	auto source = shared StopSource();
    auto token = source.token();
    shared StopCallback cb;
    cb.register(token, () shared { });
    source.reset();
    source.assertNoCallbacks();
}

@("stopsource.no-copy") @safe
unittest {
    auto source = shared StopSource();
    /// Disallow copy
    static assert(!__traits(compiles, { shared s2 = source; }));
}

@("stopsource.no-assign") @safe
unittest {
    auto source = shared StopSource();
    auto source2 = shared StopSource();
    /// Disallow assign
    static assert(!__traits(compiles, { source = shared StopSource(); }));
    static assert(!__traits(compiles, { source = source2; }));
}

@("stoptoken.isStopRequested") @safe
unittest {
	auto source = shared StopSource();
    auto token = source.token();
    token.isStopRequested.should == false;
    source.stop();
    token.isStopRequested.should == true;
}

@("stoptoken.lifetime") @safe
unittest {
    shared StopToken token;
    {
	    auto source = shared StopSource();
        /// Error: address of variable `source` assigned to `token` with longer lifetime
        static assert(!__traits(compiles, () @safe { token = source.token(); }));
    }
}

@("stoptoken.scope.no-escape") @safe
unittest {
    shared StopToken t1;
    {
	    shared source = shared StopSource();
        auto token = source.token();
        auto t2 = token;

        // assert that token can't escape the StopSource
        static assert(!__traits(compiles, t1 = token));
        // assert that a copy can't escape the StopSource
        static assert(!__traits(compiles, t1 = t2));
    }
}

@("stopcallback.lifetime") @safe
unittest {
    shared StopCallback cb;
    {
	    auto source = shared StopSource();
        auto token = source.token();
        /// We don't allow address of variable `token` to be assigned to `cb` with longer lifetime
        static assert(!__traits(compiles, () @safe { cb.place(() shared { }, token); }));
    }
}

@("stopcallback.opassign") @safe
unittest {
    shared StopCallback cb1;
    shared StopCallback cb2;
    StopCallback cb3;
    /// Disallow assign
    static assert(!__traits(compiles, { cb1 = shared StopCallback(); }));
    static assert(!__traits(compiles, { cb1 = cb2; }));
    static assert(!__traits(compiles, { cb1 = StopCallback(); }));
    static assert(!__traits(compiles, { cb1 = cb3; }));
}

@("stopsource.StopCallback.stop") @safe
unittest {
    import core.atomic;
	auto source = shared StopSource();
    auto token = source.token();
    shared bool set;
    shared StopCallback cb;
    cb.register(token, () shared { set.atomicStore(true); });
    set.atomicLoad.should == false;
    source.stop();
    set.atomicLoad.should == true;
}

@("stopsource.StopCallback.reset") @safe
unittest {
    import core.atomic;
	auto source = shared StopSource();
    auto token = source.token();
    shared bool set;
    shared StopCallback cb;
    cb.register(token, () shared { set.atomicStore(true); });
    set.atomicLoad.should == false;
    source.reset();
    set.atomicLoad.should == true;
}

@("StopSource.stoptoken.stop") @safe
unittest {
	auto source = shared StopSource();
    auto token = source.token();
    token.isStopRequested.should == false;
    source.stop();
    token.isStopRequested.should == true;
}

@("StopSource.StopCallback.stop") @safe
unittest {
    import core.atomic;
	auto source = shared StopSource();
    auto token = source.token();
    shared bool set;
    shared StopCallback cb;
    cb.register(token, () shared { set.atomicStore(true); });
    set.atomicLoad.should == false;
    source.stop();
    set.atomicLoad.should == true;
}

@("StopSource.StopCallback.dispose") @safe
unittest {
    import core.atomic;
	auto source = shared StopSource();
    auto token = source.token();
    shared bool set;
    shared StopCallback cb;
    cb.register(token, () shared { set.atomicStore(true); });
    set.atomicLoad.should == false;
    cb.dispose();
    source.stop();
    set.atomicLoad.should == false;
}
