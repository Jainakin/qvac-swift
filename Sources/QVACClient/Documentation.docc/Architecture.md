# Architecture

How the Swift actor, platform transports, bare-rpc multiplexer, and generated
QVAC 0.17 contract fit together.

## Platform boundary

```text
Application
    |
QVACClient actor
    |
Bare-rpc codec and operation table
    |
    +-- macOS: private AF_UNIX socket <-> spawned Bare worker
    |
    +-- iOS:   BareIPC socketpair <-> in-process BareKit worklet
```

Both transports present the same ordered byte-stream abstraction to the RPC layer.
Platform-specific startup and shutdown are contained behind the configuration
factory; operation implementations share one path.

## Startup and shutdown

Construction starts the transport and sends `__init_config` with the optional
client config plus runtime context. The handshake has its own finite deadline and
cancellation-safe pending state. A worker that crashes, starts in direct mode, or
never replies cannot leave initialization waiting forever.

`close()` is serialized through one shared task. Concurrent callers join the same
cleanup. macOS shuts down the socket, drains transport work, and waits for the child
process. iOS first sends the SDK's bounded `__shutdown__` command so addon static
references are released before the worklet ends.

## Wire stack

The outer layer is Holepunch bare-rpc: a 32-bit little-endian body length followed
by compact-encoded frame metadata and optional bytes. Unary, server-stream, and
duplex operations share a monotonically allocated command ID space.

The inner layer is JSON for unary responses and NDJSON for streams. A shared
incremental decoder:

- accepts arbitrary frame/record boundaries;
- drains the final unterminated record at EOF;
- enforces the configured maximum record size;
- removes only a top-level `{"__profilingTrailer": true, ...}` metadata record;
- preserves profiling metadata through the configured callback; and
- rejects malformed ordinary records.

## Generated contract

The pinned 0.17 manifest generates:

1. all concrete request and response types;
2. strict `QVACRequest` and `QVACResponse` discriminator unions;
3. the complete 39-method call-shape inventory;
4. generic and exact typed routing methods; and
5. exhaustive construction/encode/decode tests for every concrete leaf.

Conditional progress transports for model loading, asset download, finetuning,
and selected RAG operations are generated from manifest metadata. This avoids a
hand-maintained routing switch when the contract gains a method.

## Backpressure and memory

Frame size, NDJSON record size, transport buffering, and each raw operation queue
have explicit byte ceilings. Public mapped streams are pull-driven, so a slow
consumer does not create an unbounded eager decoding task. High-level fan-out views
use a bounded element count and report overflow explicitly.

Live server and duplex responses use `QVACResponseStream`, a single-consumer
sequence whose iterator owns the RPC teardown lease. Leaving a `for try await`
loop early, dropping its iterator, cancelling the consuming task, or calling
`cancel()` destroys the remote response stream immediately even if the sequence
value remains retained. Normal remote completion releases the same state without
emitting a redundant destroy frame.

The 256 MiB default wire ceiling accommodates current video/upscale records, but
base64 JSON and `Data` conversion can temporarily multiply peak memory. Applications
should select a lower limit when their supported models cannot legitimately emit
large media.

## Deadlines and cancellation

Request/reply deadlines cover the complete response. Server-stream deadlines reset
on each inbound frame and therefore represent inactivity. Duplex deadlines cover
session setup; callers end or destroy long-lived sessions explicitly.

When a timeout or task cancellation wins, pending continuations are resumed exactly
once and removed, the correct bare-rpc stream directions are closed/destroyed, and
blocked transport writes force connection teardown instead of leaking tasks behind
the socket's serial writer.

## Error boundary

Server error envelopes are decoded into typed `QVACError` values using all 136
published numeric codes. Malformed frames and unexpected response variants become
protocol violations; malformed JSON/NDJSON becomes an encoding error; operating
system failures remain transport errors. Internal bare-rpc error types are not
exposed through public async sequences.

## See also

- <doc:GettingStarted>
- <doc:Security>
