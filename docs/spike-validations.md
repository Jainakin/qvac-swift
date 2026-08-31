# Phase 0 Spike Validations — Findings

> **Historical 0.10.2 spike record.** These findings explain early design choices
> but do not describe the current 0.17.0 release candidate. For current contract,
> artifact, and validation details, use the root README and `distribution.md`.

> **Status:** All 5 outstanding validations resolved. Plan unchanged at the milestone level; several risks downgraded; two protocol details previously fuzzy in PLAN.md §2 are now firm.

Date: 2026-05-11
Environment: macOS 14 arm64 · Swift 6.3.1 · Xcode 16 · Node 25.9 · Bare 1.28.4 · @qvac/sdk 0.10.2 · bare-rpc 1.3.1

---

## Spike-A — Codegen edge cases (was QVAC-006)

**Original concern (PLAN §7 R-12):** Spike 2 reported 6/30 `requestSchema` branches collapsing to empty `{}`, suggesting transform-laden schemas would need manual generator overrides.

**Reality:** All 6 "empty" branches are nested `z.union`s (the union-of-unions pattern). The Zod-v4 → JSON Schema conversion handles them correctly; my walker just wasn't recursing. The 6 cases are:

| Index | Discriminator | Inner variants | Container |
|---|---|---|---|
| #1 | `loadModel` | 10 variants (descriptor / source / custom-plugin / reload-config) | `z.union` |
| #9 | `translate` | 2 variants (NMT / LLM mode) | `z.union` |
| #12 | `cancel` | 1 leaf + per-operation shapes | `z.intersection` (`allOf`) |
| #15 | `rag` | 9 variants (one per RAG op) | `z.union` |
| #16 | `deleteCache` | 2 variants (all / by-key) | `z.union` |
| #21 | `finetune` | 3 variants | `z.union` |

Of 8 fields-inside-leaves that DO collapse to `{}`:
- 3 are `additionalProperties: {}` (normal JSON Schema "any extras"). Map to Swift `[String: AnyDecodable]`.
- 3 are `onProgress` callbacks. **Not on the wire** — Swift omits these (uses `AsyncStream` instead).
- 2 are plugin `params: {}`. Correct: codegen emits a generic Codable parameter.

**Plan impact:** Drop R-12 from medium to low. The codegen pipeline has zero hand-maintained "transform overrides" needed at the branch level. QVAC-108 in PLAN §3.1 shrinks from ~3d to ~1d.

**Artifacts:** `spike-js/empty-branches.json`, `spike-js/empty-branches-decoded.json`, `spike-js/collapsed-fields.json`.

---

## Spike-B — `stream()` primitive over bare-rpc

**Validated against a real worker by downloading a 4 127-byte file via `downloadAsset`.**

Captured wire dance (server is QVAC's bare worker; id=3 is the request id):

| # | Direction | Wire | Meaning |
|---|---|---|---|
| 1 | → | `REQUEST type=1 id=3 cmd=3 stream=0 data=<JSON>` | request, JSON inline |
| 2 | → | `STREAM type=3 id=3 stream=0x201 (RESPONSE\|OPEN)` | **client acks downstream open** |
| 3 | ← | `RESPONSE type=2 id=3 err=false stream=0x01 (OPEN)` | server opens its outgoing-response-stream |
| 4 | ← | `STREAM type=3 id=3 stream=0x210 (RESPONSE\|DATA) data=<NDJSON>` | event 1: modelProgress |
| 5 | ← | `STREAM type=3 id=3 stream=0x210 (RESPONSE\|DATA) data=<NDJSON>` | event 2: downloadAsset final |
| 6 | ← | `STREAM type=3 id=3 stream=0x220 (RESPONSE\|END)` | terminator |
| 7 | ← | `STREAM type=3 id=3 stream=0x202 (RESPONSE\|CLOSE)` | lifecycle |

**Key finding NOT obvious from prior research:** The client MUST send a `STREAM(RESPONSE|OPEN)` (flag 0x201) to acknowledge the server's stream-open, otherwise the server sits idle even after the operation completes (we observed this — the file downloaded but no STREAM frames came until we sent the OPEN). This matches `bare-rpc/lib/incoming-stream.js:_open()` — `eagerOpen: true` on IncomingStream auto-sends it on construction.

**Plan impact:** PLAN.md §2.3 (wire-protocol stream lifecycle) needs to explicitly call out the OPEN dance. The Swift `BareRPC.Request.createResponseStream()` API must auto-send the OPEN signal before the consumer awaits frames. QVAC-103 in PLAN §3.1 grows by ~0.25d.

**Artifacts:** `spike-js/fixtures-from-probe/stream_download_asset_assembled.bin` (174 + 150 byte chunks).

---

## Spike-C — `cancel()` wire flow

**Validated.** Sent `{type: "cancel", operation: "inference", modelId: "this-model-id-does-not-exist"}`. Got back, as a single RESPONSE frame:

```json
{"type":"cancel","success":false,"error":"Model with ID \"this-model-id-does-not-exist\" not found"}
```

100 bytes of body. Bare-rpc level: ordinary RESPONSE (no STREAM frames, no stream flag). Worker stderr also printed an internal `MODEL_NOT_FOUND code=52002` stack trace — purely server-side logging, not on the wire.

**Confirms** PLAN.md §2.7: cancellation is a fresh RPC request, not a bare-rpc DESTROY flag on the original stream. The Swift `cancel()` API maps 1:1 to a normal `send()` call.

**Bonus finding (filed as a follow-up issue):** When a previous stream id has ended, the worker may emit straggling `STREAM(RESPONSE|END)` and `STREAM(RESPONSE|CLOSE)` frames AFTER the consumer has already returned. The Swift reader should silently consume these as lifecycle cleanup, not error. Logged in M1 plan.

**Plan impact:** None.

**Artifacts:** `spike-js/fixtures-from-probe/request_cancel.bin` + `response_cancel_assembled.bin`.

---

## Spike-D — Duplex protocol

**Validated** by opening a `transcribeStream` session against a nonexistent model.

Three-step session handshake (matches `client/rpc/node-rpc-client.ts:createDuplexSession`):

| # | Direction | Wire | Meaning |
|---|---|---|---|
| 1 | → | `REQUEST id=5 cmd=5 stream=0x01 (OPEN) data=null` | open outgoing-request stream |
| 2 | → | `STREAM id=5 stream=0x201 (RESPONSE\|OPEN) data=null` | open incoming-response stream |
| 3 | → | `STREAM id=5 stream=0x110 (REQUEST\|DATA) data=<JSON>` | first chunk = metadata |
| 4 | ← | `STREAM id=5 stream=0x101 (REQUEST\|OPEN)` | server ack: outbound ready |
| 5 | ← | `STREAM id=5 stream=0x108 (REQUEST\|RESUME)` | server: send more |
| 6 | ← | `RESPONSE id=5 err=false stream=0x01 (OPEN)` | server: opening response side |
| 7 | ← | `STREAM id=5 stream=0x108 (REQUEST\|RESUME)` | (another resume) |
| 8 | ← | `STREAM id=5 stream=0x210 (RESPONSE\|DATA) data=<error JSON>` | error event |
| 9 | ← | `STREAM id=5 stream=0x220 (RESPONSE\|END)` | terminator |

The error payload arrived as ordinary DATA, **not** as a bare-rpc-level ERROR frame:

```json
{"type":"error","code":52002,"message":"Model with ID \"no-such-whisper\" not found","name":"...","stack":"...","timestamp":...}
```

This matches `client/rpc/rpc-client.ts:checkAndThrowError` which examines `response.type === "error"` after JSON parsing — server-side errors are application-level, not transport-level.

**New protocol details (not in PLAN.md §2.4 previously):**
- After the initial 3-step handshake, the audio bytes the client writes go as more `STREAM(REQUEST|DATA)` frames with the **same id**. Each chunk is its own STREAM frame.
- The server emits **REQUEST|RESUME flow-control signals proactively** — the Swift outbound stream must treat these as "feel free to write more."
- An error in a duplex session terminates via the response stream's normal lifecycle (END), with the error embedded as a DATA payload.

**Plan impact:** PLAN.md §2.4 (three transport primitives) — the duplex primitive now has a concrete wire spec. The Swift `BareRPC.Request.createRequestStream()` + `createResponseStream()` need to:
1. Auto-send REQUEST(stream=OPEN) on creation of outgoing
2. Auto-send STREAM(RESPONSE|OPEN) on creation of incoming
3. Handle inbound STREAM(REQUEST|OPEN), STREAM(REQUEST|RESUME), STREAM(REQUEST|PAUSE) as flow-control
4. Map server-side `type: "error"` payloads to typed Swift errors via QVACError

QVAC-207 + QVAC-209 in PLAN §3.2 — duplex implementations — grow by ~0.5d combined for the flow-control handling.

**Artifacts:** `spike-js/fixtures-from-probe/duplex_transcribe_stream_req_open.bin`, `..._resp_open.bin`, `..._first_chunk.bin`, `stream_transcribe_stream_assembled.bin`.

---

## Spike-E — BareKit embedding

**Validated** the build/link half (the runtime half remains a Phase-1 follow-up).

What worked:
- `BareKit.xcframework` was found inside the npm package `react-native-bare-kit@^0.12.x`. Vendored to `spike-swift/Vendor/BareKit.xcframework`. Supports iOS arm64 + iOS sim (arm64 + x86_64).
- Added as a `.binaryTarget` in the existing SwiftPM `Package.swift`.
- New `BareKitProbe` library target imports `BareKit` and exercises:
  - `BareWorkletConfiguration.defaultWorkletConfiguration()`
  - `BareWorklet(configuration:)` initializer
  - `worklet.start(_:source:arguments:)` with inline JS source as `Data`
  - `BareIPC(worklet:)` initializer
  - `ipc.write(_:)` returning `NSInteger`
  - `ipc.close()`, `worklet.terminate()`
- **`xcodebuild -scheme BareKitProbe -destination 'generic/platform=iOS Simulator' build` succeeds** for both arm64 and x86_64 slices. Universal binary produced.

What was NOT validated (next phase):
- Actually launching a Worklet at runtime in an iOS Simulator instance.
- A bare-rpc round-trip over `BareIPC.write`/`read` (requires a JS source inside the worklet that handles RPC).
- Linking issues that might only show up at runtime (e.g., missing Bare native libs).

Why deferred: SwiftPM doesn't produce iOS app bundles. Runtime testing requires either (a) an Xcode iOS app target hosting `BareKitProbe`, or (b) an XCTest-bundle-in-simulator setup. Both are within scope for QVAC-222 (PLAN §3.2 P2).

**Key findings:**
- **No macOS slice in BareKit.xcframework.** macOS path for the QVAC SDK Swift client must use the subprocess + UDS approach (PLAN §2.2) — Bare-the-CLI binary spawned via `Process`. This is the same conclusion as PLAN, now empirically confirmed.
- The Obj-C surface (`BareWorklet`, `BareIPC`, etc.) bridges to Swift with zero shim work — Apple's automatic ObjC→Swift bridging handles the entire 80-line header.
- `BareWorklet.push(_:completion:)` is a built-in single-shot request/reply primitive separate from `BareIPC`. Worth knowing about — we won't use it (QVAC's worker uses BareIPC), but it could simplify simple test cases.

**Plan impact:**
- PLAN.md §2.2 confirmed: macOS = subprocess, iOS = in-process Worklet.
- PLAN.md §2.9 (mobile-bundle decision) unaffected — still recommended option A (ship maximal bundle).
- R-2 (BareKit asset wiring complexity) downgraded from "high" to "medium" — the API surface is small and Swift-friendly. Risk now centers on the addon `.bare` linking which we documented separately in spike findings on Expo plugin (PLAN §2.9).

**Artifacts:** `spike-swift/Vendor/BareKit.xcframework`, `spike-swift/Sources/BareKitProbe/BareKitProbe.swift`, `/tmp/qvac-spike-dd/Build/Products/Debug-iphonesimulator/BareKitProbe.o` (universal binary).

---

## Summary of plan deltas

| Plan reference | Change |
|---|---|
| **R-12** (codegen "zero manual edits" interpreted strictly) | Likelihood: Medium → **Low**. Impact stays Medium. |
| **R-2** (BareKit asset wiring complexity) | Impact: High → **Medium**. Build path is now proven; runtime + addon linking still untested. |
| **PLAN §2.3** (stream wire dance) | Add explicit `STREAM(RESPONSE\|OPEN)` ack step that client must send after request. |
| **PLAN §2.4** (duplex primitive) | Add concrete 3-step handshake + flow-control behaviors. |
| **QVAC-103** (BareRPC.Request lifecycle) | +0.25d for the OPEN-ack handshake. |
| **QVAC-108** (per-branch codegen overrides) | -2d (no transform overrides needed at branch level). |
| **QVAC-207** + **QVAC-209** (duplex API methods) | +0.5d combined for RESUME/PAUSE handling. |

**Net effect:** M1 estimate shrinks by ~1.5d. M2 estimate grows by ~0.75d. Wash; total stays ~5.5–9 weeks.

## What still requires runtime validation

The following are testable but require either Phase-1 CI scaffolding or a real loaded model. They are not blockers for grant application.

1. iOS Simulator runtime execution of `BareKitProbe` (needs an iOS app host target — QVAC-222).
2. Real bare-rpc round-trip over `BareIPC.write/read` inside a Worklet (QVAC-222 follow-up).
3. Streaming completion + cancellation against a real loaded LLM (QVAC-220, requires TinyLlama download — handled by M2 integration tests).
4. The 30s `__init_config` timeout boundary — we never went near it in spikes; live init completed in <100ms.

These move to Phase 1/2 with confidence the wire shape and embedding model are correct.
