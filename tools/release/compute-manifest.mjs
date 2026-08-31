#!/usr/bin/env node
// Compute the minimal native link closure and, after deterministic packaging,
// produce the immutable schema-v2 release manifest consumed by Package.swift.

import { createHash } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { existsSync, lstatSync, readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs'
import { dirname, isAbsolute, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { readBundleProvenance, verifyBundle } from './verify-bundle-provenance.mjs'

const scriptDir = dirname(fileURLToPath(import.meta.url))
const repoRoot = resolve(scriptDir, '..', '..')
const mode = process.argv[2]

function fail(message) {
  throw new Error(`[artifact-manifest] ${message}`)
}

function sha256(path) {
  return createHash('sha256').update(readFileSync(path)).digest('hex')
}

function requireRegularAsset(path, label) {
  if (!existsSync(path)) fail(`missing ${label}`)
  const metadata = lstatSync(path)
  if (metadata.isSymbolicLink() || !metadata.isFile() || metadata.size <= 0) {
    fail(`${label} must be a non-empty regular, non-symlink file`)
  }
  return metadata
}

function option(name) {
  const index = process.argv.indexOf(name)
  return index >= 0 ? process.argv[index + 1] : undefined
}

function frameworkInventory(artifactsDir) {
  const available = new Map()
  for (const entry of readdirSync(artifactsDir)) {
    const path = join(artifactsDir, entry)
    if (entry.endsWith('.xcframework') && statSync(path).isDirectory()) {
      available.set(entry.slice(0, -'.xcframework'.length), path)
    }
  }
  return available
}

function safeRelativePath(value, field, name) {
  if (typeof value !== 'string' || value.length === 0 || isAbsolute(value)
      || value.includes('\\') || value.split('/').some(component => component === '' || component === '.' || component === '..')) {
    fail(`${name} has unsafe ${field}: ${String(value)}`)
  }
  return value
}

function iosSlices(name, xcframework) {
  const infoPath = join(xcframework, 'Info.plist')
  if (!existsSync(infoPath)) fail(`${name} is missing XCFramework Info.plist`)
  let info
  try {
    const json = execFileSync('plutil', ['-convert', 'json', '-o', '-', infoPath], { encoding: 'utf8' })
    info = JSON.parse(json)
  } catch (error) {
    fail(`cannot parse ${name} XCFramework Info.plist: ${error.message}`)
  }
  if (!Array.isArray(info.AvailableLibraries)) fail(`${name} has no AvailableLibraries array`)

  const slices = []
  const coverage = { device: new Set(), simulator: new Set() }
  for (const library of info.AvailableLibraries) {
    if (library.SupportedPlatform !== 'ios') continue
    const variant = library.SupportedPlatformVariant
    if (variant !== undefined && variant !== 'simulator') {
      fail(`${name} has unsupported iOS platform variant: ${variant}`)
    }
    const kind = variant === 'simulator' ? 'simulator' : 'device'
    const identifier = safeRelativePath(library.LibraryIdentifier, 'LibraryIdentifier', name)
    const binaryRelative = safeRelativePath(
      library.BinaryPath ?? `${safeRelativePath(library.LibraryPath, 'LibraryPath', name)}/${name}`,
      'BinaryPath',
      name,
    )
    if (!Array.isArray(library.SupportedArchitectures) || library.SupportedArchitectures.length === 0) {
      fail(`${name}/${identifier} has no declared architectures`)
    }
    const binary = join(xcframework, identifier, binaryRelative)
    if (!existsSync(binary)) fail(`${name}/${identifier} is missing binary ${binaryRelative}`)
    const actual = new Set(execFileSync('lipo', ['-archs', binary], { encoding: 'utf8' }).trim().split(/\s+/).filter(Boolean))
    for (const architecture of library.SupportedArchitectures) {
      if (!actual.has(architecture)) {
        fail(`${name}/${identifier} declares ${architecture}, but its Mach-O binary does not contain it`)
      }
      coverage[kind].add(architecture)
    }
    slices.push({ identifier, kind, binary })
  }

  for (const architecture of ['arm64']) {
    if (!coverage.device.has(architecture)) fail(`${name} lacks required iOS device architecture ${architecture}`)
  }
  for (const architecture of ['arm64', 'x86_64']) {
    if (!coverage.simulator.has(architecture)) fail(`${name} lacks required iOS simulator architecture ${architecture}`)
  }
  return slices
}

function rpathDependencies(name, xcframework) {
  const dependencies = new Set()
  for (const { identifier, binary } of iosSlices(name, xcframework)) {
    const output = execFileSync('otool', ['-L', binary], { encoding: 'utf8' })
    for (const line of output.split('\n')) {
      const match = line.match(/@rpath\/([^/]+)\.framework\//)
      if (match && match[1] !== name) dependencies.add(match[1])
    }
    if (!output.trim()) fail(`otool returned no dependency data for ${name}/${identifier}`)
  }
  return dependencies
}

function computeLinkSet(artifactsDir, bundlePath) {
  const bundle = readBundleProvenance(bundlePath)
  const available = frameworkInventory(artifactsDir)
  const needed = new Set(['BareKit', ...bundle.addonTargets])
  const queue = [...needed]
  const missing = new Set()

  while (queue.length > 0) {
    const name = queue.shift()
    const framework = available.get(name)
    if (!framework) {
      missing.add(name)
      continue
    }
    for (const dependency of rpathDependencies(name, framework)) {
      if (!needed.has(dependency)) {
        needed.add(dependency)
        queue.push(dependency)
      }
    }
  }
  if (missing.size > 0) fail(`missing required xcframeworks: ${[...missing].sort().join(', ')}`)

  const targets = ['BareKit', ...[...needed].filter(name => name !== 'BareKit').sort()]
  const excludedUnreferencedTargets = [...available.keys()]
    .filter(name => !needed.has(name))
    .sort()

  return {
    schemaVersion: 1,
    mode: 'link-set',
    bundle: {
      bundleId: bundle.bundleId,
      main: bundle.main,
      embeddedSDKVersion: bundle.sdkVersion,
      size: bundle.size,
      sha256: bundle.sha256,
      addonTargets: bundle.addonTargets,
    },
    targets,
    stagedTargetCount: available.size,
    excludedUnreferencedTargets,
  }
}

if (mode === 'link-set' || mode === 'development') {
  const artifactsDir = resolve(process.argv[3] ?? '')
  const bundlePath = resolve(process.argv[4] ?? '')
  const outPath = resolve(process.argv[5] ?? '')
  if (!process.argv[3] || !process.argv[4] || !process.argv[5]) {
    fail('usage: compute-manifest.mjs <link-set|development> <xcframework-dir> <bundle> <out.json>')
  }
  verifyBundle(bundlePath)
  const linkSet = computeLinkSet(artifactsDir, bundlePath)
  if (mode === 'development') {
    const provenance = JSON.parse(readFileSync(join(repoRoot, 'tools/provenance/qvac-sdk.lock.json'), 'utf8'))
    const inventoryPath = join(repoRoot, 'tools/runtime/resolution-inventory.json')
    const development = {
      schemaVersion: 2,
      mode: 'development',
      releaseEligible: false,
      sdk: {
        version: provenance.sdkVersion,
        sourceCommit: provenance.source.commit,
        npmIntegrity: provenance.npm.integrity,
        runtimeInventorySHA256: sha256(inventoryPath),
      },
      frameworkRoot: 'tools/runtime/.build/artifacts',
      bundle: {
        path: 'Sources/QVACClient/Resources/worker.mobile.bundle',
        ...linkSet.bundle,
      },
      targets: linkSet.targets,
      nativeClosure: {
        stagedTargetCount: linkSet.stagedTargetCount,
        linkedTargetCount: linkSet.targets.length,
        excludedUnreferencedTargets: linkSet.excludedUnreferencedTargets,
      },
      reason: 'Exact local SDK 0.17.0 graph for development. It is not release-eligible until the same immutable framework archives are published and a URL manifest is generated.',
    }
    writeFileSync(outPath, JSON.stringify(development, null, 2) + '\n')
    console.log(`[artifact-manifest] development graph: ${development.targets.length} targets -> ${outPath}`)
  } else {
    writeFileSync(outPath, JSON.stringify(linkSet, null, 2) + '\n')
    console.log(
      `[artifact-manifest] link set: ${linkSet.targets.length}/${linkSet.stagedTargetCount} targets; `
      + `${linkSet.excludedUnreferencedTargets.length} unreferenced staged targets excluded -> ${outPath}`,
    )
  }
} else if (mode === 'release') {
  const linkSetPath = resolve(process.argv[3] ?? '')
  const bundlePath = resolve(process.argv[4] ?? '')
  const assetsDir = resolve(process.argv[5] ?? '')
  const outPath = resolve(process.argv[6] ?? '')
  const artifactTag = option('--artifact-tag')
  const repository = option('--repository')
  const sourceCommit = option('--source-commit')
  if (!process.argv[3] || !process.argv[4] || !process.argv[5] || !process.argv[6]
      || !artifactTag || !repository || !sourceCommit) {
    fail('usage: compute-manifest.mjs release <link-set.json> <bundle> <asset-dir> <out.json> --artifact-tag <tag> --repository <owner/repo> --source-commit <sha>')
  }
  if (!/^artifacts-sdk-0\.17\.0-r[1-9][0-9]*$/.test(artifactTag)) fail(`invalid artifact tag: ${artifactTag}`)
  if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repository)) fail(`invalid repository: ${repository}`)
  if (!/^[0-9a-f]{40}$/.test(sourceCommit)) fail(`invalid source commit: ${sourceCommit}`)

  const provenance = JSON.parse(readFileSync(join(repoRoot, 'tools/provenance/qvac-sdk.lock.json'), 'utf8'))
  const linkSet = JSON.parse(readFileSync(linkSetPath, 'utf8'))
  const bundle = verifyBundle(bundlePath)
  if (linkSet.mode !== 'link-set' || linkSet.bundle.sha256 !== bundle.sha256) fail('link set does not belong to this bundle')
  const stagedBundle = join(assetsDir, 'worker.mobile.bundle')
  requireRegularAsset(stagedBundle, 'staged worker.mobile.bundle')
  if (sha256(stagedBundle) !== bundle.sha256) fail('staged worker.mobile.bundle changed')

  const noticesAssetName = 'THIRD_PARTY_NOTICES.md'
  const noticesPath = join(assetsDir, noticesAssetName)
  const noticesMetadata = requireRegularAsset(noticesPath, `staged ${noticesAssetName}`)

  const inventoryPath = join(repoRoot, 'tools/runtime/resolution-inventory.json')
  const artifacts = linkSet.targets.map(target => {
    if (!/^[A-Za-z0-9._@-]+$/.test(target)) fail(`unsafe target: ${target}`)
    const assetName = `${target}.xcframework.zip`
    const path = join(assetsDir, assetName)
    requireRegularAsset(path, `packaged artifact ${assetName}`)
    const entries = execFileSync('unzip', ['-Z1', path], { encoding: 'utf8' })
      .split('\n').filter(Boolean)
    const unsafe = entries.find(entry => {
      const components = entry.split('/')
      return entry.startsWith('/') || entry.includes('\\')
        || components.includes('.') || components.includes('..')
        || !entry.startsWith(`${target}.xcframework/`)
    })
    if (entries.length === 0 || unsafe) {
      fail(`${assetName} does not contain exactly the expected xcframework root`)
    }
    execFileSync('unzip', ['-tqq', path], { stdio: 'pipe' })
    const checksum = sha256(path)
    return {
      target,
      assetName,
      url: `https://github.com/${repository}/releases/download/${artifactTag}/${assetName}`,
      size: statSync(path).size,
      sha256: checksum,
      swiftChecksum: checksum,
    }
  })

  const manifest = {
    schemaVersion: 2,
    mode: 'release',
    artifactTag,
    sourceCommit,
    sdk: {
      version: provenance.sdkVersion,
      sourceCommit: provenance.source.commit,
      npmIntegrity: provenance.npm.integrity,
      runtimeInventorySHA256: sha256(inventoryPath),
    },
    bundle: {
      assetName: 'worker.mobile.bundle',
      url: `https://github.com/${repository}/releases/download/${artifactTag}/worker.mobile.bundle`,
      size: bundle.size,
      sha256: bundle.sha256,
      bundleId: bundle.bundleId,
      main: bundle.main,
      embeddedSDKVersion: bundle.sdkVersion,
      addonTargets: bundle.addonTargets,
    },
    notices: {
      assetName: noticesAssetName,
      url: `https://github.com/${repository}/releases/download/${artifactTag}/${noticesAssetName}`,
      size: noticesMetadata.size,
      sha256: sha256(noticesPath),
    },
    artifacts,
  }
  writeFileSync(outPath, JSON.stringify(manifest, null, 2) + '\n')
  verifyBundle(bundlePath, outPath)
  console.log(`[artifact-manifest] release manifest: ${artifacts.length} immutable artifacts -> ${outPath}`)
} else {
  fail('first argument must be link-set, development, or release')
}
