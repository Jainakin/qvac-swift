#!/usr/bin/env node

import { createHash } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { basename, dirname, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { validateReleaseManifest } from './release-manifest.mjs'

const scriptDir = dirname(fileURLToPath(import.meta.url))
const repoRoot = resolve(scriptDir, '..', '..')

function sha256(buffer) {
  return createHash('sha256').update(buffer).digest('hex')
}

function fail(message) {
  throw new Error(`[bundle-provenance] ${message}`)
}

const portableArtifactForbiddenBytes = [
  '/Users/',
  '/private/tmp/',
  '/var/folders/',
  '/home/runner/work/',
  'C:\\Users\\',
  'file://',
]

function assertPortableEmbeddedGraph(bytes, headerBytes, header, bodyOffset) {
  const forbidden = [...portableArtifactForbiddenBytes, `${repoRoot}/`, `${basename(repoRoot)}/tools/runtime/`]
  const scan = (label, content) => {
    for (const marker of forbidden) {
      if (content.includes(Buffer.from(marker))) {
        fail(`${label} embeds non-portable checkout marker ${JSON.stringify(marker)}`)
      }
    }
  }

  scan('bundle header/resolution table', headerBytes)
  for (const [path, file] of Object.entries(header.files ?? {})) {
    if (!Number.isSafeInteger(file.offset) || !Number.isSafeInteger(file.length)
        || file.offset < 0 || file.length < 0 || bodyOffset + file.offset + file.length > bytes.length) {
      fail(`embedded file has invalid offset/length: ${path}`)
    }
    // Byte scanning every payload (not just guessed text extensions) avoids a
    // false pass when a generated script has an unfamiliar suffix.
    scan(`embedded file ${path}`, bytes.subarray(bodyOffset + file.offset, bodyOffset + file.offset + file.length))
  }
}

export function readBundleProvenance(bundlePath) {
  const bytes = readFileSync(bundlePath)
  const firstNewline = bytes.indexOf(0x0a)
  const secondNewline = bytes.indexOf(0x0a, firstNewline + 1)
  if (firstNewline < 1 || secondNewline < 0) fail('invalid bare-bundle prefix/header framing')
  const declaredHeaderBytes = Number(bytes.subarray(0, firstNewline).toString('ascii'))
  if (!Number.isSafeInteger(declaredHeaderBytes) || declaredHeaderBytes <= 0) {
    fail('first line is not a valid bare-bundle header length')
  }
  const encodedHeaderBytes = secondNewline - firstNewline - 1
  // bare-bundle counts the two newline framing bytes in its declared length.
  if (declaredHeaderBytes !== encodedHeaderBytes + 2) {
    fail(`declared header length ${declaredHeaderBytes} does not match encoded header ${encodedHeaderBytes}`)
  }

  let header
  const headerBytes = bytes.subarray(firstNewline + 1, secondNewline)
  try {
    header = JSON.parse(headerBytes.toString('utf8'))
  } catch (error) {
    fail(`header JSON is invalid: ${error.message}`)
  }
  if (!Number.isSafeInteger(header.version) || header.version < 0
      || typeof header.id !== 'string' || typeof header.main !== 'string') {
    fail('bundle header is missing version/id/main provenance fields')
  }
  if (!header.files?.[header.main]) fail(`bundle main ${header.main} is absent from files table`)

  const bodyOffset = secondNewline + 1
  const ranges = Object.entries(header.files ?? {}).map(([path, file]) => {
    if (!Number.isSafeInteger(file.offset) || !Number.isSafeInteger(file.length)
        || file.offset < 0 || file.length < 0 || bodyOffset + file.offset + file.length > bytes.length) {
      fail(`embedded file has invalid offset/length: ${path}`)
    }
    return { path, start: file.offset, end: file.offset + file.length }
  }).sort((left, right) => left.start - right.start || left.end - right.end)
  let declaredEnd = 0
  for (const range of ranges) {
    if (range.start !== declaredEnd) {
      const kind = range.start < declaredEnd ? 'overlaps another range' : 'leaves undeclared body bytes'
      fail(`embedded file ${range.path} ${kind} at offset ${range.start}`)
    }
    declaredEnd = range.end
  }
  if (declaredEnd !== bytes.length - bodyOffset) {
    fail(`bundle has ${bytes.length - bodyOffset - declaredEnd} undeclared trailing body bytes`)
  }
  assertPortableEmbeddedGraph(bytes, headerBytes, header, bodyOffset)
  function extract(path) {
    const file = header.files?.[path]
    if (!file) fail(`embedded file is missing: ${path}`)
    if (!Number.isSafeInteger(file.offset) || !Number.isSafeInteger(file.length)
        || file.offset < 0 || file.length < 0 || bodyOffset + file.offset + file.length > bytes.length) {
      fail(`embedded file has invalid offset/length: ${path}`)
    }
    return bytes.subarray(bodyOffset + file.offset, bodyOffset + file.offset + file.length)
  }

  const sdkPackagePaths = Object.keys(header.files ?? {})
    .filter(path => path.endsWith('/node_modules/@qvac/sdk/package.json'))
  if (sdkPackagePaths.length !== 1) {
    fail(`expected exactly one embedded @qvac/sdk/package.json, found ${sdkPackagePaths.length}`)
  }
  let sdkPackage
  try {
    sdkPackage = JSON.parse(extract(sdkPackagePaths[0]).toString('utf8'))
  } catch (error) {
    fail(`embedded @qvac/sdk/package.json is invalid: ${error.message}`)
  }

  const addons = [...new Set(Object.values(header.addons ?? {}).map(value => {
    const match = typeof value === 'string' ? value.match(/^linked:(.+)\.framework\//) : null
    if (!match) fail(`unrecognized linked addon mapping: ${String(value)}`)
    return match[1]
  }))].sort()

  return {
    path: resolve(bundlePath),
    size: bytes.length,
    sha256: sha256(bytes),
    headerVersion: header.version,
    bundleId: header.id,
    main: header.main,
    sdkVersion: sdkPackage.version,
    sdkPackagePath: sdkPackagePaths[0],
    addonTargets: addons,
  }
}

export function verifyBundle(bundlePath, artifactManifestPath) {
  const provenance = JSON.parse(readFileSync(resolve(repoRoot, 'tools/provenance/qvac-sdk.lock.json'), 'utf8'))
  const bundle = readBundleProvenance(bundlePath)
  if (bundle.sdkVersion !== provenance.sdkVersion) {
    fail(`${basename(bundlePath)} embeds @qvac/sdk ${bundle.sdkVersion}; exact ${provenance.sdkVersion} is required. Rebuild from tools/runtime/package-lock.json; old release assets are forbidden.`)
  }

  if (artifactManifestPath) {
    const manifest = validateReleaseManifest(JSON.parse(readFileSync(artifactManifestPath, 'utf8')))
    for (const [field, actual] of [
      ['sha256', bundle.sha256],
      ['size', bundle.size],
      ['bundleId', bundle.bundleId],
      ['main', bundle.main],
      ['embeddedSDKVersion', bundle.sdkVersion],
    ]) {
      if (manifest.bundle?.[field] !== actual) fail(`artifact manifest bundle.${field} does not match bundle`)
    }
    const declaredTargets = (manifest.bundle.addonTargets ?? []).slice().sort()
    if (JSON.stringify(declaredTargets) !== JSON.stringify(bundle.addonTargets)) {
      fail('artifact manifest addon target set does not match the bundle header')
    }
  }
  return bundle
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  const bundlePath = process.argv[2]
  const manifestFlag = process.argv.indexOf('--manifest')
  const manifestPath = manifestFlag >= 0 ? process.argv[manifestFlag + 1] : undefined
  if (!bundlePath || (manifestFlag >= 0 && !manifestPath)) {
    console.error('usage: verify-bundle-provenance.mjs <worker.mobile.bundle> [--manifest artifact-manifest.json]')
    process.exit(2)
  }
  const bundle = verifyBundle(bundlePath, manifestPath)
  console.log(`[bundle-provenance] id=${bundle.bundleId}`)
  console.log(`[bundle-provenance] sdk=${bundle.sdkVersion} sha256=${bundle.sha256} size=${bundle.size}`)
  console.log(`[bundle-provenance] main=${bundle.main} addons=${bundle.addonTargets.length}`)
  console.log(`[bundle-provenance] targets=${bundle.addonTargets.join(',')}`)
}
