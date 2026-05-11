# QVAC Swift Codegen

This directory contains the **Node-side** code generator that produces every file under
`Sources/QVACClient/Generated/`. The Swift package depends on the generator's output, not on
the generator itself — Swift consumers don't need Node installed.

## What it generates

| Output | From | Generator |
|---|---|---|
| `Sources/QVACClient/Generated/QVACErrorCodes.generated.swift` | `packages/sdk/schemas/sdk-errors-{client,server}.ts` | `generate-errors.mjs` |
| `Sources/QVACClient/Generated/QVACTypes.generated.swift` | `packages/sdk/schemas/common.ts` (request + response Zod unions) | `generate-types.mjs` |

The error generator extracts integer codes via regex (the upstream format is line-stable per
QVAC's lint config). The type generator imports the *compiled* JS that ships in `@qvac/sdk`'s
npm tarball, calls `z.toJSONSchema()` (Zod v4) with the options validated in Spike-A
(see `docs/spike-validations.md`), then walks the resulting JSON Schema tree to emit Swift
`Codable` structs for each discriminator + a discriminated-union enum (`QVACRequest`,
`QVACResponse`).

## Running

```bash
./run.sh
```

`run.sh` `npm install`s once on a clean checkout, then runs both generators. Total wall-clock
runtime is well under the grant's `KR-3: < 30s` budget (currently ~2s on M1 Mac).

Override the source-of-truth locations via env:

```bash
QVAC_SCHEMAS_DIR=/path/to/sdk/schemas \
QVAC_COMMON_JS=/path/to/sdk/dist/schemas/common.js \
./run.sh
```

## Freshness check (`AC-11`, `KR-4`)

```bash
./run.sh && git diff --exit-code Sources/QVACClient/Generated/
```

Exits non-zero if generated output drifts from checked-in. CI runs this on every PR —
if a contributor edits a generated file by hand, this catches it.

## Overrides (`overrides.json`)

The overrides file is the **only** place where per-API customization lives. It is *configuration*,
not Swift code — re-running `run.sh` still produces zero diff against the checked-in Swift
sources, which satisfies AC-11.

Currently overrides only strip "callback-shaped" fields (`onProgress`, `logger`) that the JS
client carries in its function-call surface but never sends on the wire. The Swift client's
public API replaces these with `AsyncSequence`-based progress streams (M2 work — wraps the
generated low-level types).

| Key | Effect |
|---|---|
| `omitFields["request/loadModel"]` | Strip `onProgress`, `logger` from the generated `LoadModelRequest` struct. |
| `omitFields["request/downloadAsset"]` | Same, for `DownloadAssetRequest`. |
| `omitFields["request/rag"]` | Same, for `RagRequest`. |
| `omitFields["request/finetune"]` | Same, for `FinetuneRequest`. |

Wildcard `omitFields["*"]` applies across all generated structs.

## Why this approach (and why not others)

We considered three approaches; documented at length in `docs/spike-validations.md` (Spike-A).
Tl;dr:

1. **Hand-write the wire types.** Rejected: too much surface (30 + 34 = 64 leaf types, plus their
   nested object shapes). Drift inevitable.
2. **Parse the TypeScript with `swc` / `tsc`.** Rejected: TS AST is unstable across versions
   and we'd be re-implementing TS's type system. Brittle.
3. **Use Zod's `toJSONSchema` and walk the JSON Schema (chosen).** Stable Zod-v4 surface, output
   is plain-Schema, walk is straightforward. Validated end-to-end in Spike 2.

We considered `apple/swift-openapi-generator` to do the JSON-Schema → Swift step (and may
adopt it in v0.2), but rolling our own emitter gives us tight control over the discriminated-
union shape and lets us trivially apply the overrides registry. The current emitter is ~400
LOC of JS.

## Updating against a newer `@qvac/sdk`

```bash
npm --prefix ../../spike-js install @qvac/sdk@latest
./run.sh
swift test            # confirm everything still round-trips
git diff Sources/QVACClient/Generated/    # review what changed
```

If a new discriminator type appears in the JS client, the generator picks it up automatically:
both `QVACRequest` / `QVACResponse` enums grow a case, plus a new struct. No Swift edits.

If a new field shape would require an override (a transform that maps to `JSONValue`), add an
entry to `overrides.json` and re-run.
