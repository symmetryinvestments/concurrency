module concurrency.operations.mapresult;

import concurrency;
import concurrency.receiver;
import concurrency.sender;
import concurrency.stoptoken;
import concurrency.syncwait;
import concepts;
import std.traits : TemplateOf, TemplateArgsOf, ReturnType;

/// maps all three completions
auto mapResult(Sender, MapFunction)(Sender sender, MapFunction mapFunction) {
	import concurrency.utils : isThreadSafeFunction;
	import std.traits : ReturnType;

	alias R = ReturnType!MapFunction;
	static assert(__traits(isSame, TemplateOf!R, Result));
	static assert(isThreadSafeFunction!MapFunction);
	return MapResultSender!(Sender, MapFunction)(sender, mapFunction);
}

alias ReturnedValue(T) = TemplateArgsOf!(ReturnType!(T))[0];

private struct MapResultReceiver(Value, MapFunction, Receiver) {
	Receiver receiver;
	MapFunction mapFunction;
	alias FinalValue = ReturnedValue!MapFunction;
	static if (is(Value == void))
		void setValue() @safe {
			mapAndForward(Result!(Value)());
		}

	else
		void setValue(Value value) @safe {
			mapAndForward(Result!(Value)(value));
		}

	void setDone() @trusted nothrow {
		mapAndForward(Result!(Value)(Cancelled()));
	}

	void setError(Throwable e) @trusted nothrow {
		if (auto ex = cast(Exception) e) {
			return mapAndForward(Result!(Value)(ex));
		}

		receiver.setError(e);
	}

	private void mapAndForward(Result!(Value) value) @trusted nothrow {
		try {
			auto result = mapFunction(value);
			static if (is(FinalValue == void)) {
				result.match!(
					(Exception e) => receiver.setError(e),
					(Cancelled c) => receiver.setDone(),
					(Completed c) => receiver.setValue(),
				);
			} else {
				result.match!(
					(Exception e) => receiver.setError(e),
					(Cancelled c) => receiver.setDone(),
					(ref FinalValue v) => receiver.setValue(v),
				);
			}
		} catch (Exception e) {
			// TODO: Should we chain the exceptions?
			receiver.setError(e);
		} catch (Throwable t) {
			import concurrency.error : clone;
			return receiver.setError(t.clone);
		}
	}

	mixin ForwardExtensionPoints!receiver;
}

struct MapResultSender(Sender, MapFunction) { // if (models!(Sender, isSender)) {
	alias Value = ReturnedValue!MapFunction;
	Sender sender;
	MapFunction mapFunction;
	auto connect(Receiver)(return Receiver receiver) @safe return scope {
		// ensure NRVO
		auto op = sender.connect(MapResultReceiver!(Sender.Value, MapFunction,
		                                           Receiver)(receiver, mapFunction));
		return op;
	}
}
