#!/usr/bin/env node

import { execFileSync } from 'node:child_process'
import { existsSync, readFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const runtimeDir = dirname(fileURLToPath(import.meta.url))
const repoRoot = resolve(runtimeDir, '..', '..')
const provenance = JSON.parse(readFileSync(join(repoRoot, 'tools/provenance/qvac-sdk.lock.json'), 'utf8'))
const packageJson = JSON.parse(readFileSync(join(runtimeDir, 'package.json'), 'utf8'))
const packageLock = JSON.parse(readFileSync(join(runtimeDir, 'package-lock.json'), 'utf8'))

function fail(message) {
  throw new Error(`[runtime-lock] ${message}`)
}

for (const [name, version] of Object.entries(packageJson.dependencies ?? {})) {
  if (!/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(version)) {
    fail(`root dependency ${name} must be exact, found ${version}`)
  }
}
if (packageJson.dependencies?.['@qvac/sdk'] !== provenance.sdkVersion) {
  fail(`root SDK dependency is not ${provenance.sdkVersion}`)
}
if (packageLock.lockfileVersion !== 3) fail(`expected npm lockfile v3, found ${packageLock.lockfileVersion}`)

const root = packageLock.packages?.['']
if (JSON.stringify(root?.dependencies) !== JSON.stringify(packageJson.dependencies)) {
  fail('package-lock root dependencies differ from package.json')
}

const sdkEntries = Object.entries(packageLock.packages ?? {})
  .filter(([path]) => path.endsWith('node_modules/@qvac/sdk'))
if (sdkEntries.length !== 1) fail(`expected one deduplicated @qvac/sdk, found ${sdkEntries.length}`)
const [, sdk] = sdkEntries[0]
if (sdk.version !== provenance.npm.version
    || sdk.resolved !== provenance.npm.tarball
    || sdk.integrity !== provenance.npm.integrity) {
  fail('resolved SDK tarball does not match the immutable published-tarball provenance lock')
}

for (const [path, metadata] of Object.entries(packageLock.packages ?? {})) {
  if (!path) continue
  if ((path.includes('node_modules/@qvac/') || path.includes('node_modules/bare-'))
      && (!metadata.version || !metadata.integrity || !metadata.resolved)) {
    fail(`${path} is not pinned to an immutable registry artifact`)
  }
}

// npm ls catches missing required and extraneous packages. The package.json
// walk additionally proves every installed package resolves to the exact
// version recorded by the committed lock rather than merely satisfying a
// caret range declared by the SDK.
try {
  execFileSync('npm', ['ls', '--all', '--prefix', runtimeDir], { stdio: 'pipe' })
} catch (error) {
  fail(`installed runtime graph is incomplete or extraneous; run npm ci --prefix tools/runtime (${error.message})`)
}
let installedCount = 0
for (const [path, metadata] of Object.entries(packageLock.packages ?? {})) {
  if (!path || !metadata.version) continue
  const packagePath = join(runtimeDir, path, 'package.json')
  if (!existsSync(packagePath)) continue // platform-inapplicable optional package
  const installed = JSON.parse(readFileSync(packagePath, 'utf8'))
  if (installed.version !== metadata.version) {
    fail(`${path} installed ${installed.version}, lock requires ${metadata.version}`)
  }
  installedCount++
}

console.log(`[runtime-lock] exact SDK ${sdk.version} / ${sdk.integrity}`)
console.log(`[runtime-lock] verified ${installedCount} installed package versions against package-lock.json`)
console.log(`[runtime-lock] ${provenance.upstreamDependencyLock.reason}`)
