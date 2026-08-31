# QVAC Swift code generation

Code generation is locked to the exact published QVAC SDK 0.17.0 release. Swift
consumers use only the checked-in generated files; Node and the upstream checkout
are development/CI inputs.

## Immutable inputs

`tools/provenance/qvac-sdk.lock.json` independently identifies:

- authoritative source commit `e8b440665a053a9efe852f04c3601da44f0d55d8`;
- the `@qvac/sdk@0.17.0` npm tarball SRI and shasum; and
- SHA-256 values for every `packages/sdk/contract/*.json` input.

The current `sdk-v0.17.0` tag resolves to the later `3176cca…` commit, whose
contract contains post-publication schema changes. It is recorded as a
non-authoritative tag and rejected by provenance checks; there is no assertion
that the tag was moved.

`bootstrap.sh` installs `package-lock.json` with `npm ci`, materializes the exact
source commit in the tool-owned `.build/qvac-sdk`, verifies every locked input,
and independently reconstructs the representable request/response schemas from
the published `dist/schemas/common.js` with exact Zod 4.4.3. It also compares the
published method-shape and error-code maps. Progress conditions, constants, model
type maps, and model metadata are source-only and explicitly protected by their
input hashes rather than falsely claimed as npm exports. A caller-set
`QVAC_UPSTREAM_DIR` is read-only: its origin, HEAD and hashes must already match,
and bootstrap never fetches, checks out or changes it. Tool-owned checkout paths
reject symlink components before any Git mutation.

## Outputs

| Generated Swift file | Pinned source input |
|---|---|
| `QVACErrorCodes.generated.swift` | `contract/error-codes.json` (all 136 codes) |
| `QVACTypes.generated.swift` | `contract/schema.json` |
| `QVACModelTypeContract.generated.swift` | `contract/model-type-maps.json` |
| `QVACSDKContract.generated.swift` | `contract/manifest.json` + `contract/schema.json` |
| `QVACGeneratedRoundTripTests.generated.swift` | all concrete request/response leaves in `contract/schema.json` |
| `QVACModelTypeContractTests.generated.swift` | all three maps in `contract/model-type-maps.json` |

The API generator emits the full immutable method inventory, guarded generic
routing by call shape, exact conditional-progress routing, and one collision-safe
typed wire signature per method. Adding a method to a future pinned manifest
mechanically adds a callable Swift signature without hand-editing Swift routing.
Mapped public streams use a pull-driven adapter with no eager task or second
element queue, preserving the byte-bounded transport's backpressure and consumer
cancellation.

Concrete request/response types own immutable literal discriminators. Their
initializers do not accept `type`, direct decoding validates the literal, and the
pinned unions reject unknown discriminators rather than hiding contract drift.
The generated XCTest constructs, encodes, and decodes all 39 request and 43
response leaves, both directly and through their strict unions; the generator
verifier also proves every initializer assigns every stored property.

The model-type generator emits the exact 0.17 alias-to-canonical table used by
`loadModel`, plus the source contract's engine/addon and legacy maps for complete
drift evidence. The normalizer canonicalizes only built-in aliases and preserves
canonical or custom plugin identifiers, matching the published SDK behavior.

`overrides.json` is a narrow wire-only escape hatch. The 0.17 source exporter
retains `rag.onProgress`, a JavaScript callback that cannot cross JSON; that field
is explicitly omitted. Production generators never import today's npm Zod build.
The npm parity gate imports only the published schemas/maps and does not trust or
invoke npm's contract exporter or `dist/contract` files.

## Run and verify

Use Node `22.22.0` (also recorded in `.node-version`):

```bash
./tools/codegen/run.sh
git diff --exit-code -- Sources/QVACClient/Generated
git diff --exit-code -- 'Tests/QVACClientUnitTests/*.generated.swift'
```

`QVAC_ALLOW_NODE_VERSION_MISMATCH=1` is available only for local diagnostics; CI
and release workflows require the exact Node version. `test-bootstrap-safety.sh`
is the regression check for caller-owned checkout safety.

Updating to another SDK is an explicit provenance change: select the published
release commit and npm tarball independently, update every locked contract hash,
regenerate the npm locks, pass semantic parity, review generated API changes, and
run the complete Swift and live-worker suites. Never substitute `latest` or a tag
name for these inputs.
