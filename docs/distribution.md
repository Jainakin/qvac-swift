# Distribution and release

QVACClient targets exactly `@qvac/sdk` 0.17.0. Source generation is pinned to
release commit `e8b440665a053a9efe852f04c3601da44f0d55d8`; runtime installation is pinned
by `tools/runtime/package-lock.json`; and the committed worker records the same SDK
version in its embedded package metadata.

The release system intentionally has two manifest modes:

- `Package.swift.dev` is the reproducible development manifest. Its 38 local
  binary targets come from `tools/runtime/.build/artifacts`, produced by
  `tools/runtime/link-ios-artifacts.sh`.
- An immutable `artifact-manifest.json` is published with the native GitHub
  Release. A release `Package.swift` is generated from that schema; every binary
  target then has the exact release URL and SHA-256 checksum. The external
  manifest is bound to the final Swift source commit and is not copied back into
  that commit (which would change the commit identity).

Until an unpublished artifact candidate has reproduced all final bytes, the
canonical manifest remains the exact development manifest. Committing the URL
manifest is a short, explicit release-candidate state: no source tag is allowed,
and the artifact publication workflow must reproduce and publish those exact
future URLs before the source-release workflow can run. Neither workflow invents
URLs or reuses old 0.10 assets.

## 1. Reproduce the exact development graph

Use Node 22.22.0, then run:

```bash
tools/codegen/bootstrap.sh
tools/codegen/run.sh --generate-only
git diff --exit-code -- Sources/QVACClient/Generated \
  'Tests/QVACClientUnitTests/*.generated.swift'

tools/runtime/test-bundle-reproducibility.sh
cmp tools/runtime/.build/worker.repro-a.bundle \
  Sources/QVACClient/Resources/worker.mobile.bundle
tools/runtime/link-ios-artifacts.sh
node tools/release/compute-manifest.mjs development \
  tools/runtime/.build/artifacts \
  Sources/QVACClient/Resources/worker.mobile.bundle \
  tools/release/artifacts.development.json
node tools/release/generate-package-manifest.mjs \
  tools/release/artifacts.development.json Package.swift.dev
```

The worker verifier rejects a bundle unless it embeds SDK 0.17.0, has a complete
non-overlapping file table, and contains no local checkout path or `file://` import.
The reproducibility test builds it from two separate work roots and compares all
bytes and the bundle content ID.

For this lock, `bare-link` stages 47 available XCFrameworks, while the computed
runtime closure packages 38: the bundle's exact 37 addon targets plus BareKit.
The nine staged-but-unreferenced targets are recorded in
`artifacts.development.json.nativeClosure.excludedUnreferencedTargets`; they are
excluded mechanically because neither the bundle addon table nor any required
iOS Mach-O `@rpath` dependency references them.

## 2. Produce an unpublished release candidate

Run the **Build Immutable SDK 0.17 Artifacts** workflow on `main`. Choose a new,
monotonically increasing revision such as `1` and leave `publish` disabled. The
workflow uploads an Actions artifact named `artifacts-sdk-0.17.0-r1`; it does not
create a Git tag or GitHub Release.

The workflow:

1. installs only `tools/runtime/package-lock.json` with Node 22.22.0;
2. reproduces the worker twice and compares it with the committed worker;
3. links the exact bundle addon closure plus BareKit;
4. unions Mach-O dependencies across every iOS device and simulator slice and
   requires arm64 device plus arm64/x86_64 simulator coverage for every target;
5. rejects symlinks, path escapes, and input/output overlap before mutation,
   then creates deterministic, UTC-normalized xcframework archives;
6. verifies the generated `THIRD_PARTY_NOTICES.md`, packages it beside the binary
   assets, and binds its size and checksum into `artifact-manifest.json`;
7. verifies every staged byte and uploads the unpublished candidate evidence.

Download that workflow artifact, verify it, and generate only the URL package
manifest:

```bash
CANDIDATE=/absolute/path/to/artifacts-sdk-0.17.0-r1
node tools/release/verify-release.mjs \
  "$CANDIDATE/artifact-manifest.json" \
  --assets-dir "$CANDIDATE"
node tools/release/generate-package-manifest.mjs \
  "$CANDIDATE/artifact-manifest.json" Package.swift
swift package dump-package >/dev/null
cmp "$CANDIDATE/worker.mobile.bundle" \
  Sources/QVACClient/Resources/worker.mobile.bundle
```

Review and commit `Package.swift` on `main`. Do not commit the dry-run
`artifact-manifest.json`: its `sourceCommit` identifies the pre-manifest candidate,
not the new final commit.

Push the URL-manifest commit and require the complete `CI` workflow to pass for
that new exact SHA before enabling publication. A green run for the earlier
development-manifest candidate is useful evidence, but it cannot authorize the
URL-manifest commit because the commit identity changed.

The full CI workflow accepts exactly two canonical manifest states: the generated
development manifest, or the strictly generated URL manifest for one immutable
SDK 0.17 artifact tag. For a URL-manifest commit whose artifacts do not exist yet,
CI first validates its target inventory, repository, tag, URLs, checksums, and
generator formatting, then copies the verified `Package.swift.dev` only inside
the ephemeral runner for compilation and tests. Artifact publication and source
release still verify the canonical URL manifest and every remote byte; the local
CI overlay is never committed or treated as release evidence.

## 3. Publish artifacts from the final source commit

Review `THIRD_PARTY_NOTICES.md`, including the three exact npm artifacts that
declare a license but publish no license file and therefore use pinned
supplemental texts. Confirm their source evidence and attribution before setting
`license_reviewed=true`. Then run **Build Immutable SDK 0.17 Artifacts** again
from that new exact `main` commit, with the same revision and `publish` enabled.
The checkbox is a maintainer/legal attestation, not automated legal advice. The
workflow reproduces all bytes, then hard-fails unless:

- canonical `Package.swift` exactly matches the newly computed URL manifest;
- the committed worker matches the packaged worker;
- generated third-party notices are fresh and the packaged notice checksum is
  bound into the release manifest;
- `artifact-manifest.json.sourceCommit` equals `GITHUB_SHA`; and
- neither the artifact Git tag nor GitHub Release already exists.

Only after those gates pass does it publish `artifacts-sdk-0.17.0-r1`. It then
verifies that the created artifact tag, GitHub Release target, and manifest all
resolve to the exact final source commit. Artifact tags and releases are
immutable: if anything changes, use a new `rN`; never replace an existing release.

The following command is a read-only independent check of the published release:

```bash
tools/release/prepare-release.sh artifacts-sdk-0.17.0-r1
```

It downloads and hashes every binary asset and the third-party notice, binds the
manifest to the current Git commit, verifies the canonical URL `Package.swift`
and embedded worker, and parses the package with SwiftPM. It never edits
repository files. `Package.swift.dev` remains the local exact graph for the next
development cycle.

## 4. Verify first, then create a new source version

Do **not** create or push a SemVer tag by hand. Dispatch the **Source Release**
workflow from the exact verified `main` commit with:

- `version`: `0.1.0`
- `artifact_tag`: `artifacts-sdk-0.17.0-r1`

Before any source tag exists, the workflow binds the published artifact manifest
and artifact tag to `GITHUB_SHA`, rejects a path-based/stale package, downloads and
hashes every remote artifact, builds a clean external consumer from the public Git
URL at that exact revision, and runs unit tests. It creates and pushes the immutable
SemVer tag and GitHub source release only after every gate passes. A retry may use
an already-created tag only when it resolves to the same verified commit; tags are
never moved or force-updated. Pull-request CI separately requires strict-concurrency
compilation with warnings as errors, DocC with warnings as errors, and generic iOS
device and simulator builds.

Consumers can then use:

```swift
.package(url: "https://github.com/Jainakin/qvac-swift.git", exact: "0.1.0")
```

## Updating the upstream SDK

An SDK update is a deliberate migration, not a floating install. Update all of the
following in one reviewed change:

1. authoritative source commit and every contract input hash in
   `tools/provenance/qvac-sdk.lock.json`;
2. npm tarball URL, integrity, shasum, and independently verified source identity;
3. exact codegen and runtime package locks;
4. npm/source semantic parity and all generated Swift sources/tests;
5. worker bundle, native addon closure, model fixtures, integration tests, and
   benchmark evidence;
6. a new immutable artifact revision and then a new source version.

The similarly named `sdk-v0.17.0` tag is not authoritative for this release: it
currently resolves to a later post-publication commit with schema drift. Generation
therefore uses the npm release commit above, never a floating tag or `latest`.
