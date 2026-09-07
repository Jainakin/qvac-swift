#!/usr/bin/env node

import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { spawnSync } from 'node:child_process'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  assertReleaseSourceCommit,
  validateReleaseManifest,
} from './release-manifest.mjs'

const releaseCommit = '0123456789abcdef0123456789abcdef01234567'
const otherCommit = '89abcdef0123456789abcdef0123456789abcdef'

assert.doesNotThrow(() => assertReleaseSourceCommit({ sourceCommit: releaseCommit }, releaseCommit))
assert.throws(
  () => assertReleaseSourceCommit({ sourceCommit: otherCommit }, releaseCommit),
  /does not match release commit/,
)
assert.throws(
  () => assertReleaseSourceCommit({ sourceCommit: releaseCommit }, 'main'),
  /invalid expected source commit/,
)

const hash = 'a'.repeat(64)
const artifactTag = 'artifacts-sdk-0.17.0-r2'
const legacyArtifactTag = 'artifacts-sdk-0.17.0-r1'
const legacySourceCommit = '85ac16212e43ec4572c96f04bf278cd67e52eb7f'
const releaseBase = `https://github.com/Jainakin/qvac-swift/releases/download/${artifactTag}/`
const privacyAuditBytes = readFileSync(
  fileURLToPath(new URL('./privacy-manifest-audit.json', import.meta.url)),
)
const auditedTargets = JSON.parse(privacyAuditBytes).scanEvidence.map(entry => entry.target)
const artifact = target => ({
  target,
  assetName: `${target}.xcframework.zip`,
  url: `${releaseBase}${target}.xcframework.zip`,
  size: 1,
  sha256: hash,
  swiftChecksum: hash,
})
const boundAsset = assetName => ({
  assetName,
  url: `${releaseBase}${assetName}`,
  size: 1,
  sha256: hash,
})
const manifest = {
  schemaVersion: 3,
  mode: 'release',
  artifactTag,
  sourceCommit: releaseCommit,
  sdk: {
    version: '0.17.0',
    sourceCommit: 'e8b440665a053a9efe852f04c3601da44f0d55d8',
    npmIntegrity: 'sha512-YQ==',
    runtimeInventorySHA256: hash,
  },
  bundle: {
    assetName: 'worker.mobile.bundle',
    url: `${releaseBase}worker.mobile.bundle`,
    size: 1,
    sha256: hash,
    bundleId: 'test-bundle',
    main: 'index.js',
    embeddedSDKVersion: '0.17.0',
    addonTargets: [auditedTargets[1]],
  },
  notices: {
    assetName: 'THIRD_PARTY_NOTICES.md',
    url: `${releaseBase}THIRD_PARTY_NOTICES.md`,
    size: 1,
    sha256: hash,
  },
  privacyAudit: boundAsset('privacy-manifest-audit.json'),
  runtimeResolutionInventory: boundAsset('runtime-resolution-inventory.json'),
  sdkProvenance: boundAsset('qvac-sdk-provenance.json'),
  bareKitPatch: boundAsset('bare-kit-2.3.0-qvac.patch'),
  bareKitProvenance: boundAsset('bare-kit-patch-provenance.json'),
  bareKitNativeClosure: boundAsset('bare-kit-native-closure.json'),
  artifacts: auditedTargets.map(artifact),
}

assert.doesNotThrow(() => validateReleaseManifest(manifest))
const missingNotices = structuredClone(manifest)
delete missingNotices.notices
assert.throws(() => validateReleaseManifest(missingNotices), /third-party notices/)
const foreignNotices = structuredClone(manifest)
foreignNotices.notices.url = 'https://example.com/THIRD_PARTY_NOTICES.md'
assert.throws(() => validateReleaseManifest(foreignNotices), /third-party notices URL/)
const missingInventory = structuredClone(manifest)
delete missingInventory.runtimeResolutionInventory
assert.throws(() => validateReleaseManifest(missingInventory), /runtime resolution inventory/)
const missingProvenance = structuredClone(manifest)
delete missingProvenance.sdkProvenance
assert.throws(() => validateReleaseManifest(missingProvenance), /SDK provenance/)
const missingPrivacyAudit = structuredClone(manifest)
delete missingPrivacyAudit.privacyAudit
assert.throws(() => validateReleaseManifest(missingPrivacyAudit), /privacy manifest audit/)
const missingBareKitPatch = structuredClone(manifest)
delete missingBareKitPatch.bareKitPatch
assert.throws(() => validateReleaseManifest(missingBareKitPatch), /BareKit patch/)
const missingBareKitProvenance = structuredClone(manifest)
delete missingBareKitProvenance.bareKitProvenance
assert.throws(() => validateReleaseManifest(missingBareKitProvenance), /BareKit provenance/)
const missingBareKitClosure = structuredClone(manifest)
delete missingBareKitClosure.bareKitNativeClosure
assert.throws(() => validateReleaseManifest(missingBareKitClosure), /BareKit native closure/)
const mismatchedInventoryChecksum = structuredClone(manifest)
mismatchedInventoryChecksum.runtimeResolutionInventory.sha256 = 'b'.repeat(64)
assert.throws(() => validateReleaseManifest(mismatchedInventoryChecksum), /does not match sdk\.runtimeInventorySHA256/)
const foreignProvenance = structuredClone(manifest)
foreignProvenance.sdkProvenance.url = 'https://example.com/qvac-sdk-provenance.json'
assert.throws(() => validateReleaseManifest(foreignProvenance), /SDK provenance URL/)

const legacyManifest = JSON.parse(JSON.stringify(manifest).replaceAll(artifactTag, legacyArtifactTag))
legacyManifest.schemaVersion = 2
legacyManifest.sourceCommit = legacySourceCommit
delete legacyManifest.runtimeResolutionInventory
delete legacyManifest.sdkProvenance
delete legacyManifest.privacyAudit
delete legacyManifest.bareKitPatch
delete legacyManifest.bareKitProvenance
delete legacyManifest.bareKitNativeClosure
assert.doesNotThrow(() => validateReleaseManifest(legacyManifest))
const foreignLegacyManifest = JSON.parse(
  JSON.stringify(legacyManifest).replaceAll('github.com/Jainakin/qvac-swift', 'github.com/attacker/fork'),
)
assert.throws(() => validateReleaseManifest(foreignLegacyManifest), /historical schema v2 must use/)
const legacyAtAnotherCommit = structuredClone(legacyManifest)
legacyAtAnotherCommit.sourceCommit = releaseCommit
assert.throws(() => validateReleaseManifest(legacyAtAnotherCommit), /schema v2 is accepted only/)
const newCandidateClaimingLegacySchema = structuredClone(manifest)
newCandidateClaimingLegacySchema.schemaVersion = 2
assert.throws(() => validateReleaseManifest(newCandidateClaimingLegacySchema), /schema v2 is accepted only/)
const legacyClaimingHardenedSchema = structuredClone(legacyManifest)
legacyClaimingHardenedSchema.schemaVersion = 3
assert.throws(() => validateReleaseManifest(legacyClaimingHardenedSchema), /schema v3 requires an r2-or-later/)

const digest = bytes => createHash('sha256').update(bytes).digest('hex')
const stableJSON = value => {
  if (Array.isArray(value)) return `[${value.map(stableJSON).join(',')}]`
  if (value !== null && typeof value === 'object') {
    return `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${stableJSON(value[key])}`).join(',')}}`
  }
  return JSON.stringify(value)
}
const writeAsset = (directory, name, bytes) => {
  writeFileSync(join(directory, name), bytes)
  return {
    assetName: name,
    url: `${releaseBase}${name}`,
    size: bytes.length,
    sha256: digest(bytes),
  }
}
const runLocalVerification = (manifestPath, assetsDirectory, extraArguments = []) => spawnSync(
  process.execPath,
  [
    fileURLToPath(new URL('./verify-release.mjs', import.meta.url)),
    manifestPath,
    '--assets-dir',
    assetsDirectory,
    ...extraArguments,
  ],
  { encoding: 'utf8' },
)
const cleanWorktreeVerifierPath = fileURLToPath(new URL('./require-clean-worktree.mjs', import.meta.url))
const bareKitPatchBytes = readFileSync(
  fileURLToPath(new URL('../native/bare-kit/bare-kit-2.3.0-qvac.patch', import.meta.url)),
)
const bareKitProvenanceBytes = readFileSync(
  fileURLToPath(new URL('../native/bare-kit/provenance.lock.json', import.meta.url)),
)
const bareKitProvenance = JSON.parse(bareKitProvenanceBytes.toString('utf8'))
const bareKitMirror = bareKitProvenance.nativeClosure.prebuiltArchiveMirror
const bareKitNativeClosureBytes = Buffer.from(`${JSON.stringify({
  schemaVersion: 1,
  component: 'BareKit native dependency closure',
  upstreamCommit: bareKitProvenance.upstream.commit,
  provenanceLockSHA256: digest(bareKitProvenanceBytes),
  nativeClosureSHA256: digest(Buffer.from(stableJSON(bareKitProvenance.nativeClosure))),
  sources: bareKitProvenance.nativeClosure.sources,
  targets: Object.fromEntries(
    Object.keys(bareKitMirror.targets).sort().map(target => [target, {
      driveKey: bareKitMirror.driveKey,
      checkout: bareKitMirror.checkout,
      files: bareKitMirror.targets[target],
    }]),
  ),
}, null, 2)}\n`)

const temporaryDirectory = mkdtempSync(join(tmpdir(), 'qvac-release-binding-'))
try {
  const refusedLegacyGeneration = spawnSync(
    process.execPath,
    [
      fileURLToPath(new URL('./compute-manifest.mjs', import.meta.url)),
      'release',
      join(temporaryDirectory, 'missing-link-set.json'),
      join(temporaryDirectory, 'missing-worker.bundle'),
      temporaryDirectory,
      join(temporaryDirectory, 'must-not-exist.json'),
      '--artifact-tag',
      legacyArtifactTag,
      '--repository',
      'Jainakin/qvac-swift',
      '--source-commit',
      legacySourceCommit,
    ],
    { encoding: 'utf8' },
  )
  assert.notEqual(refusedLegacyGeneration.status, 0)
  assert.match(refusedLegacyGeneration.stderr, /schema v3 starts at r2/)

  const runtimeInventoryBytes = Buffer.from(JSON.stringify({
    schemaVersion: 1,
    sdkVersion: '0.17.0',
    authoritativeSourceCommit: 'e8b440665a053a9efe852f04c3601da44f0d55d8',
  }))
  const sdkProvenanceBytes = Buffer.from(JSON.stringify({
    schemaVersion: 1,
    sdkVersion: '0.17.0',
    source: { commit: 'e8b440665a053a9efe852f04c3601da44f0d55d8' },
    npm: {
      name: '@qvac/sdk',
      version: '0.17.0',
      integrity: 'sha512-YQ==',
      gitHead: 'e8b440665a053a9efe852f04c3601da44f0d55d8',
    },
  }))
  const localManifest = structuredClone(manifest)
  localManifest.bundle = {
    ...localManifest.bundle,
    ...writeAsset(temporaryDirectory, 'worker.mobile.bundle', Buffer.from('worker')),
  }
  localManifest.notices = writeAsset(temporaryDirectory, 'THIRD_PARTY_NOTICES.md', Buffer.from('notices'))
  localManifest.privacyAudit = writeAsset(
    temporaryDirectory,
    'privacy-manifest-audit.json',
    privacyAuditBytes,
  )
  localManifest.runtimeResolutionInventory = writeAsset(
    temporaryDirectory,
    'runtime-resolution-inventory.json',
    runtimeInventoryBytes,
  )
  localManifest.sdk.runtimeInventorySHA256 = localManifest.runtimeResolutionInventory.sha256
  localManifest.sdkProvenance = writeAsset(
    temporaryDirectory,
    'qvac-sdk-provenance.json',
    sdkProvenanceBytes,
  )
  localManifest.bareKitPatch = writeAsset(
    temporaryDirectory,
    'bare-kit-2.3.0-qvac.patch',
    bareKitPatchBytes,
  )
  localManifest.bareKitProvenance = writeAsset(
    temporaryDirectory,
    'bare-kit-patch-provenance.json',
    bareKitProvenanceBytes,
  )
  localManifest.bareKitNativeClosure = writeAsset(
    temporaryDirectory,
    'bare-kit-native-closure.json',
    bareKitNativeClosureBytes,
  )
  localManifest.artifacts = auditedTargets.map(target => {
    const bytes = Buffer.from(`archive-${target}`)
    const asset = writeAsset(temporaryDirectory, `${target}.xcframework.zip`, bytes)
    return { target, ...asset, swiftChecksum: asset.sha256 }
  })
  const manifestPath = join(temporaryDirectory, 'artifact-manifest.json')
  writeFileSync(manifestPath, `${JSON.stringify(localManifest, null, 2)}\n`)

  const accepted = runLocalVerification(manifestPath, temporaryDirectory)
  assert.equal(accepted.status, 0, accepted.stderr)
  const requiredHardened = runLocalVerification(
    manifestPath,
    temporaryDirectory,
    ['--require-schema', '3'],
  )
  assert.equal(requiredHardened.status, 0, requiredHardened.stderr)

  const localLegacyManifest = JSON.parse(
    JSON.stringify(localManifest).replaceAll(artifactTag, legacyArtifactTag),
  )
  localLegacyManifest.schemaVersion = 2
  localLegacyManifest.sourceCommit = legacySourceCommit
  delete localLegacyManifest.runtimeResolutionInventory
  delete localLegacyManifest.sdkProvenance
  delete localLegacyManifest.privacyAudit
  delete localLegacyManifest.bareKitPatch
  delete localLegacyManifest.bareKitProvenance
  delete localLegacyManifest.bareKitNativeClosure
  const legacyManifestPath = join(temporaryDirectory, 'artifact-manifest-v2-legacy.json')
  writeFileSync(legacyManifestPath, `${JSON.stringify(localLegacyManifest, null, 2)}\n`)
  const acceptedLegacy = runLocalVerification(legacyManifestPath, temporaryDirectory)
  assert.equal(acceptedLegacy.status, 0, acceptedLegacy.stderr)
  const legacyRejectedByCurrentGate = runLocalVerification(
    legacyManifestPath,
    temporaryDirectory,
    ['--require-schema', '3'],
  )
  assert.notEqual(legacyRejectedByCurrentGate.status, 0)
  assert.match(legacyRejectedByCurrentGate.stderr, /requires schema v3, got schema v2/)

  writeFileSync(
    join(temporaryDirectory, localManifest.privacyAudit.assetName),
    Buffer.from(privacyAuditBytes.toString('utf8').replace('"schemaVersion": 1', '"schemaVersion": 2')),
  )
  const tamperedPrivacyAudit = runLocalVerification(manifestPath, temporaryDirectory)
  assert.notEqual(tamperedPrivacyAudit.status, 0)
  assert.match(tamperedPrivacyAudit.stderr, /SHA-256 mismatch/)
  writeFileSync(join(temporaryDirectory, localManifest.privacyAudit.assetName), privacyAuditBytes)

  writeFileSync(
    join(temporaryDirectory, localManifest.runtimeResolutionInventory.assetName),
    Buffer.from(runtimeInventoryBytes.toString('utf8').replace('0.17.0', '0.17.1')),
  )
  const tamperedInventory = runLocalVerification(manifestPath, temporaryDirectory)
  assert.notEqual(tamperedInventory.status, 0)
  assert.match(tamperedInventory.stderr, /SHA-256 mismatch/)
  writeFileSync(join(temporaryDirectory, localManifest.runtimeResolutionInventory.assetName), runtimeInventoryBytes)

  writeFileSync(
    join(temporaryDirectory, localManifest.bareKitPatch.assetName),
    Buffer.from(bareKitPatchBytes.toString('utf8').replace('diff --git', 'dxff --git')),
  )
  const tamperedBareKitPatch = runLocalVerification(manifestPath, temporaryDirectory)
  assert.notEqual(tamperedBareKitPatch.status, 0)
  assert.match(tamperedBareKitPatch.stderr, /SHA-256 mismatch/)
  writeFileSync(join(temporaryDirectory, localManifest.bareKitPatch.assetName), bareKitPatchBytes)

  writeFileSync(
    join(temporaryDirectory, localManifest.bareKitProvenance.assetName),
    Buffer.from(bareKitProvenanceBytes.toString('utf8').replace('"schemaVersion": 2', '"schemaVersion": 3')),
  )
  const tamperedBareKitProvenance = runLocalVerification(manifestPath, temporaryDirectory)
  assert.notEqual(tamperedBareKitProvenance.status, 0)
  assert.match(tamperedBareKitProvenance.stderr, /SHA-256 mismatch/)
  writeFileSync(
    join(temporaryDirectory, localManifest.bareKitProvenance.assetName),
    bareKitProvenanceBytes,
  )

  const alteredClosure = Buffer.from(
    bareKitNativeClosureBytes.toString('utf8').replace('BareKit native dependency closure', 'BareKit native dependency clozure'),
  )
  writeFileSync(join(temporaryDirectory, localManifest.bareKitNativeClosure.assetName), alteredClosure)
  const tamperedBareKitClosure = runLocalVerification(manifestPath, temporaryDirectory)
  assert.notEqual(tamperedBareKitClosure.status, 0)
  assert.match(tamperedBareKitClosure.stderr, /SHA-256 mismatch/)

  const reviewedClosureAsset = localManifest.bareKitNativeClosure
  localManifest.bareKitNativeClosure = writeAsset(
    temporaryDirectory,
    'bare-kit-native-closure.json',
    alteredClosure,
  )
  writeFileSync(manifestPath, `${JSON.stringify(localManifest, null, 2)}\n`)
  const selfConsistentWrongClosure = runLocalVerification(manifestPath, temporaryDirectory)
  assert.notEqual(selfConsistentWrongClosure.status, 0)
  assert.match(selfConsistentWrongClosure.stderr, /native closure does not match/)
  localManifest.bareKitNativeClosure = reviewedClosureAsset
  writeFileSync(
    join(temporaryDirectory, localManifest.bareKitNativeClosure.assetName),
    bareKitNativeClosureBytes,
  )
  writeFileSync(manifestPath, `${JSON.stringify(localManifest, null, 2)}\n`)

  writeFileSync(
    join(temporaryDirectory, localManifest.sdkProvenance.assetName),
    Buffer.from(sdkProvenanceBytes.toString('utf8').replace('0.17.0', '0.17.1')),
  )
  const tamperedProvenance = runLocalVerification(manifestPath, temporaryDirectory)
  assert.notEqual(tamperedProvenance.status, 0)
  assert.match(tamperedProvenance.stderr, /SHA-256 mismatch/)

  const selfConsistentWrongProvenance = Buffer.from(
    sdkProvenanceBytes.toString('utf8').replace('0.17.0', '0.17.1'),
  )
  localManifest.sdkProvenance = writeAsset(
    temporaryDirectory,
    'qvac-sdk-provenance.json',
    selfConsistentWrongProvenance,
  )
  writeFileSync(manifestPath, `${JSON.stringify(localManifest, null, 2)}\n`)
  const misleadingProvenance = runLocalVerification(manifestPath, temporaryDirectory)
  assert.notEqual(misleadingProvenance.status, 0)
  assert.match(misleadingProvenance.stderr, /SDK provenance does not describe/)

  const testRepository = join(temporaryDirectory, 'clean-worktree-test')
  mkdirSync(testRepository)
  const initialized = spawnSync('git', ['init', '--quiet', testRepository], { encoding: 'utf8' })
  assert.equal(initialized.status, 0, initialized.stderr)
  const cleanTree = spawnSync(process.execPath, [cleanWorktreeVerifierPath, testRepository], { encoding: 'utf8' })
  assert.equal(cleanTree.status, 0, cleanTree.stderr)
  writeFileSync(join(testRepository, 'untracked.txt'), 'release contamination\n')
  const untrackedTree = spawnSync(
    process.execPath,
    [cleanWorktreeVerifierPath, testRepository],
    { encoding: 'utf8' },
  )
  assert.equal(untrackedTree.status, 3)
  assert.match(untrackedTree.stderr, /including untracked files/)
  assert.match(untrackedTree.stderr, /\?\? untracked\.txt/)
} finally {
  rmSync(temporaryDirectory, { recursive: true, force: true })
}

console.log('[release-binding] immutable v2/r1 verification and hardened v3 SDK/native evidence gates enforced')
