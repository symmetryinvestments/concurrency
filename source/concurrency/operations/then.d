module concurrency.operations.then;

import concurrency;
import concurrency.receiver;
import concurrency.sender;
import concurrency.stoptoken;
import concurrency.utils;

auto then(Sender, Fun)(Sender sender, Fun fun) {
	static assert(isThreadSafeFunction!Fun);
	return ThenSender!(Sender, Fun)(sender, fun);
}

private struct ThenReceiver(Receiver, Value, Fun) {
	import std.traits : ReturnType;
	Receiver receiver;
	Fun fun;
	static if (is(Value == void)) {
		void setValue() @safe {
			static if (is(ReturnType!Fun == Result!T, T)) {
				auto r = fun();
				r.match!((Cancelled c) {
					receiver.setDone();
				}, (Exception e) {
					receiver.setError(e);
				}, (ref Result!(T).Value v) {
					static if (is(typeof(v) == Completed)) {
						receiver.setValue();
					} else {
						receiver.setValue(v.copyOrMove);
					}
				});
			} else {
				static if (is(ReturnType!Fun == void)) {
					fun();
					receiver.setValue();
				} else
					receiver.setValue(fun());
			}
		}
	} else {
		import std.typecons : isTuple;
		enum isExpandable = isTuple!Value && __traits(compiles, {
			fun(Value.init.expand);
		});
		void setValue(Value value) @safe {
			static if (is(ReturnType!Fun == Result!T, T)) {
				static if (isExpandable)
					auto r = fun(value.expand);
				else
					auto r = fun(value.copyOrMove);
				r.match!((Cancelled c) {
					receiver.setDone();
				}, (Exception e) {
					receiver.setError(e);
				}, (ref Result!(T).Value v) {
					static if (is(typeof(v) == Completed)) {
						receiver.setValue();
					} else {
						receiver.setValue(v.copyOrMove);
					}
				});
			} else static if (is(ReturnType!Fun == void)) {
				static if (isExpandable)
					fun(value.expand);
				else
					fun(value.copyOrMove);
				receiver.setValue();
			} else {
				static if (isExpandable)
					auto r = fun(value.expand);
				else
					auto r = fun(value.copyOrMove);
				receiver.setValue(r.copyOrMove);
			}
		}
	}

	void setDone() @safe nothrow {
		receiver.setDone();
	}

	void setError(Throwable e) @safe nothrow {
		receiver.setError(e);
	}

	mixin ForwardExtensionPoints!receiver;
}

struct ThenSender(Sender, Fun) {
	import std.traits : ReturnType;
	static if (is(ReturnType!fun == Result!T, T))
		alias Value = T;
	else
		alias Value = ReturnType!fun;
	Sender sender;
	Fun fun;
	auto connect(Receiver)(return Receiver receiver) @safe return scope {
		alias R = ThenReceiver!(Receiver, Sender.Value, Fun);
		// ensure NRVO
		auto op = sender.connect(R(receiver, fun));
		return op;
	}
}
