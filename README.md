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
`worker.mobile.bundle.js` as an SPM resource — no extra setup on iOS. The bundle
is ~10 MB compressed; App Store thinning trims it further per device.

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

macOS spawns the worker as a subprocess. You need (one-time):

```bash
# 1. bare runtime
brew install holepunchto/tap/bare-runtime
bare --version          # sanity check

# 2. @qvac/sdk installed somewhere — anywhere works as long as the path is stable.
#    `--legacy-peer-deps` is required because @qvac/sdk's peerDeps overlap with
#    its own deps (npm 7+ would otherwise reject the install).
mkdir my-app && cd my-app
npm init -y
npm install --legacy-peer-deps @qvac/sdk
# `node_modules/@qvac/sdk/dist/server/worker.js` is now the path the Swift client
# resolves to. Capture `$(pwd)/node_modules` and pass that to nodeModulesDir.
```

```swift
let client = try await QVACClient(configuration:
    try .macOS(nodeModulesDir: URL(fileURLWithPath: "/path/to/my-app/node_modules"))
)
// … same API as iOS from here on
```

Tips:
- The `nodeModulesDir` must contain `@qvac/sdk/dist/server/worker.js`. The path is
  validated at `connect` time; you'll see `workerNotFound` immediately if it's wrong.
- If `bare` isn't on `/opt/homebrew/bin` or `/usr/local/bin`, pass `bareExecutable:` to
  `Configuration.macOS(...)` explicitly. The package also scans nvm versioned dirs and
  falls back to `which bare`.
- The `Examples/QVACChat` macOS target uses a `resolveNodeModulesDir()` helper that
  checks (1) the `QVAC_NODE_MODULES` env var, (2) `./spike-js/node_modules` (monorepo
  layout), then (3) `./node_modules` relative to cwd. Steal the pattern if your app
  doesn't want to hard-code the path either — see [Examples/QVACChat/Sources/ContentView.swift](Examples/QVACChat/Sources/ContentView.swift).

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

On macOS the example needs to know where your `@qvac/sdk` `node_modules` live. The
app's `resolveNodeModulesDir()` helper checks in this order:

1. `QVAC_NODE_MODULES` env var (explicit override — set this when running the macOS
   target from Xcode via the scheme's Environment Variables)
2. `./spike-js/node_modules` relative to the cwd (works when launching from the
   monorepo root)
3. `./node_modules` relative to the cwd (works when the example is run from a sibling
   directory that has `@qvac/sdk` installed)

If none match, the app throws a clear error with instructions; iOS doesn't need this
because the worker bundle is shipped as an SPM resource.

## Tests

```bash
swift test --filter QVACClientUnitTests            # 70 unit tests, no Bare worker required
swift test --filter QVACClientIntegrationTests     # live-worker integration tests on macOS
xcodebuild test \
    -project spike-swift/Examples/BareKitProbeApp/BareKitProbeApp.xcodeproj \
    -scheme BareKitProbeApp \
    -destination 'platform=iOS Simulator,name=iPhone 17'   # iOS hosted XCTest
```

Integration tests are env-gated so a default `swift test` is fast and offline:

| Env var | Suite that runs | What it covers |
|---|---|---|
| `QVAC_BARE_BIN` + `QVAC_WORKER_SCRIPT` | `LiveWorkerIntegrationTests` | init, heartbeat, downloadAsset streaming, cancel envelope, close |
| `QVAC_BARE_BIN` + `QVAC_NODE_MODULES` | `QVACClientIntegrationTests` | full client lifecycle via public `QVACClient` API |
| `QVAC_RUN_REAL_MODEL_TESTS=1` + above | `RealModelIntegrationTests` | full `load → completion → cancel → unload` cycle (requires `HF_TOKEN` or a public model) |
| `QVAC_RUN_RAG_TESTS=1` + above | `RAGIntegrationTests` | full RAG ingest/search/delete vs a live worker |

CI runs the first two by default; the model-bearing suites are opt-in (they download
weights and take minutes). See `.github/workflows/ci.yml` for the wiring.

## Benchmark (KR-2)

```bash
./bench/run.sh 500       # 500 heartbeat iters Swift vs Node, prints ratio
```

The script runs both the Swift and the Node clients against the same Bare worker, then
compares mean round-trip latency. KR-2 requires Swift overhead < 5% of Node. The script
exits non-zero if the ratio exceeds `QVAC_BENCH_MAX_OVERHEAD` (default `1.05`). No
results are committed to the repo — every reviewer regenerates them locally so the
numbers reflect *their* hardware.

## Security model

The Swift client is the consumer half of a client/worker split. Threat model and the
guarantees you should expect from this library:

| Boundary | Trust assumption | What the library does |
|---|---|---|
| **macOS UDS socket** between client + spawned worker | only the spawning user can connect | socket sits inside a 0700 `mkdtemp` dir; socket file itself is `chmod 0600`; ~36-bit random path |
| **`environmentOverlay` passed to `.macOS(...)`** | caller is responsible for the values | client strips `DYLD_*`/`LD_PRELOAD`/`LD_LIBRARY_PATH`/`LD_AUDIT` before exec so untrusted overlay can't inject a dylib |
| **Inbound frames from the worker** | bounded size | `BareRPCFrameReader` caps frame size at 64 MiB; oversize frames throw `BareRPCCodecError.frameTooLarge` rather than allocating |
| **`modelSrc`/`assetSrc` URLs** | caller-supplied, library forwards verbatim | URLs are not validated. If your app accepts these from untrusted users, **you must validate them yourself** — the worker will fetch any URL you pass |
| **iOS bundled `worker.mobile.bundle.js`** | release-time vendored from `@qvac/sdk` | inherent supply-chain trust on upstream SDK; releases pin a specific `@qvac/sdk` version via `package-lock.json` |

## License

Apache-2.0 — matches upstream QVAC SDK.

## References

- [PLAN.md](PLAN.md) — full grant traceability + implementation plan
- [ISSUES.md](ISSUES.md) — issue tracker
- [docs/spike-validations.md](docs/spike-validations.md) — protocol validation evidence
- [docs/bundle-and-addons.md](docs/bundle-and-addons.md) — iOS bundle + addon strategy
- [tools/codegen/README.md](tools/codegen/README.md) — codegen pipeline
- [QVAC SDK docs](https://docs.qvac.tether.io/)
