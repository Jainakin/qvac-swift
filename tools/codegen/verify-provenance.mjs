#!/usr/bin/env node

import { createHash } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const scriptDir = dirname(fileURLToPath(import.meta.url))
const repoRoot = resolve(scriptDir, '..', '..')
const provenancePath = join(repoRoot, 'tools/provenance/qvac-sdk.lock.json')
const provenance = JSON.parse(readFileSync(provenancePath, 'utf8'))
const npmLock = JSON.parse(readFileSync(join(scriptDir, 'package-lock.json'), 'utf8'))
const sourceDir = resolve(process.env.QVAC_UPSTREAM_DIR ?? join(scriptDir, '.build/qvac-sdk'))

function fail(message) {
  throw new Error(`[provenance] ${message}`)
}

function sha256(path) {
  return createHash('sha256').update(readFileSync(path)).digest('hex')
}

if (provenance.source.commit === provenance.source.nonAuthoritativeTag.commit) {
  fail(`authoritative commit must not equal non-authoritative tag ${provenance.source.nonAuthoritativeTag.name}`)
}
if (provenance.npm.gitHead !== provenance.source.commit) {
  fail(`npm gitHead ${provenance.npm.gitHead} does not match authoritative source ${provenance.source.commit}`)
}

const rootPackage = npmLock.packages?.['']
const sdkPackage = npmLock.packages?.['node_modules/@qvac/sdk']
if (rootPackage?.dependencies?.['@qvac/sdk'] !== provenance.sdkVersion) {
  fail('tools/codegen/package-lock.json does not request the exact SDK version')
}
if (sdkPackage?.version !== provenance.npm.version) {
  fail(`npm lock resolved SDK ${sdkPackage?.version ?? '<missing>'}, expected ${provenance.npm.version}`)
}
if (sdkPackage?.resolved !== provenance.npm.tarball || sdkPackage?.integrity !== provenance.npm.integrity) {
  fail('npm lock tarball URL/integrity does not match the immutable published-tarball provenance lock')
}

const installedPackage = JSON.parse(readFileSync(join(scriptDir, 'node_modules/@qvac/sdk/package.json'), 'utf8'))
if (installedPackage.version !== provenance.sdkVersion) {
  fail(`installed SDK ${installedPackage.version} is not ${provenance.sdkVersion}`)
}

let head
try {
  head = execFileSync('git', ['-C', sourceDir, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim()
} catch {
  fail(`source checkout is missing at ${sourceDir}; run tools/codegen/bootstrap.sh`)
}
if (head !== provenance.source.commit) {
  fail(`source checkout is ${head}; expected release commit ${provenance.source.commit}`)
}
if (head === provenance.source.nonAuthoritativeTag.commit) {
  fail(`refusing non-authoritative ${provenance.source.nonAuthoritativeTag.name} commit ${head}`)
}

for (const [relativePath, expected] of Object.entries(provenance.source.inputs)) {
  const actual = sha256(join(sourceDir, relativePath))
  if (actual !== expected) fail(`${relativePath} sha256=${actual}; expected ${expected}`)
}

console.log(`[provenance] source commit: ${head}`)
console.log(`[provenance] npm: ${provenance.npm.name}@${sdkPackage.version}`)
console.log(`[provenance] npm integrity: ${sdkPackage.integrity}`)
console.log(`[provenance] non-authoritative tag: ${provenance.source.nonAuthoritativeTag.name}@${provenance.source.nonAuthoritativeTag.commit}`)
