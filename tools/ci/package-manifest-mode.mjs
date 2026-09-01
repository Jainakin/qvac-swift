#!/usr/bin/env node

import { createHash } from 'node:crypto'
import { copyFileSync, lstatSync, readFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  renderDevelopmentPackageManifest,
  renderPackageManifest,
  validateDevelopmentManifest,
} from '../release/release-manifest.mjs'

const scriptDirectory = dirname(fileURLToPath(import.meta.url))
const repositoryRoot = resolve(scriptDirectory, '../..')
const packagePath = resolve(repositoryRoot, 'Package.swift')
const developmentPackagePath = resolve(repositoryRoot, 'Package.swift.dev')
const developmentManifestPath = resolve(repositoryRoot, 'tools/release/artifacts.development.json')
const releaseBasePattern = /^https:\/\/github\.com\/Jainakin\/qvac-swift\/releases\/download\/(artifacts-sdk-0\.17\.0-r[1-9][0-9]*)\/$/
const legacyArtifactTag = 'artifacts-sdk-0.17.0-r1'
const legacySourceCommit = '85ac16212e43ec4572c96f04bf278cd67e52eb7f'

function fail(message) {
  throw new Error(`[package-manifest-mode] ${message}`)
}

function requireRegularFile(path, label) {
  let stat
  try { stat = lstatSync(path) } catch (error) { fail(`cannot inspect ${label}: ${error.message}`) }
  if (stat.isSymbolicLink() || !stat.isFile()) fail(`${label} must be a regular, non-symlink file`)
}

function countOccurrences(source, token) {
  return source.split(token).length - 1
}

function parseReleasePackage(packageText, developmentManifest) {
  const blockPattern = /        \.binaryTarget\(\n            name: "([A-Za-z0-9._@-]+)",\n            url: "(https:\/\/github\.com\/[^"\n]+)",\n            checksum: "([0-9a-f]{64})"\n        \),/g
  const artifacts = []
  let match
  while ((match = blockPattern.exec(packageText)) !== null) {
    artifacts.push({ target: match[1], url: match[2], checksum: match[3] })
  }

  const binaryTargetCount = countOccurrences(packageText, '        .binaryTarget(')
  if (binaryTargetCount !== artifacts.length) {
    fail('canonical Package.swift is neither the exact development manifest nor a strictly generated URL manifest')
  }
  if (artifacts.length !== developmentManifest.targets.length) {
    fail(`URL manifest has ${artifacts.length} binary targets; expected ${developmentManifest.targets.length}`)
  }

  const actualTargets = artifacts.map(artifact => artifact.target)
  if (JSON.stringify(actualTargets) !== JSON.stringify(developmentManifest.targets)) {
    fail('URL manifest target inventory/order differs from the verified development closure')
  }

  const dependencyPattern = /                \.target\(name: "([A-Za-z0-9._@-]+)", condition: \.when\(platforms: \[\.iOS\]\)\),/g
  const dependencies = []
  while ((match = dependencyPattern.exec(packageText)) !== null) dependencies.push(match[1])
  if (JSON.stringify(dependencies) !== JSON.stringify(developmentManifest.targets)) {
    fail('URL manifest iOS dependency inventory/order differs from the verified development closure')
  }

  let artifactTag
  let releaseBase
  for (const artifact of artifacts) {
    const suffix = `${artifact.target}.xcframework.zip`
    if (!artifact.url.endsWith(`/${suffix}`)) fail(`artifact URL/name mismatch for ${artifact.target}`)
    const base = artifact.url.slice(0, -suffix.length)
    const baseMatch = releaseBasePattern.exec(base)
    if (!baseMatch) fail(`artifact URL is not an immutable qvac-swift SDK 0.17 release URL: ${artifact.url}`)
    if (artifactTag === undefined) {
      artifactTag = baseMatch[1]
      releaseBase = base
    } else if (artifactTag !== baseMatch[1] || releaseBase !== base) {
      fail('all binary artifacts must use one immutable release tag and URL base')
    }
  }

  const syntheticManifest = {
    schemaVersion: artifactTag === legacyArtifactTag ? 2 : 3,
    mode: 'release',
    artifactTag,
    sourceCommit: artifactTag === legacyArtifactTag
      ? legacySourceCommit
      : '0000000000000000000000000000000000000001',
    sdk: developmentManifest.sdk,
    bundle: {
      assetName: 'worker.mobile.bundle',
      bundleId: developmentManifest.bundle.bundleId,
      main: developmentManifest.bundle.main,
      embeddedSDKVersion: developmentManifest.bundle.embeddedSDKVersion,
      size: developmentManifest.bundle.size,
      sha256: developmentManifest.bundle.sha256,
      addonTargets: developmentManifest.bundle.addonTargets,
      url: `${releaseBase}worker.mobile.bundle`,
    },
    notices: {
      assetName: 'THIRD_PARTY_NOTICES.md',
      size: 1,
      sha256: checksum('third-party-notices'),
      url: `${releaseBase}THIRD_PARTY_NOTICES.md`,
    },
    ...(artifactTag === legacyArtifactTag ? {} : releaseEvidence(releaseBase, developmentManifest.sdk)),
    artifacts: artifacts.map(artifact => ({
      target: artifact.target,
      assetName: `${artifact.target}.xcframework.zip`,
      size: 1,
      sha256: artifact.checksum,
      swiftChecksum: artifact.checksum,
      url: artifact.url,
    })),
  }

  const expected = renderPackageManifest(syntheticManifest)
  if (packageText !== expected) {
    fail('URL Package.swift differs from the deterministic release-manifest renderer')
  }
  return { mode: 'release', artifactTag }
}

export function inspectCanonicalPackage(packageText, developmentPackageText, developmentManifest) {
  validateDevelopmentManifest(developmentManifest)
  const expectedDevelopment = renderDevelopmentPackageManifest(developmentManifest)
  if (developmentPackageText !== expectedDevelopment) {
    fail('Package.swift.dev is stale relative to artifacts.development.json')
  }
  if (packageText === developmentPackageText) return { mode: 'development' }
  return parseReleasePackage(packageText, developmentManifest)
}

function loadInputs() {
  requireRegularFile(packagePath, 'Package.swift')
  requireRegularFile(developmentPackagePath, 'Package.swift.dev')
  requireRegularFile(developmentManifestPath, 'artifacts.development.json')
  return {
    packageText: readFileSync(packagePath, 'utf8'),
    developmentPackageText: readFileSync(developmentPackagePath, 'utf8'),
    developmentManifest: JSON.parse(readFileSync(developmentManifestPath, 'utf8')),
  }
}

function checksum(value) {
  return createHash('sha256').update(value).digest('hex')
}

function releaseEvidence(releaseBase, sdk) {
  return {
    privacyAudit: {
      assetName: 'privacy-manifest-audit.json',
      size: 1,
      sha256: checksum('privacy-manifest-audit'),
      url: `${releaseBase}privacy-manifest-audit.json`,
    },
    runtimeResolutionInventory: {
      assetName: 'runtime-resolution-inventory.json',
      size: 1,
      sha256: sdk.runtimeInventorySHA256,
      url: `${releaseBase}runtime-resolution-inventory.json`,
    },
    sdkProvenance: {
      assetName: 'qvac-sdk-provenance.json',
      size: 1,
      sha256: checksum('sdk-provenance'),
      url: `${releaseBase}qvac-sdk-provenance.json`,
    },
  }
}

function makeReleaseFixture(developmentManifest, tag = 'artifacts-sdk-0.17.0-r99') {
  const releaseBase = `https://github.com/Jainakin/qvac-swift/releases/download/${tag}/`
  return renderPackageManifest({
    schemaVersion: tag === legacyArtifactTag ? 2 : 3,
    mode: 'release',
    artifactTag: tag,
    sourceCommit: tag === legacyArtifactTag
      ? legacySourceCommit
      : '0000000000000000000000000000000000000001',
    sdk: developmentManifest.sdk,
    bundle: {
      assetName: 'worker.mobile.bundle',
      bundleId: developmentManifest.bundle.bundleId,
      main: developmentManifest.bundle.main,
      embeddedSDKVersion: developmentManifest.bundle.embeddedSDKVersion,
      size: developmentManifest.bundle.size,
      sha256: developmentManifest.bundle.sha256,
      addonTargets: developmentManifest.bundle.addonTargets,
      url: `${releaseBase}worker.mobile.bundle`,
    },
    notices: {
      assetName: 'THIRD_PARTY_NOTICES.md',
      size: 1,
      sha256: checksum('third-party-notices'),
      url: `${releaseBase}THIRD_PARTY_NOTICES.md`,
    },
    ...(tag === legacyArtifactTag ? {} : releaseEvidence(releaseBase, developmentManifest.sdk)),
    artifacts: developmentManifest.targets.map(target => {
      const digest = checksum(target)
      return {
        target,
        assetName: `${target}.xcframework.zip`,
        size: 1,
        sha256: digest,
        swiftChecksum: digest,
        url: `${releaseBase}${target}.xcframework.zip`,
      }
    }),
  })
}

function expectFailure(action, label) {
  try { action() } catch { return }
  fail(`self-test expected rejection: ${label}`)
}

function selfTest() {
  const { developmentPackageText, developmentManifest } = loadInputs()
  const development = inspectCanonicalPackage(
    developmentPackageText,
    developmentPackageText,
    developmentManifest,
  )
  if (development.mode !== 'development') fail('self-test did not recognize the development manifest')

  const release = makeReleaseFixture(developmentManifest)
  const inspected = inspectCanonicalPackage(release, developmentPackageText, developmentManifest)
  if (inspected.mode !== 'release' || inspected.artifactTag !== 'artifacts-sdk-0.17.0-r99') {
    fail('self-test did not recognize the generated URL manifest')
  }
  const legacyRelease = makeReleaseFixture(developmentManifest, legacyArtifactTag)
  const inspectedLegacy = inspectCanonicalPackage(legacyRelease, developmentPackageText, developmentManifest)
  if (inspectedLegacy.mode !== 'release' || inspectedLegacy.artifactTag !== legacyArtifactTag) {
    fail('self-test did not recognize the immutable historical r1 URL manifest')
  }
  expectFailure(
    () => inspectCanonicalPackage(release.replace('Jainakin/qvac-swift', 'attacker/fork'), developmentPackageText, developmentManifest),
    'foreign artifact repository',
  )
  expectFailure(
    () => inspectCanonicalPackage(release.replace('artifacts-sdk-0.17.0-r99', 'latest'), developmentPackageText, developmentManifest),
    'mutable release URL',
  )
  expectFailure(
    () => inspectCanonicalPackage(release.replace('checksum: "', 'checksum: "x'), developmentPackageText, developmentManifest),
    'invalid checksum',
  )
  expectFailure(
    () => inspectCanonicalPackage(`${release}\n// hand edit\n`, developmentPackageText, developmentManifest),
    'hand-edited release manifest',
  )
  console.log('[package-manifest-mode-test] development and strict URL release modes verified')
}

const argument = process.argv[2] ?? '--check'
if (argument === '--self-test') {
  selfTest()
} else {
  if (!['--check', '--activate-development'].includes(argument) || process.argv.length > 3) {
    fail('usage: package-manifest-mode.mjs [--check|--activate-development|--self-test]')
  }
  const inputs = loadInputs()
  const result = inspectCanonicalPackage(
    inputs.packageText,
    inputs.developmentPackageText,
    inputs.developmentManifest,
  )
  console.log(`[package-manifest-mode] canonical mode=${result.mode}${result.artifactTag ? ` tag=${result.artifactTag}` : ''}`)
  if (argument === '--activate-development') {
    if (process.env.CI !== 'true') fail('--activate-development is restricted to an ephemeral CI checkout')
    copyFileSync(developmentPackagePath, packagePath)
    console.log('[package-manifest-mode] activated verified Package.swift.dev for local CI compilation')
  }
}
