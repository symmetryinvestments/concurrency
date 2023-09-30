module ut.concurrency.stoptoken;

import concurrency.stoptoken;
import unit_threaded;

@("stopsource.stoptoken.stop") @safe
unittest {
	auto source = shared InPlaceStopSource();
    auto token = StopToken(source);
    token.isStopRequested.should == false;
    source.stop();
    token.isStopRequested.should == true;
}

@("stopsource.stopcallback.stop") @safe
unittest {
    import core.atomic;
	auto source = shared InPlaceStopSource();
    auto token = StopToken(source);
    shared bool set;
    token.onStop(() shared { set.atomicStore(true); });
    set.atomicLoad.should == false;
    source.stop();
    set.atomicLoad.should == true;
}

@("stopsource.inplacestopcallback.stop") @safe
unittest {
    import core.atomic;
	auto source = shared InPlaceStopSource();
    auto token = StopToken(source);
    shared bool set;
    InPlaceStopCallback cb = InPlaceStopCallback(() shared { set.atomicStore(true); });
    token.onStop(cb);
    set.atomicLoad.should == false;
    source.stop();
    set.atomicLoad.should == true;
}

@("inplacestopsource.stoptoken.stop") @safe
unittest {
	auto source = shared InPlaceStopSource();
    auto token = StopToken(source);
    token.isStopRequested.should == false;
    source.stop();
    token.isStopPossible.should == true;
}

@("inplacestopsource.stopcallback.stop") @safe
unittest {
    import core.atomic;
	auto source = shared InPlaceStopSource();
    auto token = StopToken(source);
    shared bool set;
    token.onStop(() shared { set.atomicStore(true); });
    set.atomicLoad.should == false;
    source.stop();
    set.atomicLoad.should == true;
}

@("inplacestopsource.inplacestopcallback.stop") @safe
unittest {
    import core.atomic;
	auto source = shared InPlaceStopSource();
    auto token = StopToken(source);
    shared bool set;
    InPlaceStopCallback cb = InPlaceStopCallback(() shared { set.atomicStore(true); });
    token.onStop(cb);
    set.atomicLoad.should == false;
    source.stop();
    set.atomicLoad.should == true;
}

@("inplacestopsource.stopcallback.dispose") @safe
unittest {
    import core.atomic;
	auto source = shared InPlaceStopSource();
    auto token = StopToken(source);
    shared bool set;
    auto cb = token.onStop(() shared { set.atomicStore(true); });
    set.atomicLoad.should == false;
    cb.dispose();
    source.stop();
    set.atomicLoad.should == false;
}

@("inplacestopsource.inplacestopcallback.dispose") @safe
unittest {
    import core.atomic;
	auto source = shared InPlaceStopSource();
    auto token = StopToken(source);
    shared bool set;
    InPlaceStopCallback cb = InPlaceStopCallback(() shared { set.atomicStore(true); });
    token.onStop(cb);
    set.atomicLoad.should == false;
    cb.dispose();
    source.stop();
    set.atomicLoad.should == false;
}
