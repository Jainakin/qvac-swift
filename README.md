# QVAC Swift Client

Native Swift access to QVAC's local-first AI worker for iOS 17+ and macOS 14+
(arm64), using Swift concurrency and bounded `AsyncSequence` streams.

The current source targets the exact `@qvac/sdk@0.17.0` contract and is intended
for the unreleased `v0.2.0` source release. It contains no 0.10 compatibility or
migration layer.

## Release status

The first exact production release is
[`v0.1.0`](https://github.com/Jainakin/qvac-swift/releases/tag/v0.1.0) from exact
source commit `85ac16212e43ec4572c96f04bf278cd67e52eb7f`. Its 38 checksum-pinned
XCFramework archives and provenance records are published in
[`artifacts-sdk-0.17.0-r1`](https://github.com/Jainakin/qvac-swift/releases/tag/artifacts-sdk-0.17.0-r1)
from the same commit. These prior releases are immutable by project policy and
checksum/source binding; their GitHub REST records predate repository-native
release immutability and therefore do not report `immutable: true`. GitHub-native
release immutability is enabled for subsequent publications. Every new artifact
revision and source version remains additive: existing tags and assets are never
moved or replaced.

The current grant-handoff source contains additional post-`v0.1.0` review
hardening: a finite default request deadline, generation-safe worker reconnect,
rich-duplex profiling-trailer draining, bounded batch-aware streams, stronger real
RAG/profiling coverage, and an exact-revision iOS 17 URL-consumer runtime gate. It
is intentionally not tagged or submitted to Swift Package Index here. Grant
reviewers acting as the authorized publisher—not this handoff—must publish the
next additive artifact revision
`artifacts-sdk-0.17.0-r2` and then source release `v0.2.0` from the same fully green
commit by following `docs/distribution.md`. Future publication is deliberately
blocked until the native-license and Apple privacy-manifest audits documented
there are complete; the prior `license_reviewed=true` attestation does not bypass
those evidence requirements.

For each release, canonical `Package.swift` is the public URL-backed manifest for
that release's artifact revision; `Package.swift.dev` retains the exact local
development graph.

The exact release commit passed the complete
[`CI`](https://github.com/Jainakin/qvac-swift/actions/runs/33424863638),
[`Build Immutable SDK 0.17 Artifacts`](https://github.com/Jainakin/qvac-swift/actions/runs/33468513722),
and [`Source Release`](https://github.com/Jainakin/qvac-swift/actions/runs/33468871258)
workflows. Before artifact publication, a maintainer reviewed the generated
third-party notices and three pinned supplements and explicitly authorized the
`license_reviewed=true` attestation.

See
[Submission evidence](SUBMISSION.md) for the reviewer-facing requirement matrix,
[Distribution and release](docs/distribution.md) for the guarded process, and
[Swift Package Index submission](docs/swift-package-index.md) for the post-release
index checklist. The exact redistributed-package inventory, package-provided
texts, and pinned supplements are in
[Third-party notices](THIRD_PARTY_NOTICES.md).

After the authorized grant publisher releases `v0.2.0`, consume reviewed `0.2.x`
patches as follows:

```swift
dependencies: [
    .package(
        url: "https://github.com/Jainakin/qvac-swift.git",
        .upToNextMinor(from: "0.2.0")
    ),
],
targets: [
    .target(
        name: "MyApp",
        dependencies: [
            .product(name: "QVACClient", package: "qvac-swift"),
        ]
    ),
]
```

Commit the application's `Package.resolved`. For deployments that require an
explicit source-version pin, use `exact:` with the desired reviewed tag from the
[`Releases`](https://github.com/Jainakin/qvac-swift/releases) page.

The repository-side Swift Package Index work is the publication guidance and CI
configuration supplied by `.spi.yml` and `docs/swift-package-index.md`. Actual
Index publication is intentionally reserved for the authorized publisher. The
SDK 0.17.0 SwiftUI flow has passed on a physical iPhone 15 Pro (arm64, iOS 26.5.2):
fresh model download/load, real streamed completion, terminal result, and unload.
No physical-device acceptance step remains.

## Exact upstream identity

- SDK: `@qvac/sdk@0.17.0`
- Published npm `gitHead`: `e8b440665a053a9efe852f04c3601da44f0d55d8`
- Wire methods: 39
- Error codes: 136, including client, server, model-registry, and registry ranges
- Node toolchain for codegen and artifacts: 22.22.0
- Worker SHA-256: `3d17393e67b0ed6830a5dad2f575b9d8835589a4eed321629ff2f514066cd769`

The complete source/tarball hashes are recorded in
[`tools/provenance/qvac-sdk.lock.json`](tools/provenance/qvac-sdk.lock.json).
Generation consumes the committed 0.17 contract JSON at that release commit, not
`latest`, a floating npm install, or the later drifting `sdk-v0.17.0` tag.

## Quick start

### iOS

An artifact-backed source release contains the verified worker bundle and its
complete native xcframework closure. The application does not start Node or a
subprocess.

```swift
import QVACClient

let client = try await QVACClient(
    configuration: try .iOSWithBundledResource()
)

do {
    let load = try await client.loadModelStreaming(
        modelSrc: "https://huggingface.co/bartowski/SmolLM2-135M-Instruct-GGUF/resolve/d255afaffd3441b95abca9b5cc4c819b93f66936/SmolLM2-135M-Instruct-Q4_K_M.gguf",
        modelType: "llamacpp-completion",
        rpcOptions: .init(timeout: .seconds(600))
    )

    async let loadedModelId = load.result.value
    for try await event in load.progress {
        print("download: \(event.percentage)%")
    }
    let modelId = try await loadedModelId

    let completion = try await client.completion(
        modelId: modelId,
        history: [.user("Answer in one short sentence: what is QVAC?")],
        rpcOptions: .init(timeout: .seconds(60))
    )
    for try await token in completion.tokenStream {
        print(token, terminator: "")
    }
    _ = try await completion.final.value

    try await client.unloadModel(
        modelId: modelId,
        rpcOptions: .init(timeout: .seconds(10))
    )
    await client.close()
} catch {
    await client.close()
    throw error
}
```

### macOS

macOS runs the QVAC worker in a Bare subprocess over a private Unix-domain socket.
Install the exact Bare executable and SDK into one lockfile-pinned runtime, then
pass that runtime's `node_modules` directory:

```bash
mkdir qvac-runtime
cd qvac-runtime
npm init -y
npm install --save-exact @qvac/sdk@0.17.0 bare-runtime@1.31.0
```

Commit the resulting application lockfile. For release validation, use this
repository's stronger, fully resolved runtime lock instead:

```bash
# Node must match tools/codegen/.node-version (22.22.0).
tools/runtime/bootstrap.sh
```

```swift
let configuration = try QVACClient.Configuration.macOS(
    nodeModulesDir: URL(fileURLWithPath: "/absolute/path/to/qvac-runtime/node_modules")
)
let client = try await QVACClient(configuration: configuration)
```

`Configuration.macOS` validates the worker path and first uses the package-owned
`node_modules/bare-runtime/bin/bare`, binding the executable to the same application
lockfile without relying on npm's `.bin` symlink materialization. It falls back to
PATH/common install locations only when that local binary is absent; pass
`bareExecutable:` explicitly for a different controlled deployment.

## Request deadlines, cancellation, and profiling

Every operation accepts trailing `rpcOptions:`. A request/reply deadline covers
the complete response; a server-stream deadline is an inactivity deadline between
frames; a duplex deadline covers session setup. The minimum is 100 ms.

```swift
let run = try await client.completion(
    modelId: modelId,
    history: [.user("Write a haiku")],
    rpcOptions: .init(timeout: .seconds(30))
)

try await client.cancel(
    .request(requestId: run.requestId),
    rpcOptions: .init(timeout: .seconds(2))
)
```

`QVACRPCOptions()` applies a production-safe 60-second deadline, so an ordinary
stuck request cannot hang forever. Production applications should still choose an
operation-specific deadline based on model size and expected output. Pass
`timeout: nil` only for an intentionally unbounded operation with its own external
watchdog. Timeouts and task cancellation tear down pending RPC state and stream
directions; they do not leave a permanently blocked request in the client
multiplexer.

If a worker transport dies, the next call single-flights a fresh worker and
`__init_config`, but it is not silently sent to an empty runtime. Calls that cross
that boundary receive `QVACError.connectionReset`; reload model/session state and
retry on the ready connection. Failed in-flight requests are never replayed.

On macOS, worker exit is transport-observable and live `SIGKILL` recovery is part
of the test suite. On iOS, reconnect starts after BareIPC reports a zero-byte EOF or
a write failure. The pinned BareKit runtime can keep the host IPC descriptors open
when a worklet exits itself ([BareKit #83](https://github.com/holepunchto/bare-kit/issues/83)),
so that specific exit is not observable as EOF. The finite request deadline still
prevents an indefinite API wait; if an iOS timeout coincides with a suspected
worklet exit, close and recreate `QVACClient` rather than assuming automatic state
recovery.

Profiling can be enabled per call. Metadata-only profiling trailer records are
consumed separately and never decoded as ordinary response types. High-level
terminal-aware streams—including generated server streams and concrete duplex
error paths—perform a bounded, eager drain to EOF before exposing success or
throwing the retained worker error. This captures profiling even if the consumer
then leaves the loop:

```swift
let options = QVACRPCOptions(
    timeout: .seconds(30),
    profiling: .init(enabled: true, includeServerBreakdown: true)
)
```

Provide `profilingMetadataHandler:` when constructing `QVACClient` to receive the
returned profiling object.

## API coverage

Generated request/response types and exact `wire…` entry points cover all 39
methods in the 0.17.0 manifest:

| Shape | Methods |
|---|---|
| Request/reply | `cancel`, `deleteCache`, `downloadAsset`, `embed`, `finetune`, `getLoadedModelInfo`, `getModelInfo`, `getSystemResources`, `heartbeat`, `loadModel`, `modelRegistryGetModel`, `modelRegistryList`, `modelRegistrySearch`, `pluginInvoke`, `provide`, `rag`, `resume`, `state`, `stopProvide`, `suspend`, `unloadModel` |
| Server stream | `audioGenStream`, `batchCompletionStream`, `bciTranscribe`, `classify`, `completionStream`, `diffusionStream`, `loggingStream`, `ocrStream`, `pluginInvokeStream`, `textToSpeech`, `transcribe`, `translate`, `upscaleStream`, `videoStream` |
| Duplex | `bciTranscribeStream`, `completionOrchestrate`, `textToSpeechStream`, `transcribeStream` |

Rich Swift wrappers add request IDs, typed progress/events, binary `Data`
conversion, terminal-result tasks, and targeted cancellation for common model,
completion, embedding, transcription, TTS, translation, OCR, diffusion, audio,
video, upscaling, classification, RAG, plugin, VLA, and batch workflows. The
generated wire methods remain available when an application needs every optional
contract field directly.

`QVACSDKContract.methods` is the generated runtime inventory. CI requires both the
generated type round trips and the live public-API exercise set to equal that
inventory exactly, so an upstream method cannot be silently omitted.

### Upscale example

QVAC 0.17 documents the public `diffusion` model-type alias; the Swift client
normalizes it to the canonical `sdcpp-generation` wire value from the pinned
`model-type-maps.json` contract:

```swift
let load = try await client.loadModel(
    modelSrc: "/absolute/path/to/RealESRGAN_x4plus.pth",
    modelType: "diffusion",
    modelConfig: .object(["mode": .string("upscale")]),
    rpcOptions: .init(timeout: .seconds(600))
)
let upscalerId = try await load.result.value

let inputPNG = try Data(contentsOf: inputURL)
let upscale = try await client.upscale(
    modelId: upscalerId,
    image: inputPNG,
    rpcOptions: .init(timeout: .seconds(120))
)
let outputPNGs = try await upscale.outputs.value

try await client.unloadModel(
    modelId: upscalerId,
    rpcOptions: .init(timeout: .seconds(10))
)
```

## Bounded streaming and large media

Inbound bare-rpc frames, NDJSON records, transport buffers, and per-operation raw
stream queues are bounded. The default maximum wire message is 256 MiB because
0.17 video and upscaling return complete base64 media values in one JSON record.

Tune `maximumWireMessageBytes:` and `maximumBufferedStreamBytes:` in the client
initializer for the deployment. A lower value reduces worst-case memory exposure
but rejects larger valid outputs. Raw queue accounting charges payload bytes plus a
conservative per-DATA-frame structural allowance, including for empty frames.
Base64 decoding and `Data` ownership can
temporarily require several times the encoded payload size, which matters on
memory-constrained iOS devices.

Batch-aware public run streams use the single-consumer `QVACBufferedStream`. They
queue at most 64 whole worker batches, bound queued plus partially consumed data by
the configured `maximumBufferedStreamBytes`, and flatten accepted multi-value
frames lazily for callers. A lagging lossless view fails with
`QVACStreamBufferOverflow`; its
authoritative aggregate continues independently. Observational progress views use
the same count and byte ceilings but coalesce older snapshots to retain the newest
bounded window. An indivisible batch larger than the byte budget fails only that
view rather than silently truncating it.

## Reproducible development setup

Canonical `Package.swift` deliberately remains the checksum-pinned public URL
manifest, so a normal clean clone exercises the same install path as a consumer:

```bash
node tools/ci/package-manifest-mode.mjs --check
swift package dump-package >/dev/null
swift build
swift test
```

`Package.swift.dev` describes the generated local XCFramework graph. To reproduce
that graph without changing the canonical manifest, select Node 22.22.0 and run:

```bash
tools/codegen/bootstrap.sh
tools/codegen/run.sh --generate-only
tools/runtime/link-ios-artifacts.sh
node tools/release/compute-manifest.mjs development \
  tools/runtime/.build/artifacts \
  Sources/QVACClient/Resources/worker.mobile.bundle \
  /tmp/qvac-artifacts.development.json
cmp /tmp/qvac-artifacts.development.json \
  tools/release/artifacts.development.json
node tools/release/generate-package-manifest.mjs \
  /tmp/qvac-artifacts.development.json /tmp/qvac-Package.swift.dev
cmp /tmp/qvac-Package.swift.dev Package.swift.dev
```

CI activates `Package.swift.dev` only in a disposable checkout for local-graph
builds. If you intentionally need that mode in a disposable local checkout, run
`CI=true node tools/ci/package-manifest-mode.mjs --activate-development` before
SwiftPM; do not commit the resulting `Package.swift` replacement.

The committed bundle is reproduced twice in distinct work roots and must be
byte-identical:

```bash
tools/runtime/test-bundle-reproducibility.sh
cmp tools/runtime/.build/worker.repro-a.bundle \
    Sources/QVACClient/Resources/worker.mobile.bundle
```

See [`tools/codegen/README.md`](tools/codegen/README.md) for the zero-manual-Swift
generation guarantee and [`docs/distribution.md`](docs/distribution.md) for the
artifact-first release procedure.

## Verification matrix

The required CI pipeline contains independent gates for:

- exact contract provenance, npm/source semantic parity, generated-file freshness,
  and generation time below 30 seconds after bootstrap;
- warning-free strict-concurrency build and all unit/semantic tests;
- byte-reproducible 0.17 worker and deterministic native archives;
- all 39 public operations against a live 0.17 worker with zero skips;
- checksum-pinned real LLM, RAG embedding, and ESRGAN upscale models;
- macOS, generic iOS-device, iOS Simulator, DocC, and example-app builds;
- a release-mode Swift-versus-JavaScript public API benchmark with the grant's 5%
  overhead gate; and
- a clean external Swift package that resolves the published Git URL and
  checksum-pinned binary artifacts.

Useful local entry points:

```bash
swift test --filter QVACClientUnitTests

QVAC_BARE_BIN="$PWD/tools/runtime/node_modules/bare-runtime/bin/bare" \
QVAC_NODE_MODULES="$PWD/tools/runtime/node_modules" \
QVAC_WORKER_SCRIPT="$PWD/tools/runtime/node_modules/@qvac/sdk/dist/server/worker.js" \
tools/ci/run-required-suite.sh AllRPCTypesRoundTripTests 1

QVAC_BENCH_MODEL_PATH=/absolute/path/to/SmolLM2-135M-Instruct-Q4_K_M.gguf \
bench/run.sh
```

Model-bearing suites download artifacts from immutable revisions and verify byte
size plus SHA-256 before use. Required CI invokes them through
`run-required-suite.sh`, which fails on any skip or unexpected test count; a broken
or unavailable fixture is never reported as success. The benchmark independently
checks the same pinned model metadata from `bench/workload.json` before either
public client is timed.

## Example application

[`Examples/QVACChat`](Examples/QVACChat) is a SwiftUI load → completion → unload
application for iOS and macOS. Generate its Xcode project with XcodeGen after the
development artifact graph has been materialized:

```bash
cd Examples/QVACChat
xcodegen generate
xcodebuild -project QVACChat.xcodeproj -scheme QVACChat-iOS \
  -destination 'generic/platform=iOS Simulator' build
xcodebuild -project QVACChat.xcodeproj -scheme QVACChat-macOS \
  -destination 'platform=macOS' build
```

On macOS, set `QVAC_NODE_MODULES` to the exact runtime `node_modules` directory.
iOS loads the packaged worker resource directly.

## Security and lifecycle

- macOS sockets live in an atomically created `0700` directory and use `0600`
  permissions; inherited descriptors are closed and writes cannot terminate the
  host process with `SIGPIPE`.
- dynamic-loader and diagnostic injection variables are removed from the spawned
  worker environment overlay.
- `close()` is idempotent and joinable. iOS performs the SDK's bounded
  `__shutdown__` handshake before worklet termination; macOS waits for socket and
  child-process cleanup.
- Unknown discriminators, malformed numeric error codes, invalid base64, truncated
  NDJSON, unexpected response variants, and oversized records fail explicitly.
- Model and asset URLs are caller-controlled. Applications accepting untrusted URLs
  must enforce their own HTTPS and host allowlist policy.

The full threat model is in
[`Sources/QVACClient/Documentation.docc/Security.md`](Sources/QVACClient/Documentation.docc/Security.md).

## License

Apache-2.0.
