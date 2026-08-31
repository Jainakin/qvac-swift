# QVAC Swift Client

Native Swift access to QVAC's local-first AI worker for iOS 17+ and macOS 14+
(arm64), using Swift concurrency and bounded `AsyncSequence` streams.

This submission candidate targets the exact published `@qvac/sdk@0.17.0`
contract. It does not contain a 0.10 compatibility or migration layer.

## Release status

The source, generated API, worker bundle, native-addon closure, tests, and release
automation are prepared for 0.17.0. A tagged SwiftPM release requires one external
maintainer sequence: produce an unpublished deterministic artifact candidate,
commit its checksum-pinned URL manifest, obtain green CI for that exact commit,
and only then publish the immutable xcframework archives and source tag. Until
that release exists, do not present the development `Package.swift` as a
URL-installable tag. See
[Submission evidence](SUBMISSION.md) for the reviewer-facing requirement matrix,
[Distribution and release](docs/distribution.md) for the guarded process, and
[Swift Package Index submission](docs/swift-package-index.md) for the post-release
index checklist. The exact redistributed-package inventory, package-provided
texts, and pinned supplements are in
[Third-party notices](THIRD_PARTY_NOTICES.md); binary publication is gated on an
explicit maintainer/legal review of that generated record.

Published source tags are designed to be consumed as follows:

```swift
dependencies: [
    .package(
        url: "https://github.com/Jainakin/qvac-swift.git",
        exact: "0.1.0"
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

Do not use that version requirement until `v0.1.0` (or a later reviewed source
tag) has actually been published.

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

`QVACRPCOptions()` deliberately leaves `timeout` unset, matching the executable
0.17 JavaScript contract. Production applications should set an operation-specific
deadline based on model size and expected output. Timeouts and task cancellation
tear down pending RPC state and stream directions; they do not leave a permanently
blocked request in the client multiplexer.

Profiling can be enabled per call. Metadata-only profiling trailer records are
consumed separately and never decoded as ordinary response types:

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
but rejects larger valid outputs. Base64 decoding and `Data` ownership can
temporarily require several times the encoded payload size, which matters on
memory-constrained iOS devices.

Public fan-out streams are bounded to 64 elements. A slow observer fails with
`QVACStreamBufferOverflow`; terminal result tasks continue independently when the
progress view is observational.

## Reproducible development setup

The checked-in development manifest points at generated local xcframeworks. From a
clean clone, select Node 22.22.0 and materialize the exact graph before building:

```bash
tools/codegen/bootstrap.sh
tools/codegen/run.sh --generate-only
tools/runtime/link-ios-artifacts.sh
swift package dump-package >/dev/null
swift build
swift test
```

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
- a clean external Swift package that resolves the published Git URL and immutable
  binary artifacts.

Useful local entry points:

```bash
swift test --filter QVACClientUnitTests

QVAC_BARE_BIN="$PWD/tools/runtime/node_modules/bare-runtime/bin/bare" \
QVAC_NODE_MODULES="$PWD/tools/runtime/node_modules" \
QVAC_WORKER_SCRIPT="$PWD/tools/runtime/node_modules/@qvac/sdk/dist/server/worker.js" \
tools/ci/run-required-suite.sh AllRPCTypesRoundTripTests 1

bench/run.sh 1000
```

Model-bearing suites download artifacts from immutable revisions and verify byte
size plus SHA-256 before use. Required CI invokes them through
`run-required-suite.sh`, which fails on any skip or unexpected test count; a broken
or unavailable fixture is never reported as success.

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
