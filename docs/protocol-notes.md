# QVAC 0.17 transport notes

This document records the wire behavior that is easy to miss when implementing a
QVAC client over `bare-rpc`. The observations are covered by the transport and
integration tests in this repository.

## Server streams

A server-stream request uses this sequence:

1. The client sends the `REQUEST` frame with the operation payload.
2. The client sends `STREAM(RESPONSE | OPEN)` for the same request ID.
3. The worker acknowledges the response side and emits NDJSON records in
   `STREAM(RESPONSE | DATA)` frames.
4. The worker terminates the response side with `END` and `CLOSE` frames.

The response-side `OPEN` message is required. Without it, the worker may complete
its internal operation without delivering stream records to the client.

Lifecycle frames can arrive after the last application record. The multiplexer
therefore treats late `END` and `CLOSE` frames for a completed request as cleanup,
not as new responses.

## Cancellation

QVAC cancellation is a separate request/reply operation. It is not a bare-rpc
`DESTROY` flag applied to the original request. Local stream teardown still uses
the bare-rpc lifecycle flags when a Swift task is cancelled or stops consuming a
stream.

## Duplex sessions

A duplex session opens both directions under one request ID:

1. The client sends `REQUEST` with the request-side `OPEN` flag.
2. The client sends `STREAM(RESPONSE | OPEN)`.
3. The first request-side `DATA` frame carries the operation metadata.
4. The worker acknowledges both sides and uses request-side `PAUSE` and `RESUME`
   frames for flow control.
5. Subsequent request-side `DATA` frames carry binary input.
6. Response-side `DATA` frames carry NDJSON events until `END` and `CLOSE`.

Worker errors in duplex operations are ordinary response records with
`type: "error"`; they are not necessarily bare-rpc error frames. High-level Swift
adapters retain that error, consume any following profiling trailer, and then
throw the corresponding `QVACError`.

Both remote `OPEN` acknowledgements are required before the session is reported
as ready, including when the caller disables the setup timeout.

## Platform transports

macOS starts the worker as a Bare subprocess and exchanges frames over a private
Unix-domain socket. iOS starts the packaged worker in a BareKit worklet and uses
`BareIPC`. Both transports expose the same ordered byte-stream interface to the
bare-rpc multiplexer.

## Contract generation

QVAC's request schema includes nested unions and JavaScript-only callback fields.
The generator walks nested unions recursively and omits only callback values that
cannot cross JSON. Generated request and response discriminators remain strict;
unknown cases are rejected as contract drift.
