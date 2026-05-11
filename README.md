# QVAC Swift Client

A native Swift client for the [QVAC SDK](https://docs.qvac.tether.io/) — Tether's
local-first on-device AI runtime. iOS 17+ and macOS 14+, arm64. Async/await throughout,
streaming via `AsyncSequence`, zero JavaScript at the call site.

Built against [Tether grant 2885283454](https://tether.dev/grants/bounties/2885283454/).
See [PLAN.md](PLAN.md) for the implementation roadmap.

## Status

| Phase | Scope | State |
|---|---|---|
| **M1** — IPC transport + codec + codegen | [`PLAN.md §3.1`](PLAN.md#phase-1--m1-code-gen--ipc-transport-800-usdt) | ✅ Shipped |
| **M2** — Core API surface (loadModel, completion, embed, transcribe, etc.) | [`PLAN.md §3.2`](PLAN.md#phase-2--m2-core-api-surface-1000-usdt) | ✅ Shipped |
| **M3** — RAG, plugins, docs, distribution | [`PLAN.md §3.3`](PLAN.md#phase-3--m3-rag-plugins-docs-distribution-1200-usdt) | ✅ Shipped |

## Install

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/tetherto/qvac-swift", from: "0.1.0"),
],
targets: [
    .target(
        name: "App",
        dependencies: [
            .product(name: "QVACClient", package: "qvac-swift"),
        ]
    ),
]
```

iOS 17+, macOS 14+, both arm64. The package vendors a pre-built
`worker.mobile.bundle.js` as an SPM resource — no extra setup on iOS.

## Quickstart

### iOS

```swift
import QVACClient

let client = try await QVACClient(configuration: try .iOSWithBundledResource())
let modelId = try await client.loadModel(
    modelSrc: "https://huggingface.co/.../model.gguf",
    modelType: "llamacpp-completion"
)
let run = try await client.completion(
    modelId: modelId,
    history: [.user("Say hi in one word.")]
)
for try await tok in run.tokenStream {
    print(tok, terminator: "")
}
try await client.unloadModel(modelId: modelId)
```

### macOS

macOS spawns the worker as a subprocess. You need `bare` runtime + a
`node_modules/@qvac/sdk` installation:

```bash
# one-time setup
brew install holepunchto/tap/bare-runtime
mkdir my-app && cd my-app && npm init -y
npm install @qvac/sdk
```

```swift
let client = try await QVACClient(configuration:
    try .macOS(nodeModulesDir: URL(fileURLWithPath: "/path/to/my-app/node_modules"))
)
// … same API as iOS from here on
```

## Architecture

The Swift client speaks the [bare-rpc](https://github.com/holepunchto/bare-rpc) wire
protocol on top of a byte-level [`BareTransport`](Sources/QVACClient/Internal/Transport/BareTransport.swift):

- **macOS** → `UnixDomainSocketTransport`: spawns `bare worker.js` as a subprocess,
  communicates over a Unix Domain Socket — same pattern as the JS client on Node.
- **iOS** → `BareIPCTransport`: runs the worker *in-process* as a libuv thread via
  Holepunch's BareKit, communicates over a socketpair. No subprocess (Apple forbids it).

The codec, multiplexer, and high-level API are platform-agnostic and share the same
codepaths on both platforms.

Wire types are **generated** from the QVAC SDK's Zod schemas — see
[`tools/codegen/`](tools/codegen/). Re-running the generator against the latest
`@qvac/sdk` produces no diff against the checked-in output for an unchanged version
(satisfies grant criterion **AC-11**); a daily CI job opens an issue automatically when
upstream shapes change.

More: [`docs/spike-validations.md`](docs/spike-validations.md) for protocol validation
history, [`docs/bundle-and-addons.md`](docs/bundle-and-addons.md) for iOS bundle and
native-addon strategy.

## Full API surface

| Group | Methods |
|---|---|
| Lifecycle | `init(configuration:)`, `heartbeat()`, `close()`, `cancel(_:)` |
| Model lifecycle | `loadModel`, `loadModelStreaming`, `unloadModel`, `downloadAsset`, `downloadAssetStreaming` |
| LLM | `completion` (with `events` / `tokenStream` / `final`) |
| Embeddings | `embed` (single + batch) |
| Audio | `transcribe`, `transcribeStream` (duplex), `textToSpeech`, `textToSpeechStream` (duplex) |
| Translation | `translate` (LLM + NMT modes) |
| Vision | `ocr`, `diffusion` |
| RAG | `ragIngest`, `ragSearch`, `ragChunk`, `ragSaveEmbeddings`, `ragDeleteEmbeddings`, `ragListWorkspaces`, `ragCloseWorkspace`, `ragDeleteWorkspace`, `ragReindex` |
| Plugins | `invokePlugin`, `invokePluginStream` (Codable generics) |

Reference docs: build the DocC catalog (`xcodebuild docbuild -scheme QVACClient`) or
read [`Sources/QVACClient/Documentation.docc/`](Sources/QVACClient/Documentation.docc/).

## Example app

`Examples/QVACChat/` is a complete SwiftUI demo — type a prompt, load a model, watch
tokens stream. Builds for both iOS Simulator and macOS:

```bash
cd Examples/QVACChat
xcodegen generate
xcodebuild -scheme QVACChat-iOS  -destination 'platform=iOS Simulator,name=iPhone 17'
xcodebuild -scheme QVACChat-macOS -destination 'platform=macOS'
```

## Tests

```bash
swift test --filter QVACClientUnitTests            # 66 unit tests, no Bare worker required
swift test --filter QVACClientIntegrationTests     # 9 live-worker integration tests on macOS
xcodebuild test \
    -project spike-swift/Examples/BareKitProbeApp/BareKitProbeApp.xcodeproj \
    -scheme BareKitProbeApp \
    -destination 'platform=iOS Simulator,name=iPhone 17'   # iOS hosted XCTest
```

Real-model integration tests are gated on `QVAC_RUN_REAL_MODEL_TESTS=1` + an `HF_TOKEN`
env var. Default `swift test` runs are fast and don't download anything.

## Benchmark (KR-2)

```bash
./bench/run.sh 500       # 500 heartbeat iters Swift vs Node
```

Reference numbers on M1 Mac mini, macOS 14 (see `bench/results.json`):
**Swift 67μs mean vs. Node 68μs mean — parity, well inside the 5% budget.**

## License

Apache-2.0 — matches upstream QVAC SDK.

## References

- [PLAN.md](PLAN.md) — full grant traceability + implementation plan
- [ISSUES.md](ISSUES.md) — issue tracker
- [docs/spike-validations.md](docs/spike-validations.md) — protocol validation evidence
- [docs/bundle-and-addons.md](docs/bundle-and-addons.md) — iOS bundle + addon strategy
- [tools/codegen/README.md](tools/codegen/README.md) — codegen pipeline
- [QVAC SDK docs](https://docs.qvac.tether.io/)
