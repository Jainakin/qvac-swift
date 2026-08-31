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

const manifestPath = process.argv[2]
if (!manifestPath) {
  throw new Error('usage: verify-release.mjs <artifact-manifest.json> [--source-commit <sha>] [--assets-dir <dir>] [--package <Package.swift>] [--bundle <worker.mobile.bundle>] [--remote]')
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

async function verifyRemote(url, expectedSize, expectedHash) {
  const response = await fetch(url, { redirect: 'follow', signal: AbortSignal.timeout(300_000) })
  if (!response.ok || !response.body) fail(`download failed (${response.status}) for ${url}`)
  const hash = createHash('sha256')
  let size = 0
  for await (const chunk of response.body) {
    size += chunk.byteLength
    hash.update(chunk)
  }
  const actualHash = hash.digest('hex')
  if (size !== expectedSize) fail(`remote size mismatch for ${url}: expected ${expectedSize}, got ${size}`)
  if (actualHash !== expectedHash) fail(`remote SHA-256 mismatch for ${url}: expected ${expectedHash}, got ${actualHash}`)
  console.log(`[release-preflight] remote verified ${basename(new URL(url).pathname)} (${size} bytes)`)
}

const manifest = loadReleaseManifest(resolve(manifestPath))
const expectedSourceCommit = option('--source-commit')
if (expectedSourceCommit) assertReleaseSourceCommit(manifest, expectedSourceCommit)
const assetsDir = option('--assets-dir')
if (assetsDir) {
  const root = resolve(assetsDir)
  verifyFile(join(root, manifest.bundle.assetName), manifest.bundle.size, manifest.bundle.sha256)
  verifyFile(join(root, manifest.notices.assetName), manifest.notices.size, manifest.notices.sha256)
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

if (process.argv.includes('--remote')) {
  await verifyRemote(manifest.bundle.url, manifest.bundle.size, manifest.bundle.sha256)
  await verifyRemote(manifest.notices.url, manifest.notices.size, manifest.notices.sha256)
  for (const artifact of manifest.artifacts) await verifyRemote(artifact.url, artifact.size, artifact.sha256)
}

console.log(`[release-preflight] SDK 0.17.0 release manifest verified (${manifest.artifacts.length} targets)`)
