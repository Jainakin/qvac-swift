# QVAC Swift Client — SDK 0.17.0 submission evidence

This document is the current reviewer handoff for the Swift client source. It
supersedes the historical SDK 0.10 planning and audit snapshots in `PLAN.md` and
`AUDIT.md`.

Published `0.1.x` releases target the exact `@qvac/sdk@0.17.0` contract at npm
`gitHead` `e8b440665a053a9efe852f04c3601da44f0d55d8`. They deliberately contain no
0.10 compatibility or migration layer.

## Executive status

The exact 0.17 source, generated API, worker, native dependency closure, tests,
example, and guarded release automation formed the baseline production Swift
package, `v0.1.0`, from commit
`85ac16212e43ec4572c96f04bf278cd67e52eb7f`. The current source handoff adds the
remaining review and grant hardening after that immutable baseline: a finite
default request deadline, generation-safe worker reconnect, rich-duplex
profiling-trailer draining, batch-aware bounded public streams, retained-byte
accounting for raw DATA frames, stronger RAG/profiling tests, and an exact-revision
iOS 17 runtime-consumer gate. It still targets only 0.17 and deliberately adds no
0.10 compatibility or migration layer.

No new artifact release, source tag, GitHub Release, or Swift Package Index
submission is created as part of this handoff. The authorized grant publisher
owns those publication operations and can use the guarded additive-release process
in `docs/distribution.md` after the final source commit is green.

In `v0.1.0`, canonical `Package.swift` is the checksum-pinned public URL manifest
for its 38 XCFramework archives. The archives, worker, manifest, provenance,
resolution inventory, and third-party notices are published in the
[`artifacts-sdk-0.17.0-r1`](https://github.com/Jainakin/qvac-swift/releases/tag/artifacts-sdk-0.17.0-r1)
release. The guarded source workflow verified every remote byte and an anonymous
Git-URL consumer before publishing
[`v0.1.0`](https://github.com/Jainakin/qvac-swift/releases/tag/v0.1.0) from the
same exact commit. `Package.swift.dev` retains the exact local graph. See
`docs/distribution.md` for the artifact-first release procedure.

Those prior releases are immutable by project policy and checksum/source binding:
the workflows reject moved tags, replaced revisions, or mismatched bytes. Their
GitHub REST records predate repository-native release immutability and therefore
do not report `immutable: true`. GitHub-native release immutability is enabled for
subsequent publications, which use new additive artifact revisions and SemVer
tags rather than altering `r1` or `v0.1.0`.

The historical `r1` notice inventories 146 JavaScript package identities: 143
contain package-provided license text and three use exact-artifact-bound
supplements. Its checksum remains part of the immutable `r1` artifact manifest,
and the authorized maintainer review is retained as historical evidence. The
current deeper audit additionally binds all 38 linked native targets, their exact
npm artifacts and source revisions, and ten independently identified native
components. That audit exposes four transitive native-license evidence gaps. A
`license_reviewed=true` attestation does not override them; both future
publication workflows now fail closed until the gaps recorded in
`tools/release/native-components.json` are resolved.

## Engineering-review comments

| # | Reviewer request | Resolution and evidence |
|---|---|---|
| 1 | Default missing `modelConfig` | The shared load-model request builder normalizes an omitted value to `{}` for both unary and progress calls. Unit and real-model tests exercise the omitted configuration path. |
| 2 | Add per-request timeouts | Every public operation accepts trailing `rpcOptions: QVACRPCOptions`. Unary calls use a total deadline, server streams use a resettable inactivity deadline, and duplex calls use a setup deadline. Ordinary calls now default to a finite 60-second deadline; explicit `timeout: nil` remains available only for intentionally unbounded work protected by an external watchdog. Timeout and task cancellation remove pending RPC state and close the appropriate stream directions. |
| 3 | Handle profiling trailers | `QVACNDJSONDecoder` incrementally handles fragmented/coalesced records, CRLF, EOF residuals, size limits, and top-level `__profilingTrailer: true` records. Profiling trailers are separated from typed responses. High-level terminal-aware adapters—including generated server streams and concrete duplex error paths—perform a bounded drain to EOF before exposing success or throwing the retained worker error, so a following trailer is captured even if the consumer then stops. A typed frame after logical completion is rejected as a protocol violation, while malformed non-trailers still fail decoding. Synthetic and real 0.17 model tests cover this path. |
| 4 | Pin code generation | `tools/provenance/qvac-sdk.lock.json` binds the npm tarball, integrity, shasum, release commit, and every contract input hash. Generation consumes the committed language-neutral 0.17 contract. Bootstrap independently exports the published npm contract and rejects semantic drift. Node, npm dependencies, generated output, and provenance are all locked and CI-verified. |
| 5 | Fix real-model tests | The missing/floating fixture was replaced with checksum-, size-, filename-, and revision-pinned LLM and RAG fixtures. Required-suite wrappers reject missing configuration, skips, zero executed tests, or wrong suite names. The current local runs completed LLM 4/4 and RAG 2/2 with zero skips. |
| 6 | Add upscale and URL installation | The exact 0.17 upscale API, rich `Data` result surface, alias normalization, progress/terminal behavior, large-frame support, unit tests, and a checksum-pinned real Real-ESRGAN test are implemented. The first 38 checksum-bound XCFramework archives are public in `artifacts-sdk-0.17.0-r1`; `v0.1.0` and its checksum-pinned root manifest remain installable directly from the Git URL. |
| 7 | Bring the client to the requested SDK | Generated request/response unions, exact wire entry points, and live coverage match the grant-pinned SDK 0.17.0 contract: all 39 methods, 43 response leaves, 136 error codes, and 12 public model-type aliases. New 0.17 operations include audio/video/upscale, BCI, VLA, orchestration, classification, finetune, system/model-registry, lifecycle, logging, and provider APIs. |

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
- Raw stream accounting charges both payload bytes and a conservative structural
  cost for every DATA frame, so an empty- or tiny-frame flood cannot bypass the
  configured budget. Queued and consumer-leased frames remain charged until the
  next demand signal acknowledges the lease.
- Public streams retain whole producer batches under both count and byte ceilings
  and flatten them lazily. Lossless semantic views fail explicitly when a consumer
  cannot keep up; observational progress views coalesce older snapshots and keep
  the newest bounded window without failing the authoritative operation.
- Unix-domain sockets use private owned directories, strict identity checks,
  fatal permission/close-on-exec setup, `SO_NOSIGPIPE`, bounded diagnostics,
  inherited-environment filtering, and joinable shutdown. A blocked write aborts
  the connection instead of permanently wedging later calls. Parent-side worker
  pipe writers are closed immediately after spawn, so early worker exit cannot
  leave startup cleanup waiting forever on an EOF that the parent prevents.
- Unexpected EOF, inbound failure, or outbound write failure invalidates one
  transport generation. In-flight work fails once and is never replayed; the next
  new call single-flights a fresh worker and `__init_config`. Calls that cross a
  successful reconnect receive typed `connectionReset` before any application
  request is sent, making lost model/session state explicit. Failed reconnects
  close completely and remain retryable, and explicit close is terminal. Live
  `SIGKILL` recovery is verified on macOS. On iOS the same path requires an
  observable BareIPC EOF/write failure; pinned BareKit can retain IPC descriptors
  after worklet self-exit, so a timed-out caller must close/recreate the client.
- iOS shutdown sends bounded `__shutdown__` before terminating the worklet, and
  all concurrent close callers join the same cleanup operation.
- Errors leaving high-level public request and sequence boundaries are normalized
  to `QVACError`, except Swift task cancellation, which remains
  `CancellationError`. The intentionally low-level `wireProgressStream`,
  `wireServerStream`, and `wireDuplex` escape hatches preserve
  `QVACResponse.error` as a union value and require callers to continue the same
  response iterator to EOF so a following profiling trailer is consumed.

The unreleased review delta was revalidated locally on 2026-09-01: the fail-closed
unit gate discovered and passed exactly 326/326 tests with zero skips; the
Thread Sanitizer operation suite passed 118/118 and the raw-channel retention
suite passed 9/9; all 12 required no-model live tests passed; and all seven
required pinned-model tests passed with zero skips.
Those model tests include the real profiled completion trailer, full RAG
ingest/save/search/delete/close lifecycle, and public upscale path. Strict release,
macOS example, generic iOS device, iOS Simulator, and DocC warnings-as-errors
builds passed. The iOS Simulator also passed the real bundled-worker
handshake/heartbeat/close smoke and observable-EOF adapter ordering test.

The SwiftUI example additionally passed a cold end-to-end UI test on Hardik's
iPhone 15 Pro running iOS 26.5.2: it downloaded and loaded the pinned model,
streamed a real completion to its terminal result, unloaded the model, and
reported success with zero failures or skips. The final source commit remains
subject to the same exact-SHA hosted matrix before grant handoff; local and
physical-device results are not presented as substitutes for that independent
run.

## Verification evidence

The detailed baseline results below were obtained on 2026-08-31. The streaming
benchmark was first accepted from clean source commit
`f753e8c6c438b421050bc7411720a2aa382ec91e`, then repeated by the complete hosted
matrix for exact released commit
`85ac16212e43ec4572c96f04bf278cd67e52eb7f` before either release was
allowed to publish.

| Gate | Result |
|---|---|
| Complete opt-in Swift test inventory | 235 tests: 217 unit plus 18 required live/model/benchmark tests; every required gate passed locally and in exact-release-SHA CI with zero skips |
| Unit suite | 217/217 passed after final generation/API, benchmark-path, and deterministic duplex-ordering changes |
| Strict Swift build | Passed with warnings as errors and `-strict-concurrency=complete` |
| Live contract coverage | All 39 manifest methods exercised through public generated/rich APIs |
| Pinned real LLM | 3/3 passed, zero skips |
| Pinned real RAG | 2/2 passed, zero skips |
| Pinned real upscale | 1/1 passed, zero skips, using public `diffusion` alias normalization |
| Performance KR | Real public streaming completion across 20 isolated processes in five intact four-process ABBA blocks (10 opposite-orientation Swift/Node pairs). Every process performed exactly two 1,000-token preconditioning completions followed by three retained 1,000-token measurements (2,997 inter-token intervals per process), with zero retries or exclusions. Server-normalized mean client-delivery factor ratio: 1.001096, 95% CI [0.998381, 1.003820]; raw p99 inter-token ratio: 0.992695, 95% CI [0.992260, 0.993276]. Both co-primary upper bounds are strictly <1.05. Raw end-to-end mean remained a mandatory diagnostic at 1.008413, 95% CI [1.006679, 1.010973]. All runs used GPU and produced identical final/output SHA-256 `fd703254198e4ad90b15fb8bdcd785911f71c2ac2695d4acb362dfb48f2ec234` across clients. |
| Exact-release-SHA hosted performance | Normalized mean delivery-factor ratio 0.998614, 95% CI [0.997089, 0.999988]; raw p99 ratio 0.999784, 95% CI [0.998095, 1.001847]. Both co-primary upper bounds are strictly <1.05. |
| iOS compile/smoke | Clean generic device and simulator builds passed; an external-package hosted-simulator smoke test passed 1/1 and loaded the bundled worker resource |
| DocC | Final build passed with DocC warnings as errors, Swift warnings as errors, and strict concurrency enabled |
| SwiftUI example | Final source builds passed for macOS and generic iOS Simulator after lifecycle and cross-platform input hardening |
| Exact codegen | Two isolated final runs completed in 0.25 seconds each; 39 methods, 43 responses, 136 errors, 12 aliases, and all six generated outputs were byte-identical to the tree |
| Historical `r1` package attribution | 146/146 JavaScript package identities have full text: 143 package-provided and 3 exact-artifact-bound supplements. The immutable published notice SHA-256 is `e8f71b72dfc9ac532f2a4f27c3c147bb920e202ef8ed323e0e6a4352652abb4c`. This historical result does not claim complete transitive native-binary closure for a future `r2`. |
| Release/tool safety | Bootstrap, path safety, archive reproducibility, source binding, required-suite self-test, bundle provenance, runtime-lock verification, manifest regeneration, deterministic third-party attribution, and all YAML/shell/JavaScript/JSON syntax checks passed |
| Diff hygiene | `git diff --check`, explicit file-boundary review, and a clean committed source candidate passed before publication |

The benchmark keeps model load bounded at 180 seconds and applies no
per-completion RPC timeout to either client, because the pinned JavaScript
0.17.0 stream helper does not enforce that deadline symmetrically. Both clients
instead run under the same owned 240-second process watchdog. Per-request timeout
behavior remains independently covered by the Swift unit and live contract
tests.

The normalized mean factor is fixed as each completion's public mean inter-token
latency divided by the native worker period (`1000 / stats.tokensPerSecond`),
then arithmetically averaged across the three retained completions. This isolates
client delivery overhead from GPU decode-rate assignment; raw p99 remains an
unadjusted co-primary tail guard, while raw mean, worker throughput, TTFT, and
terminal latency remain reported diagnostics. The confidence interval resamples
the five intact ABBA blocks, preserving the two opposite execution orientations
and their shared thermal regime.

This estimand was committed before the acceptance run. An earlier exact-SHA
hosted run using raw mean as a primary metric was reported as inconclusive, not
retried or relabeled: its public mean tracked the worker's native decode period
with correlation 0.99928 and paired-log R-squared 0.9989. That evidence exposed
backend-speed confounding rather than a Swift failure and motivated the
predeclared server-normalized client-overhead metric. The successful evidence
above was collected once from the subsequent clean commit with the unchanged
1.05 limit, fixed workload, zero retries, and zero exclusions.

The complete development-manifest CI run for commit
`1a5293e060bfb688c9e9d6e389368a7343b50b50` passed every job on GitHub. Its
hosted benchmark independently passed with normalized mean factor ratio
1.001227, 95% CI [0.999377, 1.003080], and raw p99 ratio 0.999750, 95% CI
[0.997800, 1.001603]. The raw mean diagnostic was 1.016105 while native worker
throughput varied from 100.87 to 169.83 tokens/second, demonstrating why worker
decode-rate assignment is retained as a diagnostic rather than attributed to
either client. The complete evidence artifact contains all 20 process samples,
10 pairs, five intact ABBA blocks, exact output hashes, and zero retries or
exclusions. The successful CI run is
<https://github.com/Jainakin/qvac-swift/actions/runs/33418309632>.

The final URL-manifest CI run for exact release commit
`85ac16212e43ec4572c96f04bf278cd67e52eb7f` passed all seven jobs:
<https://github.com/Jainakin/qvac-swift/actions/runs/33424863638>. It covered the
strict 217-test unit suite, worker reproduction, all live RPC suites, pinned real
LLM/RAG/upscale suites, DocC, generic iOS device and hosted-simulator builds, the
external consumer, first-inference SLA, and the hosted performance result above.

The non-publishing r1 artifact-candidate workflow also passed from that exact
commit and uploaded its evidence without creating a tag or GitHub Release:
<https://github.com/Jainakin/qvac-swift/actions/runs/33420629448>. Independent
local verification recomputed all 38 archive checksums, matched the worker and
third-party notice byte-for-byte, regenerated canonical `Package.swift`, and
parsed it with SwiftPM.

Publication then completed through two guarded workflows from the same exact
commit:

- checksum-bound artifacts, with the explicit `license_reviewed=true` attestation:
  <https://github.com/Jainakin/qvac-swift/actions/runs/33468513722>;
- source release, including remote-byte verification and an anonymous Git-URL
  consumer before tag creation:
  <https://github.com/Jainakin/qvac-swift/actions/runs/33468871258>.

The resulting baseline public releases are
[`artifacts-sdk-0.17.0-r1`](https://github.com/Jainakin/qvac-swift/releases/tag/artifacts-sdk-0.17.0-r1)
and [`v0.1.0`](https://github.com/Jainakin/qvac-swift/releases/tag/v0.1.0).

The CI workflow repeats these checks from a clean checkout. It additionally times
checkout/setup through first real inference and hard-fails at 600 seconds, proves
generated output freshness, reproduces the worker twice, exercises a hosted iOS
Simulator XCTest, builds the SwiftUI example for iOS and macOS, and uploads the
benchmark evidence.

Repository tooling validates both the exact path-based development graph and the
strictly generated checksum-pinned URL manifest, while pushed `main` remains in
URL-manifest mode. If a newly referenced artifact revision has not yet been
published, the iOS 17 CI job records candidate mode and tests the verified local
graph without claiming URL proof. After immutable artifact publication, the
source-release workflow must resolve the exact public Git revision, verify all 38
remote artifacts, and complete a real iOS 17 worker handshake before it may create
a SemVer tag. This makes the publication sequence non-circular and fail-closed.

## Grant acceptance and key results

| Requirement | Current source status and prior release evidence |
|---|---|
| Code generation produces compilable Swift with zero manual generated edits | Implemented; exact-release-SHA CI reproduced the generated output and required no diff |
| macOS 14 arm64 and iOS 17 arm64 compilation | Implemented; local macOS strict build plus clean iOS device/simulator builds passed |
| SwiftUI import, load, stream, and unload flow | Implemented and built; client lifecycle is closed on success, unload, and failure |
| Every RPC type round-trips against a real worker | Implemented for the complete generated 39-method inventory |
| Incremental `AsyncSequence` streams | Implemented, bounded, cancellation-aware, and lifecycle-tested |
| Real cancellation acknowledgement | Required real-model test passes without a silent skip; the worker's valid pre-start `cancelled: 0` acknowledgement is handled while cancellation is proven by the terminal result |
| Clean close and worker termination | Deterministic unit/integration coverage passes, including concurrent close and blocked I/O |
| Worker/socket reconnection | Implemented with generation isolation, no replay, single-flight reconnect, typed state-loss notification before retry, retryable cleanup, and terminal explicit close; deterministic race tests and a live native-worker macOS `SIGKILL` recovery test cover it. iOS replacement requires a BareIPC-observable EOF/write failure; current BareKit self-exit can remain unobservable, so bounded timeout plus explicit client recreation is the documented containment path. |
| Typed SDK errors | All 136 exact 0.17 codes plus registry/model-registry categories are generated and mapped |
| Clone to first inference under 10 minutes | Passed in the exact-release-SHA CI run under the hard 600-second limit |
| Streaming overhead below 5% | Passed on real public completion streams; the server-normalized mean delivery-factor and raw p99 co-primary intact-block 95% upper bounds are strictly below 1.05, with raw end-to-end metrics retained and no retries or exclusions |
| Code generation under 30 seconds | Passed twice at 0.25 seconds and remains a fixed CI gate |
| Physical iPhone example | Passed on Hardik's iPhone 15 Pro (arm64, iOS 26.5.2): fresh model download/load, real streamed completion and terminal result, then unload; 1/1 UI test passed with zero failures/skips |
| SwiftPM URL and Swift Package Index | The checksum-bound `r1` artifacts and `v0.1.0` prove baseline URL installation. CI accepts a handoff commit only after anonymously resolving that exact public Git revision with all 38 remote artifacts and completing a live iOS 17 worker handshake. Root SPI hosted-DocC configuration and publication guidance are complete. Actual additive release and Index publication remain publisher-owned and are intentionally not performed here. |

## Remaining publisher-owned work

The functional source, tests, physical-device proof, baseline URL-installation
evidence, Swift Package Index configuration, and publication guidance are
complete. No physical-device acceptance step remains.

Before publishing a new binary artifact revision, the authorized publisher must
close the four transitive native-license evidence gaps listed in
`tools/release/native-components.json`. App Store distribution also requires an
accurate per-SDK privacy manifest for every linked binary that uses Apple's
required-reason APIs; the repository's publication audit deliberately refuses to
guess reason codes. After those inputs are supplied and all publication checks
pass, the publisher can create additive `artifacts-sdk-0.17.0-r2` and `v0.2.0`
releases from the same final green commit, then submit or verify the Swift Package
Index listing if that live listing is part of acceptance.

The exact `artifacts-sdk-0.17.0-r1` and `v0.1.0` evidence remain public and are
not modified. No new artifact release, source release, or Swift Package Index
submission is part of this handoff, per the grant workflow.
