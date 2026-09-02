#!/usr/bin/env node

import { createHash } from 'node:crypto'
import {
  closeSync,
  constants,
  existsSync,
  fstatSync,
  lstatSync,
  mkdtempSync,
  mkdirSync,
  openSync,
  readFileSync,
  readdirSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs'
import { dirname, join, relative, resolve, sep } from 'node:path'
import { tmpdir } from 'node:os'
import { fileURLToPath } from 'node:url'
import { verifyBundle } from './verify-bundle-provenance.mjs'

const scriptDirectory = dirname(fileURLToPath(import.meta.url))
const repositoryRoot = resolve(scriptDirectory, '../..')
const runtimeRoot = resolve(repositoryRoot, 'tools/runtime')
const bundlePath = resolve(repositoryRoot, 'Sources/QVACClient/Resources/worker.mobile.bundle')
const inventoryPath = resolve(runtimeRoot, 'resolution-inventory.json')
const packageLockPath = resolve(runtimeRoot, 'package-lock.json')
const outputPath = resolve(repositoryRoot, 'THIRD_PARTY_NOTICES.md')
const supplementsManifestPath = resolve(scriptDirectory, 'license-supplements.json')
const supplementsRoot = resolve(scriptDirectory, 'license-supplements')
const nativeManifestPath = resolve(scriptDirectory, 'native-components.json')
const maximumNoticeBytes = 1024 * 1024
const maximumNativeEvidenceBytes = 16 * 1024 * 1024
const nativeEvidenceDirectory = 'tools/release/native-closure-evidence/'
const requiredNativeClosureRequirementIDs = [
  'ffmpeg-lgpl-static-distribution-plan',
  'barekit-v8-transitive-provenance',
  'qvac-addon-vcpkg-license-closure',
  'bare-addon-transitive-license-texts',
]
const validatedNativeClosure = Symbol('validatedNativeClosure')
// BareKit is linked into every iOS artifact closure but is not embedded in the
// portable worker bundle. Keep the non-worker native roots explicit so a new
// release cannot silently omit their attribution.
const additionalNativePackagePaths = [
  'node_modules/react-native-bare-kit/package.json',
]

function fail(message) {
  throw new Error(`[third-party-notices] ${message}`)
}

function sha256(value) {
  return createHash('sha256').update(value).digest('hex')
}

function artifactKey(resolved, integrity) {
  return `${resolved}\n${integrity}`
}

function normalizedText(path) {
  const stat = lstatSync(path)
  if (stat.isSymbolicLink() || !stat.isFile()) fail(`notice input must be a regular non-symlink file: ${path}`)
  if (stat.size <= 0 || stat.size > maximumNoticeBytes) fail(`notice input has invalid size: ${path}`)
  const bytes = readFileSync(path)
  const text = bytes.toString('utf8')
  if (Buffer.from(text, 'utf8').compare(bytes) !== 0 || text.includes('\u0000')) {
    fail(`notice input is not canonical UTF-8 text: ${path}`)
  }
  return text.replace(/\r\n?/g, '\n').replace(/[ \t]+$/gm, '').trim() + '\n'
}

function plainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

function assertExactKeys(value, expected, label) {
  if (!plainObject(value)) fail(`${label} must be an object`)
  const actual = Object.keys(value).sort()
  const wanted = [...expected].sort()
  if (actual.length !== wanted.length || actual.some((key, index) => key !== wanted[index])) {
    fail(`${label} has unexpected fields: expected ${wanted.join(', ')}, got ${actual.join(', ')}`)
  }
}

function requireString(value, label) {
  if (typeof value !== 'string' || value.trim() !== value || value.length === 0) {
    fail(`${label} must be a non-empty, trimmed string`)
  }
  return value
}

function assertNoSymlinkComponents(path, root, label) {
  const rel = relative(root, path)
  if (rel === '..' || rel.startsWith(`..${sep}`) || rel === '') {
    fail(`${label} escaped its expected root: ${path}`)
  }
  let cursor = root
  for (const component of rel.split(sep)) {
    cursor = join(cursor, component)
    if (!existsSync(cursor)) fail(`missing ${label}: ${cursor}`)
    if (lstatSync(cursor).isSymbolicLink()) fail(`${label} contains a symlink component: ${cursor}`)
  }
}

function loadLicenseSupplements(
  manifestPath = supplementsManifestPath,
  textRoot = supplementsRoot,
) {
  const rootStat = lstatSync(textRoot)
  if (rootStat.isSymbolicLink() || !rootStat.isDirectory()) {
    fail(`license supplement root must be a regular non-symlink directory: ${textRoot}`)
  }
  const manifestStat = lstatSync(manifestPath)
  if (manifestStat.isSymbolicLink() || !manifestStat.isFile()) {
    fail(`license supplement manifest must be a regular non-symlink file: ${manifestPath}`)
  }
  if (manifestStat.size <= 0 || manifestStat.size > maximumNoticeBytes) {
    fail(`license supplement manifest has invalid size: ${manifestPath}`)
  }

  let manifest
  try { manifest = JSON.parse(normalizedText(manifestPath)) } catch (error) {
    fail(`license supplement manifest is invalid JSON: ${error.message}`)
  }
  assertExactKeys(manifest, ['schemaVersion', 'reviewStatus', 'supplements'], 'license supplement manifest')
  if (manifest.schemaVersion !== 1) fail('unsupported license supplement schema version')
  if (manifest.reviewStatus !== 'maintainer-review-required') {
    fail('license supplement manifest must remain maintainer-review-required')
  }
  if (!Array.isArray(manifest.supplements)) fail('license supplement manifest supplements must be an array')

  const supplements = new Map()
  for (const [index, supplement] of manifest.supplements.entries()) {
    const label = `license supplement ${index}`
    assertExactKeys(
      supplement,
      ['identity', 'declaredLicense', 'packageArtifact', 'text', 'evidence'],
      label,
    )
    const identity = requireString(supplement.identity, `${label}.identity`)
    const declaredLicense = requireString(supplement.declaredLicense, `${label}.declaredLicense`)
    if (identity.lastIndexOf('@') <= 0) fail(`${label}.identity is not a package identity`)
    if (supplements.has(identity)) fail(`duplicate license supplement for ${identity}`)

    assertExactKeys(supplement.packageArtifact, ['resolved', 'integrity'], `${label}.packageArtifact`)
    const resolved = requireString(supplement.packageArtifact.resolved, `${label}.packageArtifact.resolved`)
    const integrity = requireString(supplement.packageArtifact.integrity, `${label}.packageArtifact.integrity`)
    if (!/^https:\/\/registry\.npmjs\.org\/.+\.tgz$/.test(resolved)) {
      fail(`${label}.packageArtifact.resolved is not an immutable npm artifact URL`)
    }
    if (!/^sha512-[A-Za-z0-9+/]+={0,2}$/.test(integrity)) {
      fail(`${label}.packageArtifact.integrity is not a SHA-512 SRI value`)
    }

    assertExactKeys(supplement.text, ['file', 'sha256'], `${label}.text`)
    const filename = requireString(supplement.text.file, `${label}.text.file`)
    const expectedHash = requireString(supplement.text.sha256, `${label}.text.sha256`)
    if (!/^[A-Za-z0-9][A-Za-z0-9._-]*\.txt$/.test(filename)) {
      fail(`${label}.text.file must be a direct .txt child of the supplement directory`)
    }
    if (!/^[0-9a-f]{64}$/.test(expectedHash)) fail(`${label}.text.sha256 is not lowercase SHA-256`)
    const textPath = resolve(textRoot, filename)
    if (dirname(textPath) !== textRoot) fail(`${label}.text.file escaped the supplement directory`)
    assertNoSymlinkComponents(textPath, textRoot, 'license supplement text')
    const text = normalizedText(textPath)
    if (readFileSync(textPath, 'utf8') !== text) {
      fail(`${label}.text.file must already be canonical UTF-8 with LF endings and one final newline`)
    }
    const actualHash = sha256(text)
    if (actualHash !== expectedHash) {
      fail(`${label}.text.sha256 mismatch: expected ${expectedHash}, got ${actualHash}`)
    }

    assertExactKeys(
      supplement.evidence,
      ['kind', 'repository', 'publishedGitHead', 'evidenceRevision', 'note'],
      `${label}.evidence`,
    )
    const kind = requireString(supplement.evidence.kind, `${label}.evidence.kind`)
    if (!['historical-upstream-license', 'spdx-and-repository-authorship'].includes(kind)) {
      fail(`${label}.evidence.kind is unsupported`)
    }
    const repository = requireString(supplement.evidence.repository, `${label}.evidence.repository`)
    if (!/^https:\/\/github\.com\/[^/]+\/[^/]+$/.test(repository)) {
      fail(`${label}.evidence.repository must be a canonical HTTPS GitHub repository URL`)
    }
    const publishedGitHead = requireString(
      supplement.evidence.publishedGitHead,
      `${label}.evidence.publishedGitHead`,
    )
    const evidenceRevision = requireString(
      supplement.evidence.evidenceRevision,
      `${label}.evidence.evidenceRevision`,
    )
    if (!/^[0-9a-f]{40}$/.test(publishedGitHead) || !/^[0-9a-f]{40}$/.test(evidenceRevision)) {
      fail(`${label}.evidence revisions must be lowercase 40-character Git commits`)
    }
    const note = requireString(supplement.evidence.note, `${label}.evidence.note`)
    if (note.length < 80) fail(`${label}.evidence.note is too short to be auditable`)

    supplements.set(identity, {
      identity,
      declaredLicense,
      packageArtifact: { resolved, integrity },
      text: { filename, hash: actualHash, value: text },
      evidence: { kind, repository, publishedGitHead, evidenceRevision, note },
    })
  }
  return supplements
}

function canonicalRepository(value, label) {
  const raw = requireString(value, label)
  const canonical = raw.replace(/^git\+/, '').replace(/\.git$/, '')
  if (!/^https:\/\/[^/]+\/[^/]+\/[^/]+$/.test(canonical)) {
    fail(`${label} must be a canonical HTTPS repository URL`)
  }
  return canonical
}

function linkedTargetName(entry) {
  return `${entry.name.replace(/^@qvac\//, 'qvac__')}.${entry.version}`
}

function canonicalJSON(value) {
  if (Array.isArray(value)) return value.map(canonicalJSON)
  if (!plainObject(value)) return value
  return Object.fromEntries(
    Object.keys(value).sort().map(key => [key, canonicalJSON(value[key])]),
  )
}

function nativeClosureDefinitionSHA256(manifest) {
  const definition = {
    schemaVersion: manifest.schemaVersion,
    scope: manifest.scope,
    packageSourceCommits: manifest.packageSourceCommits,
    verifiedComponents: manifest.verifiedComponents,
    closureRequirements: manifest.closureRequirements?.map(requirement => ({
      id: requirement.id,
      affectedTargets: requirement.affectedTargets,
      missingEvidence: requirement.missingEvidence,
      action: requirement.action,
    })),
  }
  return sha256(JSON.stringify(canonicalJSON(definition)))
}

function validatePinnedNativeEvidence(record, label, evidenceRoot) {
  assertExactKeys(record, ['file', 'sha256', 'description'], label)
  const file = requireString(record.file, `${label}.file`)
  if (!file.startsWith(nativeEvidenceDirectory) || file.includes('\\')
      || file.split('/').some(component => component === '' || component === '.' || component === '..')) {
    fail(`${label}.file must be a safe child of ${nativeEvidenceDirectory}`)
  }
  const expectedHash = requireString(record.sha256, `${label}.sha256`)
  if (!/^[0-9a-f]{64}$/.test(expectedHash)) fail(`${label}.sha256 must be lowercase SHA-256`)
  if (requireString(record.description, `${label}.description`).length < 40) {
    fail(`${label}.description is too short to identify the evidence`)
  }
  const path = resolve(evidenceRoot, file)
  const rel = relative(evidenceRoot, path)
  if (rel === '..' || rel.startsWith(`..${sep}`)) fail(`${label}.file escaped its evidence root`)
  assertNoSymlinkComponents(path, evidenceRoot, 'native closure evidence')
  const metadata = lstatSync(path)
  if (!metadata.isFile() || metadata.size <= 0 || metadata.size > maximumNativeEvidenceBytes) {
    fail(`${label}.file must be a non-empty regular file no larger than ${maximumNativeEvidenceBytes} bytes`)
  }
  const actualHash = sha256(readFileSync(path))
  if (actualHash !== expectedHash) {
    fail(`${label}.sha256 mismatch: expected ${expectedHash}, got ${actualHash}`)
  }
  return { file, sha256: actualHash, description: record.description }
}

function validateNativeClosureResolution(
  resolution,
  label,
  scope,
  closureDefinitionSHA256,
  evidenceRoot,
) {
  if (resolution === null) return null
  assertExactKeys(resolution, ['boundInputs', 'evidenceFiles', 'review'], `${label}.resolution`)
  assertExactKeys(
    resolution.boundInputs,
    [
      'linkedTargetsManifestSHA256',
      'runtimeResolutionInventorySHA256',
      'runtimePackageLockSHA256',
      'nativeClosureDefinitionSHA256',
    ],
    `${label}.resolution.boundInputs`,
  )
  const expectedBindings = {
    linkedTargetsManifestSHA256: scope.linkedTargetsManifest.sha256,
    runtimeResolutionInventorySHA256: scope.runtimeResolutionInventory.sha256,
    runtimePackageLockSHA256: scope.runtimePackageLock.sha256,
    nativeClosureDefinitionSHA256: closureDefinitionSHA256,
  }
  for (const [field, expected] of Object.entries(expectedBindings)) {
    if (resolution.boundInputs[field] !== expected) {
      fail(`${label}.resolution.boundInputs.${field} does not bind the current audited input`)
    }
  }
  if (!Array.isArray(resolution.evidenceFiles) || resolution.evidenceFiles.length === 0) {
    fail(`${label}.resolution.evidenceFiles must contain concrete pinned local evidence`)
  }
  const evidenceFiles = resolution.evidenceFiles.map((record, index) =>
    validatePinnedNativeEvidence(record, `${label}.resolution.evidenceFiles.${index}`, evidenceRoot)
  )
  if (new Set(evidenceFiles.map(record => record.file)).size !== evidenceFiles.length) {
    fail(`${label}.resolution.evidenceFiles must not repeat a file`)
  }

  assertExactKeys(
    resolution.review,
    ['decision', 'reviewedAt', 'reviewer', 'record'],
    `${label}.resolution.review`,
  )
  if (resolution.review.decision !== 'approved-for-binary-publication') {
    fail(`${label}.resolution.review.decision must be approved-for-binary-publication`)
  }
  const reviewer = requireString(resolution.review.reviewer, `${label}.resolution.review.reviewer`)
  if (reviewer.length < 3) fail(`${label}.resolution.review.reviewer is too short`)
  const reviewedAt = requireString(resolution.review.reviewedAt, `${label}.resolution.review.reviewedAt`)
  const parsedReviewedAt = Date.parse(reviewedAt)
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(reviewedAt)
      || Number.isNaN(parsedReviewedAt)
      || new Date(parsedReviewedAt).toISOString() !== reviewedAt.replace('Z', '.000Z')) {
    fail(`${label}.resolution.review.reviewedAt must be an exact UTC timestamp`)
  }
  const record = validatePinnedNativeEvidence(
    resolution.review.record,
    `${label}.resolution.review.record`,
    evidenceRoot,
  )
  if (evidenceFiles.some(evidence => evidence.file === record.file)) {
    fail(`${label}.resolution.review.record must be distinct from the technical evidence files`)
  }
  return {
    boundInputs: resolution.boundInputs,
    evidenceFiles,
    review: { decision: resolution.review.decision, reviewedAt, reviewer, record },
  }
}

function validateNativeClosureManifest(
  manifest,
  release,
  inventory,
  packageLock,
  evidenceRoot = repositoryRoot,
) {
  assertExactKeys(
    manifest,
    ['schemaVersion', 'scope', 'packageSourceCommits', 'verifiedComponents', 'closureRequirements'],
    'native component manifest',
  )
  if (manifest.schemaVersion !== 1) fail('unsupported native component manifest schema version')
  assertExactKeys(
    manifest.scope,
    ['platforms', 'linkedTargetsManifest', 'runtimeResolutionInventory', 'runtimePackageLock'],
    'native component manifest scope',
  )
  const expectedPlatforms = ['ios-arm64', 'ios-arm64-simulator', 'ios-x64-simulator']
  if (!Array.isArray(manifest.scope.platforms)
      || JSON.stringify(manifest.scope.platforms) !== JSON.stringify(expectedPlatforms)) {
    fail(`native component manifest platforms must be exactly ${expectedPlatforms.join(', ')}`)
  }

  const pinnedInputs = [
    [manifest.scope.linkedTargetsManifest, 'tools/release/artifacts.development.json'],
    [manifest.scope.runtimeResolutionInventory, 'tools/runtime/resolution-inventory.json'],
    [manifest.scope.runtimePackageLock, 'tools/runtime/package-lock.json'],
  ]
  for (const [input, expectedFile] of pinnedInputs) {
    assertExactKeys(input, ['file', 'sha256'], `native input ${expectedFile}`)
    if (input.file !== expectedFile || !/^[0-9a-f]{64}$/.test(input.sha256)) {
      fail(`native input pin must identify ${expectedFile} with lowercase SHA-256`)
    }
    const path = resolve(repositoryRoot, input.file)
    if (relative(repositoryRoot, path).startsWith('..') || !existsSync(path)) {
      fail(`native input pin escaped the repository or is missing: ${input.file}`)
    }
    const actual = sha256(readFileSync(path))
    if (actual !== input.sha256) {
      fail(`native input ${input.file} changed: expected ${input.sha256}, got ${actual}; re-audit the native closure before updating the pin`)
    }
  }

  if (!Array.isArray(release.targets) || release.targets.length === 0
      || new Set(release.targets).size !== release.targets.length) {
    fail('linked target manifest must contain a non-empty unique target set')
  }
  if (!plainObject(manifest.packageSourceCommits)) {
    fail('native component manifest packageSourceCommits must be an object')
  }
  const inventoryByTarget = new Map()
  for (const entry of inventory.packages ?? []) {
    if (entry.nativeAddon || entry.name === 'react-native-bare-kit') {
      inventoryByTarget.set(linkedTargetName(entry), entry)
    }
  }
  const packageRecords = []
  const expectedIdentities = new Set()
  for (const target of release.targets) {
    const lookup = target === 'BareKit' ? 'react-native-bare-kit.0.15.0' : target
    const entry = inventoryByTarget.get(lookup)
    if (!entry) fail(`native linked target has no exact runtime inventory package: ${target}`)
    const identity = `${entry.name}@${entry.version}`
    expectedIdentities.add(identity)
    const sourceCommit = manifest.packageSourceCommits[identity]
    if (!/^[0-9a-f]{40}$/.test(sourceCommit ?? '')) {
      fail(`native linked package ${identity} lacks a lowercase 40-character npm gitHead`)
    }
    const locked = packageLock.packages?.[entry.path]
    if (locked?.version !== entry.version || locked?.resolved !== entry.resolved
        || locked?.integrity !== entry.integrity) {
      fail(`native linked package ${identity} differs between inventory and package lock`)
    }
    const packageJsonPath = resolve(runtimeRoot, entry.path, 'package.json')
    assertNoSymlinkComponents(packageJsonPath, runtimeRoot, 'native package metadata')
    const metadata = JSON.parse(readFileSync(packageJsonPath, 'utf8'))
    if (metadata.name !== entry.name || metadata.version !== entry.version) {
      fail(`native package metadata identity differs from lock: ${identity}`)
    }
    const sourceRepository = canonicalRepository(
      typeof metadata.repository === 'string' ? metadata.repository : metadata.repository?.url,
      `${identity} repository`,
    )
    packageRecords.push({ target, identity, sourceRepository, sourceCommit, resolved: entry.resolved })
  }
  const declaredIdentities = Object.keys(manifest.packageSourceCommits)
  const unexpectedIdentities = declaredIdentities.filter(identity => !expectedIdentities.has(identity))
  const missingIdentities = [...expectedIdentities].filter(identity => !(identity in manifest.packageSourceCommits))
  if (unexpectedIdentities.length || missingIdentities.length) {
    fail(`native package source coverage differs from linked targets; missing: ${missingIdentities.join(', ') || 'none'}; unexpected: ${unexpectedIdentities.join(', ') || 'none'}`)
  }

  if (!Array.isArray(manifest.verifiedComponents)) {
    fail('native component manifest verifiedComponents must be an array')
  }
  const componentNames = new Set()
  for (const [index, component] of manifest.verifiedComponents.entries()) {
    const label = `verified native component ${index}`
    assertExactKeys(component, ['name', 'license', 'parentTargets', 'source', 'licenseFiles', 'evidence'], label)
    const name = requireString(component.name, `${label}.name`)
    if (componentNames.has(name)) fail(`duplicate verified native component: ${name}`)
    componentNames.add(name)
    requireString(component.license, `${label}.license`)
    if (!Array.isArray(component.parentTargets) || component.parentTargets.length === 0
        || new Set(component.parentTargets).size !== component.parentTargets.length
        || component.parentTargets.some(target => !release.targets.includes(target))) {
      fail(`${label}.parentTargets must be a non-empty unique subset of linked targets`)
    }
    assertExactKeys(component.source, ['repository', 'revision'], `${label}.source`)
    canonicalRepository(component.source.repository, `${label}.source.repository`)
    if (!/^[0-9a-f]{40}$/.test(component.source.revision)) {
      fail(`${label}.source.revision must be a lowercase 40-character commit`)
    }
    if (!Array.isArray(component.licenseFiles) || component.licenseFiles.length === 0) {
      fail(`${label}.licenseFiles must contain at least one exact upstream license text`)
    }
    const licensePaths = new Set()
    for (const [licenseIndex, licenseFile] of component.licenseFiles.entries()) {
      const licenseLabel = `${label}.licenseFiles.${licenseIndex}`
      assertExactKeys(licenseFile, ['path', 'url', 'sha256'], licenseLabel)
      const path = requireString(licenseFile.path, `${licenseLabel}.path`)
      if (!/^[A-Za-z0-9][A-Za-z0-9._/-]*$/.test(path) || path.split('/').includes('..')
          || licensePaths.has(path)) {
        fail(`${licenseLabel}.path must be a unique safe relative source path`)
      }
      licensePaths.add(path)
      const url = requireString(licenseFile.url, `${licenseLabel}.url`)
      if (!url.startsWith('https://') || !url.includes(`/${component.source.revision}/`)) {
        fail(`${licenseLabel}.url must be HTTPS and bind the exact component source revision`)
      }
      if (!/^[0-9a-f]{64}$/.test(licenseFile.sha256)) {
        fail(`${licenseLabel}.sha256 must be lowercase SHA-256`)
      }
    }
    if (requireString(component.evidence, `${label}.evidence`).length < 80) {
      fail(`${label}.evidence is too short to be auditable`)
    }
  }

  if (!Array.isArray(manifest.closureRequirements)) {
    fail('native component manifest closureRequirements must be an array')
  }
  const actualRequirementIDs = manifest.closureRequirements.map(requirement => requirement?.id)
  if (JSON.stringify(actualRequirementIDs) !== JSON.stringify(requiredNativeClosureRequirementIDs)) {
    fail(`native closure requirements must be exactly: ${requiredNativeClosureRequirementIDs.join(', ')}`)
  }
  const closureDefinitionHash = nativeClosureDefinitionSHA256(manifest)
  const requirements = []
  for (const [index, requirement] of manifest.closureRequirements.entries()) {
    const label = `native closure requirement ${index}`
    assertExactKeys(
      requirement,
      ['id', 'affectedTargets', 'missingEvidence', 'action', 'resolution'],
      label,
    )
    const id = requireString(requirement.id, `${label}.id`)
    if (!Array.isArray(requirement.affectedTargets) || requirement.affectedTargets.length === 0
        || new Set(requirement.affectedTargets).size !== requirement.affectedTargets.length
        || requirement.affectedTargets.some(target => !release.targets.includes(target))) {
      fail(`${label}.affectedTargets must be a non-empty unique subset of linked targets`)
    }
    if (requireString(requirement.missingEvidence, `${label}.missingEvidence`).length < 80
        || requireString(requirement.action, `${label}.action`).length < 80) {
      fail(`${label} must explain both missing evidence and the exact remediation`)
    }
    requirements.push({
      ...requirement,
      id,
      resolution: validateNativeClosureResolution(
        requirement.resolution,
        label,
        manifest.scope,
        closureDefinitionHash,
        evidenceRoot,
      ),
    })
  }
  const unresolved = requirements.filter(requirement => requirement.resolution === null)
  return {
    [validatedNativeClosure]: true,
    packageRecords,
    components: manifest.verifiedComponents,
    requirements,
    blockers: unresolved,
  }
}

function loadNativeClosureManifest() {
  const manifest = JSON.parse(normalizedText(nativeManifestPath))
  const release = JSON.parse(readFileSync(resolve(repositoryRoot, 'tools/release/artifacts.development.json'), 'utf8'))
  const inventory = JSON.parse(readFileSync(inventoryPath, 'utf8'))
  const packageLock = JSON.parse(readFileSync(packageLockPath, 'utf8'))
  return validateNativeClosureManifest(manifest, release, inventory, packageLock)
}

function assertNativeClosureComplete(nativeClosure) {
  const requirements = nativeClosure?.requirements
  if (nativeClosure?.[validatedNativeClosure] !== true
      || !Array.isArray(requirements)
      || JSON.stringify(requirements.map(requirement => requirement?.id))
        !== JSON.stringify(requiredNativeClosureRequirementIDs)) {
    fail('binary publication blocked because the mandatory native closure requirement ledger is absent or incomplete')
  }
  const unresolved = requirements.filter(requirement => !plainObject(requirement.resolution))
  if (unresolved.length === 0) return
  const ids = unresolved.map(requirement => requirement.id).join(', ')
  fail(`binary publication blocked by ${unresolved.length} unresolved native-component closure gap(s): ${ids}; see THIRD_PARTY_NOTICES.md and tools/release/native-components.json`)
}

function enforceNativeClosureForCheck(mode, nativeClosure) {
  if (mode === '--check') return
  if (mode === '--check-publication') {
    assertNativeClosureComplete(nativeClosure)
    return
  }
  fail(`unsupported notices check mode: ${mode}`)
}

function readBundlePackages(path) {
  const bytes = readFileSync(path)
  const firstNewline = bytes.indexOf(0x0a)
  const secondNewline = bytes.indexOf(0x0a, firstNewline + 1)
  if (firstNewline < 1 || secondNewline < 0) fail('worker bundle has invalid header framing')
  let header
  try { header = JSON.parse(bytes.subarray(firstNewline + 1, secondNewline).toString('utf8')) } catch (error) {
    fail(`worker bundle header is invalid: ${error.message}`)
  }
  const bodyOffset = secondNewline + 1
  const packages = []
  for (const [embeddedPath, file] of Object.entries(header.files ?? {})) {
    if (!embeddedPath.endsWith('/package.json') || embeddedPath === '/../../package.json') continue
    if (!Number.isSafeInteger(file.offset) || !Number.isSafeInteger(file.length)
        || file.offset < 0 || file.length <= 0 || bodyOffset + file.offset + file.length > bytes.length) {
      fail(`embedded package metadata has invalid range: ${embeddedPath}`)
    }
    let metadata
    try {
      metadata = JSON.parse(bytes.subarray(
        bodyOffset + file.offset,
        bodyOffset + file.offset + file.length,
      ).toString('utf8'))
    } catch (error) {
      fail(`embedded package metadata is invalid (${embeddedPath}): ${error.message}`)
    }
    // Zod includes export-subpath package.json files without package identity.
    // Their parent zod package is independently included and attributed.
    if (metadata.name === undefined && metadata.version === undefined && metadata.license === undefined) continue
    if (typeof metadata.name !== 'string' || typeof metadata.version !== 'string'
        || typeof metadata.license !== 'string' || metadata.license.length === 0) {
      fail(`embedded package lacks name/version/license metadata: ${embeddedPath}`)
    }
    const prefix = '/../../'
    if (!embeddedPath.startsWith(prefix)) fail(`unexpected embedded package path: ${embeddedPath}`)
    const relativePackagePath = embeddedPath.slice(prefix.length)
    if (!relativePackagePath.startsWith('node_modules/') || relativePackagePath.includes('..')
        || relativePackagePath.includes('\\')) {
      fail(`unsafe embedded package path: ${embeddedPath}`)
    }
    packages.push({ embeddedPath, relativePackagePath, metadata })
  }
  return packages
}

function packageSource(metadata) {
  const repository = typeof metadata.repository === 'string'
    ? metadata.repository
    : metadata.repository?.url
  return metadata.homepage ?? repository ?? ''
}

function authorText(author) {
  if (typeof author === 'string') return author
  if (author && typeof author === 'object') {
    return [author.name, author.email && `<${author.email}>`, author.url]
      .filter(Boolean).join(' ')
  }
  return ''
}

function sorted(values) {
  return [...values].sort((left, right) => left < right ? -1 : left > right ? 1 : 0)
}

function markdownCell(value) {
  return String(value ?? '').replaceAll('|', '\\|').replaceAll('\n', ' ')
}

function sourceCommitURL(repository, revision) {
  return repository.startsWith('https://code.videolan.org/')
    ? `${repository}/-/commit/${revision}`
    : `${repository}/commit/${revision}`
}

function indented(text) {
  return text.trimEnd().split('\n').map(line => line.length === 0 ? '' : `    ${line}`).join('\n')
}

function writeOutputSafely(path, contents) {
  let descriptor
  try {
    descriptor = openSync(
      path,
      constants.O_WRONLY | constants.O_CREAT | constants.O_TRUNC | constants.O_NOFOLLOW,
      0o644,
    )
  } catch (error) {
    fail(`refusing unsafe notices output ${path}: ${error.message}`)
  }
  try {
    if (!fstatSync(descriptor).isFile()) fail(`notices output is not a regular file: ${path}`)
    writeFileSync(descriptor, contents, 'utf8')
  } finally {
    closeSync(descriptor)
  }
}

function selfTestOutputSafety() {
  const directory = mkdtempSync(join(tmpdir(), 'qvac-notices-safety-'))
  try {
    const victim = join(directory, 'victim')
    const output = join(directory, 'THIRD_PARTY_NOTICES.md')
    writeFileSync(victim, 'must-survive\n')
    symlinkSync(victim, output)
    let rejected = false
    try { writeOutputSafely(output, 'overwrite\n') } catch { rejected = true }
    if (!rejected || readFileSync(victim, 'utf8') !== 'must-survive\n') {
      fail('symlink-output self-test did not reject the write and preserve its target')
    }
    console.log('[third-party-notices-test] symlink output rejected and victim preserved')

    const fixtureRoot = join(directory, 'license-supplements')
    const fixtureManifestPath = join(directory, 'license-supplements.json')
    const fixtureTextPath = join(fixtureRoot, 'fixture-MIT.txt')
    const fixtureText = 'fixture license text\n'
    mkdirSync(fixtureRoot)
    const fixture = {
      schemaVersion: 1,
      reviewStatus: 'maintainer-review-required',
      supplements: [{
        identity: 'fixture@1.0.0',
        declaredLicense: 'MIT',
        packageArtifact: {
          resolved: 'https://registry.npmjs.org/fixture/-/fixture-1.0.0.tgz',
          integrity: `sha512-${'A'.repeat(86)}==`,
        },
        text: {
          file: 'fixture-MIT.txt',
          sha256: sha256(fixtureText),
        },
        evidence: {
          kind: 'spdx-and-repository-authorship',
          repository: 'https://github.com/example/fixture',
          publishedGitHead: '1'.repeat(40),
          evidenceRevision: '2'.repeat(40),
          note: 'Fixture evidence note is intentionally long enough to exercise strict supplement manifest validation safely.',
        },
      }],
    }
    writeFileSync(fixtureManifestPath, `${JSON.stringify(fixture)}\n`)
    symlinkSync(victim, fixtureTextPath)
    rejected = false
    try { loadLicenseSupplements(fixtureManifestPath, fixtureRoot) } catch { rejected = true }
    if (!rejected || readFileSync(victim, 'utf8') !== 'must-survive\n') {
      fail('symlink supplement self-test did not reject the input and preserve its target')
    }
    rmSync(fixtureTextPath)
    writeFileSync(fixtureTextPath, fixtureText)
    fixture.supplements[0].text.sha256 = '0'.repeat(64)
    writeFileSync(fixtureManifestPath, `${JSON.stringify(fixture)}\n`)
    rejected = false
    try { loadLicenseSupplements(fixtureManifestPath, fixtureRoot) } catch { rejected = true }
    if (!rejected) fail('supplement hash self-test accepted modified text')
    fixture.supplements[0].text.sha256 = sha256(fixtureText)
    writeFileSync(fixtureManifestPath, `${JSON.stringify(fixture)}\n`)
    if (loadLicenseSupplements(fixtureManifestPath, fixtureRoot).size !== 1) {
      fail('valid supplement self-test did not load exactly one entry')
    }
    console.log('[third-party-notices-test] supplements reject symlinks/hash drift and accept exact input')
  } finally {
    rmSync(directory, { recursive: true, force: true })
  }
}

function selfTestNativeClosure() {
  const manifest = JSON.parse(normalizedText(nativeManifestPath))
  const release = JSON.parse(readFileSync(resolve(repositoryRoot, 'tools/release/artifacts.development.json'), 'utf8'))
  const inventory = JSON.parse(readFileSync(inventoryPath, 'utf8'))
  const packageLock = JSON.parse(readFileSync(packageLockPath, 'utf8'))
  const valid = validateNativeClosureManifest(manifest, release, inventory, packageLock)
  if (valid.packageRecords.length !== release.targets.length
      || valid.requirements.length !== requiredNativeClosureRequirementIDs.length
      || valid.blockers.length !== requiredNativeClosureRequirementIDs.length) {
    fail('native closure self-test fixture did not expose the exact target set and required closure ledger')
  }

  function expectRejected(mutator, label) {
    const fixture = JSON.parse(JSON.stringify(manifest))
    mutator(fixture)
    let rejected = false
    try { validateNativeClosureManifest(fixture, release, inventory, packageLock) } catch { rejected = true }
    if (!rejected) fail(`native closure self-test accepted ${label}`)
  }
  expectRejected(
    fixture => { fixture.packageSourceCommits['bare-ffmpeg@1.5.0'] = 'not-a-commit' },
    'an invalid npm gitHead',
  )
  expectRejected(
    fixture => { delete fixture.packageSourceCommits['sodium-native@5.1.0'] },
    'a missing linked-package source revision',
  )
  expectRejected(
    fixture => { fixture.verifiedComponents[0].parentTargets = ['not-a-linked-target'] },
    'an unlinked native component parent',
  )
  expectRejected(
    fixture => { fixture.verifiedComponents[0].licenseFiles[0].sha256 = 'not-a-hash' },
    'an invalid native license-text hash',
  )
  expectRejected(
    fixture => { delete fixture.closureRequirements },
    'a deleted native closure requirement ledger',
  )
  expectRejected(
    fixture => { fixture.closureRequirements = [] },
    'an empty native closure requirement ledger',
  )
  expectRejected(
    fixture => { fixture.closureRequirements.pop() },
    'a missing mandatory native closure requirement',
  )
  // Freshness checks may run while publication requirements are open. The
  // publication mode requires every item to be resolved.
  enforceNativeClosureForCheck('--check', valid)
  let completenessRejected = false
  try {
    enforceNativeClosureForCheck('--check-publication', { ...valid, blockers: [] })
  } catch (error) {
    completenessRejected = String(error.message).includes(valid.requirements[0].id)
  }
  if (!completenessRejected) {
    fail('native closure self-test let an emptied derived blocker list bypass unresolved requirements')
  }

  const evidenceRoot = mkdtempSync(join(tmpdir(), 'qvac-native-closure-evidence-'))
  try {
    const evidenceDirectory = resolve(evidenceRoot, nativeEvidenceDirectory)
    mkdirSync(evidenceDirectory, { recursive: true })
    const technicalFile = join(evidenceDirectory, 'technical-evidence.json')
    const reviewFile = join(evidenceDirectory, 'publication-review.md')
    const technicalBytes = '{"fixture":"exact native closure evidence"}\n'
    const reviewBytes = '# Fixture publication review\n\nAll native closure evidence was reviewed.\n'
    writeFileSync(technicalFile, technicalBytes)
    writeFileSync(reviewFile, reviewBytes)
    const completedManifest = JSON.parse(JSON.stringify(manifest))
    const boundInputs = {
      linkedTargetsManifestSHA256: manifest.scope.linkedTargetsManifest.sha256,
      runtimeResolutionInventorySHA256: manifest.scope.runtimeResolutionInventory.sha256,
      runtimePackageLockSHA256: manifest.scope.runtimePackageLock.sha256,
      nativeClosureDefinitionSHA256: nativeClosureDefinitionSHA256(completedManifest),
    }
    for (const requirement of completedManifest.closureRequirements) {
      requirement.resolution = {
        boundInputs,
        evidenceFiles: [{
          file: `${nativeEvidenceDirectory}technical-evidence.json`,
          sha256: sha256(technicalBytes),
          description: 'Synthetic exact technical closure report used only by the adversarial self-test.',
        }],
        review: {
          decision: 'approved-for-binary-publication',
          reviewedAt: '2026-09-01T00:00:00Z',
          reviewer: 'Self-test reviewer',
          record: {
            file: `${nativeEvidenceDirectory}publication-review.md`,
            sha256: sha256(reviewBytes),
            description: 'Synthetic independent publication approval record used only by the adversarial self-test.',
          },
        },
      }
    }
    const completed = validateNativeClosureManifest(
      completedManifest,
      release,
      inventory,
      packageLock,
      evidenceRoot,
    )
    enforceNativeClosureForCheck('--check-publication', completed)

    writeFileSync(technicalFile, '{"fixture":"tampered"}\n')
    let tamperedEvidenceRejected = false
    try {
      validateNativeClosureManifest(completedManifest, release, inventory, packageLock, evidenceRoot)
    } catch (error) {
      tamperedEvidenceRejected = String(error.message).includes('sha256 mismatch')
    }
    if (!tamperedEvidenceRejected) {
      fail('native closure self-test accepted modified local remediation evidence')
    }
    writeFileSync(technicalFile, technicalBytes)
    const driftedDefinition = JSON.parse(JSON.stringify(completedManifest))
    driftedDefinition.closureRequirements[0].action += ' Drifted after approval.'
    let driftedDefinitionRejected = false
    try {
      validateNativeClosureManifest(
        driftedDefinition,
        release,
        inventory,
        packageLock,
        evidenceRoot,
      )
    } catch (error) {
      driftedDefinitionRejected = String(error.message).includes('does not bind the current audited input')
    }
    if (!driftedDefinitionRejected) {
      fail('native closure self-test accepted closure-definition drift after approval')
    }
    const missingReview = JSON.parse(JSON.stringify(completedManifest))
    missingReview.closureRequirements[0].resolution.review.decision = 'pending'
    let missingReviewRejected = false
    try {
      validateNativeClosureManifest(missingReview, release, inventory, packageLock, evidenceRoot)
    } catch (error) {
      missingReviewRejected = String(error.message).includes('approved-for-binary-publication')
    }
    if (!missingReviewRejected) fail('native closure self-test accepted an unapproved review decision')
  } finally {
    rmSync(evidenceRoot, { recursive: true, force: true })
  }

  const artifactWorkflow = normalizedText(resolve(repositoryRoot, '.github/workflows/build-artifacts.yml'))
  if (!/- name: [^\n]+\n\s+if: inputs\.publish\n\s+run: \|\n\s+node tools\/release\/generate-third-party-notices\.mjs --check-publication\n/.test(artifactWorkflow)) {
    fail('native closure self-test found no fail-closed gate in the artifact publication branch')
  }
  const sourceWorkflow = normalizedText(resolve(repositoryRoot, '.github/workflows/release.yml'))
  if (!/- name: [^\n]+\n\s+run: \|\n\s+node tools\/release\/generate-third-party-notices\.mjs --check-publication\n/.test(sourceWorkflow)) {
    fail('native closure self-test found no fail-closed gate in the source publication workflow')
  }
  console.log('[third-party-notices-test] native target drift, source pins, mandatory requirements, byte-bound evidence, review metadata, and both publication gates enforced')
}

function collectNotices() {
  verifyBundle(bundlePath)
  const inventory = JSON.parse(readFileSync(inventoryPath, 'utf8'))
  const packageLock = JSON.parse(readFileSync(packageLockPath, 'utf8'))
  const supplements = loadLicenseSupplements()
  const nativeClosure = loadNativeClosureManifest()
  const inventoryByPath = new Map((inventory.packages ?? []).map(entry => [entry.path, entry]))
  const identities = new Map()
  const textGroups = new Map()
  const packagePayloads = readBundlePackages(bundlePath)

  for (const relativePackagePath of additionalNativePackagePaths) {
    const packageJsonPath = resolve(runtimeRoot, relativePackagePath)
    const rel = relative(runtimeRoot, packageJsonPath)
    if (rel === '..' || rel.startsWith(`..${sep}`) || rel !== relativePackagePath) {
      fail(`unsafe native-closure package path: ${relativePackagePath}`)
    }
    if (!existsSync(packageJsonPath)) {
      fail(`native-closure package metadata is missing: ${relativePackagePath}`)
    }
    const metadata = JSON.parse(readFileSync(packageJsonPath, 'utf8'))
    if (typeof metadata.name !== 'string' || typeof metadata.version !== 'string'
        || typeof metadata.license !== 'string' || metadata.license.length === 0) {
      fail(`native-closure package lacks name/version/license metadata: ${relativePackagePath}`)
    }
    packagePayloads.push({
      embeddedPath: `[native closure]/${relativePackagePath}`,
      relativePackagePath,
      metadata,
    })
  }

  for (const embedded of packagePayloads) {
    const packageJsonPath = resolve(runtimeRoot, embedded.relativePackagePath)
    const packageDirectory = dirname(packageJsonPath)
    const rel = relative(runtimeRoot, packageJsonPath)
    if (rel === '..' || rel.startsWith(`..${sep}`) || !existsSync(packageJsonPath)) {
      fail(`installed package metadata is missing or escaped runtime root: ${embedded.relativePackagePath}`)
    }
    assertNoSymlinkComponents(packageJsonPath, runtimeRoot, 'installed package metadata')
    const packageStat = lstatSync(packageJsonPath)
    if (packageStat.isSymbolicLink() || !packageStat.isFile()) fail(`package metadata is not a regular file: ${packageJsonPath}`)
    const installed = JSON.parse(readFileSync(packageJsonPath, 'utf8'))
    for (const field of ['name', 'version', 'license']) {
      if (installed[field] !== embedded.metadata[field]) {
        fail(`${embedded.relativePackagePath} ${field} differs between worker and exact runtime`)
      }
    }

    const packagePath = dirname(embedded.relativePackagePath)
    const locked = inventoryByPath.get(packagePath)
      ?? packageLock.packages?.[packagePath]
      ?? (inventory.packages ?? []).find(entry => entry.name === installed.name && entry.version === installed.version)
    if (locked?.version !== installed.version || !locked?.resolved || !locked?.integrity) {
      fail(`runtime lock lacks immutable source for ${installed.name}@${installed.version}`)
    }

    const identity = `${installed.name}@${installed.version}`
    const entry = identities.get(identity) ?? {
      name: installed.name,
      version: installed.version,
      license: installed.license,
      author: authorText(installed.author),
      source: packageSource(installed),
      resolved: new Set(),
      paths: new Set(),
      licenseHashes: new Set(),
      noticeHashes: new Set(),
      artifacts: new Set(),
      supplement: undefined,
    }
    if (entry.license !== installed.license) fail(`conflicting license expressions for ${identity}`)
    entry.resolved.add(locked.resolved)
    entry.artifacts.add(artifactKey(locked.resolved, locked.integrity))
    entry.paths.add(packagePath)

    for (const filename of readdirSync(packageDirectory)) {
      const kind = /^(licen[cs]e|copying)(\.|$)/i.test(filename)
        ? 'license'
        : /^notice(\.|$)/i.test(filename) ? 'notice' : undefined
      if (!kind) continue
      const path = join(packageDirectory, filename)
      const text = normalizedText(path)
      const hash = sha256(text)
      const group = textGroups.get(hash) ?? { hash, kind, text, packages: new Set() }
      if (group.kind !== kind || group.text !== text) fail(`notice hash collision for ${identity}/${filename}`)
      group.packages.add(identity)
      textGroups.set(hash, group)
      entry[kind === 'license' ? 'licenseHashes' : 'noticeHashes'].add(hash)
    }
    identities.set(identity, entry)
  }

  const unusedSupplements = new Set(supplements.keys())
  for (const [identity, entry] of identities) {
    const supplement = supplements.get(identity)
    if (!supplement) continue
    unusedSupplements.delete(identity)
    if (entry.license !== supplement.declaredLicense) {
      fail(`license supplement expression differs from exact package metadata for ${identity}`)
    }
    if (!entry.artifacts.has(artifactKey(
      supplement.packageArtifact.resolved,
      supplement.packageArtifact.integrity,
    ))) {
      fail(`license supplement is not bound to the exact locked npm artifact for ${identity}`)
    }
    if (entry.licenseHashes.size !== 0) {
      fail(`license supplement for ${identity} is stale because the exact package now provides license text`)
    }
    entry.supplement = supplement
  }
  if (unusedSupplements.size !== 0) {
    fail(`license supplements do not map to shipped package identities: ${sorted(unusedSupplements).join(', ')}`)
  }

  const uncovered = [...identities.entries()]
    .filter(([, entry]) => entry.licenseHashes.size === 0 && entry.supplement === undefined)
    .map(([identity]) => identity)
  if (uncovered.length !== 0) {
    fail(`shipped packages remain without full license text: ${sorted(uncovered).join(', ')}`)
  }

  return {
    identities: sorted(identities.keys()).map(identity => [identity, identities.get(identity)]),
    textGroups: sorted(textGroups.keys()).map(hash => textGroups.get(hash)),
    supplements: sorted(supplements.keys()).map(identity => supplements.get(identity)),
    nativeClosure,
  }
}

function render() {
  const { identities, textGroups, supplements, nativeClosure } = collectNotices()
  const licenseCounts = new Map()
  for (const [, entry] of identities) licenseCounts.set(entry.license, (licenseCounts.get(entry.license) ?? 0) + 1)
  const packageTextCount = identities.filter(([, entry]) => entry.licenseHashes.size !== 0).length
  const supplementedCount = identities.filter(([, entry]) => entry.supplement !== undefined).length
  const lines = [
    '# Third-Party Notices',
    '',
    '> Generated by `tools/release/generate-third-party-notices.mjs` from the',
    '> packaged worker, native dependency inventory, runtime lockfile, and the',
    '> license evidence under `tools/release/`.',
    '> Do not edit this file by hand.',
    '',
    'QVACClient distributes third-party software in its worker bundle and native',
    'iOS artifacts. This file lists the package identities, source revisions,',
    'license texts, and supplemental attribution evidence for that distribution.',
    '',
    `Inventory: ${identities.length} unique package identities; ${packageTextCount} include one or more license-text payloads in the exact package; ${supplementedCount} omit a license file and are covered by pinned supplemental texts; 0 remain without full license text.`,
    '',
    'This generated record is engineering evidence, not legal advice. A maintainer',
    'must review the applicable terms—including native libraries and every',
    'supplement below—and the native-closure publication gate must pass before',
    'binary publication. Setting `license_reviewed=true` does not override a blocker.',
    '',
    '## Native binary closure',
    '',
    'The table below is the exact iOS link set. Each npm package is bound to the',
    'immutable tarball URL/SRI in `tools/runtime/package-lock.json`, the pinned',
    'input-file digests in `tools/release/native-components.json`, and the npm',
    '`gitHead` recorded here. This establishes source identity for every top-level',
    'binary target; it does not waive the transitive blockers listed below.',
    '',
    '| Linked target | Package | Source revision | Immutable npm artifact |',
    '|---|---|---|---|',
    ...nativeClosure.packageRecords.map(record =>
      `| ${markdownCell(record.target)} | ${markdownCell(record.identity)} | [\`${record.sourceCommit}\`](${sourceCommitURL(record.sourceRepository, record.sourceCommit)}) | ${markdownCell(record.resolved)} |`
    ),
    '',
    '### Verified native component revisions',
    '',
    'The license-text links below are immutable upstream references whose bytes are',
    'fingerprinted in the manifest. They are audit evidence, not a claim that the',
    'current binary distribution already includes every required license payload.',
    '',
    '| Component | License expression | Linked through | Exact source revision | Pinned upstream license text | Evidence |',
    '|---|---|---|---|---|---|',
    ...nativeClosure.components.map(component =>
      `| ${markdownCell(component.name)} | ${markdownCell(component.license)} | ${markdownCell(component.parentTargets.join(', '))} | [\`${component.source.revision}\`](${sourceCommitURL(component.source.repository, component.source.revision)}) | ${component.licenseFiles.map(file => `[${markdownCell(file.path)}](${file.url}) \`${file.sha256}\``).join('<br>')} | ${markdownCell(component.evidence)} |`
    ),
    '',
    '### Native-closure publication requirements',
    '',
  ]

  if (nativeClosure.blockers.length === 0) {
    lines.push(
      'All mandatory closure requirements have concrete byte-bound local evidence',
      'and an independent `approved-for-binary-publication` review record.',
      '',
    )
  } else {
    lines.push(
      `Binary publication is blocked by ${nativeClosure.blockers.length} unresolved native-component evidence gap(s).`,
      'Do not publish binary artifacts until every item below is resolved and this',
      'generator passes `--check-publication`.',
      '',
    )
    for (const blocker of nativeClosure.blockers) {
      lines.push(
        `#### \`${blocker.id}\``,
        '',
        `Affected linked targets: ${blocker.affectedTargets.map(target => `\`${target}\``).join(', ')}`,
        '',
        `Missing evidence: ${blocker.missingEvidence}`,
        '',
        `Required action: ${blocker.action}`,
        '',
      )
    }
  }

  const resolvedRequirements = nativeClosure.requirements.filter(
    requirement => requirement.resolution !== null,
  )
  if (resolvedRequirements.length > 0) {
    lines.push(
      '#### Positively resolved native-closure requirements',
      '',
      '| Requirement | Reviewer | Reviewed at | Technical evidence | Review record |',
      '|---|---|---|---|---|',
      ...resolvedRequirements.map(requirement => {
        const resolution = requirement.resolution
        const evidence = resolution.evidenceFiles.map(record =>
          `\`${markdownCell(record.file)}\` \`${record.sha256}\``
        ).join('<br>')
        const review = resolution.review.record
        return `| ${markdownCell(requirement.id)} | ${markdownCell(resolution.review.reviewer)} | ${markdownCell(resolution.review.reviewedAt)} | ${evidence} | \`${markdownCell(review.file)}\` \`${review.sha256}\` |`
      }),
      '',
    )
  }

  lines.push(
    '## License-expression summary',
    '',
    '| Expression | Packages |',
    '|---|---:|',
    ...sorted(licenseCounts.keys()).map(license => `| ${markdownCell(license)} | ${licenseCounts.get(license)} |`),
    '',
    '## Pinned supplemental license texts',
    '',
    'The exact npm artifacts below declare the shown SPDX license expression but',
    'publish no `LICENSE`, `LICENCE`, or `COPYING` file. The committed supplement',
    'manifest binds each text to the exact npm URL and SRI integrity, its evidence',
    'revisions, and the text SHA-256. These are engineering-prepared attribution',
    'supplements—not files represented as present in the npm tarballs—and require',
    'maintainer/legal review before publication.',
    '',
  )

  if (supplements.length === 0) {
    lines.push('None.', '')
  } else {
    for (const supplement of supplements) {
      lines.push(
        `### ${supplement.identity} — ${supplement.declaredLicense}`,
        '',
        `Immutable npm artifact: ${supplement.packageArtifact.resolved}`,
        '',
        `Npm SRI: \`${supplement.packageArtifact.integrity}\``,
        '',
        `Supplement text SHA-256: \`${supplement.text.hash}\``,
        '',
        `Evidence basis: \`${supplement.evidence.kind}\``,
        '',
        `Repository: ${supplement.evidence.repository}`,
        '',
        `Published npm gitHead: \`${supplement.evidence.publishedGitHead}\``,
        '',
        `Evidence revision: \`${supplement.evidence.evidenceRevision}\``,
        '',
        `Evidence note: ${supplement.evidence.note}`,
        '',
        indented(supplement.text.value),
        '',
      )
    }
  }

  lines.push(
    '## Unresolved license-text gaps',
    '',
    'None. Generation fails if a shipped package has neither package-provided',
    'license text nor an exact-artifact-bound supplement, or if a supplement is',
    'stale, unused, mismatched, modified, or symlinked.',
    '',
    '## Package inventory',
    '',
    '| Package | Declared license | Immutable npm artifact |',
    '|---|---|---|',
    ...identities.map(([identity, entry]) =>
      `| ${markdownCell(identity)} | ${markdownCell(entry.license)} | ${markdownCell(sorted(entry.resolved).join('<br>'))} |`
    ),
    '',
    '## Included package-provided license and notice texts',
    '',
  )

  for (const group of textGroups) {
    lines.push(
      `### ${group.kind === 'license' ? 'License' : 'Notice'} \`${group.hash}\``,
      '',
      `Applies to: ${sorted(group.packages).map(identity => `\`${identity}\``).join(', ')}`,
      '',
      indented(group.text),
      '',
    )
  }
  return lines.join('\n').replace(/\n{3,}/g, '\n\n').trimEnd() + '\n'
}

const expected = render()
if (process.argv[2] === '--check' || process.argv[2] === '--check-publication') {
  if (!existsSync(outputPath)) fail('THIRD_PARTY_NOTICES.md is missing')
  const metadata = lstatSync(outputPath)
  if (metadata.isSymbolicLink() || !metadata.isFile()) {
    fail('THIRD_PARTY_NOTICES.md must be a regular non-symlink file')
  }
  if (readFileSync(outputPath, 'utf8') !== expected) {
    fail('THIRD_PARTY_NOTICES.md is missing or stale; regenerate with this script')
  }
  console.log('[third-party-notices] committed notices are fresh')
  enforceNativeClosureForCheck(process.argv[2], loadNativeClosureManifest())
} else if (process.argv[2] === '--self-test') {
  selfTestOutputSafety()
  selfTestNativeClosure()
} else if (process.argv.length === 2) {
  writeOutputSafely(outputPath, expected)
  console.log(`[third-party-notices] wrote exact embedded-package notices -> ${outputPath}`)
} else {
  fail('usage: generate-third-party-notices.mjs [--check|--check-publication|--self-test]')
}
