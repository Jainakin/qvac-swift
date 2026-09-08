# Coverage gate

The coverage job runs the complete reviewed 626-test `QVACClientUnitTests`
inventory on macOS with LLVM instrumentation. The inventory is bound by SHA-256
`aaf162771f7cef0803ae9cc30d7ac2051a6a7f882e1ecb19e724b718b301f813`.
The job fails if discovery changes, a required test is skipped, the executed
identities differ from the inventory, or any macOS-compiled handwritten or
generated-source threshold regresses.

Run it from the repository root:

```bash
tools/coverage/run.sh
```

The hosted job stages local binary dependencies and activates the development
manifest inside its ephemeral checkout. The activation command intentionally
refuses normal developer worktrees; local runs use the checked-in URL manifest.

Use `tools/coverage/run.sh --self-test` to exercise the analyzer's negative
cases without building Swift. A custom output directory may be supplied as the
only argument; the default is `.build/coverage-gate`. Each measurement uses a
private, automatically removed SwiftPM scratch directory so stale or concurrent
instrumentation cannot contaminate its profile. An existing evidence directory
is reused only when it contains the runner's exact ownership marker; known
evidence files are invalidated before policy validation or any build begins.
Artifacts are then created in the private scratch area and published from that
staging directory. `coverage-complete.json` is moved into place last; its byte
counts and SHA-256 digests bind every artifact, so a missing attestation means
the run is incomplete and must not be consumed as a PASS. A structurally valid
policy failure publishes the same diagnostic reports without that attestation,
so reviewers can see the regression while downstream automation still fails
closed. Analyzer or evidence-integrity failures publish no unvalidated report.

## Scope and policy

`policy.json` is deliberately explicit:

- macOS-compiled handwritten production Swift under `Sources/QVACClient` is
  gated.
- The four reviewed code-generated contract files are measured and reported as
  a separately gated scope. They cannot inflate the handwritten quality gate.
- `BareIPCTransport.swift` is the sole macOS exclusion because its BareKit
  implementation is compiled only for iOS. The `ios-and-example` job separately
  instruments it together with the iOS-only client factory and runtime-handshake
  branches, runs the reviewed iOS inventory, and enforces
  `ios-transport-policy.json` with `run-ios-transport.sh`.
- All other Swift files under the production source root must appear in the
  LLVM export. Adding or moving a generated/excluded file requires a reviewed
  policy change, so directory naming cannot silently remove code from scope.

Each metric—lines, functions, and regions—has four simultaneous checks: minimum
percentage, minimum covered elements, minimum total elements, and maximum
uncovered elements. Unlike a percentage-only gate, this combination does not
let an increase in uncovered behavior disappear behind denominator growth, and
it catches deletion of previously covered behavior.

| Scope | Metric | Minimum | Covered floor | Total floor | Uncovered ceiling |
|---|---|---:|---:|---:|---:|
| Handwritten | Lines | 97% | 15,750 | 16,232 | 500 |
| Handwritten | Functions | 94% | 1,385 | 1,483 | 95 |
| Handwritten | Regions | 92% | 4,800 | 5,214 | 425 |
| Generated | Lines | 89% | 3,500 | 3,936 | 450 |
| Generated | Functions | 100% | 325 | 325 | 0 |
| Generated | Regions | 87% | 1,940 | 2,235 | 300 |

Every macOS-compiled handwritten file must also retain at least 91% line, 65%
function, and 83% region coverage. Every reviewed generated file has an 80%
line, 95% function, and 5% region floor. The generated region floor remains low
because the generated error-code switch maps declaration-only cases as regions:
that file's reviewed minimum is 6.25%, while the other three generated files
measure at least 93.70%. The line and function floors prevent the much larger
generated types file from hiding an untested generated peer.

Thirteen security- and reliability-critical handwritten files have additional
file-specific percentage and absolute ratchets in `criticalFiles`, including
exact executable-element total floors and narrowly buffered covered/uncovered
limits. They cover
BareRPC state and framing, runtime handshake, compact decoding, checked wire
sizing, media validation, NDJSON framing, pull-stream mapping, result-memory
accounting, transport buffering and lifecycle, public stream buffering, and the
client control plane. Reductions below the configured floors require an explicit
reviewed baseline update. Each configured path must remain
in the macOS-compiled handwritten inventory, and every check appears in the JSON
and Markdown evidence. `policy.json` is the source of truth for their exact
thresholds.

The source digest and pull-request review remain the backstop against deliberate
metric gaming. Legitimate source refactors can update a reviewed baseline only
with evidence from the same change. Because the completion attestation binds the
policy digest, changing `policy.json` automatically makes earlier evidence
ineligible as proof of the new gate.

When tests are added, update the inventory, count, and SHA-256 in both the unit
runner and `policy.json`. Coverage thresholds should only move downward when a
reviewed source refactor changes LLVM's executable-element inventory and the
pull request explains why.

## Evidence

The CI artifact contains:

- `coverage-summary.json`: portable machine-readable scope, per-file metrics,
  aggregate, scope-wide per-file, and critical-file policy checks, source
  digest, and test-inventory digest.
- `coverage-summary.md`: the human-readable job summary.
- `handwritten-production.lcov`: normalized first-party handwritten records.
- `all-production-source.lcov`: handwritten plus generated production records.
- `llvm-coverage-summary.json` and `llvm-coverage.raw.lcov`: raw LLVM evidence.
- `input-manifest.json`: immutable pre-build digests for production sources,
  every regular unit-test input/resource, the policy, analyzer, and runner.
- `toolchain.json`: structured architecture, Swift, Xcode, Xcode-build, and
  LLVM identity plus Node/Bash versions and executable paths, whose digest is
  bound into the summary. Swift and LLVM must resolve through `xcrun` beneath
  the selected `DEVELOPER_DIR` (or the active `xcode-select` directory), and
  the Swift driver's canonical symlink target must remain beneath that same
  developer directory.
- `coverage-complete.json`: last-published completion record containing hashes
  and byte lengths for every other evidence artifact.
- the exact discovered test list and XCTest log.

Before invoking Swift, the runner records a deterministic digest inventory for
every production Swift source and every regular file under
`Tests/QVACClientUnitTests` (including fixture JSON), plus the policy, analyzer,
and runner. It also binds the active `Package.swift`, optional
`Package.resolved`, reviewed test inventory, and every regular build resource
under `Sources/QVACClient`. Canonical containment checks reject final or
intermediate symlink escapes. The analyzer recomputes that inventory after
coverage collection and requires an exact match. The runner captures live HEAD
and byte-exact porcelain-status digests before and after collection; they must
match. The summary records the validated 40-character source revision and
whether the measured worktree was clean or dirty. Dirty
local measurements remain valid but are explicitly identifiable.

Every raw LCOV record is structurally checked: `DA` entries must be well formed
with unique, physically valid source line numbers; exactly one consistent
`LF`/`LH` and `FNF`/`FNH` pair is required. Eligible files' line and function
totals and covered counts must match LLVM JSON before scoped evidence is emitted.
All textual evidence is decoded as strict UTF-8, while hashes are calculated
from the original, unmodified artifact bytes.

The JSON and LCOV summaries intentionally exclude tests, SwiftPM-derived source,
external binaries, and code that is compiled only on iOS from the reported
macOS production coverage.

The iOS platform evidence is deliberately separate because Xcode's generated
Swift-package scheme does not include a dependent package in `xccov`'s report.
The iOS runner therefore enables LLVM instrumentation for the dependency and
exports the transport, client, and handshake sources directly from the test
bundle and its single `Coverage.profdata`. It rejects missing or duplicate
profiles, source records, tests, skips, malformed or regressed metrics, and any
uncovered line designated as a required iOS platform branch. Run its analyzer
self-tests with:

```bash
tools/coverage/run-ios-transport.sh --self-test
```

Evidence runs must also declare the native read adapter explicitly with
`--native-read-adapter checked` for a patched r2-or-later BareKit candidate or
`--native-read-adapter legacy` for the immutable r1 baseline. There is no
default. The policy requires a mutually exclusive LLVM coverage anchor for the
selected adapter, requires the other adapter's anchor to exist with a zero
execution count, and records both sets in the evidence. A candidate therefore
cannot pass by silently exercising the wrong Objective-C ABI path or both paths.

Thread Sanitizer uses a separate build and result bundle because sanitizer and
coverage instrumentation are independent gates. The non-publishing BareKit r2
candidate job first builds an arm64 Simulator-only native framework with
`-fsanitize=thread`, verifies the native compilation units, symbols, and TSan
runtime load command, then reruns the complete reviewed iOS inventory against
that artifact. `tools/ci/verify-ios-test-log.mjs` binds the same count and
inventory SHA-256 as `ios-transport-policy.json`; requires actual sanitizer
compile and link evidence for both the Swift client and test target, BareKit
linkage, and the iOS Simulator TSan runtime; requires every reviewed test to
start and pass exactly once; rejects skips and equal-count substitutions; and
treats any Thread Sanitizer diagnostic or unavailable sanitizer as failure. Its
verification record includes the captured log's byte count and SHA-256.
Run its fail-closed self-tests with:

```bash
node tools/ci/verify-ios-test-log.mjs --self-test
```

## Reviewed calibration

Two completion-attested 626-test local calibrations on Xcode 26.6 agreed on
15,852/16,232 handwritten lines (97.66%), 1,405/1,483 functions (94.74%), and
4,856/5,214 regions (93.13%) across 38 files. The four generated files measured
3,533/3,936 lines
(89.76%), 325/325 functions (100%), and 1,966/2,235 regions (87.96%). Combined
macOS production coverage was 19,385/20,168 lines (96.12%), 1,730/1,808
functions (95.69%), and 6,822/7,449 regions (91.58%). The channel's
post-registration cancellation fallback is exercised through a deterministic
internal transport seam, so that safety branch no longer depends on scheduler
timing.

The separate iOS platform gate binds its exact test inventory and SHA-256 in
`ios-transport-policy.json` and `../ci/ios-smoke-test-inventory.txt`. Its
completion-attested output records the measured `BareIPCTransport.swift`
coverage and focused branch evidence for `QVACClient.swift` and
`Handshake.swift`; those whole-file figures are supplemental to the macOS
whole-source gate. Absolute floors and required line identities ensure the
readable-callback barriers, bounded FIFO write pump, close/error quiescence, iOS
factory, and runtime handshake cannot disappear behind percentage-only
coverage.

The 37-test local iOS calibration against the patched r2 adapter measured
`BareIPCTransport.swift` at 779/810 lines (96.17%), 108/116 functions (93.10%),
and 258/282 regions (91.49%). The
supplemental `QVACClient.swift` measurement was 484/1,690 lines (28.64%), 42/162
functions (25.93%), and 134/563 regions (23.80%); `Handshake.swift` measured
57/71 lines (80.28%), 10/11 functions (90.91%), and 29/49 regions (59.18%).
Across the three gated iOS sources, that is 1,320/2,571 lines (51.34%), 160/289
functions (55.36%), and 421/894 regions (47.09%).

The immutable r1 adapter historically measured seven more transport lines and
one more function and region because it executes the legacy-reader fallback.
The shared uncovered-line ceiling is calibrated to the stricter r2 result,
while mode-specific required lines independently prove that r1 executes the
legacy reader and r2 selects `readWithError:`.

The hosted workflow pins its toolchain independently of this local Xcode 26.6
calibration. Percentage and covered/uncovered ratchets include run-to-run
headroom; reductions below the total-element floors or any loss of generated
function coverage require a reviewed baseline update. A release claim must use a passing,
completion-attested run from the final committed source and policy; these
calibration figures alone are not release evidence.
