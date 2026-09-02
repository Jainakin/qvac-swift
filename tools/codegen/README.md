# QVAC Swift code generation

The generator produces the Swift API from the published QVAC SDK 0.17.0
contract. Generated Swift files are committed so package consumers do not need
Node.js or an upstream QVAC checkout.

## Pinned inputs

[`tools/provenance/qvac-sdk.lock.json`](../provenance/qvac-sdk.lock.json) records:

- source commit `e8b440665a053a9efe852f04c3601da44f0d55d8`;
- the `@qvac/sdk@0.17.0` npm tarball integrity and shasum; and
- SHA-256 values for every contract input.

The `sdk-v0.17.0` tag points to a later commit with schema changes, so generation
uses the npm release's `gitHead` rather than the tag.

`bootstrap.sh` installs the locked Node dependencies, checks out the pinned
source commit in `.build/qvac-sdk`, verifies each input, and reconstructs the
representable request and response schemas from the published npm package. It
also compares method shapes and error-code maps. Source-only inputs are verified
against lockfile hashes because npm does not export them.

When `QVAC_UPSTREAM_DIR` is supplied, bootstrap treats it as read-only and
requires its origin, commit, and hashes to match the lock.

## Outputs

| Generated file | Contract input |
|---|---|
| `QVACErrorCodes.generated.swift` | `error-codes.json` |
| `QVACTypes.generated.swift` | `schema.json` |
| `QVACModelTypeContract.generated.swift` | `model-type-maps.json` |
| `QVACSDKContract.generated.swift` | `manifest.json` and `schema.json` |
| `QVACGeneratedRoundTripTests.generated.swift` | Concrete request and response variants |
| `QVACModelTypeContractTests.generated.swift` | Model-type maps |

The generated contract contains 39 methods, 43 response variants, 136 error
codes, and the model-type aliases published by SDK 0.17.0. Requests and responses
validate their type discriminators, and generated tests encode and decode every
concrete variant.

`overrides.json` handles wire-only exceptions. The source schema retains
`rag.onProgress`, a JavaScript callback that cannot cross JSON, so the generator
omits that field. Generation reads the pinned source contract; published npm
schemas and maps are used only for parity validation.

## Run and verify

Use Node 22.22.0, also recorded in `.node-version`:

```bash
./tools/codegen/bootstrap.sh
./tools/codegen/run.sh --generate-only

git diff --exit-code -- Sources/QVACClient/Generated
git diff --exit-code -- 'Tests/QVACClientUnitTests/*.generated.swift'
```

`QVAC_ALLOW_NODE_VERSION_MISMATCH=1` is available for local diagnostics. CI and
release workflows require the pinned Node version.

To update the SDK, select the published source commit and npm tarball, update the
contract hashes and npm locks, regenerate the Swift API, review the diff, and run
the Swift and live-worker suites. Do not use `latest` or a floating tag as a
code-generation input.
