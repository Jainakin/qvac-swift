#!/usr/bin/env node

import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import {
  existsSync,
  lstatSync,
  readFileSync,
  readdirSync,
} from 'node:fs'
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path'
import { domainToASCII, fileURLToPath } from 'node:url'

const scriptPath = fileURLToPath(import.meta.url)
const scriptDirectory = dirname(scriptPath)
const repositoryRoot = resolve(scriptDirectory, '../..')
const defaultAuditPath = resolve(scriptDirectory, 'privacy-manifest-audit.json')
const developmentManifestPath = resolve(scriptDirectory, 'artifacts.development.json')
const buildArtifactsWorkflowPath = resolve(repositoryRoot, '.github/workflows/build-artifacts.yml')
const sourceReleaseWorkflowPath = resolve(repositoryRoot, '.github/workflows/release.yml')
const maximumManifestBytes = 1024 * 1024
const hashPattern = /^[0-9a-f]{64}$/
const targetPattern = /^[A-Za-z0-9._@-]+$/
const expectedSlices = ['ios-arm64', 'ios-arm64_x86_64-simulator']
const allowedPrivacyKeys = new Set([
  'NSPrivacyAccessedAPITypes',
  'NSPrivacyCollectedDataTypes',
  'NSPrivacyTracking',
  'NSPrivacyTrackingDomains',
])
const appleRequirementURLs = [
  'https://developer.apple.com/documentation/bundleresources/privacy-manifest-files',
  'https://developer.apple.com/documentation/bundleresources/adding-a-privacy-manifest-to-your-app-or-third-party-sdk',
  'https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api',
  'https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype',
  'https://developer.apple.com/documentation/technotes/tn3181-debugging-invalid-privacy-manifest',
  'https://developer.apple.com/documentation/technotes/tn3184-adding-data-collection-details-to-your-privacy-manifest',
]

// Keep these exact raw values synchronized with Apple's property-list key
// documentation. In particular, Apple's published spelling is
// `NSPrivacyCollectedDataTypePhotosorVideos` (lowercase "or").
const collectedDataTypeValues = new Set([
  'NSPrivacyCollectedDataTypeName',
  'NSPrivacyCollectedDataTypeEmailAddress',
  'NSPrivacyCollectedDataTypePhoneNumber',
  'NSPrivacyCollectedDataTypePhysicalAddress',
  'NSPrivacyCollectedDataTypeOtherUserContactInfo',
  'NSPrivacyCollectedDataTypeHealth',
  'NSPrivacyCollectedDataTypeFitness',
  'NSPrivacyCollectedDataTypePaymentInfo',
  'NSPrivacyCollectedDataTypeCreditInfo',
  'NSPrivacyCollectedDataTypeOtherFinancialInfo',
  'NSPrivacyCollectedDataTypePreciseLocation',
  'NSPrivacyCollectedDataTypeCoarseLocation',
  'NSPrivacyCollectedDataTypeSensitiveInfo',
  'NSPrivacyCollectedDataTypeContacts',
  'NSPrivacyCollectedDataTypeEmailsOrTextMessages',
  'NSPrivacyCollectedDataTypePhotosorVideos',
  'NSPrivacyCollectedDataTypeAudioData',
  'NSPrivacyCollectedDataTypeGameplayContent',
  'NSPrivacyCollectedDataTypeCustomerSupport',
  'NSPrivacyCollectedDataTypeOtherUserContent',
  'NSPrivacyCollectedDataTypeBrowsingHistory',
  'NSPrivacyCollectedDataTypeSearchHistory',
  'NSPrivacyCollectedDataTypeUserID',
  'NSPrivacyCollectedDataTypeDeviceID',
  'NSPrivacyCollectedDataTypePurchaseHistory',
  'NSPrivacyCollectedDataTypeProductInteraction',
  'NSPrivacyCollectedDataTypeAdvertisingData',
  'NSPrivacyCollectedDataTypeOtherUsageData',
  'NSPrivacyCollectedDataTypeCrashData',
  'NSPrivacyCollectedDataTypePerformanceData',
  'NSPrivacyCollectedDataTypeOtherDiagnosticData',
  'NSPrivacyCollectedDataTypeEnvironmentScanning',
  'NSPrivacyCollectedDataTypeHands',
  'NSPrivacyCollectedDataTypeHead',
  'NSPrivacyCollectedDataTypeOtherDataTypes',
])
const collectedDataPurposeValues = new Set([
  'NSPrivacyCollectedDataTypePurposeThirdPartyAdvertising',
  'NSPrivacyCollectedDataTypePurposeDeveloperAdvertising',
  'NSPrivacyCollectedDataTypePurposeAnalytics',
  'NSPrivacyCollectedDataTypePurposeProductPersonalization',
  'NSPrivacyCollectedDataTypePurposeAppFunctionality',
  'NSPrivacyCollectedDataTypePurposeOther',
])

// These identifiers are the API spellings Apple publishes for the five current
// required-reason categories. Binary inspection is deliberately conservative:
// an identifier may map to more than one category when its call arguments, which
// are not recoverable from an import table, determine the category.
const categoryIdentifiers = new Map([
  ['NSPrivacyAccessedAPICategoryActiveKeyboards', new Set(['activeInputModes'])],
  ['NSPrivacyAccessedAPICategoryDiskSpace', new Set([
    'fstatfs',
    'fstatvfs',
    'getattrlist',
    'statfs',
    'statvfs',
    'systemFreeSize',
    'systemSize',
    'volumeAvailableCapacityForImportantUsageKey',
    'volumeAvailableCapacityForOpportunisticUsageKey',
    'volumeAvailableCapacityKey',
    'volumeTotalCapacityKey',
  ])],
  ['NSPrivacyAccessedAPICategoryFileTimestamp', new Set([
    'contentModificationDateKey',
    'creationDate',
    'creationDateKey',
    'fgetattrlist',
    'fileModificationDate',
    'fstat',
    'fstatat',
    'getattrlist',
    'getattrlistat',
    'getattrlistbulk',
    'lstat',
    'modificationDate',
    'stat',
  ])],
  ['NSPrivacyAccessedAPICategorySystemBootTime', new Set([
    'mach_absolute_time',
    'systemUptime',
  ])],
  ['NSPrivacyAccessedAPICategoryUserDefaults', new Set([
    'NSUserDefaults',
    'standardUserDefaults',
  ])],
])
// Apple requires every reason string to be one of the values associated with the
// selected category. Keep this exact allowlist paired with the official primary
// reference pinned above; do not accept shape-only or cross-category values.
const categoryReasons = new Map([
  ['NSPrivacyAccessedAPICategoryActiveKeyboards', new Set(['3EC4.1', '54BD.1'])],
  ['NSPrivacyAccessedAPICategoryDiskSpace', new Set(['7D9E.1', '85F4.1', 'B728.1', 'E174.1'])],
  ['NSPrivacyAccessedAPICategoryFileTimestamp', new Set(['0A2A.1', '3B52.1', 'C617.1', 'DDA9.1'])],
  ['NSPrivacyAccessedAPICategorySystemBootTime', new Set(['35F9.1', '3D61.1', '8FFB.1'])],
  ['NSPrivacyAccessedAPICategoryUserDefaults', new Set(['1C8F.1', 'AC6B.1', 'C56D.1', 'CA92.1'])],
])
const knownIdentifiers = new Set([...categoryIdentifiers.values()].flatMap(values => [...values]))
const stringScanIdentifiers = new Set([
  'activeInputModes',
  'contentModificationDateKey',
  'creationDate',
  'creationDateKey',
  'fileModificationDate',
  'modificationDate',
  'standardUserDefaults',
  'systemFreeSize',
  'systemSize',
  'systemUptime',
  'volumeAvailableCapacityForImportantUsageKey',
  'volumeAvailableCapacityForOpportunisticUsageKey',
  'volumeAvailableCapacityKey',
  'volumeTotalCapacityKey',
])

function fail(message) {
  throw new Error(`[privacy-manifest-audit] ${message}`)
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

function requireTrimmedString(value, label) {
  if (typeof value !== 'string' || value.length === 0 || value.trim() !== value) {
    fail(`${label} must be a non-empty trimmed string`)
  }
  return value
}

function requireRegularFile(path, label, maximumBytes) {
  if (!existsSync(path)) fail(`missing ${label}: ${path}`)
  const metadata = lstatSync(path)
  if (metadata.isSymbolicLink() || !metadata.isFile() || metadata.size <= 0) {
    fail(`${label} must be a non-empty regular non-symlink file: ${path}`)
  }
  if (maximumBytes !== undefined && metadata.size > maximumBytes) {
    fail(`${label} exceeds ${maximumBytes} bytes: ${path}`)
  }
  return metadata
}

function sha256Bytes(bytes) {
  return createHash('sha256').update(bytes).digest('hex')
}

function sha256File(path) {
  return sha256Bytes(readFileSync(path))
}

function loadJSONFile(path, label) {
  requireRegularFile(path, label, maximumManifestBytes)
  try {
    return JSON.parse(readFileSync(path, 'utf8'))
  } catch (error) {
    fail(`${label} is not valid JSON: ${error.message}`)
  }
}

function safeRelativePath(value, label) {
  if (typeof value !== 'string' || value.length === 0 || isAbsolute(value)
      || value.includes('\\')
      || value.split('/').some(component => component === '' || component === '.' || component === '..')) {
    fail(`${label} is not a safe relative path: ${String(value)}`)
  }
  return value
}

function assertWithinRootWithoutSymlinks(path, root, label) {
  const rel = relative(root, path)
  if (rel === '' || rel === '..' || rel.startsWith(`..${sep}`)) {
    fail(`${label} escaped its expected root: ${path}`)
  }
  let cursor = root
  for (const component of rel.split(sep)) {
    cursor = join(cursor, component)
    if (!existsSync(cursor)) fail(`missing ${label}: ${cursor}`)
    if (lstatSync(cursor).isSymbolicLink()) fail(`${label} contains a symlink component: ${cursor}`)
  }
}

function sortedUniqueStrings(value, label) {
  if (!Array.isArray(value) || value.some(item => typeof item !== 'string' || item.length === 0 || item.trim() !== item)) {
    fail(`${label} must be an array of non-empty trimmed strings`)
  }
  if (new Set(value).size !== value.length) fail(`${label} must not contain duplicates`)
  const sorted = [...value].sort()
  if (JSON.stringify(value) !== JSON.stringify(sorted)) fail(`${label} must use canonical lexical order`)
  return value
}

function requireBoolean(value, label) {
  if (typeof value !== 'boolean') fail(`${label} must be Boolean`)
  return value
}

function normalizeTrackingDomains(value, label) {
  const domains = sortedUniqueStrings(value, label)
  for (const domain of domains) {
    const labels = domain.split('.')
    const ascii = domainToASCII(domain)
    if (ascii !== domain || domain !== domain.toLowerCase()
        || domain.length > 253 || labels.length < 2
        || labels.some(component => component.length === 0 || component.length > 63
          || !/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/.test(component))
        || /^\d+$/.test(labels.at(-1))) {
      fail(`${label} contains noncanonical internet domain ${domain}`)
    }
  }
  return domains
}

function normalizeCollectedDataTypes(value, label, manifestKeys = false) {
  if (!Array.isArray(value)) fail(`${label} must be an array`)
  const keys = manifestKeys
    ? ['NSPrivacyCollectedDataType', 'NSPrivacyCollectedDataTypeLinked', 'NSPrivacyCollectedDataTypeTracking', 'NSPrivacyCollectedDataTypePurposes']
    : ['dataType', 'linked', 'tracking', 'purposes']
  const normalized = value.map((entry, index) => {
    const entryLabel = `${label}.${index}`
    assertExactKeys(entry, keys, entryLabel)
    const dataType = requireTrimmedString(
      manifestKeys ? entry.NSPrivacyCollectedDataType : entry.dataType,
      `${entryLabel}.${keys[0]}`,
    )
    if (!collectedDataTypeValues.has(dataType)) {
      fail(`${entryLabel}.${keys[0]} is not an Apple-published collected-data type`)
    }
    const linked = requireBoolean(
      manifestKeys ? entry.NSPrivacyCollectedDataTypeLinked : entry.linked,
      `${entryLabel}.${keys[1]}`,
    )
    const tracking = requireBoolean(
      manifestKeys ? entry.NSPrivacyCollectedDataTypeTracking : entry.tracking,
      `${entryLabel}.${keys[2]}`,
    )
    const purposes = sortedUniqueStrings(
      manifestKeys ? entry.NSPrivacyCollectedDataTypePurposes : entry.purposes,
      `${entryLabel}.${keys[3]}`,
    )
    if (purposes.length === 0) fail(`${entryLabel}.${keys[3]} must not be empty`)
    const unsupportedPurpose = purposes.find(purpose => !collectedDataPurposeValues.has(purpose))
    if (unsupportedPurpose) {
      fail(`${entryLabel}.${keys[3]} contains unsupported Apple purpose ${unsupportedPurpose}`)
    }
    return { dataType, linked, tracking, purposes }
  })
  if (new Set(normalized.map(entry => entry.dataType)).size !== normalized.length) {
    fail(`${label} must not declare a collected-data type more than once`)
  }
  const sorted = [...normalized].sort((left, right) => left.dataType.localeCompare(right.dataType))
  if (JSON.stringify(normalized) !== JSON.stringify(sorted)) {
    fail(`${label} must use canonical collected-data type order`)
  }
  return normalized
}

function validateTrackingConsistency(tracking, trackingDomains, collectedDataTypes, label) {
  if (tracking && trackingDomains.length === 0) {
    fail(`${label} cannot enable tracking without at least one tracking domain`)
  }
  if (!tracking && trackingDomains.length > 0) {
    fail(`${label} cannot list tracking domains while tracking is false`)
  }
  if (!tracking && collectedDataTypes.some(entry => entry.tracking)) {
    fail(`${label} cannot mark collected data as used for tracking while tracking is false`)
  }
}

function normalizeCategoryEvidence(value, label) {
  if (!Array.isArray(value)) fail(`${label} must be an array`)
  const categories = new Set()
  const normalized = value.map((entry, index) => {
    const entryLabel = `${label}.${index}`
    assertExactKeys(entry, ['category', 'identifiers'], entryLabel)
    const category = requireTrimmedString(entry.category, `${entryLabel}.category`)
    const allowed = categoryIdentifiers.get(category)
    if (!allowed || categories.has(category)) fail(`${entryLabel}.category is unsupported or duplicated`)
    categories.add(category)
    const identifiers = sortedUniqueStrings(entry.identifiers, `${entryLabel}.identifiers`)
    if (identifiers.length === 0 || identifiers.some(identifier => !allowed.has(identifier))) {
      fail(`${entryLabel}.identifiers contains an identifier outside ${category}`)
    }
    return { category, identifiers }
  })
  const sorted = [...normalized].sort((left, right) => left.category.localeCompare(right.category))
  if (JSON.stringify(value) !== JSON.stringify(sorted)) fail(`${label} must use canonical category order`)
  return normalized
}

function validateDevelopmentManifest(manifest) {
  if (manifest?.schemaVersion !== 2 || manifest?.mode !== 'development'
      || manifest?.sdk?.version !== '0.17.0'
      || !Array.isArray(manifest.targets) || manifest.targets.length !== 38
      || new Set(manifest.targets).size !== manifest.targets.length
      || manifest.targets.some(target => !targetPattern.test(target))) {
    fail('artifacts.development.json is not the exact 38-target SDK 0.17.0 development closure')
  }
  return manifest
}

function validateReviewDecision(decision, evidence, label) {
  assertExactKeys(
    decision,
    [
      'target',
      'disposition',
      'privacyManifestSHA256',
      'tracking',
      'trackingDomains',
      'collectedDataTypes',
      'accessedAPITypes',
      'reviewEvidence',
    ],
    label,
  )
  if (decision.target !== evidence.target) fail(`${label}.target does not match scan evidence order`)
  if (!['manifest-reviewed', 'no-manifest-required-reviewed'].includes(decision.disposition)) {
    fail(`${label}.disposition is unsupported`)
  }
  const reviewEvidence = requireTrimmedString(decision.reviewEvidence, `${label}.reviewEvidence`)
  if (reviewEvidence.length < 80) fail(`${label}.reviewEvidence is too short to be auditable`)

  const tracking = requireBoolean(decision.tracking, `${label}.tracking`)
  const trackingDomains = normalizeTrackingDomains(decision.trackingDomains, `${label}.trackingDomains`)
  const collectedDataTypes = normalizeCollectedDataTypes(
    decision.collectedDataTypes,
    `${label}.collectedDataTypes`,
  )
  validateTrackingConsistency(tracking, trackingDomains, collectedDataTypes, label)

  if (!Array.isArray(decision.accessedAPITypes)) fail(`${label}.accessedAPITypes must be an array`)
  const categories = new Set()
  for (const [index, entry] of decision.accessedAPITypes.entries()) {
    const entryLabel = `${label}.accessedAPITypes.${index}`
    assertExactKeys(entry, ['category', 'reasons'], entryLabel)
    const category = requireTrimmedString(entry.category, `${entryLabel}.category`)
    if (!categoryIdentifiers.has(category) || categories.has(category)) {
      fail(`${entryLabel}.category is unsupported or duplicated`)
    }
    categories.add(category)
    const reasons = sortedUniqueStrings(entry.reasons, `${entryLabel}.reasons`)
    if (reasons.length === 0) fail(`${entryLabel}.reasons must contain an owner-approved Apple reason code`)
    const allowedReasons = categoryReasons.get(category)
    const invalidReason = reasons.find(reason => !allowedReasons.has(reason))
    if (invalidReason) {
      fail(`${entryLabel}.reasons contains ${invalidReason}, which is not an Apple-approved reason for ${category}`)
    }
  }
  const sortedTypes = [...decision.accessedAPITypes].sort((left, right) => left.category.localeCompare(right.category))
  if (JSON.stringify(decision.accessedAPITypes) !== JSON.stringify(sortedTypes)) {
    fail(`${label}.accessedAPITypes must use canonical category order`)
  }

  if (decision.disposition === 'manifest-reviewed') {
    if (!hashPattern.test(decision.privacyManifestSHA256 ?? '')
        || decision.privacyManifestSHA256 !== evidence.privacyManifestSHA256) {
      fail(`${label} must bind the exact scanned PrivacyInfo.xcprivacy byte`)
    }
    const declared = new Set(decision.accessedAPITypes.map(entry => entry.category))
    for (const entry of evidence.requiredReasonAPIs) {
      if (!declared.has(entry.category)) fail(`${label} does not declare detected category ${entry.category}`)
    }
  } else if (decision.privacyManifestSHA256 !== null
      || decision.tracking !== false
      || decision.trackingDomains.length !== 0
      || decision.collectedDataTypes.length !== 0
      || decision.accessedAPITypes.length !== 0
      || evidence.privacyManifestSHA256 !== null
      || evidence.requiredReasonAPIs.length !== 0) {
    fail(`${label} cannot approve no manifest when a manifest or required-reason API was detected`)
  }
  return decision
}

export function validatePrivacyAuditDocument(
  audit,
  developmentManifest = loadJSONFile(developmentManifestPath, 'development artifact manifest'),
) {
  validateDevelopmentManifest(developmentManifest)
  assertExactKeys(
    audit,
    ['schemaVersion', 'status', 'scope', 'scanEvidence', 'reviewDecisions', 'publicationBlockers'],
    'privacy audit',
  )
  if (audit.schemaVersion !== 1) fail('unsupported privacy audit schema version')
  if (!['maintainer-review-required', 'reviewed'].includes(audit.status)) {
    fail('privacy audit status must be maintainer-review-required or reviewed')
  }
  assertExactKeys(
    audit.scope,
    ['platform', 'sdkVersion', 'linkedTargetsManifest', 'frameworkSlices', 'scannerVersion', 'appleRequirements'],
    'privacy audit scope',
  )
  if (audit.scope.platform !== 'iOS' || audit.scope.sdkVersion !== '0.17.0'
      || audit.scope.scannerVersion !== 2
      || JSON.stringify(audit.scope.frameworkSlices) !== JSON.stringify(expectedSlices)
      || JSON.stringify(audit.scope.appleRequirements) !== JSON.stringify(appleRequirementURLs)) {
    fail('privacy audit scope is not the exact supported iOS SDK 0.17.0 scan contract')
  }
  assertExactKeys(audit.scope.linkedTargetsManifest, ['file', 'sha256'], 'privacy audit linked target pin')
  if (audit.scope.linkedTargetsManifest.file !== 'tools/release/artifacts.development.json'
      || !hashPattern.test(audit.scope.linkedTargetsManifest.sha256 ?? '')) {
    fail('privacy audit must pin tools/release/artifacts.development.json by SHA-256')
  }
  if (sha256File(developmentManifestPath) !== audit.scope.linkedTargetsManifest.sha256) {
    fail('artifacts.development.json changed; rescan and re-review privacy evidence before updating its pin')
  }

  if (!Array.isArray(audit.scanEvidence) || audit.scanEvidence.length !== developmentManifest.targets.length) {
    fail(`privacy audit must contain scan evidence for all ${developmentManifest.targets.length} linked targets`)
  }
  const evidenceByTarget = new Map()
  for (const [index, evidence] of audit.scanEvidence.entries()) {
    const label = `privacy scan evidence ${index}`
    assertExactKeys(
      evidence,
      ['target', 'requiredReasonAPIs', 'privacyManifestSHA256'],
      label,
    )
    if (evidence.target !== developmentManifest.targets[index]) {
      fail(`${label}.target must exactly follow the linked-target inventory`)
    }
    normalizeCategoryEvidence(evidence.requiredReasonAPIs, `${label}.requiredReasonAPIs`)
    if (evidence.privacyManifestSHA256 !== null && !hashPattern.test(evidence.privacyManifestSHA256)) {
      fail(`${label}.privacyManifestSHA256 must be null or lowercase SHA-256`)
    }
    evidenceByTarget.set(evidence.target, evidence)
  }

  if (!Array.isArray(audit.reviewDecisions)) fail('privacy audit reviewDecisions must be an array')
  const decisions = new Set()
  for (const [index, decision] of audit.reviewDecisions.entries()) {
    const evidence = evidenceByTarget.get(decision?.target)
    if (!evidence || decisions.has(decision.target)) {
      fail(`privacy review decision ${index} has an unknown or duplicate target`)
    }
    decisions.add(decision.target)
    validateReviewDecision(decision, evidence, `privacy review decision ${index}`)
  }
  const canonicalDecisionOrder = developmentManifest.targets.filter(target => decisions.has(target))
  if (JSON.stringify(audit.reviewDecisions.map(decision => decision.target)) !== JSON.stringify(canonicalDecisionOrder)) {
    fail('privacy review decisions must follow linked-target order')
  }

  if (!Array.isArray(audit.publicationBlockers)) fail('privacy audit publicationBlockers must be an array')
  const blockerIds = new Set()
  const blockedTargets = new Set()
  for (const [index, blocker] of audit.publicationBlockers.entries()) {
    const label = `privacy publication blocker ${index}`
    assertExactKeys(blocker, ['id', 'affectedTargets', 'missingEvidence', 'action'], label)
    const id = requireTrimmedString(blocker.id, `${label}.id`)
    if (!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(id) || blockerIds.has(id)) {
      fail(`${label}.id must be unique lowercase kebab-case`)
    }
    blockerIds.add(id)
    if (!Array.isArray(blocker.affectedTargets) || blocker.affectedTargets.length === 0
        || new Set(blocker.affectedTargets).size !== blocker.affectedTargets.length
        || blocker.affectedTargets.some(target => !evidenceByTarget.has(target))) {
      fail(`${label}.affectedTargets must be a non-empty unique subset of linked targets`)
    }
    const canonicalAffectedOrder = developmentManifest.targets.filter(
      target => blocker.affectedTargets.includes(target),
    )
    if (JSON.stringify(blocker.affectedTargets) !== JSON.stringify(canonicalAffectedOrder)) {
      fail(`${label}.affectedTargets must follow linked-target order`)
    }
    for (const target of blocker.affectedTargets) blockedTargets.add(target)
    if (requireTrimmedString(blocker.missingEvidence, `${label}.missingEvidence`).length < 80
        || requireTrimmedString(blocker.action, `${label}.action`).length < 80) {
      fail(`${label} remediation text is too short to be auditable`)
    }
  }
  if ((audit.publicationBlockers.length === 0) !== (audit.status === 'reviewed')) {
    fail('privacy audit status must be reviewed exactly when publicationBlockers is empty')
  }
  if (audit.publicationBlockers.length > 0) {
    const uncovered = developmentManifest.targets.filter(
      target => !decisions.has(target) && !blockedTargets.has(target),
    )
    if (uncovered.length > 0) {
      fail(`unreviewed privacy targets lack a publication blocker: ${uncovered.join(', ')}`)
    }
  }
  return audit
}

function parsePlist(path, label) {
  requireRegularFile(path, label, maximumManifestBytes)
  try {
    execFileSync('plutil', ['-lint', path], { stdio: 'pipe' })
    return JSON.parse(execFileSync('plutil', ['-convert', 'json', '-o', '-', path], {
      encoding: 'utf8',
      maxBuffer: maximumManifestBytes * 2,
    }))
  } catch (error) {
    fail(`${label} is not a valid property list: ${error.message}`)
  }
}

function validatePrivacyManifest(plist, label) {
  if (!plainObject(plist)) fail(`${label} must have a dictionary root`)
  const unexpected = Object.keys(plist).filter(key => !allowedPrivacyKeys.has(key))
  if (unexpected.length > 0) fail(`${label} contains unexpected keys: ${unexpected.join(', ')}`)

  const tracking = 'NSPrivacyTracking' in plist
    ? requireBoolean(plist.NSPrivacyTracking, `${label}.NSPrivacyTracking`)
    : false
  const trackingDomains = 'NSPrivacyTrackingDomains' in plist
    ? normalizeTrackingDomains(plist.NSPrivacyTrackingDomains, `${label}.NSPrivacyTrackingDomains`)
    : []
  if ('NSPrivacyTrackingDomains' in plist && trackingDomains.length === 0) {
    fail(`${label}.NSPrivacyTrackingDomains must be omitted instead of empty`)
  }

  const collected = 'NSPrivacyCollectedDataTypes' in plist
    ? normalizeCollectedDataTypes(
      plist.NSPrivacyCollectedDataTypes,
      `${label}.NSPrivacyCollectedDataTypes`,
      true,
    )
    : []
  if ('NSPrivacyCollectedDataTypes' in plist && collected.length === 0) {
    fail(`${label}.NSPrivacyCollectedDataTypes must be omitted instead of empty`)
  }
  validateTrackingConsistency(tracking, trackingDomains, collected, label)

  const accessed = plist.NSPrivacyAccessedAPITypes ?? []
  if (!Array.isArray(accessed)) fail(`${label}.NSPrivacyAccessedAPITypes must be an array`)
  if ('NSPrivacyAccessedAPITypes' in plist && accessed.length === 0) {
    fail(`${label}.NSPrivacyAccessedAPITypes must be omitted instead of empty`)
  }
  const normalized = accessed.map((entry, index) => {
    const entryLabel = `${label}.NSPrivacyAccessedAPITypes.${index}`
    assertExactKeys(entry, ['NSPrivacyAccessedAPIType', 'NSPrivacyAccessedAPITypeReasons'], entryLabel)
    const category = requireTrimmedString(entry.NSPrivacyAccessedAPIType, `${entryLabel}.NSPrivacyAccessedAPIType`)
    if (!categoryIdentifiers.has(category)) fail(`${entryLabel} uses an unsupported category`)
    const reasons = sortedUniqueStrings(entry.NSPrivacyAccessedAPITypeReasons, `${entryLabel}.NSPrivacyAccessedAPITypeReasons`)
    if (reasons.length === 0) fail(`${entryLabel} has no approved reasons`)
    const invalidReason = reasons.find(reason => !categoryReasons.get(category).has(reason))
    if (invalidReason) {
      fail(`${entryLabel} contains ${invalidReason}, which is not an Apple-approved reason for ${category}`)
    }
    return { category, reasons }
  }).sort((left, right) => left.category.localeCompare(right.category))
  if (new Set(normalized.map(entry => entry.category)).size !== normalized.length) {
    fail(`${label} declares a required-reason category more than once`)
  }
  return {
    tracking,
    trackingDomains,
    collectedDataTypes: collected,
    accessedAPITypes: normalized,
  }
}

function detectedIdentifiers(binary) {
  let undefinedSymbols
  let strings
  try {
    undefinedSymbols = execFileSync('xcrun', ['nm', '-u', binary], {
      encoding: 'utf8',
      maxBuffer: 64 * 1024 * 1024,
    })
    strings = execFileSync('/usr/bin/strings', ['-a', binary], {
      encoding: 'utf8',
      maxBuffer: 64 * 1024 * 1024,
      env: { ...process.env, LC_ALL: 'C', LANG: 'C' },
    })
  } catch (error) {
    fail(`required-reason API scan failed for ${binary}: ${error.message}`)
  }
  const detected = new Set()
  for (const line of undefinedSymbols.split('\n')) {
    const raw = line.trim().split(/\s+/).at(-1) ?? ''
    const identifier = raw.replace(/^_/, '').replace(/\$.+$/, '')
    if (knownIdentifiers.has(identifier)) detected.add(identifier)
    if (raw === '_OBJC_CLASS_$_NSUserDefaults') detected.add('NSUserDefaults')
  }
  for (const value of strings.split('\n')) {
    if (stringScanIdentifiers.has(value)) detected.add(value)
  }
  return detected
}

function evidenceForIdentifiers(identifiers) {
  const result = []
  for (const [category, allowed] of categoryIdentifiers) {
    const matches = [...identifiers].filter(identifier => allowed.has(identifier)).sort()
    if (matches.length > 0) result.push({ category, identifiers: matches })
  }
  return result.sort((left, right) => left.category.localeCompare(right.category))
}

function collectPrivacyPaths(root, current = root) {
  const matches = []
  for (const entry of readdirSync(current).sort()) {
    const path = join(current, entry)
    const metadata = lstatSync(path)
    if (metadata.isSymbolicLink()) {
      if (entry === 'PrivacyInfo.xcprivacy') fail(`privacy manifest must not be a symlink: ${path}`)
      continue
    }
    if (metadata.isDirectory()) matches.push(...collectPrivacyPaths(root, path))
    else if (entry === 'PrivacyInfo.xcprivacy') matches.push(path)
  }
  return matches
}

function scanTarget(frameworksRoot, target) {
  const xcframework = join(frameworksRoot, `${target}.xcframework`)
  assertWithinRootWithoutSymlinks(xcframework, frameworksRoot, `${target} XCFramework`)
  if (!lstatSync(xcframework).isDirectory()) fail(`${target} XCFramework is not a directory`)
  const info = parsePlist(join(xcframework, 'Info.plist'), `${target} XCFramework Info.plist`)
  if (!Array.isArray(info.AvailableLibraries)) fail(`${target} XCFramework has no AvailableLibraries array`)
  const libraries = info.AvailableLibraries.filter(entry => entry?.SupportedPlatform === 'ios')
    .sort((left, right) => String(left.LibraryIdentifier).localeCompare(String(right.LibraryIdentifier)))
  const identifiers = libraries.map(entry => entry.LibraryIdentifier)
  if (JSON.stringify(identifiers) !== JSON.stringify(expectedSlices)) {
    fail(`${target} iOS slice inventory differs from ${expectedSlices.join(', ')}`)
  }

  const detected = new Set()
  const manifestPaths = []
  const manifestHashes = new Set()
  let normalizedManifest
  for (const library of libraries) {
    const identifier = safeRelativePath(library.LibraryIdentifier, `${target} LibraryIdentifier`)
    const libraryPath = safeRelativePath(library.LibraryPath, `${target}/${identifier} LibraryPath`)
    if (!libraryPath.endsWith('.framework')) fail(`${target}/${identifier} is not a framework slice`)
    const framework = join(xcframework, identifier, libraryPath)
    assertWithinRootWithoutSymlinks(framework, xcframework, `${target}/${identifier} framework`)
    if (!lstatSync(framework).isDirectory()) fail(`${target}/${identifier} framework is not a directory`)
    const binaryRelative = safeRelativePath(
      library.BinaryPath ?? `${libraryPath}/${target}`,
      `${target}/${identifier} BinaryPath`,
    )
    const binary = join(xcframework, identifier, binaryRelative)
    assertWithinRootWithoutSymlinks(binary, xcframework, `${target}/${identifier} binary`)
    requireRegularFile(binary, `${target}/${identifier} binary`)
    for (const value of detectedIdentifiers(binary)) detected.add(value)

    const privacyPath = join(framework, 'PrivacyInfo.xcprivacy')
    if (existsSync(privacyPath)) {
      assertWithinRootWithoutSymlinks(privacyPath, xcframework, `${target}/${identifier} privacy manifest`)
      const plist = parsePlist(privacyPath, `${target}/${identifier} PrivacyInfo.xcprivacy`)
      const manifest = validatePrivacyManifest(plist, `${target}/${identifier} PrivacyInfo.xcprivacy`)
      if (normalizedManifest !== undefined
          && JSON.stringify(manifest) !== JSON.stringify(normalizedManifest)) {
        fail(`${target} privacy manifests differ semantically across iOS slices`)
      }
      normalizedManifest = manifest
      manifestPaths.push(privacyPath)
      manifestHashes.add(sha256File(privacyPath))
    }
  }

  const allPrivacyPaths = collectPrivacyPaths(xcframework)
  if (allPrivacyPaths.length !== manifestPaths.length
      || allPrivacyPaths.some(path => !manifestPaths.includes(path))) {
    fail(`${target} contains PrivacyInfo.xcprivacy outside an iOS framework root`)
  }
  if (![0, expectedSlices.length].includes(manifestPaths.length)) {
    fail(`${target} must bundle PrivacyInfo.xcprivacy in every iOS XCFramework slice or none`)
  }
  if (manifestHashes.size > 1) fail(`${target} privacy manifest bytes differ across iOS slices`)
  return {
    target,
    frameworkSlices: expectedSlices,
    requiredReasonAPIs: evidenceForIdentifiers(detected),
    privacyManifestSHA256: manifestHashes.size === 1 ? [...manifestHashes][0] : null,
    tracking: normalizedManifest?.tracking ?? false,
    trackingDomains: normalizedManifest?.trackingDomains ?? [],
    collectedDataTypes: normalizedManifest?.collectedDataTypes ?? [],
    accessedAPITypes: normalizedManifest?.accessedAPITypes ?? [],
  }
}

function loadLinkSet(path) {
  const linkSet = loadJSONFile(path, 'native link set')
  if (linkSet?.schemaVersion !== 1 || linkSet?.mode !== 'link-set'
      || !Array.isArray(linkSet.targets) || linkSet.targets.length !== 38
      || new Set(linkSet.targets).size !== linkSet.targets.length) {
    fail('native link set is not the exact 38-target closure')
  }
  return linkSet
}

export function scanFrameworkClosure(frameworksDirectory, linkSetPath) {
  const frameworksRoot = resolve(frameworksDirectory)
  if (!existsSync(frameworksRoot) || lstatSync(frameworksRoot).isSymbolicLink()
      || !lstatSync(frameworksRoot).isDirectory()) {
    fail(`framework root must be a real directory: ${frameworksRoot}`)
  }
  const linkSet = loadLinkSet(resolve(linkSetPath))
  const development = validateDevelopmentManifest(
    loadJSONFile(developmentManifestPath, 'development artifact manifest'),
  )
  if (JSON.stringify(linkSet.targets) !== JSON.stringify(development.targets)) {
    fail('native link set target inventory differs from artifacts.development.json')
  }
  return linkSet.targets.map(target => scanTarget(frameworksRoot, target))
}

export function assertScanMatchesAudit(audit, scan) {
  const comparable = scan.map(({
    accessedAPITypes: _accessedAPITypes,
    tracking: _tracking,
    trackingDomains: _trackingDomains,
    collectedDataTypes: _collectedDataTypes,
    frameworkSlices: _frameworkSlices,
    ...evidence
  }) => evidence)
  if (JSON.stringify(comparable) !== JSON.stringify(audit.scanEvidence)) {
    fail('current 38-target privacy scan differs from privacy-manifest-audit.json; re-audit before changing evidence')
  }
  return scan
}

export function assertPrivacyPublicationReady(audit, scan) {
  if (audit.publicationBlockers.length > 0) {
    const ids = audit.publicationBlockers.map(blocker => blocker.id).join(', ')
    fail(`publication blocked by ${audit.publicationBlockers.length} unresolved privacy gap(s): ${ids}; see tools/release/privacy-manifest-audit.json and docs/distribution.md`)
  }
  if (audit.status !== 'reviewed' || audit.reviewDecisions.length !== audit.scanEvidence.length) {
    fail('publication requires a reviewed decision for every linked XCFramework target')
  }
  for (let index = 0; index < audit.scanEvidence.length; index += 1) {
    const evidence = audit.scanEvidence[index]
    const decision = audit.reviewDecisions[index]
    validateReviewDecision(decision, evidence, `privacy review decision ${index}`)
    if (scan) {
      const actual = scan[index]
      if (!actual || actual.target !== decision.target) {
        fail(`${decision.target} framework scan is missing or out of order`)
      }
      if (decision.disposition === 'manifest-reviewed') {
        if (actual.privacyManifestSHA256 !== decision.privacyManifestSHA256) {
          fail(`${decision.target} PrivacyInfo.xcprivacy bytes differ from the reviewed decision`)
        }
        const actualDeclarations = {
          tracking: actual.tracking,
          trackingDomains: actual.trackingDomains,
          collectedDataTypes: actual.collectedDataTypes,
          accessedAPITypes: actual.accessedAPITypes,
        }
        const reviewedDeclarations = {
          tracking: decision.tracking,
          trackingDomains: decision.trackingDomains,
          collectedDataTypes: decision.collectedDataTypes,
          accessedAPITypes: decision.accessedAPITypes,
        }
        if (JSON.stringify(actualDeclarations) !== JSON.stringify(reviewedDeclarations)) {
          fail(`${decision.target} PrivacyInfo.xcprivacy declarations differ from the reviewed decision`)
        }
      } else if (actual.privacyManifestSHA256 !== null
          || actual.tracking !== false
          || actual.trackingDomains.length !== 0
          || actual.collectedDataTypes.length !== 0
          || actual.accessedAPITypes.length !== 0) {
        fail(`${decision.target} framework scan contains an unreviewed privacy manifest or declarations`)
      }
    }
  }
  return audit
}

function archivePrivacyHashes(archive, target) {
  let listing
  try {
    listing = execFileSync('unzip', ['-Z1', archive], { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 })
  } catch (error) {
    fail(`cannot inspect ${archive}: ${error.message}`)
  }
  const names = listing.split('\n').filter(name => name.endsWith('/PrivacyInfo.xcprivacy'))
  const expectedNames = expectedSlices.map(
    identifier => `${target}.xcframework/${identifier}/${target}.framework/PrivacyInfo.xcprivacy`,
  )
  if (JSON.stringify(names.sort()) !== JSON.stringify(expectedNames.sort())) {
    fail(`${target} archive does not contain PrivacyInfo.xcprivacy at every exact iOS framework root`)
  }
  const hashes = new Set()
  for (const name of names) {
    try {
      hashes.add(sha256Bytes(execFileSync('unzip', ['-p', archive, name], { maxBuffer: maximumManifestBytes })))
    } catch (error) {
      fail(`cannot read ${name} from ${archive}: ${error.message}`)
    }
  }
  return hashes
}

function verifyPackagedManifests(audit, assetsDirectory) {
  const root = resolve(assetsDirectory)
  if (!existsSync(root) || lstatSync(root).isSymbolicLink() || !lstatSync(root).isDirectory()) {
    fail(`release assets root must be a real directory: ${root}`)
  }
  for (const [index, decision] of audit.reviewDecisions.entries()) {
    const archive = join(root, `${decision.target}.xcframework.zip`)
    requireRegularFile(archive, `${decision.target} packaged XCFramework`)
    if (decision.disposition === 'manifest-reviewed') {
      const hashes = archivePrivacyHashes(archive, decision.target)
      if (hashes.size !== 1 || !hashes.has(decision.privacyManifestSHA256)) {
        fail(`${decision.target} archive privacy manifest does not match reviewed bytes`)
      }
    } else {
      let listing
      try { listing = execFileSync('unzip', ['-Z1', archive], { encoding: 'utf8' }) } catch (error) {
        fail(`cannot inspect ${archive}: ${error.message}`)
      }
      if (listing.split('\n').some(name => name.endsWith('/PrivacyInfo.xcprivacy'))) {
        fail(`${decision.target} archive contains an unreviewed privacy manifest`)
      }
    }
    if (audit.scanEvidence[index].target !== decision.target) fail('privacy decision order changed')
  }
}

function completeSyntheticAudit(audit) {
  const completed = structuredClone(audit)
  completed.status = 'reviewed'
  completed.publicationBlockers = []
  completed.scanEvidence = completed.scanEvidence.map(evidence => ({
    ...evidence,
    privacyManifestSHA256: evidence.requiredReasonAPIs.length > 0 ? 'a'.repeat(64) : null,
  }))
  completed.reviewDecisions = completed.scanEvidence.map(evidence => ({
    target: evidence.target,
    disposition: evidence.requiredReasonAPIs.length > 0
      ? 'manifest-reviewed'
      : 'no-manifest-required-reviewed',
    privacyManifestSHA256: evidence.privacyManifestSHA256,
    tracking: false,
    trackingDomains: [],
    collectedDataTypes: [],
    accessedAPITypes: evidence.requiredReasonAPIs.map(entry => ({
      category: entry.category,
      reasons: [[...categoryReasons.get(entry.category)].sort()[0]],
    })),
    reviewEvidence: 'Synthetic self-test evidence only; production requires target-owner review of API purposes, collection, tracking, and every selected Apple reason.',
  }))
  return completed
}

function selfTest(audit, development) {
  assert.doesNotThrow(() => validatePrivacyAuditDocument(audit, development))
  assert.throws(() => assertPrivacyPublicationReady(audit), /publication blocked/)

  const missingTarget = structuredClone(audit)
  missingTarget.scanEvidence.pop()
  assert.throws(() => validatePrivacyAuditDocument(missingTarget, development), /all 38 linked targets/)

  const driftedPin = structuredClone(audit)
  driftedPin.scope.linkedTargetsManifest.sha256 = '0'.repeat(64)
  assert.throws(() => validatePrivacyAuditDocument(driftedPin, development), /changed; rescan/)

  const uncoveredTarget = structuredClone(audit)
  uncoveredTarget.publicationBlockers.at(-1).affectedTargets.pop()
  assert.throws(() => validatePrivacyAuditDocument(uncoveredTarget, development), /lack a publication blocker/)

  const completed = completeSyntheticAudit(audit)
  assert.doesNotThrow(() => validatePrivacyAuditDocument(completed, development))
  assert.doesNotThrow(() => assertPrivacyPublicationReady(completed))
  const completedScan = completed.reviewDecisions.map((decision, index) => ({
    target: decision.target,
    frameworkSlices: expectedSlices,
    requiredReasonAPIs: completed.scanEvidence[index].requiredReasonAPIs,
    privacyManifestSHA256: decision.privacyManifestSHA256,
    tracking: decision.tracking,
    trackingDomains: decision.trackingDomains,
    collectedDataTypes: decision.collectedDataTypes,
    accessedAPITypes: decision.accessedAPITypes,
  }))
  assert.doesNotThrow(() => assertPrivacyPublicationReady(completed, completedScan))
  const undeclaredCategory = structuredClone(completed)
  const affectedIndex = undeclaredCategory.scanEvidence.findIndex(entry => entry.requiredReasonAPIs.length > 0)
  undeclaredCategory.reviewDecisions[affectedIndex].accessedAPITypes = []
  assert.throws(() => validatePrivacyAuditDocument(undeclaredCategory, development), /does not declare detected category/)
  const fabricatedReason = structuredClone(completed)
  fabricatedReason.reviewDecisions[affectedIndex].accessedAPITypes[0].reasons = ['FAKE.1']
  assert.throws(
    () => validatePrivacyAuditDocument(fabricatedReason, development),
    /not an Apple-approved reason/,
  )
  const crossCategoryReason = structuredClone(completed)
  const reviewedCategory = crossCategoryReason.reviewDecisions[affectedIndex].accessedAPITypes[0].category
  const otherCategory = [...categoryReasons.keys()].find(category => category !== reviewedCategory)
  crossCategoryReason.reviewDecisions[affectedIndex].accessedAPITypes[0].reasons = [
    [...categoryReasons.get(otherCategory)][0],
  ]
  assert.throws(
    () => validatePrivacyAuditDocument(crossCategoryReason, development),
    /not an Apple-approved reason/,
  )
  const incompleteReview = structuredClone(completed)
  incompleteReview.reviewDecisions.pop()
  assert.throws(() => assertPrivacyPublicationReady(incompleteReview), /reviewed decision for every/)
  const missingPrivacyBinding = structuredClone(completed)
  delete missingPrivacyBinding.reviewDecisions[affectedIndex].collectedDataTypes
  assert.throws(
    () => validatePrivacyAuditDocument(missingPrivacyBinding, development),
    /unexpected fields/,
  )
  const forgedByteBinding = structuredClone(completed)
  forgedByteBinding.reviewDecisions[affectedIndex].privacyManifestSHA256 = 'b'.repeat(64)
  assert.throws(
    () => validatePrivacyAuditDocument(forgedByteBinding, development),
    /bind the exact scanned PrivacyInfo\.xcprivacy byte/,
  )
  const forgedDeclarationScan = structuredClone(completedScan)
  forgedDeclarationScan[affectedIndex].collectedDataTypes = [{
    dataType: 'NSPrivacyCollectedDataTypeContacts',
    linked: false,
    tracking: false,
    purposes: ['NSPrivacyCollectedDataTypePurposeAppFunctionality'],
  }]
  assert.throws(
    () => assertPrivacyPublicationReady(completed, forgedDeclarationScan),
    /declarations differ from the reviewed decision/,
  )
  const forgedByteScan = structuredClone(completedScan)
  forgedByteScan[affectedIndex].privacyManifestSHA256 = 'b'.repeat(64)
  assert.throws(
    () => assertPrivacyPublicationReady(completed, forgedByteScan),
    /bytes differ from the reviewed decision/,
  )

  const fileTimestampPlist = {
    NSPrivacyAccessedAPITypes: [{
      NSPrivacyAccessedAPIType: 'NSPrivacyAccessedAPICategoryFileTimestamp',
      NSPrivacyAccessedAPITypeReasons: ['C617.1'],
    }],
  }
  assert.doesNotThrow(() => validatePrivacyManifest(fileTimestampPlist, 'synthetic privacy manifest'))
  const fabricatedManifestReason = structuredClone(fileTimestampPlist)
  fabricatedManifestReason.NSPrivacyAccessedAPITypes[0].NSPrivacyAccessedAPITypeReasons = ['FAKE.1']
  assert.throws(
    () => validatePrivacyManifest(fabricatedManifestReason, 'synthetic privacy manifest'),
    /not an Apple-approved reason/,
  )
  const crossCategoryManifestReason = structuredClone(fileTimestampPlist)
  crossCategoryManifestReason.NSPrivacyAccessedAPITypes[0].NSPrivacyAccessedAPITypeReasons = ['35F9.1']
  assert.throws(
    () => validatePrivacyManifest(crossCategoryManifestReason, 'synthetic privacy manifest'),
    /not an Apple-approved reason/,
  )

  const completePrivacyPlist = {
    NSPrivacyTracking: true,
    NSPrivacyTrackingDomains: ['metrics.example.com', 'tracking.example.com'],
    NSPrivacyCollectedDataTypes: [
      {
        NSPrivacyCollectedDataType: 'NSPrivacyCollectedDataTypeContacts',
        NSPrivacyCollectedDataTypeLinked: true,
        NSPrivacyCollectedDataTypeTracking: false,
        NSPrivacyCollectedDataTypePurposes: [
          'NSPrivacyCollectedDataTypePurposeAppFunctionality',
        ],
      },
      {
        NSPrivacyCollectedDataType: 'NSPrivacyCollectedDataTypeUserID',
        NSPrivacyCollectedDataTypeLinked: false,
        NSPrivacyCollectedDataTypeTracking: true,
        NSPrivacyCollectedDataTypePurposes: [
          'NSPrivacyCollectedDataTypePurposeAnalytics',
          'NSPrivacyCollectedDataTypePurposeProductPersonalization',
        ],
      },
    ],
  }
  assert.deepEqual(
    validatePrivacyManifest(completePrivacyPlist, 'complete synthetic privacy manifest'),
    {
      tracking: true,
      trackingDomains: ['metrics.example.com', 'tracking.example.com'],
      collectedDataTypes: [
        {
          dataType: 'NSPrivacyCollectedDataTypeContacts',
          linked: true,
          tracking: false,
          purposes: ['NSPrivacyCollectedDataTypePurposeAppFunctionality'],
        },
        {
          dataType: 'NSPrivacyCollectedDataTypeUserID',
          linked: false,
          tracking: true,
          purposes: [
            'NSPrivacyCollectedDataTypePurposeAnalytics',
            'NSPrivacyCollectedDataTypePurposeProductPersonalization',
          ],
        },
      ],
      accessedAPITypes: [],
    },
  )
  const expectManifestFailure = (mutate, pattern) => {
    const candidate = structuredClone(completePrivacyPlist)
    mutate(candidate)
    assert.throws(
      () => validatePrivacyManifest(candidate, 'adversarial synthetic privacy manifest'),
      pattern,
    )
  }
  expectManifestFailure(
    candidate => { candidate.NSPrivacyCollectedDataTypes[0] = 'malformed' },
    /must be an object/,
  )
  expectManifestFailure(
    candidate => { delete candidate.NSPrivacyCollectedDataTypes[0].NSPrivacyCollectedDataTypeLinked },
    /unexpected fields/,
  )
  expectManifestFailure(
    candidate => {
      candidate.NSPrivacyCollectedDataTypes[0].NSPrivacyCollectedDataType = 'NSPrivacyCollectedDataTypeUnknown'
    },
    /not an Apple-published collected-data type/,
  )
  expectManifestFailure(
    candidate => { candidate.NSPrivacyCollectedDataTypes[0].NSPrivacyCollectedDataTypeLinked = 1 },
    /NSPrivacyCollectedDataTypeLinked must be Boolean/,
  )
  expectManifestFailure(
    candidate => { candidate.NSPrivacyCollectedDataTypes[0].NSPrivacyCollectedDataTypeTracking = 'false' },
    /NSPrivacyCollectedDataTypeTracking must be Boolean/,
  )
  expectManifestFailure(
    candidate => {
      candidate.NSPrivacyCollectedDataTypes[0].NSPrivacyCollectedDataTypePurposes = [
        'NSPrivacyCollectedDataTypePurposeUnknown',
      ]
    },
    /contains unsupported Apple purpose/,
  )
  expectManifestFailure(
    candidate => { candidate.NSPrivacyCollectedDataTypes[0].NSPrivacyCollectedDataTypePurposes = [] },
    /must not be empty/,
  )
  expectManifestFailure(
    candidate => { candidate.NSPrivacyCollectedDataTypes.push(candidate.NSPrivacyCollectedDataTypes[0]) },
    /must not declare a collected-data type more than once/,
  )
  expectManifestFailure(
    candidate => { candidate.NSPrivacyCollectedDataTypes.reverse() },
    /must use canonical collected-data type order/,
  )
  expectManifestFailure(
    candidate => { candidate.NSPrivacyTracking = 1 },
    /NSPrivacyTracking must be Boolean/,
  )
  expectManifestFailure(
    candidate => { candidate.NSPrivacyTrackingDomains = ['metrics.example.com', 'metrics.example.com'] },
    /must not contain duplicates/,
  )
  expectManifestFailure(
    candidate => { candidate.NSPrivacyTrackingDomains = ['Tracking.example.com'] },
    /contains noncanonical internet domain/,
  )
  expectManifestFailure(
    candidate => { candidate.NSPrivacyTrackingDomains = ['https:\/\/tracking.example.com/path'] },
    /contains noncanonical internet domain/,
  )
  expectManifestFailure(
    candidate => { candidate.NSPrivacyTrackingDomains.reverse() },
    /must use canonical lexical order/,
  )
  expectManifestFailure(
    candidate => { candidate.NSPrivacyTracking = false },
    /cannot list tracking domains while tracking is false/,
  )
  expectManifestFailure(
    candidate => { delete candidate.NSPrivacyTrackingDomains },
    /cannot enable tracking without at least one tracking domain/,
  )
  expectManifestFailure(
    candidate => {
      candidate.NSPrivacyTracking = false
      delete candidate.NSPrivacyTrackingDomains
    },
    /cannot mark collected data as used for tracking while tracking is false/,
  )
  expectManifestFailure(
    candidate => { candidate.NSPrivacyCollectedDataTypes = [] },
    /must be omitted instead of empty/,
  )
  expectManifestFailure(
    candidate => { candidate.NSPrivacyUnexpected = false },
    /contains unexpected keys/,
  )

  const artifactWorkflow = readFileSync(buildArtifactsWorkflowPath, 'utf8')
  assert.match(
    artifactWorkflow,
    /if: inputs\.publish[\s\S]{0,500}verify-privacy-manifests\.mjs --check-publication[\s\S]{0,500}--frameworks tools\/runtime\/\.build\/artifacts[\s\S]{0,500}--assets-dir tools\/runtime\/\.build\/release-assets/,
  )
  const sourceWorkflow = readFileSync(sourceReleaseWorkflowPath, 'utf8')
  assert.match(
    sourceWorkflow,
    /Require complete native-license and privacy closure before publication[\s\S]{0,500}generate-third-party-notices\.mjs --check-publication[\s\S]{0,500}verify-privacy-manifests\.mjs --check-publication/,
  )
  console.log('[privacy-manifest-audit-test] target drift, Apple schema/value allowlists, collection/tracking consistency, byte-bound declarations, closure, and both publication gates enforced')
}

function option(name) {
  const index = process.argv.indexOf(name)
  return index >= 0 ? process.argv[index + 1] : undefined
}

function main() {
  const mode = process.argv[2] ?? '--check'
  if (!['--check', '--check-frameworks', '--check-publication', '--self-test'].includes(mode)) {
    fail('usage: verify-privacy-manifests.mjs [--check|--check-frameworks|--check-publication|--self-test] [--frameworks <dir> --link-set <json> --assets-dir <dir>]')
  }
  const audit = validatePrivacyAuditDocument(loadJSONFile(defaultAuditPath, 'privacy manifest audit'))
  const frameworks = option('--frameworks')
  const linkSet = option('--link-set')
  const assets = option('--assets-dir')
  if ((frameworks === undefined) !== (linkSet === undefined)) {
    fail('--frameworks and --link-set must be provided together')
  }
  if (mode === '--check-frameworks' && (!frameworks || !linkSet || assets)) {
    fail('--check-frameworks requires --frameworks and --link-set only')
  }
  if (mode === '--check' && (frameworks || linkSet || assets)) fail('--check accepts no path options')
  if (mode === '--self-test' && (frameworks || linkSet || assets)) fail('--self-test accepts no path options')
  if (assets && (!frameworks || mode !== '--check-publication')) {
    fail('--assets-dir is valid only for a framework-backed publication check')
  }

  if (mode === '--self-test') {
    selfTest(audit, loadJSONFile(developmentManifestPath, 'development artifact manifest'))
    return
  }
  let scan
  if (frameworks) {
    scan = assertScanMatchesAudit(audit, scanFrameworkClosure(frameworks, linkSet))
    console.log(`[privacy-manifest-audit] current ${scan.length}-target framework scan matches committed evidence`)
  }
  if (mode === '--check-publication') {
    assertPrivacyPublicationReady(audit, scan)
    if (assets) verifyPackagedManifests(audit, assets)
    console.log('[privacy-manifest-audit] reviewed privacy manifests and packaged bytes are publication-ready')
  } else {
    const affected = audit.scanEvidence.filter(entry => entry.requiredReasonAPIs.length > 0).length
    console.log(`[privacy-manifest-audit] metadata is fresh: ${audit.scanEvidence.length} targets, ${affected} with detected required-reason API imports; publication blockers are retained`)
  }
}

if (resolve(process.argv[1] ?? '') === scriptPath) main()
