# Contributing

Contributions should keep the generated API, worker bundle, binary manifests, and
tests aligned with the pinned QVAC SDK release.

## Requirements

- macOS on Apple silicon
- Xcode 16.4 or later
- Swift 5.10 or later
- Node 22.22.0
- XcodeGen for the example application

## Development setup

Install the locked code-generation and runtime dependencies:

```bash
tools/codegen/bootstrap.sh
tools/runtime/bootstrap.sh
```

The root `Package.swift` is the URL-backed consumer manifest. Local binary work
uses `Package.swift.dev`; activate it only in a disposable checkout or worktree:

```bash
tools/runtime/link-ios-artifacts.sh
CI=true node tools/ci/package-manifest-mode.mjs --activate-development
swift build
```

## Generated files

Do not edit files under `Sources/QVACClient/Generated` or generated test files by
hand. Change the pinned contract or generator, then run:

```bash
tools/codegen/run.sh --generate-only
git diff -- Sources/QVACClient/Generated \
  'Tests/QVACClientUnitTests/*.generated.swift'
```

An SDK update must also update the provenance lock, npm locks, worker bundle,
model fixtures, and release evidence. See
[`tools/codegen/README.md`](tools/codegen/README.md) and
[`docs/distribution.md`](docs/distribution.md).

## Tests

Run the checks relevant to the change. For most Swift changes:

```bash
swift build -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete
tools/ci/run-unit-tests.sh
```

Changes to transport, streaming, generated APIs, model operations, packaging, or
release tooling should also run the corresponding integration and reproducibility
checks from `.github/workflows/ci.yml`. Required suites must not skip tests.

Documentation changes should build with DocC warnings treated as errors. CI runs
the canonical command.

## Pull requests

Keep pull requests focused and include:

- the problem and user-visible behavior;
- tests or verification performed;
- generated-file or artifact changes, if any;
- platform and toolchain details for runtime issues; and
- documentation updates for public API changes.

Do not commit model downloads, credentials, local absolute paths, Xcode derived
data, or temporary device-test artifacts.
