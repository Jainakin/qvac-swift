#!/usr/bin/env node

import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'

// SemVer 2.0.0 without build metadata. Source tags intentionally exclude build
// metadata so one precedence value cannot be published under multiple tags.
const pattern = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-((?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*))*))?$/

function parse(value) {
  const match = pattern.exec(value)
  if (!match) throw new Error(`invalid source SemVer without v or build metadata: ${value}`)
  return {
    value,
    core: [BigInt(match[1]), BigInt(match[2]), BigInt(match[3])],
    prerelease: match[4]?.split('.') ?? [],
  }
}

function compareIdentifier(left, right) {
  const leftNumeric = /^\d+$/.test(left)
  const rightNumeric = /^\d+$/.test(right)
  if (leftNumeric && rightNumeric) {
    const lhs = BigInt(left)
    const rhs = BigInt(right)
    return lhs < rhs ? -1 : lhs > rhs ? 1 : 0
  }
  if (leftNumeric !== rightNumeric) return leftNumeric ? -1 : 1
  return left < right ? -1 : left > right ? 1 : 0
}

function compare(left, right) {
  for (let index = 0; index < 3; index += 1) {
    if (left.core[index] !== right.core[index]) {
      return left.core[index] < right.core[index] ? -1 : 1
    }
  }
  if (left.prerelease.length === 0 || right.prerelease.length === 0) {
    if (left.prerelease.length === right.prerelease.length) return 0
    return left.prerelease.length === 0 ? 1 : -1
  }
  const count = Math.max(left.prerelease.length, right.prerelease.length)
  for (let index = 0; index < count; index += 1) {
    if (left.prerelease[index] === undefined) return -1
    if (right.prerelease[index] === undefined) return 1
    const result = compareIdentifier(left.prerelease[index], right.prerelease[index])
    if (result !== 0) return result
  }
  return 0
}

function selfTest() {
  const ascending = [
    '1.0.0-alpha',
    '1.0.0-alpha.1',
    '1.0.0-alpha.beta',
    '1.0.0-beta',
    '1.0.0-beta.2',
    '1.0.0-beta.11',
    '1.0.0-rc.1',
    '1.0.0',
    '1.0.1',
    '1.1.0',
    '2.0.0',
  ].map(parse)
  for (let index = 1; index < ascending.length; index += 1) {
    assert.equal(compare(ascending[index - 1], ascending[index]), -1)
    assert.equal(compare(ascending[index], ascending[index - 1]), 1)
  }
  assert.equal(compare(parse('999999999999999999999.0.0'), parse('2.0.0')), 1)
  for (const invalid of [
    'v1.0.0', '01.0.0', '1.01.0', '1.0.01', '1.0', '1.0.0-',
    '1.0.0-01', '1.0.0-alpha..1', '1.0.0+build', '1.0.0-alpha+build',
  ]) {
    assert.throws(() => parse(invalid))
  }
  console.log('[release-version-test] strict SemVer parsing and precedence verified')
}

if (process.argv[2] === '--self-test') {
  selfTest()
  process.exit(0)
}

const requestedText = process.argv[2]
if (!requestedText || process.argv.length > 4) {
  throw new Error('usage: validate-release-version.mjs <requested-version> [existing-versions-file]')
}
const requested = parse(requestedText)
const existingPath = process.argv[3]
let highest
if (existingPath) {
  for (const raw of readFileSync(existingPath, 'utf8').split(/\r?\n/)) {
    if (!raw) continue
    if (!pattern.test(raw)) continue
    const version = parse(raw)
    if (!highest || compare(version, highest) > 0) highest = version
  }
}
if (highest && compare(requested, highest) <= 0) {
  throw new Error(`new source version ${requested.value} must be greater than existing ${highest.value}`)
}

console.log(
  `[release-version] ${requested.value} is valid; prerelease=${requested.prerelease.length > 0}`
  + (highest ? `; previous=${highest.value}` : '; no earlier SemVer tag'),
)
