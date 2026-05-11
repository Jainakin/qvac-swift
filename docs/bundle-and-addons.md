# QVAC Mobile Bundle + Native Addons — How It Works on iOS, and How the Swift Package Should Ship Them

**Status:** validated against the live tooling on 2026-05-11.
**Spike artifacts:** `spike-js/node_modules/{bare-link,bare-pack,@qvac/*}`, `/tmp/qvac-frameworks/*.xcframework`.
**Sources of truth:**
- `holepunchto/bare-link` — addon → framework/xcframework pipeline
- `holepunchto/bare-pack` — JS module → bundle pipeline
- `tetherto/qvac/packages/sdk/expo/plugins/*` — how the Expo path stitches them
- `tetherto/qvac/packages/cli` — the `qvac bundle sdk` orchestrator
- `holepunchto/bare-kit/shared/{worklet.js,worklet.c,ipc.c}` — runtime that loads everything

This document answers the original Phase-0 questions (PLAN.md OQ-3) and locks the SPM design before M1.

---

## 1. Two artifacts the iOS app must contain

A working QVAC iOS app needs both of these at runtime:

1. **A JS bundle** — a single archive containing the worker's JS source + every JS dependency it transitively imports, plus a manifest of which native addons it expects to load.
2. **A set of native addon frameworks** — one Apple framework per `@qvac/*` (and supporting Bare) addon, packaged so that `dlopen` works at the right paths.

The Expo path generates both at *consumer-app build time*. Our Swift package must reproduce or pre-ship them.

### 1.1 The JS bundle (`worker.mobile.bundle.js` / `.bundle`)

**Producer:** `@qvac/cli bundle sdk` — itself a thin wrapper over `bare-pack`.

What `bare-pack` does, per `node_modules/bare-pack/index.js:6-75`:
1. Starts from an entry module (the worker), walks every `require`/`import` via `bare-module-traverse`.
2. Writes each visited module's source into a `bare-bundle::Bundle` object keyed by URL.
3. Tracks two side-tables: `addons` (URLs of native `.bare` modules required by the JS) and `assets` (data files the JS expects to find at runtime).

The result is a serialized `.bundle` file. On Bare, `BareWorklet.start(name: "app", ofType: "bundle")` extracts it to a cache dir and runs the marked `main` module. (Holepunch's `bare-kit/shared/worklet.js` does the extraction transparently.)

**For QVAC specifically**, the `qvac bundle sdk` invocation flags are (from `packages/sdk/expo/plugins/withMobileBundle.ts:131-148`):
```
qvac bundle sdk \
  --sdk-path  <path-to-installed-@qvac/sdk> \
  --config    <project>/qvac.config.{json,js,mjs}      # optional plugin allowlist
  --host      ios-arm64 --host ios-arm64-simulator --host ios-x64-simulator --host android-arm64
  --defer     expo-file-system --defer react-native-bare-kit --defer @qvac/sdk/worker.mobile.bundle
  --quiet
```
Output: `<projectRoot>/qvac/worker.bundle.js` (copied to `<sdkDir>/dist/worker.mobile.bundle.js`).

The `--host` flag determines which addon prebuilds the bundle expects at runtime — it doesn't include the binaries, just records their URLs. The `--defer` flag tells the packer "don't try to bundle these modules; they'll be resolved at runtime by the host."

### 1.2 The addon frameworks (`*.framework` / `*.xcframework`)

**Producer:** `bare-link` (`node_modules/bare-link/index.js:6-87`).

What `bare-link` does for Apple targets (per `lib/platform/apple.js` + `apple/create-framework.js`):
1. Walks the consumer app's `node_modules`, finds every package with `pkg.addon === true` in its `package.json`.
2. For each addon, looks for `prebuilds/<host>/<sanitized-name>.bare` (which is just a Mach-O dylib renamed).
3. Combines multi-host slices into Apple fat binaries.
4. Rewrites Mach-O install names so addons reference each other via `@rpath/<name>.<version>.framework/<name>.<version>`.
5. Emits a per-addon `.framework` directory (with Info.plist, Resources, code-sign), then bundles them into an `.xcframework`.
6. Recurses into addon dependencies, so transitive dependents (e.g. `bare-tls` from `llm-llamacpp`) are produced too.

**Manifest filtering (`addons.manifest.json`):** the patched `react-native-bare-kit/ios/link.mjs` (copied from `packages/sdk/expo/plugins/patches/ios-link.mjs`) can narrow the set of addons linked, by reading `<projectRoot>/qvac/addons.manifest.json`:
```json
{
  "addons": ["@qvac/llm-llamacpp", "@qvac/transcription-whispercpp"]
}
```
Without this manifest, bare-link links every addon found in `node_modules`. This is the primary mechanism to control app size.

### 1.3 The runtime contract: how the worklet finds its addons

When the worklet's JS does `require.addon('@qvac/llm-llamacpp')`:

1. Bare's module loader matches the package against the bundle's `addons` table (the side-table from §1.1).
2. The platform-specific addon loader (`bare-kit/shared/ipc.c` and friends on Apple) calls `dlopen` on the framework's executable file: `@rpath/qvac__llm-llamacpp.<version>.framework/qvac__llm-llamacpp.<version>`.
3. `@rpath` is resolved relative to the host app binary (Apple's standard runpath search). Apple frameworks live in `<App>.app/Frameworks/`.
4. Once `dlopen` succeeds, Bare invokes the addon's Node-API init function and exposes its surface to JS.

If a framework is missing at runtime, the call throws `MODULE_NOT_FOUND`. (We observed this in the spike when `hyperdrive` peer-dep was uninstalled; the worker crashed at startup.)

**Critical consequence:** every `.bare` an addon's compiled JS expects must be present as a framework in `<App>.app/Frameworks/`. Even one missing addon breaks bootstrap. **The JS bundle and the framework set must be consistent**: the bundle's `addons` table is a subset of (or equal to) the available frameworks. The Expo plugin enforces this by deriving both from the same `node_modules` snapshot.

---

## 2. Real-world sizes (measured)

Running `bare-link` against the kitchen-sink dep set (`@qvac/llm-llamacpp` + `@qvac/embed-llamacpp` + `@qvac/transcription-whispercpp` + `@qvac/transcription-parakeet` + `@qvac/translation-nmtcpp` + `@qvac/tts-onnx` + `@qvac/ocr-onnx` + `@qvac/diffusion-cpp` + transitive deps) for hosts `ios-arm64`, `ios-arm64-simulator`, `ios-x64-simulator`:

- **41 xcframeworks produced**
- **Total: 442 MB** (all three iOS slices combined)
- **Device-only (`ios-arm64` slice): ~147 MB** estimated

Top 10 by size (the others are <10 MB each):

| Framework | Size (3 slices) |
|---|---|
| bare-ffmpeg.1.2.2 | 89 MB |
| qvac__diffusion-cpp.0.3.0 | 72 MB |
| qvac__onnx.0.14.0 | 62 MB |
| qvac__translation-nmtcpp.2.1.1 | 36 MB |
| qvac__llm-llamacpp.0.20.0 | 29 MB |
| rocksdb-native.3.15.1 | 26 MB |
| qvac__llm-llamacpp.0.17.4 | 24 MB (older copy from peer-dep) |
| qvac__ocr-onnx.0.4.5 | 23 MB |
| qvac__tts-onnx.0.8.6 | 23 MB |
| qvac__embed-llamacpp.0.14.0 | 22 MB |
| qvac__transcription-whispercpp.0.6.8 | 8.8 MB |
| bare-tls.3.1.3 | 8.9 MB |

For a typical "chat + voice" app (`llm-llamacpp` + `embed-llamacpp` + `transcription-whispercpp` + `tts-onnx`), the iOS-arm64-only download budget would be ~70 MB compressed via App Thinning. For App Store delivery this is well within limits (Apple's max app size is 4 GB; max OTA download on cellular is 200 MB after 2024 lift).

---

## 3. SPM packaging options

The grant says (§SI-4): *"Integration glue (e.g. a thin Swift wrapper that shells out or embeds Bare to spawn the worker) must be provided so that a Swift app can `import QVACClient` and use it end-to-end without manual worker management."*

"Without manual worker management" implies the consumer shouldn't need to invoke Node, npm, bare-link, or bare-pack themselves. With that constraint, three options:

### Option A — Pre-built kitchen-sink xcframeworks vendored in the SPM repo

**Mechanism:** The qvac-swift repo's CI runs `npm install @qvac/sdk @qvac/llm-llamacpp …` plus `node bare-pack ./worker.entry.js` plus `node bare-link .` against the install. The outputs (one `.bundle` file + 41 `.xcframework`s) are committed to the repo under `Vendor/`. `Package.swift` declares each as a `.binaryTarget` and ships them as one umbrella library product.

**Consumer DX:**
```swift
// Package.swift of the consumer app
dependencies: [.package(url: "github.com/tetherto/qvac-swift", from: "0.1.0")]
// then:
import QVACClient
let client = try await QVACClient()
let modelId = try await client.loadModel(.llama_3_2_1B_INST_Q4_0)
for try await tok in client.completion(modelId: modelId, prompt: "hi") { ... }
```
No Node. No build scripts.

**Tradeoffs:**

| Pro | Con |
|---|---|
| Best UX. Zero ceremony. | 442 MB checked into the repo. |
| Reproducible — pinned versions. | Every consumer downloads everything even if they only want LLM. |
| Build time is instant (binaryTargets are just unzipped). | App Store binary thinning helps but base ~150 MB is still a lot for some apps. |
| Trivial CI: just `swift build`. | Bumping addon versions requires re-running CI in qvac-swift repo. |

**SPM mechanics:**
- Use GitHub Releases (not raw repo) for the xcframeworks to avoid 442 MB checked into git. Each release tag publishes a `.zip` per xcframework, referenced via `.binaryTarget(url: …, checksum: …)`.
- `Package.swift` lists 41 binary targets + one library product that depends on all of them.
- `.bundle` file (the JS bundle) is a `.copy(...)` resource on the main `QVACClient` target.

### Option B — Build-time `bare-link` + `bare-pack` invocation via SPM build plugin

**Mechanism:** Consumer's `Package.swift` declares `QVACClient` as a dependency. `QVACClient` has a SwiftPM **build tool plugin** that, at consumer-build-time:
1. Locates `node` (errors if not installed).
2. Reads `qvac.swift.config.json` from the consumer's package (lists which `@qvac/*` plugins they want).
3. Runs `bare-link --host ios-arm64 …` to produce xcframeworks into the build dir.
4. Runs `bare-pack` to produce `worker.bundle`.
5. Returns paths to xcodebuild via SPM plugin output channels.

**Consumer DX:**
```bash
# Consumer one-time setup:
npm install @qvac/sdk @qvac/llm-llamacpp
# Then:
swift build  # plugin runs node + bare-link automatically
```
A `qvac.swift.config.json` declares the addon set; the plugin enforces it via bare-link's manifest filtering.

**Tradeoffs:**

| Pro | Con |
|---|---|
| Minimal binary (only the addons consumer asked for, e.g. ~30 MB for LLM-only). | Requires Node v22+ on the build machine. CI must install it. |
| Always picks up the latest `@qvac/sdk` version. | Build plugins are slow (Node startup + linking dwarfs Swift compile). |
| Addon set is data-driven. | Plugin sandboxing limits filesystem access; needs `--allow-network`/etc. (Apple's SPM-plugin sandbox is strict.) |
| Best for power users. | Apple's SwiftPM build plugins cannot reliably download network resources or run arbitrary subprocesses; the plugin's `permission` request may fail in Xcode without UI. |

### Option C — Multiple SPM products, each a preset addon variant

**Mechanism:** qvac-swift ships several library products:
- `QVACClient` (core — RPC + types, no addons, no bundle)
- `QVACClient-LLM` (depends on core + bundled `llm-llamacpp` xcframeworks + the corresponding `.bundle`)
- `QVACClient-Voice` (LLM + Whisper + TTS)
- `QVACClient-Vision` (LLM + OCR + Diffusion)
- `QVACClient-Full` (everything = Option A)

Each variant has its own pre-built `.bundle` + framework set. CI generates all of them on every release.

**Consumer DX:**
```swift
dependencies: [.package(url: "github.com/tetherto/qvac-swift", from: "0.1.0")],
targets: [.target(name: "App", dependencies: [
    .product(name: "QVACClient-LLM", package: "qvac-swift")
])]
```
No Node required. Choice without complexity.

**Tradeoffs:**

| Pro | Con |
|---|---|
| Good UX, no Node required, app-size controlled. | qvac-swift CI must produce N variants per release. |
| Each variant is a sensible bundle. | Adding a new variant requires a new SPM product (not configurable at consumer level). |
| Per-variant `.binaryTarget` per addon is reusable across variants (one upload, multiple products link it). | Some consumers will inevitably want a custom mix that doesn't match any preset. |

---

## 4. Recommendation: Option A as v0.1, Option C in v0.2, Option B never

### Why A for v0.1

1. **Fastest to ship.** One CI pipeline, one config, one product.
2. **Best matches grant SI-4 verbatim** — "without manual worker management" rules out option B; option C is a refinement of A.
3. **App Store viable:** ~150 MB on-device. Big, but most QVAC apps will be ML-heavy anyway.
4. **Forces a real reference implementation** of the full stack — a foundation for option C variants later.

### Why C for v0.2

After A ships and we have user data on which subsets are actually used, we can ship 2–3 presets. Each preset is just a reduced SPM product against the same vendored frameworks; no new tooling.

### Why not B

SwiftPM build plugins have two hard limits that kill them for our case:
- **Sandbox + network:** Apple's plugin sandbox blocks arbitrary network access. Running `npm install` or pulling binaries on-demand can't be done from a build plugin without `--disable-sandbox`, which is heavy-handed and not viable for App Store apps.
- **Node toolchain dependency:** the plugin must run `node`, which means every consumer's machine + every CI runner must have Node 22+. That's a real burden, and a foot-gun for users new to JS tooling.

We can revisit B if a power-user community asks for it.

---

## 5. Concrete v0.1 build pipeline (Option A)

```
qvac-swift repo CI (on release tag):
┌──────────────────────────────────────────────────────────────┐
│  1. npm install @qvac/sdk + @qvac/llm-llamacpp + …           │  
│  2. node tools/build/bundle-and-link.mjs:                    │
│     a. bare-pack worker.entry.js → worker.bundle             │
│     b. bare-link --host ios-arm64 … → /build/frameworks/     │
│  3. For each .xcframework:                                   │
│     a. zip + sha256 → /build/release-artifacts/              │
│  4. Tag + GitHub Release → upload all zips                   │
│  5. Generate Package.swift with binaryTarget URL + checksum  │
│     entries for each release artifact                        │
│  6. Commit & push (or generate Package.swift at release-time │
│     and tag a new minor)                                     │
└──────────────────────────────────────────────────────────────┘
                            │
                            ▼
Consumer app:
┌──────────────────────────────────────────────────────────────┐
│  Package.swift:                                              │
│    dependencies: [.package(url: "github.com/tetherto/qvac-   │
│    swift", from: "0.1.0")]                                   │
│  → SwiftPM downloads xcframework zips from the GitHub        │
│    Release (cached in ~/Library/Caches/org.swift.swiftpm/)   │
│  → xcodebuild integrates them; Xcode embeds Frameworks       │
│    automatically                                             │
└──────────────────────────────────────────────────────────────┘
                            │
                            ▼
App at runtime on iOS:
┌──────────────────────────────────────────────────────────────┐
│  1. Swift code calls QVACClient.completion(...)              │
│  2. BareWorklet starts with the embedded worker.bundle as JS │
│     source (loaded as a Bundle resource from QVACClient.bun- │
│     dle, packaged via SPM resource declarations)             │
│  3. Worklet does require.addon('@qvac/llm-llamacpp')         │
│  4. Bare loader dlopens                                      │
│       @rpath/qvac__llm-llamacpp.0.20.0.framework/…           │
│     which lives in App.app/Frameworks/ — placed there auto-  │
│     matically by SwiftPM's framework-embedding step          │
│  5. RPC over BareIPC ↔ Swift host (PLAN §2.2)                │
└──────────────────────────────────────────────────────────────┘
```

**Outstanding question for Tether (already in OQ-3):** is publishing 442 MB worth of xcframeworks as GitHub Release assets per qvac-swift version acceptable to the Tether infrastructure team? If not, alternative hosting (S3, CDN) is straightforward — `.binaryTarget(url:)` accepts any URL.

---

## 6. Implementation deltas this implies for the plan

| Area | Was | Now |
|---|---|---|
| **PLAN §2.9** | Speculative A/B/C tradeoff | Locked: A for v0.1, C for v0.2, B rejected. |
| **PLAN §3 QVAC-218** ("Worker lifecycle glue (iOS)") | "4d" | Subdivide: 1d for SPM resource bundling of `.bundle`; 2d for CI pipeline that runs bare-pack + bare-link; 2d for `binaryTarget` Package.swift generation. **Total 5d (+1d).** |
| **PLAN §6 CI matrix** | No release pipeline detail | Add `release.yml` that runs `node tools/build/bundle-and-link.mjs` then uploads xcframeworks to the GitHub Release. |
| **PLAN §7 R-3** ("Bundle generation requires heavy `@qvac/cli` deps") | Medium/Medium | Drop to Low/Low. We've validated bare-pack + bare-link standalone, no @qvac/cli required if we drive bare-pack directly. |
| **New risk R-15** | — | **Apple Mach-O signing requirements**: bare-link calls `codesign` on each framework. For App Store submission, the consumer's developer cert must re-sign on archive. Apple's standard `--deep` signing handles this; document in README. |

---

## 7. Verified runtime evidence

The spike-swift `BareKitProbeApp` (Phase-0 QVAC-004 follow-up) demonstrates the iOS-side runtime model end-to-end with **no addons** (just a byte-echo worklet) — confirms BareKit + BareIPC paths. The next M1 work item that exercises a real addon-loading path is:

- **QVAC-218 sub-task:** ship a minimal `QVACClient-Mini` variant containing only `bare-fs` + a stub addon, prove the whole framework-discovery + dlopen flow runs inside the simulator app. Then iterate up to `@qvac/llm-llamacpp` (smallest real plugin).
- **QVAC-222** still adopts this as its mandatory integration test.

## 8. References / source code reading
- `node_modules/bare-link/index.js` — entry point, host dispatch
- `node_modules/bare-link/lib/platform/apple.js` — Apple-specific dispatch
- `node_modules/bare-link/lib/platform/apple/create-framework.js` — the framework producer (the real work)
- `node_modules/bare-link/lib/platform/apple/create-xcframework.js` — assembles slices
- `node_modules/bare-pack/index.js` — JS bundle producer
- `qvac-sparse/packages/sdk/expo/plugins/withMobileBundle.ts` — Expo orchestrator
- `qvac-sparse/packages/sdk/expo/plugins/patches/ios-link.mjs` — manifest-aware shim
- `holepunchto/bare-kit/shared/worklet.js` — bundle extraction at runtime
- `holepunchto/bare-kit/shared/apple/ipc.m` — BareIPC implementation (the channel BareKitProbe used)
