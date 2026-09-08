# QVAC Swift Client — QVAC SDK 0.17.0 review record

This document records the engineering status of the QVAC Swift Client review
candidate. The implementation targets only `@qvac/sdk@0.17.0`; it contains no
migration layer or compatibility path for earlier SDK versions.

The candidate has not been tagged, released, or submitted to Swift Package
Index. The existing `v0.1.0` source release and
`artifacts-sdk-0.17.0-r1` artifact release remain the checksum-pinned public
installation baseline while this work is reviewed.

## Candidate scope

| Item | Value |
|---|---|
| QVAC SDK | `@qvac/sdk@0.17.0` |
| Pinned upstream source | `e8b440665a053a9efe852f04c3601da44f0d55d8` |
| Generated contract | 39 methods, 43 response variants, 136 error codes, and 12 model-type aliases |
| Supported platforms | iOS 17 or later; macOS 14 or later on Apple silicon |
| Distribution state | Review candidate only; no new artifact release, source tag, GitHub Release, or Swift Package Index submission |

This file intentionally does not embed its own commit SHA. Final acceptance
evidence must identify the delivered commit and a clean hosted run whose
`head_sha` matches it.

The `@qvac/cli@0.10.0` package that appears in the locked native build tooling
is an upstream build-time dependency. It is not the Swift client's SDK, API, or
worker contract. The delivered client intentionally supports only QVAC SDK
0.17.0 and contains no cross-version compatibility behavior.

## Engineering review items

| # | Requested change | Resolution |
|---|---|---|
| 1 | Default a missing `modelConfig` | Both model-loading paths encode an empty object when `modelConfig` is omitted. Unit and real-model coverage exercise the omitted value. |
| 2 | Add per-request timeouts | Per-call `QVACRPCOptions` provide total deadlines for unary calls, inactivity deadlines for server streams, and setup deadlines for duplex calls. The default timeout is 60 seconds. Timeout and cancellation paths remove pending RPC state. |
| 3 | Handle profiling-trailer lines | The incremental NDJSON decoder separates profiling records from typed responses. Server-stream and duplex adapters drain terminal metadata before returning success or the retained worker error. |
| 4 | Pin code generation | The npm tarball, source commit, contract inputs, Node dependencies, and generated outputs are locked to the published 0.17.0 package provenance and checked by deterministic generation tooling. |
| 5 | Repair real-model tests | Fixtures reference valid repositories and immutable revisions, with expected sizes and SHA-256 checksums. Required suites fail on missing configuration, unexpected skips, test substitution, or inventory drift. |
| 6 | Add upscaling and URL installation | The 0.17 upscaling operation exposes typed stream responses, validated `Data` outputs, and statistics. The public package manifest uses checksum-pinned XCFramework URLs and resolves through the repository URL. |
| 7 | Update to SDK 0.17.0 | Generated types and public operations cover the complete 0.17.0 contract. No legacy 0.10 API or migration behavior is included. |

## Recorded local validation

The table records current working-tree calibration for the complete 626-test
inventory. These local measurements do not replace clean hosted validation of
the delivered commit.

| Gate | Result |
|---|---|
| Unit tests (current) | 626 of 626 passed with no failures or skips |
| macOS Thread Sanitizer | 626 of 626 passed with no failures, skips, or sanitizer diagnostics |
| macOS Address Sanitizer | 626 of 626 passed with no failures, skips, or sanitizer diagnostics |
| macOS Undefined Behavior Sanitizer | 626 of 626 passed with no failures, skips, or sanitizer diagnostics |
| Required integration tests | 19 of 19 passed with no failures or skips, including live-worker, real-model completion and profiling, RAG, and upscaling coverage |
| Handwritten macOS production coverage (current 626-test calibration) | 15,852/16,232 lines (97.66%), 1,405/1,483 functions (94.74%), and 4,856/5,214 regions (93.13%) |
| Generated-source coverage (current 626-test calibration) | 3,533/3,936 lines (89.76%), 325/325 functions (100%), and 1,966/2,235 regions (87.96%) |
| Combined macOS production coverage (current 626-test calibration) | 19,385/20,168 lines (96.12%), 1,730/1,808 functions (95.69%), and 6,822/7,449 regions (91.58%) |
| iOS platform coverage (patched r2 adapter) | 37 of 37 reviewed tests passed. `BareIPCTransport.swift` measured 779/810 lines (96.17%), 108/116 functions (93.10%), and 258/282 regions (91.49%); supplemental `QVACClient.swift` and handshake measurements bring the gated iOS sources to 1,320/2,571 lines (51.34%), 160/289 functions (55.36%), and 421/894 regions (47.09%). |
| Native IPC stress (patched r2, regular simulator) | 2 of 2 reviewed tests passed: a byte-exact 16 MiB backpressured echo, 12 concurrent close/read races, and a 256 MiB sustained-memory run with 245,808 bytes retained growth after warm-up and a 0.001035 fitted slope |
| Native IPC stress (patched r2, Thread Sanitizer) | The exact close/read race test passed with the Swift and native BareKit units instrumented and no Thread Sanitizer diagnostic |
| iOS Simulator Thread Sanitizer | The 37-test inventory passed locally with Swift-side instrumentation against the public r1 BareKit binary. The non-publishing artifact gate separately instruments every native unit built from the pinned patched BareKit source; its three prebuilt archives are excluded from that claim. |
| Historical physical iPhone calibration (r1 only) | An earlier local run passed 1 of 1 selected arm64 test on an iPhone 15 Pro running iOS 26.6.1. `QVACChatPhysicalDeviceTests/testLoadStreamAndUnloadOnPhysicalDevice()` completed worker startup, model load, streaming inference, and unload using the immutable public r1 BareKit artifact. This evidence does not validate the patched r2 artifact and is not bound to the final delivered commit; an exact-source r2 device run remains pending. |
| Package manifest | SwiftPM resolves one library product backed by 38 checksum-pinned binary targets |
| Publication guard | Fails closed on any of the six license/privacy blockers and on the separate BareKit r2 activation gate |

The unit inventory is bound to SHA-256
`aaf162771f7cef0803ae9cc30d7ac2051a6a7f882e1ecb19e724b718b301f813`.
The iOS platform inventory contains 37 exact XCTest identities and is bound to
SHA-256
`406d901b69476eafa308f691cfa2284abb0a1acbbeda90aa3d4f0eee00f55108`.
The regular native-stress inventory contains two exact XCTest identities and is
bound to SHA-256
`abb66aa33315d7afed7d6789bfb24430fecd0fa1fc1481c9c5ae9b6fa124dddf`.
Its sanitizer inventory contains the exact close/read race identity and is
bound to SHA-256
`fec0733bd30026410a7244b9aaa4129a6085cb2961657fb3ab6fdd45c2b1a6aa`.
The required integration inventory contains 19 exact XCTest identities and is
bound to SHA-256
`36fd43ce30aa0d22e278cb7fd3f5ba6835f44cafba08112f576f0acad811e134`.
The runners compare discovery, started tests, passed tests, skip records, and
the committed inventories so a renamed, substituted, or silently skipped test
cannot satisfy a count-only gate.

Detailed coverage policy and evidence semantics are documented in
[`tools/coverage/README.md`](tools/coverage/README.md).

## Runtime behavior reviewed in this candidate

- Public streams retain producer output within explicit count and byte limits.
  Lossless streams report overflow; progress streams coalesce superseded
  snapshots without dropping their terminal result.
- Raw stream accounting includes queued and consumer-held data plus per-frame
  overhead, preventing empty-frame floods from bypassing the configured budget.
- Profiling trailers are accepted after logical completion, including
  server-stream and duplex error paths.
- Per-request timeouts and cancellation clean up pending RPC state and close the
  relevant stream directions.
- Incoming frame, error-message, registry, media, text, and VLA payloads are
  admitted against explicit resource limits before avoidable materialization.
- Connection replacement does not replay in-flight work. Callers receive
  `QVACError.connectionReset` and restore model or session state explicitly.
- macOS uses a private Unix-domain socket and managed Bare subprocess. iOS uses
  the packaged worker in a BareKit worklet.

## Final commit acceptance

Before the source candidate is delivered as final, the exact committed tree
must have a clean hosted validation run that confirms:

1. the reviewed unit and integration inventories, with no failures or skips;
2. macOS sanitizer, iOS native-instrumented Thread Sanitizer, and
   completion-attested coverage gates;
3. deterministic code generation and runtime-artifact reproduction;
4. strict macOS, generic iOS device, and iOS Simulator builds;
5. DocC, external SwiftPM URL-consumer, example-application, and iOS runtime
   checks.

Physical-device validation is not currently claimed for the final r2
candidate. If it is included in the final review package, the signed test
result must bind both the delivered source revision and the exact patched r2
BareKit artifact. The historical r1 calibration above must not be presented as
r2 evidence.

The delivery record outside this source tree must identify the delivered commit
and its matching hosted run. Calibration output from a dirty worktree must not
be presented as final-commit evidence.

## Publication prerequisites

Source and engineering review can proceed without publishing new binaries.
Binary publication must remain disabled until the following independent
license and privacy inputs are resolved:

| Blocker | Required evidence |
|---|---|
| `ffmpeg-lgpl-static-distribution-plan` | An approved LGPL-2.1 compliance route for the statically distributed FFmpeg component, including the required source, notices, and relinking materials |
| `barekit-v8-transitive-provenance` | An authoritative mapping from the pinned BareKit/Hyperdrive artifact to the complete V8, Chromium, ICU, simdutf, and other bundled source and license inventory |
| `qvac-addon-vcpkg-license-closure` | A build-produced vcpkg dependency graph, source checksums, enabled features, and complete license payload for the QVAC native addons |
| `bare-addon-transitive-license-texts` | A complete, build-bound static dependency closure and license-text set for the Bare native addons |
| `required-reason-api-privacy-manifests` | Reviewed Apple-approved reason codes and byte-identical `PrivacyInfo.xcprivacy` files for each affected iOS framework slice |
| `complete-sdk-privacy-practices-review` | A completed SDK privacy-practices and data-collection review covering every distributed framework |

The authoritative records are
[`tools/release/native-components.json`](tools/release/native-components.json)
and
[`tools/release/privacy-manifest-audit.json`](tools/release/privacy-manifest-audit.json).
The release tooling rejects publication while any record remains open.
`license_reviewed=true` records human review of the supplied notices; it does
not close missing native provenance, LGPL distribution, or Apple privacy
evidence.

BareKit r2 also has a separate engineering-activation gate in
[`tools/native/bare-kit/provenance.lock.json`](tools/native/bare-kit/provenance.lock.json).
It requires reproducibility review, the complete simulator and physical-device
validation matrix, and byte-bound patch and dependency-closure evidence. The
artifact workflow currently rejects every `publish=true` run by design. Closing
the six license and privacy records alone must not remove that guard; a reviewed
unlock is appropriate only after all activation evidence is complete.

After those inputs are complete, a designated publisher can follow
[`docs/distribution.md`](docs/distribution.md). Publication is intentionally
outside the scope of this source review.
