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

console.log('[release-binding] immutable v2/r1 compatibility and hardened v3 evidence/clean-tree gates enforced')
