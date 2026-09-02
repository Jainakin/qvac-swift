# QVAC Swift Client 0.17.0 submission

This document summarizes the grant-review candidate on `main`. It targets only
`@qvac/sdk@0.17.0`; no migration or compatibility code for earlier SDK versions
is included.

## Candidate

| Item | Evidence |
|---|---|
| Validated implementation | [`de7b41312e049fb71ea015f0d0a24c02809ddb78`](https://github.com/Jainakin/qvac-swift/commit/de7b41312e049fb71ea015f0d0a24c02809ddb78) |
| Hosted validation | [GitHub Actions run 33513093458](https://github.com/Jainakin/qvac-swift/actions/runs/33513093458), 8 of 8 jobs passed |
| QVAC SDK | `@qvac/sdk@0.17.0` |
| Upstream source | `e8b440665a053a9efe852f04c3601da44f0d55d8` |
| API inventory | 39 methods, 43 response variants, 136 error codes, 12 model-type aliases |
| Platforms | iOS 17 or later; macOS 14 or later on Apple silicon |

The hosted validation is bound to the implementation commit above. Later changes
in this candidate affect documentation, source comments, notice rendering,
workflow display text, and the corresponding release-tool self-tests. They do not
change runtime behavior or publication gates.

No new artifact release, source tag, GitHub Release, or Swift Package Index
submission is part of this candidate. The existing `v0.1.0` and
`artifacts-sdk-0.17.0-r1` releases remain the checksum-pinned URL-installation
baseline.

## Engineering review

| # | Request | Resolution |
|---|---|---|
| 1 | Default a missing `modelConfig` | Both model-loading paths send an empty object when `modelConfig` is omitted. Unit and real-model tests cover this case. |
| 2 | Add per-request timeouts | Every operation accepts `QVACRPCOptions`. Unary calls use total deadlines, server streams use inactivity deadlines, and duplex calls use setup deadlines. The default is 60 seconds. |
| 3 | Handle profiling trailers | The incremental NDJSON decoder separates profiling records from typed responses. Server-stream and duplex adapters drain terminal metadata before returning success or the retained worker error. |
| 4 | Pin code generation | Source, npm tarball, contract inputs, Node dependencies, and generated outputs are locked to the published 0.17.0 release commit and verified in CI. |
| 5 | Repair real-model tests | Model fixtures use valid repositories, immutable revisions, expected sizes, and SHA-256 checksums. Required suites fail on missing configuration, unexpected skips, or an incorrect test count. |
| 6 | Add upscaling and URL installation | The 0.17 upscaling operation has typed progress and `Data` results. The package resolves from its public Git URL through checksum-pinned XCFramework releases. |
| 7 | Update to SDK 0.17.0 | Generated types and public operations cover the full 0.17.0 contract. The client does not include the former 0.10 API. |

## Validation

| Gate | Result |
|---|---|
| Unit inventory | 326 of 326 passed; no skips |
| Operation semantics under Thread Sanitizer | 118 of 118 passed |
| Raw-channel retention | 9 of 9 passed |
| Live worker without models | 12 of 12 passed |
| Pinned real-model suites | 7 of 7 passed, covering completion, profiling, RAG, and upscaling |
| Code generation | Generated files reproduced without a diff; source and npm contracts matched |
| Runtime artifact | Two isolated builds produced the committed worker bundle byte-for-byte |
| Swift builds | Strict release, macOS, generic iOS device, and iOS Simulator builds passed |
| Documentation | DocC built with warnings treated as errors |
| Package integration | Clean external consumers resolved the Git URL; the iOS 17 runtime package test passed |
| Example app | QVACChat built for iOS and macOS |
| Performance | The real Swift-versus-JavaScript streaming benchmark passed its predefined 5% overhead limit |

The final CI run exercised these gates from a clean hosted checkout. Its eight
jobs covered code generation, worker reproduction, unit tests, real-model and
live-worker integration, documentation, Apple-platform builds, package
installation, and the iOS 17 runtime check.

### Physical device

QVACChat also passed a cold end-to-end test on an iPhone 15 Pro (arm64, iOS
26.5.2): it downloaded and loaded the pinned model, streamed a real completion to
its terminal result, unloaded the model, and closed the client. The UI test passed
without failures or skips.

## Runtime behavior reviewed for this candidate

- Public streams retain complete producer batches within count and byte limits.
  Lossless streams report overflow; progress streams coalesce older snapshots.
- Raw stream accounting includes queued and consumer-held data plus per-frame
  overhead, preventing empty-frame floods from bypassing the configured budget.
- Profiling trailers are accepted after logical completion, including server
  stream and duplex error paths.
- Timeouts and cancellation remove pending RPC state and close the relevant
  stream directions.
- Connection replacement never replays in-flight work. Callers receive
  `QVACError.connectionReset` and restore model or session state explicitly.
- macOS uses a private Unix-domain socket and managed Bare subprocess. iOS uses
  the packaged worker in a BareKit worklet.

## Publication prerequisites

The Swift implementation and acceptance test suite are complete. Public binary
publication remains blocked by evidence that must come from the native dependency
owners or the authorized publisher:

1. Confirm the LGPL obligations and corresponding-source or relinking route for
   the statically distributed FFmpeg component.
2. Complete provenance for the BareKit/V8 Hyperdrive dependency chain.
3. Complete vcpkg and license provenance for QVAC native addons.
4. Collect the full transitive license texts for `bare-addon` dependencies.
5. Add reviewed `PrivacyInfo.xcprivacy` files for required-reason API use.
6. Complete the per-SDK privacy-practices and data-collection review.

The unresolved native-license items are recorded in
[`tools/release/native-components.json`](tools/release/native-components.json).
Privacy evidence is recorded in
[`tools/release/privacy-manifest-audit.json`](tools/release/privacy-manifest-audit.json).
The release workflows reject publication while these records remain open;
`license_reviewed=true` does not override them.

Once those inputs are complete, the publisher can follow
[`docs/distribution.md`](docs/distribution.md) to create a new artifact revision,
verify the public package, create the source release, and submit it to Swift
Package Index if desired.
