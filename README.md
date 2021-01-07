# Structured Concurrency

Provides various primitives useful for structured concurrency and async tasks.

## StopToken

See http://www.open-std.org/jtc1/sc22/wg21/docs/papers/2020/p2175r0.html for a thorough explanation for why we need stop tokens in particular and cancellation in general.

StopTokens are thread-safe objects used to request cancellation. They can be polled or subscribed to.

## Senders/Receivers

See http://www.open-std.org/jtc1/sc22/wg21/docs/papers/2020/p0443r14.html for the C++ proposal for introducing Senders/Receivers.

A Sender is a lazy Task (in the general sense of the word). It needs to be connected to a Receiver and then started before it will (eventually) call one of the three receiver methods: setValue, setDone, setError.

It can be used to model many asynchronous operations. It enforces structured concurrency because a Sender cannot start without it being awaited on.

## Operations

The basic operation is `sync_wait`. It takes a Sender and blocks the currency execution context until the Sender is completed. It then returns or throws anything the Sender has send, if any.
