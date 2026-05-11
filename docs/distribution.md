# Distribution

This document covers how releases are cut and how consumers discover the package.

## Release process (`v*` tags)

1. Bump the version in any user-facing docs that reference it.
2. Run the codegen freshness check locally to be sure nothing's drifted:
   ```bash
   ./tools/codegen/run.sh
   git diff --exit-code Sources/QVACClient/Generated/
   ```
3. Tag and push:
   ```bash
   git tag v0.1.0
   git push origin v0.1.0
   ```
4. `.github/workflows/release.yml` fires automatically:
   - Runs unit tests + codegen check
   - Generates `worker.mobile.bundle.js` via `@qvac/cli bundle sdk` for iOS targets
   - Runs `bare-link` against the addon set to produce ~40 iOS xcframeworks
   - Zips each xcframework + emits SHA-256 checksums
   - Creates a GitHub Release with all artifacts attached
   - Pings the Swift Package Index refresh endpoint
5. The Swift Package Index picks up the new tag within ~10 minutes and rebuilds its
   compatibility matrix.

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
