# Security model

The enforced boundaries and caller responsibilities for the client/worker design.

## macOS process and socket isolation

The worker connects through an AF_UNIX socket inside an atomically created `0700`
temporary directory. The socket is restricted to `0600`, accepted descriptors have
close-on-exec set, and the directory permissions restrict access to the current
user. Socket writes suppress `SIGPIPE`, so a worker crash or close/write race
becomes a Swift transport error instead of terminating the host application.

The caller-provided environment overlay cannot set dynamic-loader or common runtime
diagnostic injection variables. The worker path and Bare executable are validated
before launch, and bounded stdout/stderr capture retains startup diagnostics while
keeping worker output out of the host application's inherited handles.

## iOS worklet lifecycle

The worker runs inside the application process through BareKit. A release links the
complete native addon closure corresponding to the verified worker bundle. On close,
the client sends the 0.17 `__shutdown__` handshake before worklet termination to
release addon-owned JavaScript references safely.

The worker bundle is built twice from separate roots with Node 22.22.0 and a fully
resolved npm lock. Its complete file table, embedded SDK version, addon inventory,
content ID, SHA-256, non-overlap, and absence of local build paths are verified.

## Resource limits

The default maximum size for an inbound bare-rpc message or decoded NDJSON
record is 256 MiB.
Encoded requests and outbound duplex chunks use a separate 48 MiB
`maximumOutboundPayloadBytes` ceiling (or the lower wire limit), and oversized
values, including initial and replacement `__init_config` handshakes, are rejected
before a transport write. Convenience APIs that convert `Data` to inline base64
additionally enforce a 24 MiB aggregate `maximumInlineBinaryBytes` raw-input
budget and a 1,024-item `maximumInlineBinaryItems` ceiling before base64 or JSON
allocation. The item ceiling also bounds per-value container overhead. Binary
duplex data above the outbound limit must be split into smaller chunks.

Inbound transport buffers and each raw stream queue are byte-bounded. Transport
adapters deliver at most 64 KiB to the frame decoder at a time; raw operation queues
use the per-operation `maximumBufferedStreamBytes` budget (the wire ceiling by default).
Raw queue accounting includes payload bytes plus a conservative per-DATA-frame
structural allowance, so empty and tiny frames cannot bypass that bound.
The multiplexer checks remaining queue capacity before copying a STREAM(DATA)
field out of the receive frame. Data for settled or unknown operations is validated
and skipped. Remote bare-rpc error message and code text has a separate 64 KiB
aggregate UTF-8 retention ceiling (or the lower wire ceiling); oversized and late
errors are strict-UTF-8-validated without constructing diagnostic strings. A valid
resource-limit failure terminates only its owning operation, while malformed framing
still closes the transport generation.
Public fan-out streams are separately bounded. Lossless views retain whole wire
batches within both a batch-count ceiling and `maximumBufferedStreamBytes`, then
flatten multi-value frames lazily. They fail explicitly on slow-consumer overflow
instead of allocating without limit or dropping semantic data. Observational
progress views retain a bounded window of the newest snapshots and coalesce older
snapshots under burst load. Buffer budgets apply per stream and per concurrent
operation.

High-level APIs that eagerly assemble a result from multiple records enforce
`maximumAccumulatedResultBytes`, which defaults to `maximumWireMessageBytes`.
Accounting includes conservative retained-container overhead, not only payload
bytes. VLA action data is additionally bounded by `maximumVLAActionBytes`, which
defaults to the smallest of 8 MiB, the wire ceiling, and the accumulated-result
ceiling. This dedicated bound covers both response pre-copy admission and decoded
Float32 action bytes, limiting the simultaneous base64, binary, and array
representations. Crossings report
``QVACError/resourceLimitExceeded(operation:resource:maximumBytes:attemptedBytes:)``.
Metadata/control responses with open-ended JSON fields have a separate encoded
`maximumMetadataResponseBytes` ceiling. It defaults to the smallest of 256 KiB,
the wire ceiling, and the accumulated-result ceiling; explicit values cannot
exceed either client-wide cap. The ceiling applies to loaded/static model info,
system-resource snapshots, registry-get responses, and VLA hyperparameters.
Unpaginated registry list/search responses instead use
`maximumRegistryResponseBytes`, which defaults to the smallest of 4 MiB, the wire
ceiling, and the accumulated-result ceiling. The larger dedicated ceiling leaves
headroom for the 0.17 catalog without weakening bounded single-object metadata.
The unary multiplexer rejects a data field above the applicable ceiling
before copying that field out of the frame buffer or parsing its JSON, and the
rejection affects only its owning request. Bare-rpc framing must still receive and
validate the complete frame under `maximumWireMessageBytes`; the metadata ceiling
is therefore a decode/retention boundary, not a replacement for the global inbound
wire bound. Generic plugin and model-result payloads remain governed by the wire
and operation-specific result limits because they may legitimately carry large
tensors or media.

Batch completion accepts at most `maximumBatchPrompts` prompts (256 by default).
The client checks this limit before request encoding and before allocating
per-prompt tasks, streams, or result state. Configure it to the largest batch the
application intentionally permits, and reduce it for memory-constrained devices.

The limits are configurable because video and upscaling can return a complete
base64 media output in one record, while image, audio, and tensor requests may
inline several buffers. Base64 parsing, JSON decoding, and final `Data` ownership
can temporarily use several times the payload size. Choose lower limits for
memory-constrained deployments and validate them on representative physical
devices.

QVACClient does not add model RAM, disk, or inference-time quotas. Applications
decide which models and operations are permitted and should set an explicit
per-request deadline.

## URL policy

Model and asset source strings are forwarded to the trusted worker. If an
application accepts them from an untrusted user, it must enforce its own policy.
Typical controls include:

- require HTTPS;
- allowlist approved model/CDN hosts;
- reject file, loopback, and private-network URLs when SSRF is in scope; and
- verify expected size and digest before treating downloaded content as trusted.

The integration fixtures in this repository are pinned to immutable source
revisions and validate both byte length and SHA-256.

## Protocol validation

Generated request and response unions reject unknown type discriminators. Numeric
wire error codes must be finite, integral, and within Swift `Int` range. The client
also rejects invalid base64, malformed profiling records, truncated NDJSON,
unexpected response variants, oversized frames, duplicate response-stream
consumption, and invalid timeout or buffer limits.

Only an explicit top-level profiling-trailer marker is skipped. A malformed ordinary
response cannot be reclassified as profiling data to bypass decoding.

## Logging and profiling

The default OS logger marks dynamic worker text private. Pass `logger: nil` to
disable client logs. Profiling metadata is delivered only through the caller's
handler; applications are responsible for its retention and redaction.

## Caller lifecycle responsibility

Always await `close()` when the client is no longer needed. It is idempotent and
joinable, including concurrent calls. Destructor cleanup is best effort only because
Swift cannot await asynchronous work from `deinit`.

## Supply-chain boundary

Release checks bind the upstream commit, npm tarball, generated contract, worker
bundle, runtime dependency graph, and native archive checksums. Source releases
also verify that every referenced binary is available at its versioned public URL.

Compromise of the trusted upstream source or native model implementations remains a
supply-chain risk outside the protocol client's authority.
