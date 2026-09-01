# Distribution and release

QVACClient targets exactly `@qvac/sdk` 0.17.0. Source generation is pinned to
release commit `e8b440665a053a9efe852f04c3601da44f0d55d8`; runtime installation is pinned
by `tools/runtime/package-lock.json`; and the committed worker records the same SDK
version in its embedded package metadata.

The current grant handoff is intentionally unreleased. Grant reviewers acting as
the authorized publisher—not this implementation handoff—own the additive
publication of `artifacts-sdk-0.17.0-r2` followed by source release `v0.2.0` after
all gates below pass.

The release system intentionally has two manifest modes:

- `Package.swift.dev` is the reproducible development manifest. Its 38 local
  binary targets come from `tools/runtime/.build/artifacts`, produced by
  `tools/runtime/link-ios-artifacts.sh`.
- A checksum-bound `artifact-manifest.json` is published with the GitHub artifact
  release. A release `Package.swift` is generated from that schema; every binary
  target then has the exact release URL and SHA-256 checksum. The published
  manifest is bound to the final Swift source commit; it remains a release asset
  rather than a second committed source of truth.

The immutable `artifacts-sdk-0.17.0-r1` baseline published a schema-v2 manifest
before the runtime, SDK-provenance, and privacy-audit JSON assets were byte-bound.
The verifier retains a narrow read-only compatibility path for schema v2 only
when both the artifact tag and source commit exactly match that historical
release. Schema v3 is the current hardened format: it requires all three evidence
assets, starts at `r2`, and is the only format the candidate,
artifact-publication, and source-release workflows accept for new work. The
producer cannot emit another schema-v2 manifest.

Between releases, canonical `Package.swift` keeps the latest published 0.17 URL
manifest, while CI activates `Package.swift.dev` only inside disposable checkouts
for local-graph jobs. Committing a newly generated URL manifest for an unused
`rN` creates a short, explicit candidate state. In that state, the iOS 17 CI gate
records a local-graph worker handshake because the future URLs correctly return
404; it never calls that candidate result URL-installation evidence. Artifact
publication is then allowed only from the same green commit. The source-release
workflow performs the mandatory anonymous public-URL iOS 17 handshake after the
artifacts exist and before it creates any SemVer tag. This ordering removes a
publish-before-test cycle without weakening the public-consumer gate. Neither
workflow invents URLs or reuses old 0.10 assets.

GitHub's repository-level **immutable releases** setting must be enabled before
publishing any new artifact or source release. Choose the next unused artifact
revision (`artifacts-sdk-0.17.0-rN`) and the next unused source SemVer (`vX.Y.Z`);
never reuse, replace, or move either tag. The first exact releases,
`artifacts-sdk-0.17.0-r1` and `v0.1.0`, predate that repository setting and are
preserved by project policy, exact source binding, and published checksums rather
than GitHub-native immutability. All subsequent releases use the native setting,
and the release workflows verify GitHub's release attestations before succeeding.

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
monotonically increasing revision `N` (`N >= 2`) and leave `publish` disabled.
The workflow uploads an Actions artifact named `artifacts-sdk-0.17.0-rN`; it does
not create a Git tag or GitHub Release. For example, after the published `r1`
baseline, use revision `2` to prepare `artifacts-sdk-0.17.0-r2`.

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
7. rescans all 38 linked XCFrameworks against the committed
   `privacy-manifest-audit.json`, packages that audit, and binds its exact byte;
8. packages `runtime-resolution-inventory.json` and `qvac-sdk-provenance.json`,
   binds each evidence file's exact byte size and SHA-256 into the schema-v3
   manifest, and cross-checks their SDK identity against the manifest's SDK
   declaration;
9. verifies every staged byte and uploads the unpublished candidate evidence.

Download that workflow artifact, verify it, and generate only the URL package
manifest:

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

Review and commit `Package.swift` on `main`. Do not commit the dry-run
`artifact-manifest.json`: its `sourceCommit` identifies the pre-manifest candidate,
not the new final commit.

Push the URL-manifest commit and require the complete `CI` workflow to pass for
that new exact SHA before enabling publication. A green run for the earlier
commit is useful evidence, but it cannot authorize the URL-manifest commit because
the commit identity changed.

The repository validator recognizes the generated development manifest and the
strictly generated URL manifest for one immutable SDK 0.17 artifact tag. Pushed
`main` commits must keep the latter so the repository remains URL-installable;
local-graph CI jobs activate the former only after verifying it in their
disposable checkout. For a URL-manifest commit whose artifact release returns an
authenticated GitHub API 404, CI validates its target inventory, repository, tag,
URLs, checksums, and generator formatting, then runs its exact iOS 17 worker
handshake against the verified local graph. Any API or non-404 response error
fails closed. If the artifact release already exists, the same job instead
resolves the pushed Git revision anonymously, verifies all 38 remote binaries,
and runs the worker handshake. The candidate overlay is never committed or
represented as URL evidence.

## 3. Publish artifacts from the final source commit

### Privacy-manifest publication blocker

Grant/source review and unpublished candidate generation may proceed, but a new
binary artifact release and its source release are intentionally blocked today.
Apple requires a third-party SDK to report its own required-reason API use in a
bundled `PrivacyInfo.xcprivacy`; it cannot rely on the consuming app's manifest.
For binary Swift packages, Apple says each supported XCFramework platform must
contain the necessary manifest, and static frameworks can carry that resource.
See Apple's [privacy-manifest requirements](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files),
[XCFramework placement guidance](https://developer.apple.com/documentation/bundleresources/adding-a-privacy-manifest-to-your-app-or-third-party-sdk),
and [required-reason API policy](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api).

The deterministic audit in `tools/release/privacy-manifest-audit.json` covers the
exact 38-target, two-slice closure. It currently records no bundled privacy
manifest in any target and detects required-reason imports in 16 targets: File
Timestamp, Disk Space, and System Boot Time categories are represented. This is
binary evidence, not a reason selection and not a complete privacy-practices
review. In particular, an import scan cannot establish call purpose, dynamically
resolved use, data collection, tracking domains, or whether an SDK enables an app
to collect data. No Apple reason code is inferred by the tooling.

Before publication, the authorized target owners must:

1. review source and runtime behavior for all 38 targets, including required API
   purposes, collected data, enabled collection, and tracking domains;
2. for every applicable target, select only Apple-approved reasons that accurately
   match the reviewed behavior and place one byte-identical `PrivacyInfo.xcprivacy`
   at the root of both iOS framework slices;
3. record a substantive decision for every target in `reviewDecisions`, binding
   each present manifest's SHA-256 and exact category/reason declarations; use a
   reviewed no-manifest decision only when the source review supports it;
4. rerun the framework scan, validate Xcode's assembled privacy report, and retain
   that review evidence; and
5. remove the two privacy blockers and set audit status to `reviewed` only after
   those facts are true.

Use these checks during remediation:

```bash
node tools/release/verify-privacy-manifests.mjs --check
node tools/release/verify-privacy-manifests.mjs --check-frameworks \
  --frameworks tools/runtime/.build/artifacts \
  --link-set tools/runtime/.build/link-set.json
node tools/release/verify-privacy-manifests.mjs --check-publication \
  --frameworks tools/runtime/.build/artifacts \
  --link-set tools/runtime/.build/link-set.json \
  --assets-dir tools/runtime/.build/release-assets
```

The first two commands are freshness/evidence checks and pass with documented
blockers. The last command is the irreversible publication boundary and must fail
until closure is real. Once reviewed, it also verifies every packaged archive
contains the exact manifest bytes at each framework root. Those archives and the
audit asset are then independently checksum-bound by schema-v3
`artifact-manifest.json`. Neither `license_reviewed=true` nor a consuming app's
privacy manifest overrides this gate.

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
- the complete privacy audit is reviewed, all required framework manifests match
  their approved declarations and SHA-256 values, and the packaged audit byte is
  bound into the release manifest;
- the packaged runtime inventory and SDK provenance files are byte-bound into
  the release manifest and describe the exact declared SDK source/npm artifact;
- `artifact-manifest.json.sourceCommit` equals `GITHUB_SHA`; and
- the artifact tag and release are both absent for an initial publication, or
  they form the exact existing immutable pair for a read-only recovery; partial
  or mismatched states are rejected.

Only after those gates pass does it publish `artifacts-sdk-0.17.0-rN`. It then
uses `gh release verify` and `gh release verify-asset` to verify GitHub's release
attestation and every local asset against the published immutable release. It
also verifies that the artifact tag, GitHub Release target, and manifest all
resolve to the exact final source commit. If anything changes, use a new `rN`;
never replace an existing release.

Artifact publication is an irreversible producer boundary, not the final package
acceptance gate. Do not create a source tag yet. The next workflow independently
downloads the public artifacts and exercises the package URL on exact iOS 17
before making the source version visible.

Publication is retry-safe across GitHub's irreversible boundary. If a transient
API or attestation failure occurs after an immutable release was published,
rerun the original workflow run for that revision; it rebuilds the candidate and
resumes a read-only audit only when the existing tag, release target, source
commit, native immutable state, attestation, and every asset all match. A new
manual dispatch always resolves its selected `main`, so do not use a new dispatch
to audit an older revision after `main` advances. The following tag-anchored Source
Release workflow independently repeats the immutable attestation and byte checks.
Partial or mismatched states fail closed.

The following command is a read-only independent check of the published release:

```bash
tools/release/prepare-release.sh artifacts-sdk-0.17.0-rN
```

It downloads the assets into a fresh temporary directory, verifies the release
attestation with `gh release verify`, verifies each byte with
`gh release verify-asset`, and independently hashes every binary asset and the
third-party notice, privacy audit, runtime-resolution inventory, and SDK
provenance before consuming their metadata. It then binds the manifest to the
current Git commit, verifies the canonical URL `Package.swift` and embedded
worker, and parses the package with SwiftPM. The command also refuses a tree
containing any tracked or untracked change. It never edits repository files.
`Package.swift.dev` remains the local exact graph for the next development cycle.

## 4. Verify first, then create a new source version

Do **not** create or push a SemVer tag by hand. After the immutable artifact
release exists, dispatch the **Source Release** workflow with its Git ref selector
set to the exact published artifact tag (for example,
`artifacts-sdk-0.17.0-r2`) and with:

- `version`: `0.2.0`, without a `v` prefix. The current grant-handoff source
  changes public stream property types relative to `v0.1.0`, so it must not be
  published as a `0.1.x` patch release.
- `artifact_tag`: the published artifact revision used by canonical
  `Package.swift` (for example, `artifacts-sdk-0.17.0-r2`)

Grant reviewers acting as the authorized publisher own both additive publication
steps: first `artifacts-sdk-0.17.0-r2`, then `v0.2.0` after every source-release
gate passes. This implementation handoff publishes neither. The handoff targets
the new API directly and intentionally adds no compatibility or migration layer.

The equivalent command is explicit about the immutable ref:

```bash
gh workflow run release.yml \
  --ref artifacts-sdk-0.17.0-r2 \
  -f version=0.2.0 \
  -f artifact_tag=artifacts-sdk-0.17.0-r2
```

The artifact tag is the immutable release anchor, so ordinary pushes to `main`
during this verification cannot strand an already-published artifact revision.
Before any source tag exists, the workflow verifies that its selected Git ref and
the artifact release tag both resolve to `GITHUB_SHA`, verifies the artifact
release attestation with `gh release verify`, binds the published artifact manifest
to that commit, rejects a path-based/stale package, downloads and hashes every
remote artifact, builds a clean external consumer from the public Git URL at that
exact revision, runs unit tests, and performs a fresh anonymous install plus
`__init_config`, heartbeat, and close on an exact iOS 17.0 Simulator.
It creates the annotated SemVer tag through the GitHub API and creates the GitHub
source release only after every gate passes, then verifies the source release
attestation with `gh release verify`. Stable versions become latest; valid SemVer
prereleases remain prereleases and never become latest. A retry may use an
already-created tag only when it resolves to the same verified commit; tags are
never moved or force-updated. Pull-request CI separately requires
strict-concurrency compilation with warnings as errors, DocC with warnings as
errors, and generic iOS device and simulator builds.

If verification is interrupted after the source release becomes immutable,
rerunning the same version resumes only the non-mutating CI, package, tag, and
release-attestation audit. It never recreates or edits the existing release.

Consumers can then use:

```swift
.package(url: "https://github.com/Jainakin/qvac-swift.git", .upToNextMinor(from: "0.2.0"))
```

Applications that require a fully frozen dependency graph should commit
`Package.resolved` or select the desired published version with `exact:`.

The `v0.2.0` run-view properties use the single-consumer `QVACBufferedStream`.
They queue at most 64 whole producer batches, apply the client's
`maximumBufferedStreamBytes` budget across queued plus partially consumed data,
and flatten accepted batches lazily. Lossless views fail explicitly on overflow;
observational progress views coalesce older snapshots under both ceilings, while
authoritative result tasks remain independent.

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
