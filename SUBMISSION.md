# QVAC Swift Client — SDK 0.17.0 submission evidence

This document is the current reviewer handoff for the unreleased Swift client. It
supersedes the historical SDK 0.10 planning and audit snapshots in `PLAN.md` and
`AUDIT.md`.

The candidate targets the exact published `@qvac/sdk@0.17.0` contract at npm
`gitHead` `e8b440665a053a9efe852f04c3601da44f0d55d8`. It deliberately contains no
0.10 compatibility or migration layer.

## Executive status

All seven source-side engineering-review changes are implemented in the working
tree. The source, generated API, worker, native dependency closure, tests,
example, and guarded release automation form a production candidate. Reviewer
item 6 becomes externally complete only when its immutable binary artifacts and
source tag are published through the guarded release sequence below.

The repository is not yet a published SwiftPM release. The canonical
`Package.swift` intentionally remains the local, path-based development manifest
until a maintainer publishes the immutable binary artifacts. Claiming URL
installability before that publication would be incorrect. See
`docs/distribution.md` for the artifact-first release sequence.

`THIRD_PARTY_NOTICES.md` is deterministically generated from the exact worker
payload plus the BareKit native closure root. It inventories 146 package
identities: 143 contain package-provided license text and the remaining three
are covered by exact-artifact-bound supplemental texts with pinned source
evidence and hashes. No shipped identity remains without full license text. Its
checksum is part of the immutable artifact manifest, and binary publication
still requires an explicit maintainer/legal review attestation.

## Engineering-review comments

| # | Reviewer request | Resolution and evidence |
|---|---|---|
| 1 | Default missing `modelConfig` | The shared load-model request builder normalizes an omitted value to `{}` for both unary and progress calls. Unit and real-model tests exercise the omitted configuration path. |
| 2 | Add per-request timeouts | Every public operation accepts trailing `rpcOptions: QVACRPCOptions`. Unary calls use a total deadline, server streams use a resettable inactivity deadline, and duplex calls use a setup deadline. Timeout and task cancellation remove pending RPC state and close the appropriate stream directions. The default remains `nil`, exactly matching the executable 0.17 contract; production examples set operation-specific bounds. |
| 3 | Handle profiling trailers | `QVACNDJSONDecoder` incrementally handles fragmented/coalesced records, CRLF, EOF residuals, size limits, and top-level `__profilingTrailer: true` records. A profiling trailer is separated from typed responses; malformed non-trailers still fail decoding. |
| 4 | Pin code generation | `tools/provenance/qvac-sdk.lock.json` binds the npm tarball, integrity, shasum, release commit, and every contract input hash. Generation consumes the committed language-neutral 0.17 contract. Bootstrap independently exports the published npm contract and rejects semantic drift. Node, npm dependencies, generated output, and provenance are all locked and CI-verified. |
| 5 | Fix real-model tests | The missing/floating fixture was replaced with checksum-, size-, filename-, and revision-pinned LLM and RAG fixtures. Required-suite wrappers reject missing configuration, skips, zero executed tests, or wrong suite names. The final local runs completed LLM 3/3 and RAG 2/2 with zero skips. |
| 6 | Add upscale and URL installation | The exact 0.17 upscale API, rich `Data` result surface, alias normalization, progress/terminal behavior, large-frame support, unit tests, and a checksum-pinned real Real-ESRGAN test are implemented. URL distribution is release-automation complete but externally pending: produce an unpublished 38-archive candidate, commit its checksum/URL manifest, obtain exact-SHA CI, then publish the immutable artifacts and guarded source release. |
| 7 | Bring the client to the current SDK | Generated request/response unions, exact wire entry points, and live coverage now match all 39 SDK 0.17 methods, 43 response leaves, 136 error codes, and 12 public model-type aliases. New 0.17 operations include audio/video/upscale, BCI, VLA, orchestration, classification, finetune, system/model-registry, lifecycle, logging, and provider APIs. |

## Architecture and production hardening

- The committed worker is a deterministic SDK 0.17.0 reconstruction: bundle ID
  `cb0f8598ce37f4b488d90583ec5273829da9fbce0749cb796d4686e7a8294991`,
  SHA-256
  `3d17393e67b0ed6830a5dad2f575b9d8835589a4eed321629ff2f514066cd769`,
  11,495,184 bytes, and 37 direct addon targets.
- Two isolated Node 22.22.0 builds produced byte-identical workers. The iOS graph
  packages the 37 referenced addons plus BareKit; nine staged but unreferenced
  frameworks are excluded mechanically.
- `QVACResponseStream` is a pull-driven, single-consumer sequence whose iterator
  lifetime owns RPC teardown. Breaking iteration while retaining the sequence,
  dropping an unread iterator, cancellation, normal completion, and concurrent
  close are covered by deterministic lifecycle tests.
- Wire messages and NDJSON records are capped at a configurable 256 MiB by
  default; raw queued stream bytes are bounded separately. A public upscale path
  regression covers a record larger than the old 64 MiB ceiling.
- Unix-domain sockets use private owned directories, strict identity checks,
  fatal permission/close-on-exec setup, `SO_NOSIGPIPE`, bounded diagnostics,
  inherited-environment filtering, and joinable shutdown. A blocked write aborts
  the connection instead of permanently wedging later calls. Parent-side worker
  pipe writers are closed immediately after spawn, so early worker exit cannot
  leave startup cleanup waiting forever on an EOF that the parent prevents.
- iOS shutdown sends bounded `__shutdown__` before terminating the worklet, and
  all concurrent close callers join the same cleanup operation.
- Errors leaving public request and sequence boundaries are normalized to
  `QVACError`, except Swift task cancellation, which remains `CancellationError`.

## Local verification on the final candidate

The following results were obtained on 2026-08-31 on the final candidate tree.
The streaming benchmark was run from clean source commit
`4da0693e83281c567c0faa0eb7714e05f762282e`; the release workflow requires the
same full matrix to pass again for the exact final URL-manifest commit before it
can publish any immutable binary or source release.

| Gate | Result |
|---|---|
| Complete opt-in Swift test inventory | 234 tests: 216 unit plus 18 required live/model/benchmark tests; each required gate has passed locally with zero skips, and exact-final-SHA CI is mandatory before publication |
| Unit suite | 216/216 passed after final generation/API and benchmark-path changes |
| Strict Swift build | Passed with warnings as errors and `-strict-concurrency=complete` |
| Live contract coverage | All 39 manifest methods exercised through public generated/rich APIs |
| Pinned real LLM | 3/3 passed, zero skips |
| Pinned real RAG | 2/2 passed, zero skips |
| Pinned real upscale | 1/1 passed, zero skips, using public `diffusion` alias normalization |
| Performance KR | Real public streaming completion, 10 adjacent order-balanced process pairs and 1,000 content events per process: mean inter-token Swift/JS ratio 0.988014, 95% CI [0.972110, 1.004448]; p99 ratio 0.994116, 95% CI [0.993208, 0.995020]. Both strict upper bounds are <1.05, with identical final/output SHA-256 across clients |
| iOS compile/smoke | Clean generic device and simulator builds passed; an external-package hosted-simulator smoke test passed 1/1 and loaded the bundled worker resource |
| DocC | Final build passed with DocC warnings as errors, Swift warnings as errors, and strict concurrency enabled |
| SwiftUI example | Final source builds passed for macOS and generic iOS Simulator after lifecycle and cross-platform input hardening |
| Exact codegen | Two isolated final runs completed in 0.25 seconds each; 39 methods, 43 responses, 136 errors, 12 aliases, and all six generated outputs were byte-identical to the tree |
| Third-party attribution | 146/146 shipped identities have full text: 143 package-provided and 3 exact-artifact-bound supplements; 0 unresolved. The final generated notice SHA-256 is `e8f71b72dfc9ac532f2a4f27c3c147bb920e202ef8ed323e0e6a4352652abb4c` |
| Release/tool safety | Bootstrap, path safety, archive reproducibility, source binding, required-suite self-test, bundle provenance, runtime-lock verification, manifest regeneration, deterministic third-party attribution, and all YAML/shell/JavaScript/JSON syntax checks passed |
| Diff hygiene | Final preflight requires `git diff --check`, an explicit file-boundary review, and a clean committed source candidate before publication |

The CI workflow repeats these checks from a clean checkout. It additionally times
checkout/setup through first real inference and hard-fails at 600 seconds, proves
generated output freshness, reproduces the worker twice, exercises a hosted iOS
Simulator XCTest, builds the SwiftUI example for iOS and macOS, and uploads the
benchmark evidence.

CI validates both legitimate repository phases: the exact path-based development
manifest and a strictly generated immutable-URL release manifest. In the latter
prepublication phase, it uses `Package.swift.dev` only as an ephemeral build
overlay; publication and source-release gates continue to verify the canonical
URL manifest and all remote bytes. This keeps the final release commit testable
without weakening its public distribution contract.

## Grant acceptance and key results

| Requirement | Candidate status |
|---|---|
| Code generation produces compilable Swift with zero manual generated edits | Implemented and locally verified; CI reproduces and requires no diff |
| macOS 14 arm64 and iOS 17 arm64 compilation | Implemented; local macOS strict build plus clean iOS device/simulator builds passed |
| SwiftUI import, load, stream, and unload flow | Implemented and built; client lifecycle is closed on success, unload, and failure |
| Every RPC type round-trips against a real worker | Implemented for the complete generated 39-method inventory |
| Incremental `AsyncSequence` streams | Implemented, bounded, cancellation-aware, and lifecycle-tested |
| Real cancellation acknowledgement | Required real-model test passes without a silent skip; the worker's valid pre-start `cancelled: 0` acknowledgement is handled while cancellation is proven by the terminal result |
| Clean close and worker termination | Deterministic unit/integration coverage passes, including concurrent close and blocked I/O |
| Typed SDK errors | All 136 exact 0.17 codes plus registry/model-registry categories are generated and mapped |
| Clone to first inference under 10 minutes | Enforced by CI; must still be demonstrated by the successful remote CI run for the final committed SHA |
| Streaming overhead below 5% | Passed on real public completion streams; both co-primary process-paired 95% upper bounds are strictly below 1.05, with no retries or exclusions |
| Code generation under 30 seconds | Passed twice at 0.25 seconds and remains a fixed CI gate |
| Physical iPhone example | Source and generic device build are ready; a current 0.17 run on an actual iPhone remains required evidence |
| SwiftPM URL tag and Swift Package Index | Release tooling/guidance are ready; immutable binary publication, `v0.1.0`, anonymous URL-consumer verification, and Index submission remain external release actions |

## Required release actions

These are not source-code defects and cannot be completed honestly without
publishing external state:

1. Commit every intended generated/source/release file, including the tracked
   `Package.swift.dev`, while excluding the user-owned diagnostic file
   `Package.swift.release-broken-from-private-repo`.
2. Push the development-manifest candidate; an initial green full `CI` run is a
   useful candidate gate.
3. Run the artifact workflow in dry-run mode, review the deterministic evidence
   and `THIRD_PARTY_NOTICES.md`, generate the checksum-pinned URL `Package.swift`,
   and commit and push that URL-manifest state.
4. Obtain a new green full `CI` workflow for the exact URL-manifest commit SHA.
   The earlier candidate run cannot authorize this different commit.
5. Publish a new immutable artifact revision from that exact final commit with
   the third-party-review attestation enabled. Never replace an existing artifact
   tag or release.
6. Run the source-release workflow. It rechecks the exact successful CI run,
   remote artifact bytes, source binding, and an anonymous Git-URL consumer before
   it creates `v0.1.0`.
7. Run the SwiftUI example on a physical iPhone with SDK 0.17.0 and retain the
   device/build/log evidence for the grant reviewer.
8. Submit the published package to Swift Package Index and verify the indexed
   platforms, product, version, and hosted documentation.

No tag, GitHub Release, artifact publication, or Swift Package Index submission
has been performed from this working tree.
