module concurrency.error;

// In order to handle Errors that get thrown on non-main threads we have to make a clone. There are cases where the Error is constructed in TLS, which either might be overwritten with another Error (if the thread continues work and hits another Error), or might point to invalid memory once the thread is cleaned up. In order to be safe we have to clone the Error.

class ThrowableClone(T : Throwable) : T {
	this(Args...)(Throwable.TraceInfo info, Args args) @safe nothrow {
		super(args);
		if (info)
			this.info = new ClonedTraceInfo(info);
	}
}

// The reason it accepts a Throwable is because there might be classes that derive directly from Throwable but aren't Exceptions. We treat them as errors here.
Throwable clone(Throwable t) nothrow @safe {
	import core.exception;
	if (auto a = cast(AssertError) t)
		return new ThrowableClone!AssertError(t.info, a.msg, a.file, a.line,
		                                      a.next);
	if (auto r = cast(RangeError) t)
		return new ThrowableClone!RangeError(t.info, r.file, r.line, r.next);
	if (auto e = cast(Error) t)
		return new ThrowableClone!Error(t.info, t.msg, t.file, t.line, t.next);
	return new ThrowableClone!Throwable(t.info, t.msg, t.file, t.line, t.next);
}

class ClonedTraceInfo : Throwable.TraceInfo {
	string[] buf;
	this(Throwable.TraceInfo t) @trusted nothrow {
		if (t) {
			try {
				foreach (i, line; t)
					buf ~= line.idup();
			} catch (Throwable t) {
				// alas...
			}
		}
	}

	override int opApply(scope int delegate(ref const(char[])) dg) const {
		return opApply((ref size_t, ref const(char[]) buf) => dg(buf));
	}

	override
	int opApply(scope int delegate(ref size_t, ref const(char[])) dg) const {
		foreach (i, line; buf) {
			if (dg(i, line))
				return 1;
		}

		return 0;
	}

	override string toString() const {
		string buf;
		foreach (i, line; this)
			buf ~= i ? "\n" ~ line : line;
		return buf;
	}
}
