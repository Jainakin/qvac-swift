# Distribution

This document covers how releases are cut and how consumers discover the package.

## Release process (`v*` tags)

This is a two-step flow because `Package.swift` is dual-mode:

- **dev mode** (the one checked in) uses `binaryTarget(path: "spike-swift/Vendor/BareKit.xcframework")`
  so the monorepo `swift build` works.
- **consumer mode** uses `binaryTarget(url:checksum:)` so external apps that do
  `.package(url: "...", from: "0.1.0")` can resolve. Generated at release time.

### Step 1 — initial tag (uploads artifacts)

```bash
# Codegen freshness — be sure nothing's drifted.
./tools/codegen/run.sh
git diff --exit-code Sources/QVACClient/Generated/

# Tag + push.
git tag v0.1.0
git push origin v0.1.0
```

`.github/workflows/release.yml` fires automatically:
- Runs unit tests + codegen check
- Generates `worker.mobile.bundle.js` via `@qvac/cli bundle sdk` for iOS targets
- Runs `bare-link` against the addon set to produce ~40 iOS xcframeworks
- Zips each xcframework + emits SHA-256 checksums
- Creates a GitHub Release with all artifacts attached
- Pings the Swift Package Index refresh endpoint
- Prints a warning that the tagged commit's `Package.swift` is still dev-mode

### Step 2 — rewrite Package.swift for consumers, move the tag

After the release workflow finishes:

```bash
# Rewrites Package.swift in place using checksums computed from the just-uploaded
# artifacts. The previous dev-mode manifest is preserved as Package.swift.dev.
tools/release/prepare-release.sh v0.1.0

# Sanity check.
diff Package.swift.dev Package.swift   # should show URL targets replacing path targets
swift package describe                  # should resolve successfully

# Commit + move the tag to the new commit.
git add Package.swift Package.swift.dev
git commit -m "release: pin v0.1.0 binary targets"
git tag -fa v0.1.0 -m "v0.1.0"
git push origin main
git push origin v0.1.0 --force-with-lease
```

Now `.package(url: "https://github.com/.../qvac-swift", from: "0.1.0")` resolves to the
URL-based manifest in a clean checkout, and SPM consumers fetch the artifacts directly
from the GitHub Release.

### Step 3 — Swift Package Index reindex

SPI picks up the new tag within ~10 minutes. If you want to force a reindex, hit the
SPI refresh endpoint manually (the release workflow already does this).

## Swift Package Index submission

First-time setup (one-shot, after the repo is public):

1. Visit https://swiftpackageindex.com/add-a-package
2. Paste the repo URL (`https://github.com/tetherto/qvac-swift`)
3. SPI's `PackageList.json` PR-bot opens a PR against
   https://github.com/SwiftPackageIndex/PackageList — review + merge it.
4. SPI auto-builds against every tagged release after that.

To bump the package and force a re-index, push a new tag — no other action needed.

## Versioning

We follow [SemVer](https://semver.org/):

- `0.x.y` — pre-1.0, breaking changes between minor versions allowed but rare.
- `1.0.0` — first stable release. After this, major-version bumps are reserved for
  breaking changes.

The QVAC SDK version this Swift client targets is recorded in
`tools/codegen/package.json`'s `@qvac/sdk` dependency. The Swift client's version
moves independently — a Swift bugfix release does not require an SDK bump.

## What ships in each release

Artifact zips uploaded to each GitHub Release (consumed via `binaryTarget(url:checksum:)`):

- `BareKit.xcframework.zip` — Holepunch's BareKit (iOS arm64 + iOS sim).
- `qvac__llm-llamacpp.<v>.xcframework.zip` — LLM inference (llama.cpp).
- `qvac__embed-llamacpp.<v>.xcframework.zip` — Embedding model support.
- `qvac__transcription-whispercpp.<v>.xcframework.zip` — Whisper STT.
- `qvac__transcription-parakeet.<v>.xcframework.zip` — Parakeet STT.
- `qvac__translation-nmtcpp.<v>.xcframework.zip` — NMT translation.
- `qvac__tts-onnx.<v>.xcframework.zip` — ONNX TTS.
- `qvac__ocr-onnx.<v>.xcframework.zip` — ONNX OCR.
- `qvac__diffusion-cpp.<v>.xcframework.zip` — sd.cpp image generation.
- Plus all transitive `bare-*` and `@qvac/onnx`, `rocksdb-native`, `bare-ffmpeg`,
  `sodium-native`, etc.

Total per-release upload: ~440 MB (compressed). All three iOS slices in each
xcframework. App Store thinning trims this to ~150 MB at install time per device.

See [`docs/bundle-and-addons.md`](bundle-and-addons.md) for the rationale.

## Updating the QVAC SDK version

Edit `spike-js/package.json` (used by codegen + release CI) to pin a new version:

```bash
npm --prefix spike-js install --save --legacy-peer-deps @qvac/sdk@0.11.0
./tools/codegen/run.sh
git diff Sources/QVACClient/Generated/   # review what changed
git add Sources/QVACClient/Generated/
git commit -m "regen against @qvac/sdk@0.11.0"
```

The drift workflow (`.github/workflows/codegen-drift.yml`) auto-opens a tracking issue
when upstream changes; you don't have to poll manually.

## Consumer app — App Store deployment notes

For iOS apps targeting the App Store that consume `QVACClient`:

### Network usage description

QVACClient loads models from arbitrary HTTPS URLs through the worker. If your app
forwards untrusted URLs (e.g. from a user clipboard / QR scan / deep link) you must
validate them — see the Security article in DocC.

If the app advertises specific model sources only, declare them in `Info.plist`:

```xml
<key>NSAppTransportSecurity</key>
<dict>
  <key>NSAllowsArbitraryLoads</key>
  <false/>
  <key>NSExceptionDomains</key>
  <dict>
    <key>huggingface.co</key>
    <dict>
      <key>NSExceptionAllowsInsecureHTTPLoads</key>
      <false/>
      <key>NSIncludesSubdomains</key>
      <true/>
    </dict>
  </dict>
</dict>
```

### Background fetch / long-running model loads

If your UX allows the user to keep model downloads running while the app is
backgrounded:

```xml
<key>UIBackgroundModes</key>
<array>
  <string>processing</string>
</array>
```

Models often run 100–500 MB so this is a real consideration.

### Privacy manifest

iOS 17+ Privacy Manifest entries you'll likely need (in your app's `PrivacyInfo.xcprivacy`):

- `NSPrivacyAccessedAPICategoryFileTimestamp` — the worker reads cache file metadata.
- `NSPrivacyAccessedAPICategoryDiskSpace` — the worker checks disk space before downloads.
- `NSPrivacyAccessedAPICategorySystemBootTime` — used by the worker's logging timestamps.

(QVACClient itself doesn't call these APIs directly, but the in-process BareKit
worker may; Apple requires the app to declare them.)

### macOS sandbox / App Store

For sandboxed macOS apps spawning the worker subprocess via `.macOS(...)`, you need:

```xml
<key>com.apple.security.cs.allow-jit</key>
<true/>
<key>com.apple.security.cs.disable-library-validation</key>
<true/>
<key>com.apple.security.network.client</key>
<true/>
```

The first two are required because `bare` JITs JavaScript and loads native addons.
The third lets the worker fetch models. The `Examples/QVACChat/Sources/Info.plist`
in this repo is a non-sandboxed dev configuration — replace it with the above
entries for App Store submission.
