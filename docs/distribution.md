# Release process

QVACClient is built against `@qvac/sdk@0.17.0`. Code generation uses source
commit `e8b440665a053a9efe852f04c3601da44f0d55d8`, and the runtime dependency graph
is locked by `tools/runtime/package-lock.json`.

Only designated maintainers publish releases after every check in this document
passes. The current review candidate has not been published.

## Package manifests

The repository has two package manifests:

- `Package.swift.dev` references the 38 locally generated XCFrameworks under
  `tools/runtime/.build/artifacts`.
- `Package.swift` is the consumer manifest. Its binary targets use versioned
  GitHub Release URLs and SwiftPM checksums.

CI temporarily activates the development manifest in disposable checkouts. The
committed manifest remains URL-backed so a clean clone exercises the same package
layout as a consumer.

The historical `artifacts-sdk-0.17.0-r1` and `v0.1.0` releases are checksum-pinned
but predate GitHub-enforced release immutability. Do not edit or move them. New
artifact revisions start at `r2`, use evidence schema 3, and are published under
new tags. Enable GitHub immutable releases before publishing a new artifact or
source release.

## Publication blockers

Candidate builds and source review may proceed, but the release workflows block a
new binary publication until the native-license and privacy reviews are complete.

### Native licenses

[`tools/release/native-components.json`](../tools/release/native-components.json)
records four open evidence items:

1. FFmpeg LGPL static-distribution obligations and the corresponding-source or
   relinking route.
2. BareKit/V8 Hyperdrive transitive provenance.
3. QVAC addon vcpkg and license closure.
4. Complete transitive license texts for `bare-addon` dependencies.

Review [`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md), including its three
pinned supplemental texts. `license_reviewed=true` records that review; it does
not clear unresolved native-component requirements.

### Privacy manifests

[`tools/release/privacy-manifest-audit.json`](../tools/release/privacy-manifest-audit.json)
covers all 38 linked targets on device and simulator slices. The current scan
finds required-reason API imports in 16 targets and no bundled
`PrivacyInfo.xcprivacy` files.

Before publication, the dependency owners or publisher must:

1. review required API purposes, collected data, enabled collection, tracking,
   and tracking domains for every target;
2. select only Apple reason codes supported by that review;
3. place the approved manifest at the root of each applicable framework slice;
4. record the decision and manifest SHA-256 for every target in the audit; and
5. validate the assembled Xcode privacy report.

The scanner reports API evidence but does not infer reason codes or privacy
practices. A consuming application's privacy manifest cannot replace the SDK's
own declarations.

Useful checks:

```bash
node tools/release/generate-third-party-notices.mjs --check
node tools/release/verify-privacy-manifests.mjs --check
node tools/release/verify-privacy-manifests.mjs --check-frameworks \
  --frameworks tools/runtime/.build/artifacts \
  --link-set tools/runtime/.build/link-set.json
```

The corresponding `--check-publication` commands must remain failing until the
open requirements are resolved.

Apple references:

- [Privacy manifest files](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files)
- [Adding a privacy manifest to an SDK](https://developer.apple.com/documentation/bundleresources/adding-a-privacy-manifest-to-your-app-or-third-party-sdk)
- [Required-reason APIs](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)
- [Describing data use](https://developer.apple.com/documentation/bundleresources/describing-data-use-in-privacy-manifests)

## 1. Reproduce the development graph

Use Node 22.22.0:

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

The runtime closure contains the 37 addons referenced by the worker plus BareKit.
Staged frameworks that are not referenced by the worker or by a Mach-O dependency
are excluded.

## 2. Prepare an artifact candidate

Run the **Build SDK 0.17 Artifacts** workflow on `main` with a new revision number
of 2 or higher and leave `publish` disabled. The workflow uploads an Actions
artifact named `artifacts-sdk-0.17.0-rN`; it does not create a tag or GitHub
Release.

The candidate contains deterministic XCFramework archives, the worker bundle,
third-party notices, the privacy audit, runtime inventory, SDK provenance, and
`artifact-manifest.json`.

Download the candidate and verify it locally:

```bash
CANDIDATE=/absolute/path/to/artifacts-sdk-0.17.0-rN

node tools/release/verify-release.mjs \
  "$CANDIDATE/artifact-manifest.json" \
  --require-schema 3 \
  --assets-dir "$CANDIDATE" \
  --privacy-audit tools/release/privacy-manifest-audit.json

node tools/release/generate-package-manifest.mjs \
  "$CANDIDATE/artifact-manifest.json" Package.swift

swift package dump-package >/dev/null
cmp "$CANDIDATE/worker.mobile.bundle" \
  Sources/QVACClient/Resources/worker.mobile.bundle
```

Commit the generated `Package.swift` to `main`. Do not commit the dry-run
`artifact-manifest.json`; it identifies the commit from which the candidate was
built, before the URL manifest was committed.

Require the complete CI workflow to pass on the new manifest commit. While the
future artifact URLs return 404, CI validates their structure and runs the iOS 17
worker test against the locally reproduced graph. This candidate result is not
presented as public URL-installation evidence.

## 3. Publish the artifact release

After the publication blockers are resolved:

1. confirm GitHub immutable releases are enabled;
2. review the generated notices and privacy evidence;
3. rerun **Build SDK 0.17 Artifacts** from the final `main` commit with the same
   unused revision, `publish` enabled, and `license_reviewed=true`;
4. wait for the workflow to verify the successful CI run for that commit and
   publish `artifacts-sdk-0.17.0-rN`; and
5. retain the workflow and release attestations with the submission record.

The workflow rebuilds the assets, binds them to the source commit, checks the URL
manifest, verifies every release asset, and rejects partial or mismatched release
state. Never replace an existing asset or move an existing artifact tag; choose a
new revision instead.

If a transient API failure occurs after GitHub has published the release, rerun
the original workflow run. It resumes only when the tag, release, commit, and
asset checksums match. Do not dispatch a new run for an older revision after
`main` has advanced.

An independent read-only verification is available after publication:

```bash
tools/release/prepare-release.sh artifacts-sdk-0.17.0-rN
```

This command requires a clean worktree, downloads the release into a temporary
directory, verifies its attestations and checksums, checks the source binding and
package manifest, and does not modify repository files.

## 4. Publish the source release

Do not create a source tag manually. Dispatch **Source Release** with its Git ref
set to the artifact tag and provide:

- `version`: the new SemVer without a `v` prefix, for example `0.2.0`;
- `artifact_tag`: the artifact release used by `Package.swift`, for example
  `artifacts-sdk-0.17.0-r2`.

The current stream API differs from `v0.1.0`, so publish it as a new minor version
rather than a `0.1.x` patch.

```bash
gh workflow run release.yml \
  --ref artifacts-sdk-0.17.0-r2 \
  -f version=0.2.0 \
  -f artifact_tag=artifacts-sdk-0.17.0-r2
```

Before creating the source tag, the workflow verifies the artifact release,
resolves the package from the public Git URL, hashes every binary dependency,
runs unit tests, and completes an iOS 17 worker handshake from a clean external
consumer. The source release is created only after those checks pass.

Consumers can then depend on the reviewed version:

```swift
.package(
    url: "https://github.com/Jainakin/qvac-swift.git",
    .upToNextMinor(from: "0.2.0")
)
```

Commit `Package.resolved` in applications that require a frozen dependency graph.
Swift Package Index submission is a separate maintainer action described in
[`swift-package-index.md`](swift-package-index.md).

## Updating QVAC SDK

An SDK update must change the provenance and runtime inputs together:

1. update the source commit, npm tarball identity, and contract hashes;
2. update the code-generation and runtime lockfiles;
3. regenerate Swift sources and tests, then review the API diff;
4. rebuild the worker and native addon closure;
5. update model fixtures, live tests, and benchmark evidence; and
6. publish a new artifact revision followed by a new source version.

Do not use `latest` or a floating tag as a release input.
