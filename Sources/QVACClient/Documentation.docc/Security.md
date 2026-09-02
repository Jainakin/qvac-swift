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

The default maximum bare-rpc message and NDJSON record is 256 MiB. The same
`maximumWireMessageBytes` ceiling rejects oversized encoded requests and duplex
chunks before a write. Binary duplex data above it must be split into smaller chunks.
Inbound transport buffers and each raw stream queue are byte-bounded. Transport
adapters deliver at most 64 KiB to the frame decoder at a time; raw operation queues
use the per-operation `maximumBufferedStreamBytes` budget (the wire ceiling by default).
Raw queue accounting includes payload bytes plus a conservative per-DATA-frame
structural allowance, so empty and tiny frames cannot bypass that bound.
Public fan-out streams are separately bounded. Lossless views retain whole wire
batches within both a batch-count ceiling and `maximumBufferedStreamBytes`, then
flatten multi-value frames lazily. They fail explicitly on slow-consumer overflow
instead of allocating without limit or dropping semantic data. Observational
progress views retain a bounded window of the newest snapshots and coalesce older
snapshots under burst load. Buffer budgets apply per stream and per concurrent
operation.

The limit is configurable because video and upscaling can return a complete base64
media output in one record. Base64 parsing, JSON decoding, and final
`Data` ownership can temporarily use several times the payload size. Choose a lower
limit for memory-constrained deployments that do not support large media outputs,
and validate the chosen limit on representative physical devices.

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
