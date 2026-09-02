# QVAC Swift Client

Swift bindings for the QVAC 0.17.0 local AI runtime on iOS and macOS.

`QVACClient` provides async Swift APIs for model lifecycle, text generation,
embeddings, audio, vision, RAG, plugins, and the rest of the QVAC 0.17.0 RPC
surface. Streaming operations use bounded `AsyncSequence` types, and every
request supports cancellation, timeouts, and optional profiling metadata.

## Status

The source on `main` is the review candidate for `@qvac/sdk@0.17.0`. The
latest published baseline is
[`v0.1.0`](https://github.com/Jainakin/qvac-swift/releases/tag/v0.1.0); the next
release will be created after review. This repository does not
include a compatibility layer for earlier QVAC SDK versions.

| Requirement | Version |
|---|---|
| Swift | 5.10 or later |
| iOS | 17 or later |
| macOS | 14 or later, Apple silicon |
| QVAC SDK | 0.17.0 |

## Installation

The 0.2 release line contains the current SDK 0.17.0 API. Add the package URL in
Xcode, or declare it in `Package.swift`:

```swift
dependencies: [
    .package(
        url: "https://github.com/Jainakin/qvac-swift.git",
        .upToNextMinor(from: "0.2.0")
    )
],
targets: [
    .target(
        name: "MyApp",
        dependencies: [
            .product(name: "QVACClient", package: "qvac-swift")
        ]
    )
]
```

If `0.2.0` is not yet available during review, evaluators can temporarily replace
the version requirement with `branch: "main"`. Do not ship a branch-based
dependency. Commit your application's `Package.resolved` file when using a
reviewed release. The existing `v0.1.0` tag predates the current stream types and
buffering behavior.

## Quick start

### iOS

The iOS package includes the worker bundle and native runtime dependencies. No
Node.js process is started on the device.

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
    for try await progress in load.progress {
        print("download: \(progress.percentage)%")
    }
    let modelId = try await loadedModelId

    let completion = try await client.completion(
        modelId: modelId,
        history: [.user("Explain local-first AI in one sentence.")],
        rpcOptions: .init(timeout: .seconds(60))
    )

    for try await token in completion.tokenStream {
        print(token, terminator: "")
    }
    _ = try await completion.final.value

    try await client.unloadModel(modelId: modelId)
    await client.close()
} catch {
    await client.close()
    throw error
}
```

### macOS

On macOS, the client runs the QVAC worker as a Bare subprocess over a private
Unix-domain socket. Install the matching runtime in your application environment:

```bash
mkdir qvac-runtime
cd qvac-runtime
npm init -y
npm install --save-exact @qvac/sdk@0.17.0 bare-runtime@1.31.0
```

Keep the generated npm lockfile, then pass the resulting `node_modules`
directory to the client:

```swift
let configuration = try QVACClient.Configuration.macOS(
    nodeModulesDir: URL(
        fileURLWithPath: "/absolute/path/to/qvac-runtime/node_modules"
    )
)
let client = try await QVACClient(configuration: configuration)
```

The configuration uses `node_modules/bare-runtime/bin/bare` when available. Set
`bareExecutable` only when your deployment manages that executable separately.

## API overview

The generated contract covers all 39 methods published by QVAC SDK 0.17.0:

| Area | Operations |
|---|---|
| Models | Load, unload, inspect, download, cache, and registry operations |
| Language | Completion, batch completion, orchestration, embedding, and translation |
| Audio | Transcription, BCI transcription, speech synthesis, and audio generation |
| Vision and media | OCR, classification, diffusion, video, upscaling, and VLA operations |
| Data and extensions | RAG, plugins, finetuning, logging, and provider lifecycle |
| Runtime | Heartbeat, state, cancellation, suspend, resume, and system resources |

Higher-level APIs expose typed results, progress, request IDs, and `Data`
conversion for common operations. Generated `wire...` methods are also available
when an application needs the complete request schema.

### Deadlines and cancellation

`QVACRPCOptions` can be supplied to every operation. The default timeout is 60
seconds. Unary calls use a total deadline, server streams use an inactivity
deadline, and duplex calls apply the deadline while opening the session.

Choose longer limits for model downloads and large media operations. Set
`timeout: nil` only when another watchdog bounds the operation.

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

If the worker connection is replaced, in-flight work is not replayed. The next
caller receives `QVACError.connectionReset` so it can restore model or session
state before retrying.

### Streaming and memory limits

Wire messages, decoded records, raw queues, and public streams all have explicit
limits. `QVACBufferedStream` stores complete producer batches and flattens them
lazily. Lossless streams report `QVACStreamBufferOverflow` when a consumer cannot
keep up; progress streams coalesce older snapshots while retaining the newest
bounded window.

The default wire-message limit is 256 MiB to accommodate media returned as
base64 JSON. Applications can lower `maximumWireMessageBytes` and
`maximumBufferedStreamBytes` for their model set and memory budget.

### Profiling

Enable profiling per request and provide a metadata handler when creating the
client:

```swift
let client = try await QVACClient(
    configuration: try .iOSWithBundledResource(),
    profilingMetadataHandler: { metadata in
        print(metadata.value)
    }
)

let options = QVACRPCOptions(
    timeout: .seconds(30),
    profiling: .init(enabled: true, includeServerBreakdown: true)
)
```

Profiling trailers are consumed separately from typed response values.

## Development

The root `Package.swift` is the URL-backed consumer manifest. `Package.swift.dev`
describes the locally generated XCFramework graph used by development and CI.

Use Node 22.22.0 for code generation and runtime artifacts:

The activation command replaces `Package.swift`; run this sequence in a
disposable checkout or worktree.

```bash
tools/codegen/bootstrap.sh
tools/codegen/run.sh --generate-only
tools/runtime/link-ios-artifacts.sh
CI=true node tools/ci/package-manifest-mode.mjs --activate-development

swift build -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete
tools/ci/run-unit-tests.sh
```

Run the example application after generating its Xcode project:

```bash
cd Examples/QVACChat
xcodegen generate
xcodebuild -project QVACChat.xcodeproj -scheme QVACChat-iOS \
  -destination 'generic/platform=iOS Simulator' build
xcodebuild -project QVACChat.xcodeproj -scheme QVACChat-macOS \
  -destination 'platform=macOS' build
```

Required live and model suites validate their fixtures by revision, byte count,
and SHA-256 and treat missing configuration or skipped tests as failures.

## Documentation

- [Getting started](Sources/QVACClient/Documentation.docc/GettingStarted.md)
- [Architecture](Sources/QVACClient/Documentation.docc/Architecture.md)
- [Security model](Sources/QVACClient/Documentation.docc/Security.md)
- [Transport protocol notes](docs/protocol-notes.md)
- [Code generation](tools/codegen/README.md)
- [Distribution and release](docs/distribution.md)
- [Submission evidence](SUBMISSION.md)
- [Third-party notices](THIRD_PARTY_NOTICES.md)
- [Changelog](CHANGELOG.md)
- [Contributing](CONTRIBUTING.md)
- [Security policy](SECURITY.md)

## Release integrity

Code generation is pinned to the published `@qvac/sdk@0.17.0` source commit
`e8b440665a053a9efe852f04c3601da44f0d55d8`. Runtime dependencies, generated
contracts, the worker bundle, and binary artifacts are checksum-verified in CI.
See [`tools/provenance/qvac-sdk.lock.json`](tools/provenance/qvac-sdk.lock.json)
for the source and package identities.

The next binary release remains blocked until the native-license and Apple
privacy-manifest reviews listed in [the release guide](docs/distribution.md) are
complete. Designated maintainers own release and Swift Package Index publication.

## License

QVACClient source is licensed under Apache-2.0; see [LICENSE](LICENSE). Bundled
runtime components are subject to their own terms, documented in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
