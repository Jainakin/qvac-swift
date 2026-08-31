# QVAC Swift Client — Issue Tracker

> **Historical planning record.** This tracker describes the original grant work
> and the May 0.10.x implementation. It is no longer the authoritative status of
> the 0.17.0 submission candidate; use `README.md`, `docs/distribution.md`, and CI.

> This was the authoritative tracker for the original grant implementation. Its
> strict record format is documented in [PLAN.md §4](PLAN.md#4-issue-tracker-schema).

## Index

| ID | Title | Phase | Status | Type | Priority |
|---|---|---|---|---|---|
| [QVAC-000](#qvac-000) | Weekly progress tracking issue | — | open | chore | P0-blocker |
| [QVAC-001](#qvac-001) | Apply for the Tether grant | P0 | open | chore | P0-blocker |
| [QVAC-002](#qvac-002) | Open the Phase 0 issues in the tracker | P0 | open | chore | P0-blocker |
| [QVAC-003](#qvac-003) | Spike: map Expo plugin + bare-link addon resolution | P0 | spike | spike | P1-must |
| [QVAC-004](#qvac-004) | Spike: BareKit `BareKitProbe` Swift sample | P0 | spike | spike | P0-blocker |
| [QVAC-005](#qvac-005) | Spike: macOS Bare worker heartbeat round-trip | P0 | spike | spike | P0-blocker |
| [QVAC-006](#qvac-006) | Spike: identify the 6 transform-collapsed Zod branches | P0 | spike | spike | P1-must |
| [QVAC-007](#qvac-007) | Send Tether the 7 open questions; decide GO/NO-GO | P0 | open | chore | P0-blocker |
| [QVAC-008](#qvac-008) | Create the `qvac-swift` GitHub repo (per OQ-4 outcome) | P0 | blocked | chore | P0-blocker |
| [QVAC-009](#qvac-009) | Initialize repo: Package.swift, LICENSE, README shell, CI placeholder | P0 | open | chore | P1-must |
| [QVAC-010](#qvac-010) | Wire ISSUES.md (this file) into a GitHub Issues template + label set | P0 | open | chore | P1-must |
| [QVAC-011](#qvac-011) | Set up macOS-arm64 dev environment | P0 | open | chore | P0-blocker |
| [QVAC-012](#qvac-012) | Set up iOS physical-device build pipeline | P0 | open | chore | P1-must |
| [QVAC-013](#qvac-013) | Write project CLAUDE.md + weekly-update template | P0 | open | docs | P2-should |

**For Phases 1–4 issue lists, see [PLAN.md §3](PLAN.md#3-phase-plan).** They get expanded into this format as their phase begins (no point pre-expanding all ~80 issues — many details solidify only after P0 spikes).

---

## QVAC-000

```yaml
id: QVAC-000
title: Weekly progress tracking issue
phase: —
status: open
type: chore
priority: P0-blocker
grant-refs: [AR-6]
blockers: []
estimate: 30m/week (recurring)
assignee: <you>
created: 2026-05-11
updated: 2026-05-11
labels: [docs, ci]
```

### Summary
The grant (AR-6) requires "weekly progress updates in English via GitHub issues/PRs." This issue holds those updates as comments, one per week. Each Sunday post the update following the template in [PLAN.md Appendix B](PLAN.md#appendix-b--weekly-update-template-ar-6-compliance).

### Acceptance criteria
- [ ] An update is posted at least every 7 days from grant acceptance until M3 submission.
- [ ] Each update includes: phase, issues moved to done, issues in progress, exit gates closed, risks, open Tether questions, next-week intent.
- [ ] No week is skipped without an explicit pre-announcement.

### Test plan
- Manual: `gh issue view 0 --comments | grep -c '## Week'` ≥ ceil(weeks elapsed).

### Notes
- 2026-05-11: Created.

---

## QVAC-001

```yaml
id: QVAC-001
title: Apply for the Tether grant
phase: P0
status: open
type: chore
priority: P0-blocker
grant-refs: []
blockers: []
estimate: 2h
assignee: <you>
created: 2026-05-11
updated: 2026-05-11
labels: [tether-oq]
```

### Summary
Submit the grant application on tether.dev. Include the existing spike artifacts (compact-encoding Swift port with 8/8 passing tests; Zod→JSON Schema dump showing 30 request / 34 response branches with discriminator coverage) as proof of capability. Reference [PLAN.md](PLAN.md).

### Acceptance criteria
- [ ] Application submitted on tether.dev.
- [ ] Confirmation email/acknowledgement received.
- [ ] Application includes a link to the spike repo (or attached artifacts).
- [ ] Application links to this PLAN.md.

### Implementation notes
- Grant URL: https://tether.dev/grants/bounties/2885283454/
- Spike artifacts location: `/Users/hardik/Projects/qvac-swift/spike-swift/`, `/Users/hardik/Projects/qvac-swift/spike-js/`.

### Test plan
- Manual: forward confirmation email to record.

### Notes
- 2026-05-11: Created. Application pending user decision.

---

## QVAC-002

```yaml
id: QVAC-002
title: Open the Phase 0 issues in the tracker
phase: P0
status: open
type: chore
priority: P0-blocker
grant-refs: [AR-6]
blockers: [QVAC-008, QVAC-010]
estimate: 1h
assignee: <you>
created: 2026-05-11
updated: 2026-05-11
labels: [chore]
```

### Summary
Once the repo exists (QVAC-008) and the issue template is wired up (QVAC-010), open issues QVAC-001 through QVAC-013 as actual GitHub Issues. This file (`ISSUES.md`) is the source of truth; the GitHub Issues are mirrors used for status visibility.

### Acceptance criteria
- [ ] QVAC-001 through QVAC-013 exist as GitHub Issues with matching IDs in the title prefix.
- [ ] Each Issue's body matches the corresponding section in this file.
- [ ] Labels applied per `labels:` field.

### Test plan
- Manual: `gh issue list --label phase-p0 | wc -l` returns 13.

---

## QVAC-003

```yaml
id: QVAC-003
title: Spike — map Expo plugin + bare-link addon resolution end-to-end
phase: P0
status: spike
type: spike
priority: P1-must
grant-refs: [SI-4]
blockers: []
estimate: 1.5d
assignee: <you>
created: 2026-05-11
updated: 2026-05-11
labels: [spike, worker-bundle, transport]
```

### Summary
Reading the JS source we found that `worker.mobile.bundle.js` is generated at consumer-build time by `@qvac/cli bundle sdk`, and addon `.bare` files are linked by `bare-link` based on either `qvac/addons.manifest.json` or "all addons in node_modules." For our Swift package consumers we must reproduce this — see PLAN §2.9 options A/B/C.

Output: `docs/bundle-and-addons.md` documenting:
1. Exact CLI commands the Expo plugin runs and their flags.
2. Where the bundle and addons land on disk after Expo prebuild.
3. The shape of `qvac/addons.manifest.json`.
4. The runtime contract: when Bare starts inside BareKit, how does it locate the addon `.bare` files? (Look at `bare-kit` source.)
5. Concrete proposal for SPM equivalent (recommend option A unless evidence pushes elsewhere).

### Acceptance criteria
- [ ] `docs/bundle-and-addons.md` exists with the 5 sections above.
- [ ] At least one screenshot or `tree` output of a real Expo-built iOS app showing where the `.bare` files land.
- [ ] Provisional recommendation for SPM (A/B/C) with reasoning.
- [ ] Confirms the Phase 0 OQ-3 question to Tether.

### Implementation notes
- Source files to read: `qvac-sparse/packages/sdk/expo/plugins/withMobileBundle.ts`, `qvac-sparse/packages/sdk/expo/plugins/patches/ios-link.mjs` (already read in PLAN research).
- `bare-link` source: clone `github.com/holepunchto/bare-link` to inspect.
- BareKit source: `github.com/holepunchto/bare-kit`, specifically `apple/ios/*.m` for how addons are loaded at runtime.

### Test plan
- Manual review of the spike doc by a reviewer (self or pair).

### Notes
- 2026-05-11: Created.

---

## QVAC-004

```yaml
id: QVAC-004
title: Spike — BareKit `BareKitProbe` Swift sample
phase: P0
status: spike
type: spike
priority: P0-blocker
grant-refs: [SI-4, SI-6, AR-2]
blockers: []
estimate: 2d
assignee: <you>
created: 2026-05-11
updated: 2026-05-11
labels: [spike, transport, lifecycle]
```

### Summary
Build a minimal iOS app `BareKitProbe` that:
1. Embeds `BareKit.xcframework` from holepunchto/bare-kit's releases.
2. Starts a `BareWorklet` with a tiny inline JS source (just `setTimeout(()=>{},1e9)`).
3. Opens a `BareIPC` channel.
4. Writes a known-good bare-rpc heartbeat REQUEST frame (built using our `CompactEncoding` Swift port from Spike 1).
5. Reads the RESPONSE frame and decodes it.

This is the smallest possible proof that Swift + BareKit + our codec can complete an RPC round-trip in-process on iOS.

### Acceptance criteria
- [ ] `Examples/BareKitProbe/` builds on macOS arm64.
- [ ] Runs on iOS 17+ simulator, prints "heartbeat ok" to console.
- [ ] No memory leaks per `leaks(1)` over 100 iterations.
- [ ] `BareIPC` callbacks demonstrably fire on the documented GCD queue.
- [ ] `BareWorklet.terminate()` returns within 1s.

### Implementation notes
- BareKit xcframework: download from `github.com/holepunchto/bare-kit/releases`.
- Reference: `github.com/holepunchto/bare-ios` sample (read it; copy structure).
- Use Spike 1's `CompactEncoding.swift` directly.
- This is the riskiest unknown in the project — if BareKit's Obj-C API doesn't bridge cleanly to Swift, the whole plan needs rework.

### Test plan
- Manual: build + run on macOS simulator + iOS sim.
- Automated (post-spike): integrate into Phase 2's CI.

### Notes
- 2026-05-11: Created. **Highest-uncertainty item in Phase 0** — do this first.

---

## QVAC-005

```yaml
id: QVAC-005
title: Spike — macOS Bare worker heartbeat round-trip
phase: P0
status: spike
type: spike
priority: P0-blocker
grant-refs: [SI-1, AC-4]
blockers: []
estimate: 1d
assignee: <you>
created: 2026-05-11
updated: 2026-05-11
labels: [spike, transport]
```

### Summary
Prove the macOS path. Spawn `bare worker.js` (where `worker.js` is `@qvac/sdk/dist/server/worker.js`) from a tiny Node script, connect to its Unix Domain Socket from Swift using our `CompactEncoding` + `BareRPC` codec, send `__init_config` then `heartbeat`, capture the responses, decode them. Save the captured byte sequence as a wire fixture in `Tests/Fixtures/bare-rpc-frames/`.

### Acceptance criteria
- [ ] A Swift CLI tool `Examples/MacOSProbe/` exists.
- [ ] `swift run MacOSProbe` succeeds within 5s on a clean machine (after `bare` and `@qvac/sdk` are installed).
- [ ] Captured fixtures saved for future regression tests.

### Implementation notes
- Refer to PLAN §2.2 + §2.5 for the protocol.
- Refer to `qvac-sparse/packages/sdk/client/rpc/node-rpc-client.ts:198–282` for the canonical client logic.

### Test plan
- Manual + becomes the seed for QVAC-114 (P1 integration test).

### Notes
- 2026-05-11: Created.

---

## QVAC-006

```yaml
id: QVAC-006
title: Spike — identify the 6 transform-collapsed Zod request branches
phase: P0
status: spike
type: spike
priority: P1-must
grant-refs: [SI-2, AC-1, AC-11]
blockers: []
estimate: 0.5d
assignee: <you>
created: 2026-05-11
updated: 2026-05-11
labels: [spike, codegen]
```

### Summary
Spike 2 from the existing work showed that 6 of 30 request branches collapse to empty `{}` under `z.toJSONSchema(..., { unrepresentable: "any" })` because they have top-level `.transform()` calls. Identify exactly which branches, which transforms cause the collapse, and propose a remediation per branch (override emitter / source PR / `.pipe()` alternative).

### Acceptance criteria
- [ ] `docs/codegen-edge-cases.md` lists all 6 branches by request `type` literal.
- [ ] For each: the source file + line of the offending `.transform()`, the transform's purpose, and the recommended Swift output shape.
- [ ] Categorized as "fix in generator" vs "fix upstream via PR to QVAC."

### Implementation notes
- Start from `/Users/hardik/Projects/qvac-swift/spike-js/requestSchema.json` (already generated).
- Find branches with `topKeys=[]` (output of the existing spike).
- Cross-reference against `qvac-sparse/packages/sdk/schemas/load-model.ts` and others (load-model has 13 transforms, most likely culprits).

### Test plan
- Manual review.

### Notes
- 2026-05-11: Created. Already partially done in spike — this formalizes.

---

## QVAC-007

```yaml
id: QVAC-007
title: Send Tether the 7 open questions; decide GO/NO-GO
phase: P0
status: open
type: chore
priority: P0-blocker
grant-refs: []
blockers: [QVAC-003, QVAC-004, QVAC-005, QVAC-006]
estimate: 2h
assignee: <you>
created: 2026-05-11
updated: 2026-05-11
labels: [tether-oq]
```

### Summary
Email or open a discussion thread with Tether listing OQ-1 through OQ-7 from [PLAN.md §8](PLAN.md#8-open-questions-for-tether). After their reply, write a one-page GO/NO-GO decision document.

### Acceptance criteria
- [ ] All 7 questions sent in a single message.
- [ ] Tether's responses recorded in this issue's Notes.
- [ ] `docs/go-no-go.md` written with the decision.
- [ ] If GO: M1 timeline confirmed feasible given Tether's answers; if NO-GO: clear rationale and any next steps documented.

### Test plan
- Manual.

### Notes
- 2026-05-11: Created. Pending Phase 0 spikes — do this AFTER spikes so we can answer "do you have any other questions" thoughtfully.

---

## QVAC-008

```yaml
id: QVAC-008
title: Create the `qvac-swift` GitHub repo (per OQ-4 outcome)
phase: P0
status: blocked
type: chore
priority: P0-blocker
grant-refs: [SI-4, SI-5]
blockers: [QVAC-007]
estimate: 1h
assignee: <you>
created: 2026-05-11
updated: 2026-05-11
labels: [chore]
```

### Summary
Per OQ-4: SI-4 says "lives in the @qvac/sdk monorepo," but SPM packages are most ergonomic as their own repo. Depending on Tether's answer:
- If standalone repo: create `tetherto/qvac-swift` (or own personal repo if Tether prefers fork-first).
- If monorepo: create a feature branch / fork that adds `packages/sdk-swift/`.

### Acceptance criteria
- [ ] Repo (or feature branch) exists.
- [ ] Apache-2.0 LICENSE matches QVAC's.
- [ ] `main` branch protected.

### Test plan
- Manual: visit the repo URL.

### Notes
- 2026-05-11: Created. Blocked on QVAC-007.

---

## QVAC-009

```yaml
id: QVAC-009
title: Initialize repo — Package.swift, LICENSE, README shell, CI placeholder
phase: P0
status: open
type: chore
priority: P1-must
grant-refs: [D-3, D-5, SI-6]
blockers: [QVAC-008]
estimate: 0.5d
assignee: <you>
created: 2026-05-11
updated: 2026-05-11
labels: [chore, ci]
```

### Summary
Bootstrap the repo:
- `Package.swift` with macOS 14+ / iOS 17+ platforms, single empty library product.
- `LICENSE` (Apache-2.0).
- `README.md` skeleton with sections matching PLAN §3 Phase 3 QVAC-315.
- `.gitignore` for Swift.
- `.github/workflows/phase0.yml` running `swift build` on macOS-14.
- `CODE_OF_CONDUCT.md` (contributor covenant).

### Acceptance criteria
- [ ] `swift build` succeeds on the empty library on macOS arm64.
- [ ] Phase-0 CI workflow runs green on the first push.
- [ ] All files are in place per the file-tree at [PLAN.md Appendix A](PLAN.md#appendix-a--files-and-directories-at-end-of-project).

### Implementation notes
- Use Apple's "Publishing a Swift Package with Xcode" guide steps as the reference.

### Test plan
- Automated: `phase0.yml` must be green.

---

## QVAC-010

```yaml
id: QVAC-010
title: Wire ISSUES.md into a GitHub Issues template + label set
phase: P0
status: open
type: chore
priority: P1-must
grant-refs: [AR-6]
blockers: [QVAC-008]
estimate: 1h
assignee: <you>
created: 2026-05-11
updated: 2026-05-11
labels: [chore]
```

### Summary
Add `.github/ISSUE_TEMPLATE/` files that mirror the strict schema from [PLAN.md §4](PLAN.md#4-issue-tracker-schema):
- `task.yml`
- `bug.yml`
- `spike.yml`

Configure the label set from [PLAN.md §4.3](PLAN.md#43-label-taxonomy) using `gh label create`.

### Acceptance criteria
- [ ] Three issue templates exist.
- [ ] All labels from §4.3 created and color-coded.
- [ ] A test issue can be opened that matches the template and applies labels.

### Test plan
- Manual: open a throwaway test issue.

---

## QVAC-011

```yaml
id: QVAC-011
title: Set up macOS-arm64 dev environment
phase: P0
status: open
type: chore
priority: P0-blocker
grant-refs: [AR-5]
blockers: []
estimate: 2h
assignee: <you>
created: 2026-05-11
updated: 2026-05-11
labels: [chore]
```

### Summary
Confirm all toolchain versions and install missing pieces:
- macOS 14.x+ on Apple Silicon (already confirmed: Darwin 25.2.0 arm64).
- Xcode 16+ with iOS 17 simulator.
- Swift 6.3.x via `xcode-select` (already confirmed: 6.3.1).
- Node 22+ (already confirmed: 25.9.0).
- Bun ≥ 1.x.
- Bare runtime ≥ 1.24: `npm i -g bare-runtime` or via Homebrew.
- `@qvac/cli`: `npm i -g @qvac/cli`.

### Acceptance criteria
- [ ] `swift --version` ≥ 5.10.
- [ ] `xcodebuild -version` shows Xcode 16+.
- [ ] `bare --version` ≥ 1.24.
- [ ] `qvac --version` runs without error.
- [ ] `xcrun simctl list` shows an iOS 17+ simulator.

### Test plan
- Automated: a shell script `tools/check-env.sh` asserts every version constraint and exits non-zero on any miss.

---

## QVAC-012

```yaml
id: QVAC-012
title: Set up iOS physical-device build pipeline
phase: P0
status: open
type: chore
priority: P1-must
grant-refs: [AR-5, KR-5]
blockers: [QVAC-011]
estimate: 2h
assignee: <you>
created: 2026-05-11
updated: 2026-05-11
labels: [chore]
```

### Summary
Configure code signing for iOS device deployment. Needed for KR-5 (physical-device validation in Phase 4).
- Apple Developer account (free is sufficient for sideloading; paid for App Store).
- Development certificate + provisioning profile for `*.bundleIdentifier`.
- Test deploy a stock SwiftUI app to a real device.

### Acceptance criteria
- [ ] A stock SwiftUI "Hello World" app installs and runs on the physical device.
- [ ] Provisioning profile expires far enough in the future to cover the project timeline (until at least 2026-08).

### Test plan
- Manual.

---

## QVAC-013

```yaml
id: QVAC-013
title: Write project CLAUDE.md + weekly-update template
phase: P0
status: open
type: docs
priority: P2-should
grant-refs: [AR-6]
blockers: [QVAC-008]
estimate: 1h
assignee: <you>
created: 2026-05-11
updated: 2026-05-11
labels: [docs]
```

### Summary
Create a `CLAUDE.md` at the repo root documenting:
- Project conventions (Swift formatting, codegen invocation, fixture regeneration).
- Test commands.
- Working with the codegen pipeline.
- Pointer to PLAN.md as the source of truth.

Also seed the QVAC-000 weekly update issue with the first entry using the [PLAN.md Appendix B](PLAN.md#appendix-b--weekly-update-template-ar-6-compliance) template.

### Acceptance criteria
- [ ] `CLAUDE.md` exists at repo root.
- [ ] First weekly update posted on QVAC-000.

### Test plan
- Manual review.

---

## Format reference (for new issues)

Copy this template when creating a new issue:

```markdown
## QVAC-NNN

​```yaml
id: QVAC-NNN
title: <imperative, ≤80 chars>
phase: P0 | P1 | P2 | P3 | P4
status: open | spike | in-progress | blocked | in-review | done | wont-fix
type: spike | task | bug | blocker | docs | test | ci | chore
priority: P0-blocker | P1-must | P2-should | P3-nice
grant-refs: [SI-N, AC-N, ...]
blockers: [QVAC-NNN, ...]
estimate: <Nd> | <Nh>
assignee: <github-handle>
created: YYYY-MM-DD
updated: YYYY-MM-DD
labels: [...]
​```

### Summary
<1–2 paragraphs>

### Acceptance criteria
- [ ] <testable>
- [ ] <testable>

### Implementation notes
<pointers, file paths, line numbers, links>

### Test plan
- <how to validate>

### Notes (dated)
- YYYY-MM-DD: <update>
```

For **bugs**, add the addendum from [PLAN.md §4.4](PLAN.md#44-bug-template-addendum).
