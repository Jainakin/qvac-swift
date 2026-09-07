#!/usr/bin/env node

import { createHash } from 'node:crypto'
import { existsSync, lstatSync, readFileSync } from 'node:fs'
import { basename, join, resolve } from 'node:path'
import {
  assertReleaseSourceCommit,
  loadReleaseManifest,
  renderPackageManifest,
  sha256,
} from './release-manifest.mjs'
import { verifyBundle } from './verify-bundle-provenance.mjs'
import { validatePrivacyAuditDocument } from './verify-privacy-manifests.mjs'

const manifestPath = process.argv[2]
if (!manifestPath) {
  throw new Error('usage: verify-release.mjs <artifact-manifest.json> [--require-schema <2|3>] [--source-commit <sha>] [--assets-dir <dir>] [--package <Package.swift>] [--bundle <worker.mobile.bundle>] [--privacy-audit <json>] [--remote]')
}

function option(name) {
  const index = process.argv.indexOf(name)
  return index >= 0 ? process.argv[index + 1] : undefined
}

function fail(message) {
  throw new Error(`[release-preflight] ${message}`)
}

function verifyFile(path, expectedSize, expectedHash) {
  if (!existsSync(path)) fail(`missing ${path}`)
  const metadata = lstatSync(path)
  if (metadata.isSymbolicLink() || !metadata.isFile()) fail(`expected a regular non-symlink file: ${path}`)
  if (metadata.size !== expectedSize) fail(`size mismatch for ${path}`)
  const actual = sha256(path)
  if (actual !== expectedHash) fail(`SHA-256 mismatch for ${path}: expected ${expectedHash}, got ${actual}`)
}

function parseJSONEvidence(bytes, label) {
  try {
    return JSON.parse(bytes.toString('utf8'))
  } catch (error) {
    fail(`${label} is not valid JSON: ${error.message}`)
  }
}

function stableJSON(value) {
  if (Array.isArray(value)) return `[${value.map(stableJSON).join(',')}]`
  if (value !== null && typeof value === 'object') {
    return `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${stableJSON(value[key])}`).join(',')}}`
  }
  return JSON.stringify(value)
}

function digestBytes(bytes) {
  return createHash('sha256').update(bytes).digest('hex')
}

function verifyEvidenceContents(
  manifest,
  runtimeInventoryBytes,
  sdkProvenanceBytes,
  privacyAuditBytes,
  bareKitPatchBytes,
  bareKitProvenanceBytes,
  bareKitNativeClosureBytes,
) {
  const inventory = parseJSONEvidence(runtimeInventoryBytes, 'runtime resolution inventory')
  if (inventory?.schemaVersion !== 1
      || inventory?.sdkVersion !== manifest.sdk.version
      || inventory?.authoritativeSourceCommit !== manifest.sdk.sourceCommit) {
    fail('runtime resolution inventory does not describe the manifest SDK source')
  }

  const provenance = parseJSONEvidence(sdkProvenanceBytes, 'SDK provenance')
  if (provenance?.schemaVersion !== 1
      || provenance?.sdkVersion !== manifest.sdk.version
      || provenance?.source?.commit !== manifest.sdk.sourceCommit
      || provenance?.npm?.name !== '@qvac/sdk'
      || provenance?.npm?.version !== manifest.sdk.version
      || provenance?.npm?.integrity !== manifest.sdk.npmIntegrity
      || provenance?.npm?.gitHead !== manifest.sdk.sourceCommit) {
    fail('SDK provenance does not describe the manifest SDK source and npm artifact')
  }

  const privacyAudit = parseJSONEvidence(privacyAuditBytes, 'privacy manifest audit')
  validatePrivacyAuditDocument(privacyAudit)
  if (privacyAudit.scope.sdkVersion !== manifest.sdk.version
      || privacyAudit.scanEvidence.length !== manifest.artifacts.length
      || JSON.stringify(privacyAudit.scanEvidence.map(entry => entry.target))
        !== JSON.stringify(manifest.artifacts.map(entry => entry.target))) {
    fail('privacy manifest audit does not describe the manifest SDK and artifact closure')
  }

  const bareKitProvenance = parseJSONEvidence(bareKitProvenanceBytes, 'BareKit provenance')
  if (bareKitProvenance?.schemaVersion !== 2
      || bareKitProvenance?.component !== 'BareKit'
      || bareKitProvenance?.upstreamVersion !== '2.3.0'
      || bareKitProvenance?.patch?.file !== manifest.bareKitPatch.assetName
      || bareKitProvenance?.patch?.sha256 !== digestBytes(bareKitPatchBytes)
      || bareKitProvenance?.candidate?.revisionFloor !== 2
      || bareKitProvenance?.nativeClosure === null
      || typeof bareKitProvenance?.nativeClosure !== 'object') {
    fail('BareKit provenance does not describe the manifest patch and r2 native closure')
  }

  const closure = parseJSONEvidence(bareKitNativeClosureBytes, 'BareKit native closure')
  const mirror = bareKitProvenance.nativeClosure.prebuiltArchiveMirror
  const expectedTargets = Object.fromEntries(
    Object.keys(mirror?.targets ?? {}).sort().map(target => [target, {
      driveKey: mirror.driveKey,
      checkout: mirror.checkout,
      files: mirror.targets[target],
    }]),
  )
  if (closure?.schemaVersion !== 1
      || closure?.component !== 'BareKit native dependency closure'
      || closure?.upstreamCommit !== bareKitProvenance.upstream?.commit
      || closure?.provenanceLockSHA256 !== digestBytes(bareKitProvenanceBytes)
      || closure?.nativeClosureSHA256 !== digestBytes(Buffer.from(stableJSON(bareKitProvenance.nativeClosure)))
      || stableJSON(closure?.sources) !== stableJSON(bareKitProvenance.nativeClosure.sources)
      || stableJSON(closure?.targets) !== stableJSON(expectedTargets)) {
    fail('BareKit native closure does not match the bound provenance lock')
  }
}

async function verifyRemote(url, expectedSize, expectedHash, captureBytes = false) {
  const response = await fetch(url, { redirect: 'follow', signal: AbortSignal.timeout(300_000) })
  if (!response.ok || !response.body) fail(`download failed (${response.status}) for ${url}`)
  const hash = createHash('sha256')
  const chunks = captureBytes ? [] : undefined
  let size = 0
  for await (const chunk of response.body) {
    size += chunk.byteLength
    if (size > expectedSize) fail(`remote size exceeds ${expectedSize} bytes for ${url}`)
    hash.update(chunk)
    if (chunks) chunks.push(Buffer.from(chunk))
  }
  const actualHash = hash.digest('hex')
  if (size !== expectedSize) fail(`remote size mismatch for ${url}: expected ${expectedSize}, got ${size}`)
  if (actualHash !== expectedHash) fail(`remote SHA-256 mismatch for ${url}: expected ${expectedHash}, got ${actualHash}`)
  console.log(`[release-preflight] remote verified ${basename(new URL(url).pathname)} (${size} bytes)`)
  return chunks ? Buffer.concat(chunks, size) : undefined
}

const manifest = loadReleaseManifest(resolve(manifestPath))
const requiredSchema = option('--require-schema')
if (requiredSchema !== undefined) {
  if (!['2', '3'].includes(requiredSchema)) fail(`invalid required schema: ${requiredSchema}`)
  if (manifest.schemaVersion !== Number(requiredSchema)) {
    fail(`release path requires schema v${requiredSchema}, got schema v${manifest.schemaVersion}`)
  }
}
const expectedSourceCommit = option('--source-commit')
if (expectedSourceCommit) assertReleaseSourceCommit(manifest, expectedSourceCommit)
const assetsDir = option('--assets-dir')
if (assetsDir) {
  const root = resolve(assetsDir)
  verifyFile(join(root, manifest.bundle.assetName), manifest.bundle.size, manifest.bundle.sha256)
  verifyFile(join(root, manifest.notices.assetName), manifest.notices.size, manifest.notices.sha256)
  if (manifest.schemaVersion === 3) {
    const privacyAuditPath = join(root, manifest.privacyAudit.assetName)
    const runtimeInventoryPath = join(root, manifest.runtimeResolutionInventory.assetName)
    const sdkProvenancePath = join(root, manifest.sdkProvenance.assetName)
    const bareKitPatchPath = join(root, manifest.bareKitPatch.assetName)
    const bareKitProvenancePath = join(root, manifest.bareKitProvenance.assetName)
    const bareKitNativeClosurePath = join(root, manifest.bareKitNativeClosure.assetName)
    verifyFile(privacyAuditPath, manifest.privacyAudit.size, manifest.privacyAudit.sha256)
    verifyFile(
      runtimeInventoryPath,
      manifest.runtimeResolutionInventory.size,
      manifest.runtimeResolutionInventory.sha256,
    )
    verifyFile(sdkProvenancePath, manifest.sdkProvenance.size, manifest.sdkProvenance.sha256)
    verifyFile(bareKitPatchPath, manifest.bareKitPatch.size, manifest.bareKitPatch.sha256)
    verifyFile(
      bareKitProvenancePath,
      manifest.bareKitProvenance.size,
      manifest.bareKitProvenance.sha256,
    )
    verifyFile(
      bareKitNativeClosurePath,
      manifest.bareKitNativeClosure.size,
      manifest.bareKitNativeClosure.sha256,
    )
    verifyEvidenceContents(
      manifest,
      readFileSync(runtimeInventoryPath),
      readFileSync(sdkProvenancePath),
      readFileSync(privacyAuditPath),
      readFileSync(bareKitPatchPath),
      readFileSync(bareKitProvenancePath),
      readFileSync(bareKitNativeClosurePath),
    )
  }
  for (const artifact of manifest.artifacts) verifyFile(join(root, artifact.assetName), artifact.size, artifact.sha256)
}

const packagePath = option('--package')
if (packagePath) {
  const path = resolve(packagePath)
  if (!existsSync(path)) fail(`missing canonical package manifest: ${path}`)
  const actual = readFileSync(path, 'utf8')
  const expected = renderPackageManifest(manifest)
  if (actual !== expected) fail(`${path} is path-based, stale, or differs from the verified release manifest; regenerate it with generate-package-manifest.mjs`)
  const binaryTargetBodies = [...actual.matchAll(/\.binaryTarget\(([\s\S]*?)\n\s*\),/g)].map(match => match[1])
  if (binaryTargetBodies.length !== manifest.artifacts.length) fail(`${path} has an unexpected binary-target count`)
  if (binaryTargetBodies.some(body => /\bpath\s*:/.test(body))) fail(`${path} contains a path-based binary target`)
  console.log(`[release-preflight] canonical Package.swift exactly matches ${manifest.artifacts.length} immutable artifacts`)
}

const bundlePath = option('--bundle')
if (bundlePath) {
  const bundle = verifyBundle(resolve(bundlePath), resolve(manifestPath))
  if (bundle.sha256 !== manifest.bundle.sha256) fail('committed worker bundle does not match release manifest')
}

const privacyAuditPath = option('--privacy-audit')
if (privacyAuditPath) {
  if (manifest.schemaVersion !== 3) fail('--privacy-audit requires a hardened schema-v3 release')
  verifyFile(resolve(privacyAuditPath), manifest.privacyAudit.size, manifest.privacyAudit.sha256)
}

if (process.argv.includes('--remote')) {
  await verifyRemote(manifest.bundle.url, manifest.bundle.size, manifest.bundle.sha256)
  await verifyRemote(manifest.notices.url, manifest.notices.size, manifest.notices.sha256)
  if (manifest.schemaVersion === 3) {
    const privacyAuditBytes = await verifyRemote(
      manifest.privacyAudit.url,
      manifest.privacyAudit.size,
      manifest.privacyAudit.sha256,
      true,
    )
    const runtimeInventoryBytes = await verifyRemote(
      manifest.runtimeResolutionInventory.url,
      manifest.runtimeResolutionInventory.size,
      manifest.runtimeResolutionInventory.sha256,
      true,
    )
    const sdkProvenanceBytes = await verifyRemote(
      manifest.sdkProvenance.url,
      manifest.sdkProvenance.size,
      manifest.sdkProvenance.sha256,
      true,
    )
    const bareKitPatchBytes = await verifyRemote(
      manifest.bareKitPatch.url,
      manifest.bareKitPatch.size,
      manifest.bareKitPatch.sha256,
      true,
    )
    const bareKitProvenanceBytes = await verifyRemote(
      manifest.bareKitProvenance.url,
      manifest.bareKitProvenance.size,
      manifest.bareKitProvenance.sha256,
      true,
    )
    const bareKitNativeClosureBytes = await verifyRemote(
      manifest.bareKitNativeClosure.url,
      manifest.bareKitNativeClosure.size,
      manifest.bareKitNativeClosure.sha256,
      true,
    )
    verifyEvidenceContents(
      manifest,
      runtimeInventoryBytes,
      sdkProvenanceBytes,
      privacyAuditBytes,
      bareKitPatchBytes,
      bareKitProvenanceBytes,
      bareKitNativeClosureBytes,
    )
  }
  for (const artifact of manifest.artifacts) await verifyRemote(artifact.url, artifact.size, artifact.sha256)
}

const formatDescription = manifest.schemaVersion === 3 ? 'hardened byte-bound' : 'historical immutable r1'
console.log(`[release-preflight] SDK 0.17.0 ${formatDescription} schema v${manifest.schemaVersion} manifest verified (${manifest.artifacts.length} targets)`)
