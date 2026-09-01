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

Unexpected EOF, an inbound channel error, or an outbound write failure makes that
transport generation terminal. Every operation already assigned to it fails once
and is never replayed. The next new API call starts one shared reconnect attempt,
waits for the old transport to finish closing, creates a fresh worker, and repeats
`__init_config`; concurrent callers join the same attempt. A failed reconnect is
fully closed and a later call may retry. A successful reconnect deliberately does
not send any waiting application request: every caller that crossed the boundary
receives ``QVACError/connectionReset``. Because the replacement is a new worker,
loaded models and other in-memory session state are intentionally **not** restored.
Each caller waits cancellation-safely without canceling the shared reconnect. A
canceled sole waiter cannot install the replacement; the next non-canceled caller
finishes the attempt and receives the reset signal. Reload the required state,
then retry on the ready generation. Explicit `close()` remains terminal and
disables reconnect.

macOS process exit and `SIGKILL` are observed through socket EOF. iOS generation
replacement is available when BareIPC exposes zero-byte EOF or a write failure,
but it is not a general worklet-crash detector: the pinned BareKit runtime can
leave host IPC descriptors open after a worklet exits itself (upstream BareKit
issue 83). In that case per-request deadlines bound the caller's wait, and the
application should close and recreate the client if it suspects the worklet ended.

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
consumer does not create an unbounded eager decoding task. High-level lossless
fan-out views retain whole wire batches under count and configured byte ceilings.
``QVACBufferedStream`` flattens multi-value batches lazily, so one valid TTS or
completion frame cannot overflow before Swift schedules its consumer. Slow-consumer
overflow is still explicit and never drops a partial batch.
Observational progress fan-out retains the newest bounded window and coalesces old
snapshots, because the 0.17 worker may emit progress once per network chunk.

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

Rich duplex adapters eagerly consume the metadata-only record and response EOF
before exposing a logical terminal event. That final drain has its own five-second
ceiling, so a malformed worker that sends `done` without a trailer or stream end
cannot turn a normal `for try await` loop into an unbounded wait.

## Error boundary

Server error envelopes are decoded into typed `QVACError` values using all 136
published numeric codes. Malformed frames and unexpected response variants become
protocol violations; malformed JSON/NDJSON becomes an encoding error; operating
system failures remain transport errors. Internal bare-rpc error types are not
exposed through public async sequences.

The `wireProgressStream`, `wireServerStream`, and `wireDuplex` escape hatches are
deliberately lower level: their `QVACResponse` union preserves an `.error` record as
a domain element. A caller using those APIs must continue the same response iterator
to EOF after observing `.error` so a following profiling trailer is consumed.
Concrete-response generated adapters and high-level run APIs perform that bounded
drain themselves and then throw the corresponding `QVACError`; generated conditional
progress accessors remain wire-union streams because one operation can emit several
response variants.

## See also

- <doc:GettingStarted>
- <doc:Security>
