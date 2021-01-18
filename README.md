# Structured Concurrency

<img src="https://github.com/symmetryinvestments/concurrency/workflows/build/badge.svg"/>

Provides various primitives useful for structured concurrency and async tasks.

## StopToken

StopTokens are thread-safe objects used to request cancellation. They can be polled or subscribed to.

See http://www.open-std.org/jtc1/sc22/wg21/docs/papers/2020/p2175r0.html for a thorough explanation for why we need stop tokens in particular and cancellation in general.

## Senders/Receivers

A Sender is a lazy Task (in the general sense of the word). It needs to be connected to a Receiver and then started before it will (eventually) call one of the three receiver methods exactly once: setValue, setDone, setError.

It can be used to model many asynchronous operations. It enforces structured concurrency because a Sender cannot start without it being awaited on.

 `setValue` is the only one allowed to throw exceptions, and if it does, `setError` is called with the Exception. `setDone` is called when the operation has been cancelled. 

See http://www.open-std.org/jtc1/sc22/wg21/docs/papers/2020/p0443r14.html for the C++ proposal for introducing Senders/Receivers.

Currently we have the following Senders:

- `ValueSender`. Just produces a plain value.
- `ThreadSender`. Calls the setValue function in the context of a new thread.
- `Nursery`. A place to await multiple Senders.

## Operations

Senders enjoy the following operations.

- `sync_wait`. It takes a Sender and blocks the current execution context until the Sender is completed. It then returns or throws anything the Sender has send, if any. (note: attributes are inferred when possible, so that e.g. if the Sender doesn't call `setError`, `sync_wait` itself is nothrow).

- `then`. Chains a lambda to be called after the Sender is completed.

### To be added

- `retry`. It retries the underlying Sender as many times as unconfigured until success or cancellation.

- `when_all`. It completes only when all Senders have completed. If any Sender completed with an error, all Senders are cancelled.

- `when_any` or `amb`. It completes when one Sender has been completed and cancels all others.

- others...

## Nursery

A place where Senders can be awaited in. Senders placed in the Nursery are started only when the Nursery is started.

In many ways it is like the `when_all`, except as an object. That allows it to be passed around and for work to be registered into it dynamically.
