#!/usr/bin/env node

import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const runtimeDir = dirname(fileURLToPath(import.meta.url))
const repoRoot = resolve(runtimeDir, '..', '..')
const provenance = JSON.parse(readFileSync(join(repoRoot, 'tools/provenance/qvac-sdk.lock.json'), 'utf8'))
const packageLock = JSON.parse(readFileSync(join(runtimeDir, 'package-lock.json'), 'utf8'))
const outputPath = join(runtimeDir, 'resolution-inventory.json')
const checkOnly = process.argv.includes('--check')

function packageName(packagePath, metadata) {
  if (metadata.name) return metadata.name
  const suffix = packagePath.split('node_modules/').at(-1)
  return suffix || '<root>'
}

function installedMetadata(packagePath) {
  const path = join(runtimeDir, packagePath, 'package.json')
  if (!existsSync(path)) return null
  return JSON.parse(readFileSync(path, 'utf8'))
}

const packages = []
for (const [packagePath, metadata] of Object.entries(packageLock.packages ?? {})) {
  if (!packagePath) continue
  const installed = installedMetadata(packagePath)
  const name = packageName(packagePath, installed ?? metadata)
  const nativeAddon = Boolean(
    installed?.addon
    || installed?.dependencies?.['bare-addon']
    || /(^|-)native($|-)/.test(name)
    || name === 'react-native-bare-kit'
  )
  const inScope = name.startsWith('@qvac/') || name.startsWith('bare-') || nativeAddon
  if (!inScope) continue
  if (!metadata.version || !metadata.resolved || !metadata.integrity) {
    throw new Error(`[runtime-inventory] ${packagePath} lacks immutable version/resolved/integrity metadata`)
  }
  packages.push({
    name,
    version: metadata.version,
    path: packagePath,
    resolved: metadata.resolved,
    integrity: metadata.integrity,
    nativeAddon,
  })
}

packages.sort((a, b) =>
  a.name < b.name ? -1 : a.name > b.name ? 1
    : a.path < b.path ? -1 : a.path > b.path ? 1 : 0
)

const inventory = {
  schemaVersion: 1,
  sdkVersion: provenance.sdkVersion,
  authoritativeSourceCommit: provenance.source.commit,
  identity: 'qvac-swift-tested-reconstruction',
  upstreamLockAvailable: false,
  warning: provenance.upstreamDependencyLock.reason,
  packages,
}
const rendered = JSON.stringify(inventory, null, 2) + '\n'

if (checkOnly) {
  if (!existsSync(outputPath) || readFileSync(outputPath, 'utf8') !== rendered) {
    throw new Error('[runtime-inventory] resolution-inventory.json is stale; run npm run inventory --prefix tools/runtime')
  }
  console.log(`[runtime-inventory] verified ${packages.length} exact QVAC/Bare/native resolutions`)
} else {
  writeFileSync(outputPath, rendered)
  console.log(`[runtime-inventory] wrote ${packages.length} exact QVAC/Bare/native resolutions -> ${outputPath}`)
}
