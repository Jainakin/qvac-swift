#!/usr/bin/env node

import { createHash } from 'node:crypto'
import {
  lstatSync,
  readFileSync,
  realpathSync,
  renameSync,
  rmSync,
  writeFileSync,
} from 'node:fs'
import { dirname, relative, resolve, sep } from 'node:path'
import { fileURLToPath } from 'node:url'

const scriptDirectory = dirname(fileURLToPath(import.meta.url))
const repositoryRoot = resolve(scriptDirectory, '../..')
const policyPath = resolve(scriptDirectory, 'ios-transport-policy.json')

function fail(message) { throw new Error(`[ios-transport-coverage] ${message}`) }
function sha256(bytes) { return createHash('sha256').update(bytes).digest('hex') }

function regularBytes(path, label) {
  let stat
  try { stat = lstatSync(path) } catch (error) { fail(`cannot inspect ${label}: ${error.message}`) }
  if (stat.isSymbolicLink() || !stat.isFile()) fail(`${label} must be a regular, non-symlink file`)
  return readFileSync(path)
}

function utf8(bytes, label) {
  try { return new TextDecoder('utf-8', { fatal: true }).decode(bytes) }
  catch { fail(`${label} is not valid UTF-8`) }
}

function json(bytes, label) {
  try { return JSON.parse(utf8(bytes, label)) }
  catch (error) { fail(`${label} is not valid JSON: ${error.message}`) }
}

function metric(value, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) fail(`${label} is missing`)
  const { count, covered, percent } = value
  if (!Number.isSafeInteger(count) || count <= 0) fail(`${label}.count must be a positive integer`)
  if (!Number.isSafeInteger(covered) || covered < 0 || covered > count) {
    fail(`${label}.covered must be an integer between zero and count`)
  }
  if (typeof percent !== 'number' || !Number.isFinite(percent)) fail(`${label}.percent is invalid`)
  const calculated = covered * 100 / count
  if (Math.abs(percent - calculated) > 1e-9) fail(`${label}.percent disagrees with its counts`)
  return { total: count, covered, uncovered: count - covered, percent }
}

function validateGate(gate, label) {
  const keys = [
    'minimumPercentBasisPoints',
    'minimumCovered',
    'minimumTotal',
    'maximumUncovered',
  ]
  if (!gate || typeof gate !== 'object' || Array.isArray(gate) ||
      keys.some(key => !Number.isSafeInteger(gate[key]) || gate[key] < 0)) {
    fail(`${label} is invalid`)
  }
  if (gate.minimumPercentBasisPoints > 10_000) fail(`${label}.minimumPercentBasisPoints exceeds 10000`)
}

function resolveSources(policy) {
  if (!Array.isArray(policy.sources) || policy.sources.length === 0) {
    fail('policy.sources must be a nonempty array')
  }
  const seen = new Set()
  return policy.sources.map((entry, index) => {
    const label = `policy.sources[${index}]`
    if (!entry || typeof entry !== 'object' || Array.isArray(entry) ||
        typeof entry.path !== 'string' || !entry.path.endsWith('.swift')) {
      fail(`${label}.path must name a Swift source`)
    }
    if (seen.has(entry.path)) fail(`duplicate policy source: ${entry.path}`)
    seen.add(entry.path)
    const absolute = resolve(repositoryRoot, entry.path)
    const containment = relative(repositoryRoot, absolute)
    if (containment === '..' || containment.startsWith(`..${sep}`) || resolve(absolute) === repositoryRoot) {
      fail(`${label}.path escapes the repository`)
    }
    const sourceBytes = regularBytes(absolute, `${label}.path`)
    const physicalLineCount = utf8(sourceBytes, `${label}.path`).split('\n').length
    const canonical = realpathSync(absolute)
    const canonicalContainment = relative(repositoryRoot, canonical)
    if (canonicalContainment === '..' || canonicalContainment.startsWith(`..${sep}`)) {
      fail(`${label}.path resolves outside the repository`)
    }
    for (const name of ['lines', 'functions', 'regions']) {
      validateGate(entry.gate?.[name], `${label}.gate.${name}`)
    }
    if (!Array.isArray(entry.requiredCoveredLines) || entry.requiredCoveredLines.length === 0 ||
        entry.requiredCoveredLines.some(line => !Number.isSafeInteger(line) || line <= 0 || line > physicalLineCount) ||
        new Set(entry.requiredCoveredLines).size !== entry.requiredCoveredLines.length) {
      fail(`${label}.requiredCoveredLines must contain unique physical source line numbers`)
    }
    return {
      path: entry.path,
      absolute: canonical,
      gate: entry.gate,
      requiredCoveredLines: entry.requiredCoveredLines,
    }
  })
}

function validateCoverage(report, expectedSources) {
  if (report?.type !== 'llvm.coverage.json.export' || !Array.isArray(report.data) || report.data.length !== 1) {
    fail('LLVM export must contain exactly one coverage data object')
  }
  const data = report.data[0]
  if (!Array.isArray(data.files)) fail('LLVM export files must be an array')
  if (data.files.length !== expectedSources.length) {
    fail(`expected ${expectedSources.length} source records; found ${data.files.length}`)
  }
  const files = expectedSources.map(source => {
    const matches = data.files.filter(file => {
      if (typeof file?.filename !== 'string') return false
      try { return realpathSync(file.filename) === source.absolute }
      catch { return false }
    })
    if (matches.length !== 1) {
      fail(`expected one export record for ${source.path}; found ${matches.length}`)
    }
    if (!Array.isArray(matches[0].segments)) fail(`${source.path}.segments must be an array`)
    for (const line of source.requiredCoveredLines) {
      const covered = matches[0].segments.some(segment =>
        Array.isArray(segment) && segment[0] === line &&
        typeof segment[2] === 'number' && segment[2] > 0 && segment[3] === true
      )
      if (!covered) fail(`${source.path} required line ${line} was not covered`)
    }
    const result = {}
    for (const name of ['lines', 'functions', 'regions']) {
      result[name] = metric(matches[0].summary?.[name], `${source.path}.summary.${name}`)
      const gate = source.gate[name]
      const basisPoints = Math.floor(result[name].covered * 10_000 / result[name].total)
      if (basisPoints < gate.minimumPercentBasisPoints ||
          result[name].covered < gate.minimumCovered ||
          result[name].total < gate.minimumTotal ||
          result[name].uncovered > gate.maximumUncovered) {
        fail(`${source.path} ${name} coverage ${result[name].covered}/${result[name].total} (${result[name].percent.toFixed(2)}%) violates policy`)
      }
    }
    return {
      source: source.path,
      requiredCoveredLines: source.requiredCoveredLines,
      metrics: result,
    }
  })
  const totals = {}
  for (const name of ['lines', 'functions', 'regions']) {
    totals[name] = metric(data.totals?.[name], `data.totals.${name}`)
    const covered = files.reduce((sum, file) => sum + file.metrics[name].covered, 0)
    const total = files.reduce((sum, file) => sum + file.metrics[name].total, 0)
    if (totals[name].covered !== covered || totals[name].total !== total) {
      fail(`source and aggregate ${name} coverage disagree`)
    }
  }
  return { files, totals }
}

function inventory(text, policy) {
  if (!text.endsWith('\n')) fail('test inventory must end with a newline')
  const entries = text.slice(0, -1).split('\n')
  const pattern = /^[A-Za-z_][A-Za-z0-9_]*\/test[A-Za-z0-9_]+$/
  if (entries.length !== policy.test.expectedCount || entries.some(entry => !pattern.test(entry))) {
    fail('test inventory count or syntax is invalid')
  }
  const sorted = [...entries].sort()
  if (new Set(entries).size !== entries.length || entries.some((entry, index) => entry !== sorted[index])) {
    fail('test inventory must be unique and bytewise sorted')
  }
  return entries
}

function validateTestLog(text, module, expected) {
  if (!text.includes('** TEST SUCCEEDED **')) fail('xcodebuild did not report TEST SUCCEEDED')
  if (/^Test Case .*\]' (?:failed|skipped) /m.test(text) || /Executed 0 tests?/m.test(text)) {
    fail('XCTest reported a failure, skip, or empty run')
  }
  const escapedModule = module.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  const pattern = new RegExp(
    `^Test Case '-\\[${escapedModule}\\.([A-Za-z_][A-Za-z0-9_]*) (test[A-Za-z0-9_]+)\\]' passed \\(\\d+(?:\\.\\d+)? seconds\\)\\.$`,
    'gm',
  )
  const actual = [...text.matchAll(pattern)].map(match => `${match[1]}/${match[2]}`)
  if (new Set(actual).size !== actual.length) fail('a passing test identity appeared more than once')
  actual.sort()
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    fail(`executed test inventory mismatch: expected ${expected.length}, observed ${actual.length}`)
  }
}

function analyze({ coverage, log, policy, inventoryText, sources }) {
  if (policy?.schemaVersion !== 2 || policy.test?.module !== 'QVACiOSSmokeTests') fail('unsupported policy')
  const expected = inventory(inventoryText, policy)
  validateTestLog(log, policy.test.module, expected)
  return validateCoverage(coverage, sources)
}

function expectFailure(action, label) {
  try { action() } catch { return }
  fail(`self-test expected rejection: ${label}`)
}

function selfTest() {
  const paths = [
    'Sources/QVACClient/Internal/Transport/BareIPCTransport.swift',
    'Sources/QVACClient/Internal/BareRPC/Handshake.swift',
  ]
  const gates = (covered, total) => Object.fromEntries(
    ['lines', 'functions', 'regions'].map(name => [name, {
      minimumPercentBasisPoints: Math.floor(covered * 10_000 / total),
      minimumCovered: covered,
      minimumTotal: total,
      maximumUncovered: total - covered,
    }]),
  )
  const policy = {
    schemaVersion: 2,
    test: { module: 'QVACiOSSmokeTests', expectedCount: 1 },
    sources: [
      { path: paths[0], requiredCoveredLines: [47], gate: gates(3, 4) },
      { path: paths[1], requiredCoveredLines: [24], gate: gates(2, 2) },
    ],
  }
  const sources = policy.sources.map(entry => ({
    path: entry.path,
    absolute: realpathSync(resolve(repositoryRoot, entry.path)),
    gate: entry.gate,
    requiredCoveredLines: entry.requiredCoveredLines,
  }))
  const first = { count: 4, covered: 3, percent: 75 }
  const second = { count: 2, covered: 2, percent: 100 }
  const total = { count: 6, covered: 5, percent: 5 * 100 / 6 }
  const coverage = { type: 'llvm.coverage.json.export', data: [{
    files: [
      { filename: sources[0].absolute, segments: [[47, 1, 1, true, true, false]], summary: { lines: first, functions: first, regions: first } },
      { filename: sources[1].absolute, segments: [[24, 1, 1, true, true, false]], summary: { lines: second, functions: second, regions: second } },
    ],
    totals: { lines: total, functions: total, regions: total },
  }] }
  const inventoryText = 'TransportTests/testPasses\n'
  const log = "Test Case '-[QVACiOSSmokeTests.TransportTests testPasses]' passed (0.001 seconds).\n** TEST SUCCEEDED **\n"
  analyze({ coverage, log, policy, inventoryText, sources })
  expectFailure(() => analyze({
    coverage,
    log: `${log}Test Case '-[QVACiOSSmokeTests.TransportTests testPasses]' skipped (0.001 seconds).\n`,
    policy,
    inventoryText,
    sources,
  }), 'skip')
  expectFailure(() => analyze({ coverage, log: '** TEST SUCCEEDED **\n', policy, inventoryText, sources }), 'missing test')
  expectFailure(() => analyze({ coverage: { ...coverage, data: [{ ...coverage.data[0], files: coverage.data[0].files.slice(0, 1) }] }, log, policy, inventoryText, sources }), 'missing file')
  const low = structuredClone(coverage)
  low.data[0].files[0].summary.lines = { count: 4, covered: 2, percent: 50 }
  low.data[0].totals.lines = { count: 6, covered: 4, percent: 4 * 100 / 6 }
  expectFailure(() => analyze({ coverage: low, log, policy, inventoryText, sources }), 'threshold')
  const uncoveredRequiredLine = structuredClone(coverage)
  uncoveredRequiredLine.data[0].files[0].segments[0][2] = 0
  expectFailure(() => analyze({ coverage: uncoveredRequiredLine, log, policy, inventoryText, sources }), 'required line')
  console.log('[ios-transport-coverage-test] positive and fail-closed cases passed')
}

if (process.argv[2] === '--self-test') {
  if (process.argv.length !== 3) fail('usage: analyze-ios-transport.mjs --self-test')
  selfTest()
} else {
  if (process.argv.length !== 6) {
    fail('usage: analyze-ios-transport.mjs <llvm-export.json> <xcodebuild.log> <summary.json> <summary.md>')
  }
  const [, , coveragePath, logPath, summaryPath, markdownPath] = process.argv
  const policyBytes = regularBytes(policyPath, 'policy')
  const policy = json(policyBytes, 'policy')
  const inventoryPath = resolve(repositoryRoot, policy.test?.inventoryPath ?? '')
  const inventoryBytes = regularBytes(inventoryPath, 'test inventory')
  if (sha256(inventoryBytes) !== policy.test.inventorySHA256) fail('test inventory SHA-256 differs from policy')
  const coverageBytes = regularBytes(coveragePath, 'LLVM export')
  const logBytes = regularBytes(logPath, 'xcodebuild log')
  const sources = resolveSources(policy)
  const result = analyze({
    coverage: json(coverageBytes, 'LLVM export'),
    log: utf8(logBytes, 'xcodebuild log'),
    policy,
    inventoryText: utf8(inventoryBytes, 'test inventory'),
    sources,
  })
  const evidence = {
    schemaVersion: 2,
    status: 'PASS',
    scope: result,
    testCount: policy.test.expectedCount,
    sha256: {
      sources: Object.fromEntries(sources.map(source => [
        source.path,
        sha256(regularBytes(source.absolute, source.path)),
      ])),
      inventory: sha256(inventoryBytes),
      llvmExport: sha256(coverageBytes),
      xcodebuildLog: sha256(logBytes),
      policy: sha256(policyBytes),
    },
  }
  for (const output of [summaryPath, markdownPath]) rmSync(output, { force: true })
  const summaryTemporary = `${summaryPath}.tmp`
  const markdownTemporary = `${markdownPath}.tmp`
  writeFileSync(summaryTemporary, `${JSON.stringify(evidence, null, 2)}\n`, { flag: 'wx' })
  const rows = result.files.flatMap(file => ['lines', 'functions', 'regions'].map(name => {
    const metric = file.metrics[name]
    return `| \`${file.source}\` | ${name} | ${metric.covered}/${metric.total} | ${metric.percent.toFixed(2)}% |`
  }))
  const aggregateRows = ['lines', 'functions', 'regions'].map(name => {
    const metric = result.totals[name]
    return `| **aggregate** | ${name} | ${metric.covered}/${metric.total} | ${metric.percent.toFixed(2)}% |`
  })
  writeFileSync(markdownTemporary, [
    '### iOS platform coverage', '', '| Source | Metric | Covered | Percent |', '|---|---|---:|---:|',
    ...rows, ...aggregateRows, '', `Verified tests: ${policy.test.expectedCount}`, '',
  ].join('\n'), { flag: 'wx' })
  renameSync(summaryTemporary, summaryPath)
  renameSync(markdownTemporary, markdownPath)
  console.log(`[ios-transport-coverage] PASS aggregate-lines=${result.totals.lines.covered}/${result.totals.lines.total} (${result.totals.lines.percent.toFixed(2)}%)`)
}
