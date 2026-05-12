# Security model

The threat model behind the client/worker split, the protections this library
enforces, and the responsibilities that remain with the caller.

## Overview

QVACClient is the *client* half of a client/worker architecture. The worker is a Bare
JS runtime that does the actual model loading, inference, and asset download. On macOS
the worker runs as a subprocess this library spawns; on iOS it runs in-process inside a
BareKit worklet thread. Either way the client communicates with the worker over a
binary RPC protocol, and most of the security-interesting state (downloaded models,
sockets, file handles) lives on the worker side.

This document covers what the client *guarantees* against a local adversary, and which
threats remain the caller's responsibility.

## Library-enforced protections

### macOS Unix Domain Socket

The macOS transport spawns the worker as a subprocess and accepts its connection over a
named UDS. Threats considered:

- A different local user racing to connect before the worker does. **Mitigation**: the
  socket lives inside a `mkdtemp(3)`-allocated directory that is created with mode
  `0700` atomically — only the owning user can traverse into it. The socket file itself
  is then `chmod 0600`. Path entropy is ~36 bits (the OS-supplied `mkdtemp` random
  suffix) rather than the previous 16 bits.

- A different local user predicting the socket path. **Mitigation**: the random suffix
  in the parent directory's name means a brute-force pre-creation of every possible
  path requires ≥2³⁶ filesystem entries.

### Spawned-worker environment

The `environmentOverlay` you can pass to ``QVACClient/Configuration/macOS(nodeModulesDir:bareExecutable:initTimeout:environmentOverlay:)``
is merged into the spawned worker's environment after the library strips any key
matching:

- `DYLD_*`
- `LD_PRELOAD`
- `LD_LIBRARY_PATH`
- `LD_AUDIT`

This prevents a caller (or any value they forward from untrusted sources) from
injecting a dylib or audit module into the worker process via dynamic-linker
environment variables. If you need to set one of those values for a legitimate reason,
you must do so before spawning your *own* process and inheriting through
`ProcessInfo.processInfo.environment` — not via `environmentOverlay`.

### Inbound frame size

The bare-rpc frame reader caps a single declared frame at 64 MiB
(``BareRPCFrameReader/defaultMaxFrameSize``). A peer that ships a 4 GiB length prefix
will get a `BareRPCCodecError.frameTooLarge` rather than driving the client's process
into OOM.

### Race-free transport shutdown

`close()` shuts the socket via `shutdown(SHUT_RDWR)` first, waits for the reader thread
to exit, drains pending writes through the serial write queue, and only then calls
`close(2)` on the descriptor. This prevents a use-after-close window where another
resource could be assigned the same FD number while the reader was mid-syscall.

The reader thread additionally holds its own `dup(2)`'d copy of the descriptor so even
during the brief shutdown phase it operates on a private FD number.

## Caller responsibilities

### Model and asset URLs

``QVACClient/loadModel(modelSrc:modelType:modelConfig:modelName:)`` and
``QVACClient/downloadAsset(assetSrc:seed:)`` accept arbitrary strings and forward them
verbatim to the worker. The worker will fetch any URL passed in.

If your app accepts these values from end-user input (QR codes, web URLs, deep links,
clipboard), **you must validate them before calling QVACClient**. At minimum:

- Limit the scheme to `https://`.
- Allowlist the hostnames you trust (e.g. `huggingface.co`, a CDN you control).
- Reject local-file (`file://`) and loopback URLs if your threat model includes SSRF.

The library deliberately does no scheme/host validation because the legitimate set of
sources is application-specific.

### Worker resource limits

The library does not impose memory, disk, or wall-clock limits on the worker. A
malicious or malformed prompt that drives the worker to allocate gigabytes will degrade
or crash the worker — and on macOS will leave the subprocess in whatever state the
worker chose. Use ``QVACClient/cancel(_:)`` to abort an in-progress operation.

### iOS bundled worker bundle

The `worker.mobile.bundle.js` file shipped with the package is a release-time vendoring
of `@qvac/sdk`. The supply-chain trust boundary is the upstream SDK at the time we cut
a release — pinned via `package-lock.json` in the release workflow. If you require a
specific worker version, build your own bundle and pass it to
``QVACClient/Configuration/iOS(workletBundleData:entryName:arguments:memoryLimit:)``.

### Calling `close()`

The Swift runtime cannot run `async` code from a `deinit`, so the actor's destructor
can only schedule a *best-effort* close on a background `Task`. If your program exits
before that task runs, the spawned worker subprocess and its socket may persist. Always
explicitly call ``QVACClient/close()`` (and `await` it) when you are done with a
client. The library is otherwise idempotent — calling `close()` multiple times is
safe.

## Known non-mitigations

| Threat | Why it's out of scope |
|---|---|
| Compromised upstream `@qvac/sdk` npm package | Standard supply chain. Pin versions; audit upstream. |
| Worker process exhausts host RAM via huge model | Caller controls which models load; library doesn't gate |
| End-user provides a malicious model URL | Caller must validate before forwarding (see above) |
| Memory snapshot of worker process | Out-of-scope; worker memory contains model weights + activations by design |
