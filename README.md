# Structured Concurrency

<img src="https://github.com/symmetryinvestments/concurrency/workflows/build/badge.svg"/>

Provides various primitives useful for structured concurrency and async tasks.

## Senders/Receivers

A Sender is a lazy Task (in the general sense of the word). It needs to be connected to a Receiver and then started before it will (eventually) call one of the three receiver methods exactly once: `setValue`, `setDone`, `setError`.

It can be used to model many asynchronous operations: Futures, Fiber, Coroutines, Threads, etc. It enforces structured concurrency because a Sender cannot start without it being awaited on.

 `setValue` is the only one allowed to throw exceptions, and if it does, `setError` is called with the Exception. `setDone` is called when the operation has been cancelled.

See http://www.open-std.org/jtc1/sc22/wg21/docs/papers/2020/p0443r14.html for the C++ proposal for introducing Senders/Receivers.

Currently we have the following Senders:

- `ValueSender`. Just produces a plain value.
- `ThreadSender`. Calls the setValue function in the context of a new thread.
- `Nursery`. A place to await multiple Senders.
- `ForkSender`. Forks the program and executes the supplied function.
- `ThrowingSender`. Always throws.
- `DoneSender`. Always cancels.
- `VoidSender`. Always calls setValue with no arguments.

### Writing your own Sender

Most of the asynchronous tasks you will do involve writing your own `Sender`.

Here is the implementation of the `ValueSender`.

```dlang
/// A Sender that sends a single value of type T
struct ValueSender(T) {
  alias Value = T;
  T value;
  static struct Op(Receiver) {
    Receiver receiver;
    T value;
    void start() {
      receiver.setValue(value);
    }
  }
  Op!Receiver connect(Receiver)(Receiver receiver) {
    return Op!(Receiver)(receiver, value);
  }
}
```

A `ValueSender!int` is nothing more than a `int` wrapped in a struct with a `connect` method. It can be constructed and passed around, but it won't produce a value until it is connected and started. The `Op` object (operational-state) returned by `connect` represents the state of a connected Sender/Receiver pair, which in case of the `ValueSender` includes the value to be send. After connecting the operational-state still need its `start` method called, before it actually produces a value.

A Receiver needs to implement the `setValue`, `setError` and `setDone`. A Sender is required to call exactly one of the three functions once. Both `setError` and `setdone` are required to be `nothrow`. If `setValue` is not nothrow then the Sender must call `setError` if `setValue` throws.

Most Senders should call `receiver.getStopToken` to retrieve a stoptoken by which they can be notified (or polled) whether they are cancelled. See the section of stoptokens how this works.

## Operations

Senders enjoy the following operations.

- `sync_wait`. It takes a Sender and blocks the current execution context until the Sender is completed. It then returns or throws anything the Sender has send, if any. (note: attributes are inferred when possible, so that e.g. if the Sender doesn't call `setError`, `sync_wait` itself is nothrow).

- `then`. Chains a callable to be invoked when the Sender is completed with a value.

- `via`. Start one Sender in the setValue of another. Useful for when you want to change the execution context. `ValueSender!int(4).via(ThreadSender())` produces an `int` in the context of a new thread.

- `withStopToken`. Like `then` but injects a StopToken as well.

- `withStopSource`. When applied after a Sender you can stop the Sender manually with the stopsource. It will still stop when the downstream receiver's StopToken is triggered.

- `race`. Runs multiple Senders and completes with the value produced by the first to complete, after first cancelling and awaiting the others. When both Senders complete with an error, the first error is propagated. When both Senders complete with cancellation, `race` completes with cancellation as well.

- `ignoreError`. Redirects the `setException` to `setDone`, so as not to trigger the downstream error path.

- `finally_`. Takes a Sender and a callable or value and completes with that regardless of whether the Sender completed with `setValue` or `setException`.

- `whenAll`. Produces a tuple of values after all Senders produced their values. If one or more Senders complete with an error, `whenAll` will complete with the first error, after stopping and awaiting the remaining Senders. Likewise, if one Sender completes with cancellation, `whenAll` completes with cancellation as well, after stopping and awaiting the remaining Senders.

- `retry`. It retries the underlying Sender until success or cancellation. The retry logic is customizable. Included is a Times, that will retry n times and then propagate the latest failure.

- `completeWithCancellation`. Wraps the Sender and redirects the setValue termination to complete with cancellation. The Sender is not allowed to produce a Value.

- `toShared`. Wraps a Sender in a SharedSender that forwards the same termination call to each connected Receiver.

## Streams

A Stream has a `.collect` function that accepts a `shared` callable and returns a Sender. Once the Sender is connected and started the Stream will call the callable zero or more times before one of the three terminal functions of the Receiver is called.

An exception throw in the callable will cancel the stream and complete the Sender with that exception.

Streams can be cancelled by triggering the StopToken supplied via the Receiver.

The callable supplied to the Stream has to annotated with `shared` because the execution context where the callable is called from is undefined.

Currently there are the following Streams:

- `infiniteStream`. Continously emits the same value.
- `iotaStream`. Emits the values that span the given starting and stopping values.
- `arrayStream`. Emits every value from the array.
- `intervalStream`. Emits every interval.
- `doneStream`. Upon start immediately emits cancellation.
- `errorStream`. Upon start immediately emits an error.

With the following operations:

- `take`. Emits at most the first n values.
- `transform`. Applies a tranformation function to each value.
- `scan`. Applies an accumulator function with seed to each value.
- `sample`. Forwards the latest value of the base Stream every time the trigger Stream emits a value. If the base stream hasn't produced a (new) value the trigger is ignored.
- `via`. Starts the Stream on the context of another Sender.

Most of the time you will need to write your own Stream however. The following helpers can speed that up:

- `loopStream`. Takes a struct with a `loop` function and calls that with an `emit` and `stopToken` while ensuring the struct is alive during that.
- `fromStreamOp`. Constructs a full Stream given only a templated OperationalState. Allows passing in custom values into the OperationalState's constructor. Since Streams build on Senders they require a bit of boilerplate to setup, this helper eliminates that.

## Nursery

A place where Senders can be awaited in. Senders placed in the Nursery are started only when the Nursery is started.

In many ways it is like the `when_all`, except as an object. That allows it to be passed around and for work to be registered into it dynamically.

## StopToken

StopTokens are thread-safe objects used to request cancellation. They can be polled or subscribed to.

A receiver may have a `getStopToken` that returns one. If not a default `getStopToken` is available that returns a `NeverStopToken`.

A Sender should retrieve a StopToken via `getStopToken` on the connecting Receiver and try to abort as quick as possible when it gets triggered.

The simplest way is to poll the stoptoken regularly. There is a `isStopRequested` method that will return `true` if the Sender should abort. After cleanup the Sender must call `setDone`.

> NOTE: In some cases when a stop is requested, the Sender is already busy setting a value or an exception. Receivers should not assume that because the stoptoken is triggered only `setDone` will be called, it is perfectly valid to call one of the other two as well.

You might need a push notification that a stop has been requested. There is a free function called `onStop` that takes a StopToken and a delegate. The delegate will be called - in an undefined execution context - to signify that a stop is requested. The `onStop` function returns a `StopCallback` that needs its `dispose` to be called before the Sender has terminated. Not calling `dispose` will lead to memory leaks in long-running Senders (e.g. the Nursery).

See http://www.open-std.org/jtc1/sc22/wg21/docs/papers/2020/p2175r0.html for a thorough explanation for why we need stop tokens in particular and cancellation in general.

## DSemver

This package uses [dsemver](https://github.com/symmetryinvestments/dsemver) to calculate the next semantic version.

run `dub run dsemver@1.1.0 -- -p $(pwd) -c` to calcuate the next version.
