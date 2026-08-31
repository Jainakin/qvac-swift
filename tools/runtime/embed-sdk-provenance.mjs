#!/usr/bin/env node
// Make the exact SDK package metadata part of the bundle graph. bare-pack would
// otherwise tree-shake package.json, leaving a mobile artifact whose embedded SDK
// version cannot be independently inspected.

import { readFileSync, writeFileSync } from 'node:fs'
import { dirname, relative, resolve, sep } from 'node:path'
import { fileURLToPath } from 'node:url'

const runtimeDir = dirname(fileURLToPath(import.meta.url))
const repoRoot = resolve(runtimeDir, '..', '..')
const entryPath = process.argv[2]
if (!entryPath) {
  console.error('usage: embed-sdk-provenance.mjs <generated-worker.entry.mjs>')
  process.exit(2)
}
const provenance = JSON.parse(readFileSync(resolve(repoRoot, 'tools/provenance/qvac-sdk.lock.json'), 'utf8'))
const sdkPackagePath = resolve(runtimeDir, 'node_modules/@qvac/sdk/package.json')
const sdkPackage = JSON.parse(readFileSync(sdkPackagePath, 'utf8'))
if (sdkPackage.version !== provenance.sdkVersion) {
  throw new Error(`[embed-provenance] installed SDK ${sdkPackage.version}; expected ${provenance.sdkVersion}`)
}
const original = readFileSync(entryPath, 'utf8')
if (original.includes('QVAC_SWIFT_EMBEDDED_SDK_VERSION')) {
  throw new Error('[embed-provenance] generated entry already contains a provenance marker')
}

// @qvac/cli currently emits absolute file: URLs for every SDK import. Those URLs
// leak the checkout path into both the entry source and bare-pack's resolution
// table, so byte-identical artifacts cannot be produced in two checkouts. Keep
// the generated entry and runtime node_modules at a fixed relative depth, then
// rewrite only URLs rooted in this exact, lockfile-installed node_modules tree.
const nodeModulesPath = resolve(runtimeDir, 'node_modules')
const nodeModulesURLPrefix = new URL('./node_modules/', import.meta.url).href
let portableModulesPath = relative(dirname(resolve(entryPath)), nodeModulesPath).split(sep).join('/')
if (!portableModulesPath.startsWith('.')) portableModulesPath = `./${portableModulesPath}`

const foreignFileURLs = [...original.matchAll(/["'](file:\/\/[^"']+)["']/g)]
  .map(match => match[1])
  .filter(url => !url.startsWith(nodeModulesURLPrefix))
if (foreignFileURLs.length > 0) {
  throw new Error(`[embed-provenance] generated entry contains file URL(s) outside pinned runtime node_modules: ${foreignFileURLs.join(', ')}`)
}
const normalized = original.split(nodeModulesURLPrefix).join(`${portableModulesPath}/`)
if (normalized.includes('file://')) {
  throw new Error('[embed-provenance] generated entry still contains a non-portable file URL')
}

const prelude = `// qvac-swift artifact provenance: generated from the committed runtime lock.\n`
  + `import qvacSwiftSDKPackage from ${JSON.stringify(`${portableModulesPath}/@qvac/sdk/package.json`)};\n`
  + `export const QVAC_SWIFT_EMBEDDED_SDK_VERSION = qvacSwiftSDKPackage.version;\n`
  + `if (QVAC_SWIFT_EMBEDDED_SDK_VERSION !== ${JSON.stringify(provenance.sdkVersion)}) {\n`
  + `  throw new Error("qvac-swift bundle SDK provenance mismatch");\n`
  + `}\n\n`
writeFileSync(entryPath, prelude + normalized)
console.log(`[embed-provenance] normalized SDK imports and embedded @qvac/sdk ${sdkPackage.version} metadata`)
