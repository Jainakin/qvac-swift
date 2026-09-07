#!/usr/bin/env node

import { createHash } from 'node:crypto'
import { TextDecoder } from 'node:util'
import {
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  realpathSync,
  renameSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import {
  dirname,
  isAbsolute,
  join,
  relative,
  resolve,
  sep,
} from 'node:path'
import { fileURLToPath } from 'node:url'

const METRIC_NAMES = Object.freeze(['lines', 'functions', 'regions'])
const UNIT_TEST_SOURCE_ROOT = 'Tests/QVACClientUnitTests'
const POLICY_FILE = 'tools/coverage/policy.json'
const TOOLING_FILES = Object.freeze([
  'tools/coverage/analyze-coverage.mjs',
  'tools/coverage/run.sh',
])
const EVIDENCE_FILES = Object.freeze([
  'swift-test-list.txt', 'swift-test-output.log', 'llvm-coverage-summary.json',
  'llvm-coverage.raw.lcov', 'coverage-summary.json', 'coverage-summary.md',
  'handwritten-production.lcov', 'all-production-source.lcov', 'toolchain.json',
  'input-manifest.json',
])
const TEST_IDENTIFIER = /^[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*\/[A-Za-z_][A-Za-z0-9_]*$/
const SHA256 = /^[0-9a-f]{64}$/

class CoverageError extends Error {}

function fail(message) {
  throw new CoverageError(message)
}

function assert(condition, message) {
  if (!condition) fail(message)
}

function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

function requireExactKeys(object, keys, label) {
  assert(isPlainObject(object), `${label} must be an object`)
  const actual = Object.keys(object).sort()
  const expected = [...keys].sort()
  assert(
    JSON.stringify(actual) === JSON.stringify(expected),
    `${label} keys must be exactly: ${expected.join(', ')}`,
  )
}

function requireInteger(value, label, minimum, maximum = Number.MAX_SAFE_INTEGER) {
  assert(Number.isSafeInteger(value), `${label} must be a safe integer`)
  assert(value >= minimum && value <= maximum, `${label} must be between ${minimum} and ${maximum}`)
}

function requireIdentifier(value, label) {
  assert(
    typeof value === 'string' && /^[A-Za-z_][A-Za-z0-9_]*$/.test(value),
    `${label} must be a Swift identifier`,
  )
}

function requireRelativePath(value, label) {
  assert(typeof value === 'string' && value.length > 0, `${label} must be a non-empty string`)
  assert(!isAbsolute(value), `${label} must be repository-relative`)
  assert(!value.includes('\\'), `${label} must use '/' separators`)
  const components = value.split('/')
  assert(
    components.every(component => component.length > 0 && component !== '.' && component !== '..'),
    `${label} must be a normalized child path`,
  )
  return value
}

function readRegularFile(path, label) {
  let stat
  try {
    stat = lstatSync(path)
  } catch (error) {
    fail(`cannot inspect ${label}: ${error.message}`)
  }
  assert(stat.isFile() && !stat.isSymbolicLink(), `${label} must be a regular, non-symlink file`)
  return readFileSync(path)
}

function parseJSON(buffer, label) {
  try {
    return JSON.parse(decodeUTF8(buffer, label))
  } catch (error) {
    fail(`${label} is not valid JSON: ${error.message}`)
  }
}

function decodeUTF8(buffer, label) {
  try {
    return new TextDecoder('utf-8', { fatal: true }).decode(buffer)
  } catch (error) {
    fail(`${label} is not valid UTF-8: ${error.message}`)
  }
}

function sha256(buffer) {
  return createHash('sha256').update(buffer).digest('hex')
}

function loadPolicy(path) {
  const bytes = readRegularFile(path, 'coverage policy')
  const policy = parseJSON(bytes, 'coverage policy')
  validatePolicy(policy)
  return { policy, sha256: sha256(bytes) }
}

function validatePolicy(policy) {
  requireExactKeys(policy, ['schemaVersion', 'test', 'scope', 'gate'], 'policy')
  assert(policy.schemaVersion === 1, 'policy.schemaVersion must be 1')

  requireExactKeys(
    policy.test,
    ['module', 'product', 'expectedCount', 'inventoryPath', 'inventorySHA256'],
    'policy.test',
  )
  requireIdentifier(policy.test.module, 'policy.test.module')
  requireIdentifier(policy.test.product, 'policy.test.product')
  requireInteger(policy.test.expectedCount, 'policy.test.expectedCount', 1)
  requireRelativePath(policy.test.inventoryPath, 'policy.test.inventoryPath')
  assert(SHA256.test(policy.test.inventorySHA256), 'policy.test.inventorySHA256 must be a lowercase SHA-256')

  requireExactKeys(policy.scope, ['sourceRoot', 'generatedFiles', 'platformExclusions'], 'policy.scope')
  requireRelativePath(policy.scope.sourceRoot, 'policy.scope.sourceRoot')
  assert(Array.isArray(policy.scope.generatedFiles) && policy.scope.generatedFiles.length > 0,
    'policy.scope.generatedFiles must be a non-empty array')
  const generated = policy.scope.generatedFiles.map((value, index) =>
    requireRelativePath(value, `policy.scope.generatedFiles[${index}]`))
  assert(new Set(generated).size === generated.length, 'policy.scope.generatedFiles must be unique')
  assert(generated.every(path => path.endsWith('.swift')), 'every generated file must be Swift source')
  assert([...generated].sort().join('\n') === generated.join('\n'), 'policy.scope.generatedFiles must be sorted')

  assert(Array.isArray(policy.scope.platformExclusions), 'policy.scope.platformExclusions must be an array')
  const exclusions = policy.scope.platformExclusions.map((entry, index) => {
    requireExactKeys(entry, ['path', 'reason'], `policy.scope.platformExclusions[${index}]`)
    const path = requireRelativePath(entry.path, `policy.scope.platformExclusions[${index}].path`)
    assert(path.endsWith('.swift'), `policy.scope.platformExclusions[${index}].path must be Swift source`)
    assert(typeof entry.reason === 'string' && entry.reason.trim().length >= 20,
      `policy.scope.platformExclusions[${index}].reason must explain the platform exclusion`)
    return path
  })
  assert(new Set(exclusions).size === exclusions.length, 'platform exclusion paths must be unique')
  assert(generated.every(path => !exclusions.includes(path)), 'generated and platform-excluded paths must not overlap')

  requireExactKeys(policy.gate, ['handwritten', 'generated', 'criticalFiles'], 'policy.gate')
  requireExactKeys(
    policy.gate.handwritten,
    [...METRIC_NAMES, 'perFileMinimumPercentBasisPoints'],
    'policy.gate.handwritten',
  )
  for (const metric of METRIC_NAMES) {
    const threshold = policy.gate.handwritten[metric]
    requireExactKeys(
      threshold,
      ['minimumPercentBasisPoints', 'minimumCovered', 'minimumTotal', 'maximumUncovered'],
      `policy.gate.handwritten.${metric}`,
    )
    requireInteger(threshold.minimumPercentBasisPoints,
      `policy.gate.handwritten.${metric}.minimumPercentBasisPoints`, 1, 10_000)
    requireInteger(threshold.minimumCovered,
      `policy.gate.handwritten.${metric}.minimumCovered`, 1)
    requireInteger(threshold.minimumTotal,
      `policy.gate.handwritten.${metric}.minimumTotal`, 1)
    requireInteger(threshold.maximumUncovered,
      `policy.gate.handwritten.${metric}.maximumUncovered`, 0)
    assert(threshold.minimumCovered <= threshold.minimumTotal,
      `policy.gate.handwritten.${metric} cannot require more covered elements than total elements`)
  }
  requireExactKeys(
    policy.gate.generated,
    [...METRIC_NAMES, 'perFileMinimumPercentBasisPoints'],
    'policy.gate.generated',
  )
  for (const metric of METRIC_NAMES) {
    const threshold = policy.gate.generated[metric]
    requireExactKeys(
      threshold,
      ['minimumPercentBasisPoints', 'minimumCovered', 'minimumTotal', 'maximumUncovered'],
      `policy.gate.generated.${metric}`,
    )
    requireInteger(threshold.minimumPercentBasisPoints,
      `policy.gate.generated.${metric}.minimumPercentBasisPoints`, 1, 10_000)
    requireInteger(threshold.minimumCovered,
      `policy.gate.generated.${metric}.minimumCovered`, 1)
    requireInteger(threshold.minimumTotal,
      `policy.gate.generated.${metric}.minimumTotal`, 1)
    requireInteger(threshold.maximumUncovered,
      `policy.gate.generated.${metric}.maximumUncovered`, 0)
    assert(threshold.minimumCovered <= threshold.minimumTotal,
      `policy.gate.generated.${metric} cannot require more covered elements than total elements`)
  }
  for (const scopeName of ['handwritten', 'generated']) {
    requireExactKeys(
      policy.gate[scopeName].perFileMinimumPercentBasisPoints,
      METRIC_NAMES,
      `policy.gate.${scopeName}.perFileMinimumPercentBasisPoints`,
    )
    for (const metric of METRIC_NAMES) {
      requireInteger(
        policy.gate[scopeName].perFileMinimumPercentBasisPoints[metric],
        `policy.gate.${scopeName}.perFileMinimumPercentBasisPoints.${metric}`,
        1,
        10_000,
      )
    }
  }

  assert(Array.isArray(policy.gate.criticalFiles), 'policy.gate.criticalFiles must be an array')
  const criticalPaths = policy.gate.criticalFiles.map((entry, index) => {
    const label = `policy.gate.criticalFiles[${index}]`
    requireExactKeys(entry, ['path', ...METRIC_NAMES], label)
    const path = requireRelativePath(entry.path, `${label}.path`)
    assert(path.startsWith(`${policy.scope.sourceRoot}/`) && path.endsWith('.swift'),
      `${label}.path must name Swift source beneath policy.scope.sourceRoot`)
    assert(!generated.includes(path) && !exclusions.includes(path),
      `${label}.path must name macOS-compiled handwritten source`)
    for (const metric of METRIC_NAMES) {
      const threshold = entry[metric]
      requireExactKeys(
        threshold,
        ['minimumPercentBasisPoints', 'minimumCovered', 'minimumTotal', 'maximumUncovered'],
        `${label}.${metric}`,
      )
      requireInteger(threshold.minimumPercentBasisPoints,
        `${label}.${metric}.minimumPercentBasisPoints`, 1, 10_000)
      requireInteger(threshold.minimumCovered, `${label}.${metric}.minimumCovered`, 1)
      requireInteger(threshold.minimumTotal, `${label}.${metric}.minimumTotal`, 1)
      requireInteger(threshold.maximumUncovered, `${label}.${metric}.maximumUncovered`, 0)
      assert(threshold.minimumCovered <= threshold.minimumTotal,
        `${label}.${metric} cannot require more covered elements than total elements`)
    }
    return path
  })
  assert(new Set(criticalPaths).size === criticalPaths.length,
    'policy.gate.criticalFiles paths must be unique')
  assert([...criticalPaths].sort().join('\n') === criticalPaths.join('\n'),
    'policy.gate.criticalFiles must be sorted by path')
}

function resolveRepositoryPath(repositoryRoot, relativePath, label) {
  const path = resolve(repositoryRoot, relativePath)
  const rel = relative(repositoryRoot, path)
  assert(rel !== '' && rel !== '..' && !rel.startsWith(`..${sep}`), `${label} escapes the repository`)
  return path
}

function resolveCanonicalRepositoryPath(repositoryRoot, relativePath, label) {
  const lexical = resolveRepositoryPath(repositoryRoot, relativePath, label)
  let canonical
  try {
    canonical = realpathSync(lexical)
  } catch (error) {
    fail(`cannot resolve ${label}: ${error.message}`)
  }
  assert(canonical === lexical, `${label} resolves through a symlink: ${relativePath}`)
  return canonical
}

function validateInventory(policy, repositoryRoot, inventoryPath = undefined) {
  const configuredPath = resolveCanonicalRepositoryPath(
    repositoryRoot,
    policy.test.inventoryPath,
    'test inventory path',
  )
  const actualPath = inventoryPath === undefined ? configuredPath : resolve(inventoryPath)
  assert(actualPath === configuredPath, 'test inventory path must match policy.test.inventoryPath')
  const bytes = readRegularFile(actualPath, 'reviewed unit-test inventory')
  const digest = sha256(bytes)
  assert(digest === policy.test.inventorySHA256,
    `unit-test inventory SHA-256 is ${digest}; expected ${policy.test.inventorySHA256}`)
  const text = decodeUTF8(bytes, 'reviewed unit-test inventory')
  assert(text.endsWith('\n'), 'unit-test inventory must end with one newline')
  const identifiers = text.slice(0, -1).split('\n')
  assert(identifiers.length === policy.test.expectedCount,
    `unit-test inventory has ${identifiers.length} entries; expected ${policy.test.expectedCount}`)
  assert(identifiers.every(identifier => TEST_IDENTIFIER.test(identifier)),
    'unit-test inventory contains a malformed identifier')
  assert(identifiers.every(identifier => identifier.startsWith(`${policy.test.module}.`)),
    `unit-test inventory contains an identifier outside ${policy.test.module}`)
  assert(new Set(identifiers).size === identifiers.length, 'unit-test inventory contains a duplicate identifier')
  const sorted = [...identifiers].sort((left, right) => Buffer.compare(Buffer.from(left), Buffer.from(right)))
  assert(JSON.stringify(sorted) === JSON.stringify(identifiers),
    'unit-test inventory must use canonical bytewise ordering')
  return { identifiers, sha256: digest, path: actualPath }
}

function discoveredInventory(listing, module) {
  const prefix = `${module}.`
  const relevant = listing.split(/\r?\n/u).filter(line => line.startsWith(prefix))
  assert(relevant.length > 0, `swift test list discovered zero tests in ${module}`)
  assert(relevant.every(identifier => TEST_IDENTIFIER.test(identifier)),
    `swift test list emitted a malformed ${module} identifier`)
  return relevant.sort((left, right) => Buffer.compare(Buffer.from(left), Buffer.from(right)))
}

function requireSameInventory(actual, expected, label) {
  assert(actual.length === expected.length,
    `${label} has ${actual.length} entries; expected ${expected.length}`)
  for (let index = 0; index < expected.length; index += 1) {
    assert(actual[index] === expected[index],
      `${label} differs at entry ${index + 1}: ${actual[index] ?? '<missing>'} != ${expected[index]}`)
  }
}

function verifyDiscovery(listing, policy, inventory) {
  const discovered = discoveredInventory(listing, policy.test.module)
  requireSameInventory(discovered, inventory.identifiers, 'discovered unit-test inventory')
  return discovered
}

function executionInventory(output, policy) {
  const module = policy.test.module.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&')
  const startedPattern = new RegExp(
    `^Test Case '-\\[(${module}\\.[A-Za-z_][A-Za-z0-9_]*) ([A-Za-z_][A-Za-z0-9_]*)\\]' started\\.$`,
    'u',
  )
  const passedPattern = new RegExp(
    `^Test Case '-\\[(${module}\\.[A-Za-z_][A-Za-z0-9_]*) ([A-Za-z_][A-Za-z0-9_]*)\\]' passed \\([0-9]+(?:\\.[0-9]+)? seconds\\)\\.$`,
    'u',
  )
  const anyStarted = /^Test Case '-\[[^\]]+\]' started\.$/u
  const started = []
  const passed = []
  let allStarted = 0
  for (const line of output.split(/\r?\n/u)) {
    if (anyStarted.test(line)) allStarted += 1
    const startedMatch = startedPattern.exec(line)
    if (startedMatch) started.push(`${startedMatch[1]}/${startedMatch[2]}`)
    const passedMatch = passedPattern.exec(line)
    if (passedMatch) passed.push(`${passedMatch[1]}/${passedMatch[2]}`)
  }
  const byteSort = values => values.sort((left, right) => Buffer.compare(Buffer.from(left), Buffer.from(right)))
  return { started: byteSort(started), passed: byteSort(passed), allStarted }
}

function verifyExecution(output, policy, inventory) {
  assert(!/^Test Case .* skipped(?:[ (]|$)/mu.test(output),
    `${policy.test.module} reported a skipped test`)
  assert(!/Executed [0-9]+ tests?, with [1-9][0-9]* tests? skipped/mu.test(output),
    `${policy.test.module} aggregate reported skipped tests`)
  assert(!/^\s*Executed 0 tests?(?:[, ]|$)/mu.test(output), 'XCTest reported zero executed tests')
  const execution = executionInventory(output, policy)
  assert(execution.allStarted === policy.test.expectedCount,
    `XCTest started ${execution.allStarted} total tests; expected ${policy.test.expectedCount}`)
  requireSameInventory(execution.started, inventory.identifiers, 'started unit-test inventory')
  requireSameInventory(execution.passed, inventory.identifiers, 'passing unit-test inventory')
  const aggregate = new RegExp(
    `^\\s*Executed ${policy.test.expectedCount} tests?, with 0 failures \\(0 unexpected\\)`,
    'mu',
  )
  assert(aggregate.test(output),
    `XCTest did not report exactly ${policy.test.expectedCount} tests with zero failures`)
  return execution
}

function listRegularInputs(root, inputRootRelative, label) {
  const inputRoot = resolveCanonicalRepositoryPath(root, inputRootRelative, `${label} root`)
  const rootStat = lstatSync(inputRoot)
  assert(rootStat.isDirectory() && !rootStat.isSymbolicLink(), `${label} root must be a real directory`)
  const inputs = []
  function visit(directory) {
    const entries = readdirSync(directory, { withFileTypes: true })
      .sort((left, right) => Buffer.compare(Buffer.from(left.name), Buffer.from(right.name)))
    for (const entry of entries) {
      const path = join(directory, entry.name)
      const relativePath = relative(root, path).split(sep).join('/')
      assert(!entry.isSymbolicLink(), `${label} must not contain symlinks: ${relativePath}`)
      if (entry.isDirectory()) visit(path)
      else {
        assert(entry.isFile(), `${label} must contain only directories and regular files: ${relativePath}`)
        inputs.push(relativePath)
      }
    }
  }
  visit(inputRoot)
  assert(inputs.length > 0, `${label} contains no regular files`)
  return inputs.sort((left, right) => Buffer.compare(Buffer.from(left), Buffer.from(right)))
}

function listSwiftSources(root, sourceRootRelative) {
  const sources = listRegularInputs(root, sourceRootRelative, 'source scope')
    .filter(path => path.endsWith('.swift'))
  assert(sources.length > 0, 'source scope contains no Swift files')
  return sources
}

function buildScope(policy, repositoryRoot) {
  const allFiles = listSwiftSources(repositoryRoot, policy.scope.sourceRoot)
  const allSet = new Set(allFiles)
  const generated = [...policy.scope.generatedFiles]
  const generatedSet = new Set(generated)
  const excluded = policy.scope.platformExclusions.map(entry => entry.path)
  const excludedSet = new Set(excluded)
  for (const path of [...generated, ...excluded]) {
    assert(allSet.has(path), `reviewed coverage classification names a missing source file: ${path}`)
  }

  const generatedDirectory = `${policy.scope.sourceRoot}/Generated/`
  const actualGenerated = allFiles.filter(path => path.startsWith(generatedDirectory))
  requireSameInventory(actualGenerated, generated, 'generated-source inventory')

  const handwritten = allFiles.filter(path => !generatedSet.has(path) && !excludedSet.has(path))
  const eligible = allFiles.filter(path => !excludedSet.has(path))
  assert(handwritten.length > 0, 'handwritten source scope is empty')
  return { allFiles, eligible, handwritten, generated, excluded }
}

function repositoryRelativeFilename(filename, repositoryRoot) {
  assert(typeof filename === 'string' && filename.length > 0, 'LLVM coverage filename must be a string')
  const candidate = isAbsolute(filename) ? filename : resolve(repositoryRoot, filename)
  const rel = relative(repositoryRoot, candidate)
  if (rel === '' || rel === '..' || rel.startsWith(`..${sep}`)) return undefined
  return rel.split(sep).join('/')
}

function normalizeCoverageFilename(filename, repositoryRoot) {
  const lexical = repositoryRelativeFilename(filename, repositoryRoot)
  if (lexical === undefined) return undefined
  const candidate = resolve(repositoryRoot, lexical)
  let canonical
  try {
    canonical = realpathSync(candidate)
  } catch (error) {
    fail(`cannot resolve LLVM coverage filename ${filename}: ${error.message}`)
  }
  const rel = relative(repositoryRoot, canonical)
  if (rel === '' || rel === '..' || rel.startsWith(`..${sep}`)) return undefined
  const normalized = rel.split(sep).join('/')
  assert(normalized === lexical, `LLVM coverage source resolves through a symlink: ${filename}`)
  return normalized
}

function parseMetric(summary, metric, label) {
  const value = summary?.[metric]
  assert(isPlainObject(value), `${label}.${metric} must be an object`)
  requireInteger(value.count, `${label}.${metric}.count`, 0)
  requireInteger(value.covered, `${label}.${metric}.covered`, 0)
  assert(value.covered <= value.count, `${label}.${metric}.covered exceeds count`)
  if (Object.hasOwn(value, 'notcovered')) {
    requireInteger(value.notcovered, `${label}.${metric}.notcovered`, 0)
    assert(value.notcovered === value.count - value.covered,
      `${label}.${metric}.notcovered is inconsistent`)
  }
  return { total: value.count, covered: value.covered, uncovered: value.count - value.covered }
}

function parseLLVMExport(document, repositoryRoot, scope) {
  assert(isPlainObject(document), 'LLVM coverage export must be an object')
  assert(document.type === 'llvm.coverage.json.export', 'unexpected LLVM coverage export type')
  // Xcode 16 exports schema 2.x and newer Xcode toolchains export 3.x. The
  // per-file summaries consumed below are identical across those versions.
  assert(typeof document.version === 'string' && /^[23]\./u.test(document.version),
    `unsupported LLVM coverage JSON version: ${document.version}`)
  assert(Array.isArray(document.data) && document.data.length === 1,
    'LLVM coverage export must contain exactly one merged data object')
  assert(Array.isArray(document.data[0].files), 'LLVM coverage export files must be an array')

  const relevant = new Map()
  const sourcePrefix = `${scope.sourceRoot}/`
  for (const file of document.data[0].files) {
    assert(isPlainObject(file), 'LLVM coverage file entry must be an object')
    const lexicalPath = repositoryRelativeFilename(file.filename, repositoryRoot)
    if (lexicalPath === undefined || !lexicalPath.startsWith(sourcePrefix) || !lexicalPath.endsWith('.swift')) continue
    const path = normalizeCoverageFilename(file.filename, repositoryRoot)
    assert(!relevant.has(path), `LLVM coverage export contains duplicate source entry: ${path}`)
    const metrics = Object.fromEntries(METRIC_NAMES.map(metric => [
      metric,
      parseMetric(file.summary, metric, `LLVM coverage file ${path}`),
    ]))
    relevant.set(path, metrics)
  }

  const coveragePaths = [...relevant.keys()].sort((left, right) => Buffer.compare(Buffer.from(left), Buffer.from(right)))
  requireSameInventory(coveragePaths, scope.eligible, 'instrumented production-source inventory')
  for (const excluded of scope.excluded) {
    assert(!relevant.has(excluded), `platform-excluded source unexpectedly appeared in macOS coverage: ${excluded}`)
  }
  return { version: document.version, files: relevant }
}

function percentageBasisPoints(metric) {
  return metric.total === 0 ? 0 : Math.floor((metric.covered * 10_000) / metric.total)
}

function displayPercent(metric) {
  return metric.total === 0 ? '0.00' : ((metric.covered * 100) / metric.total).toFixed(2)
}

function aggregate(paths, coverage) {
  const metrics = Object.fromEntries(METRIC_NAMES.map(metric => [
    metric,
    { total: 0, covered: 0, uncovered: 0 },
  ]))
  for (const path of paths) {
    const file = coverage.files.get(path)
    assert(file !== undefined, `missing parsed coverage for ${path}`)
    for (const metric of METRIC_NAMES) {
      metrics[metric].total += file[metric].total
      metrics[metric].covered += file[metric].covered
      metrics[metric].uncovered += file[metric].uncovered
    }
  }
  for (const metric of METRIC_NAMES) {
    metrics[metric].percentBasisPoints = percentageBasisPoints(metrics[metric])
    metrics[metric].percent = Number(displayPercent(metrics[metric]))
  }
  return { fileCount: paths.length, metrics }
}

function fileDigestEvidence(repositoryRoot, paths, label) {
  const hash = createHash('sha256')
  const files = []
  for (const path of paths) {
    const bytes = readRegularFile(resolveCanonicalRepositoryPath(repositoryRoot, path, label), `${label} ${path}`)
    const digest = sha256(bytes)
    files.push({ path, sha256: digest })
    hash.update(path).update('\0').update(digest).update('\n')
  }
  return { digestSHA256: hash.digest('hex'), files }
}

function buildInputManifest({ policy, policySHA256, repositoryRoot, sourceRevision, repositoryState, repositoryStatusSHA256 }) {
  assert(/^[0-9a-f]{40}$/u.test(sourceRevision),
    'source revision must be a lowercase 40-character Git object ID')
  assert(repositoryState === 'clean' || repositoryState === 'dirty',
    'repository state must be exactly clean or dirty')
  assert(SHA256.test(repositoryStatusSHA256), 'repository status digest must be a lowercase SHA-256')
  const scope = buildScope(policy, repositoryRoot)
  const testInputPaths = listRegularInputs(repositoryRoot, UNIT_TEST_SOURCE_ROOT, 'unit-test input scope')
  const buildInputPaths = listRegularInputs(repositoryRoot, policy.scope.sourceRoot, 'build resource scope')
  buildInputPaths.push('Package.swift')
  buildInputPaths.push(policy.test.inventoryPath)
  try {
    const resolved = lstatSync(join(repositoryRoot, 'Package.resolved'))
    assert(resolved.isFile() && !resolved.isSymbolicLink(), 'Package.resolved must be a regular, non-symlink file')
    buildInputPaths.push('Package.resolved')
  } catch (error) {
    if (error?.code !== 'ENOENT') throw error
  }
  buildInputPaths.sort((left, right) => Buffer.compare(Buffer.from(left), Buffer.from(right)))
  return {
    schemaVersion: 1,
    sourceRevision,
    repositoryState,
    repositoryStatusSHA256,
    production: fileDigestEvidence(repositoryRoot, scope.allFiles, 'production source file'),
    buildInputs: fileDigestEvidence(repositoryRoot, buildInputPaths, 'SwiftPM build input'),
    testInputs: {
      root: UNIT_TEST_SOURCE_ROOT,
      ...fileDigestEvidence(repositoryRoot, testInputPaths, 'unit-test input file'),
    },
    policy: { path: POLICY_FILE, sha256: policySHA256 },
    tooling: {
      ...fileDigestEvidence(repositoryRoot, TOOLING_FILES, 'coverage tooling file'),
    },
  }
}

function verifyInputManifest(supplied, expected) {
  assert(isPlainObject(supplied), 'pre-build input manifest must be an object')
  assert(JSON.stringify(supplied) === JSON.stringify(expected),
    'production, test, policy, tooling, revision, or repository state changed after pre-build capture')
}

function validateToolchainEvidence(document) {
  requireExactKeys(document, ['schemaVersion', 'architecture', 'developerDirectory', 'swift', 'xcode', 'llvm', 'node', 'bash'], 'toolchain evidence')
  assert(document.schemaVersion === 1, 'toolchain evidence schemaVersion must be 1')
  assert(typeof document.architecture === 'string' && /^[A-Za-z0-9_-]{1,32}$/u.test(document.architecture),
    'toolchain architecture is malformed')
  assert(typeof document.developerDirectory === 'string' && document.developerDirectory.startsWith('/'),
    'toolchain developer directory must be absolute')
  const validateToolPath = (path, label) => assert(typeof path === 'string' && path.startsWith('/') && resolve(path) === path,
    `${label} must be an absolute normalized path`)
  requireExactKeys(document.swift, ['version', 'path'], 'toolchain evidence swift')
  validateToolPath(document.swift.path, 'Swift tool path')
  assert(typeof document.swift.version === 'string' &&
    /^Apple Swift version [ -~]{1,240}$/u.test(document.swift.version), 'Swift version evidence is malformed')
  requireExactKeys(document.xcode, ['version', 'buildVersion', 'path'], 'toolchain evidence xcode')
  validateToolPath(document.xcode.path, 'Xcode tool path')
  assert(typeof document.xcode.version === 'string' && /^Xcode [0-9]+(?:\.[0-9]+)*$/u.test(document.xcode.version),
    'Xcode version evidence is malformed')
  assert(typeof document.xcode.buildVersion === 'string' &&
    /^Build version [A-Za-z0-9.]{1,64}$/u.test(document.xcode.buildVersion),
  'Xcode build-version evidence is malformed')
  requireExactKeys(document.llvm, ['version', 'path'], 'toolchain evidence llvm')
  validateToolPath(document.llvm.path, 'LLVM tool path')
  assert(typeof document.llvm.version === 'string' &&
    /^(?:Apple )?LLVM version [ -~]{1,240}$/u.test(document.llvm.version), 'LLVM version evidence is malformed')
  for (const name of ['node', 'bash']) {
    requireExactKeys(document[name], ['version', 'path'], `toolchain evidence ${name}`)
    validateToolPath(document[name].path, `${name} tool path`)
    assert(typeof document[name].version === 'string' && /^[ -~]{1,240}$/u.test(document[name].version),
      `${name} version evidence is malformed`)
  }
  assert(document.swift.path.startsWith(`${document.developerDirectory}/`) &&
    document.xcode.path.startsWith(`${document.developerDirectory}/`) &&
    document.llvm.path.startsWith(`${document.developerDirectory}/`),
  'Swift, xcodebuild, and LLVM must resolve below the selected developer directory')
  return document
}

function buildToolchainEvidence(input) {
  return validateToolchainEvidence({
    schemaVersion: 1,
    architecture: input.architecture,
    developerDirectory: input.developerDirectory,
    swift: { version: input.swiftVersion, path: input.swiftPath },
    xcode: { version: input.xcodeVersion, buildVersion: input.xcodeBuildVersion, path: input.xcodePath },
    llvm: { version: input.llvmVersion, path: input.llvmPath },
    node: { version: input.nodeVersion, path: input.nodePath },
    bash: { version: input.bashVersion, path: input.bashPath },
  })
}

function evaluateAggregateGate(scope, actual, thresholds) {
  const checks = []
  for (const metricName of METRIC_NAMES) {
    const metric = actual.metrics[metricName]
    const threshold = thresholds[metricName]
    const metricChecks = [
      {
        rule: 'minimumPercentBasisPoints',
        actual: metric.percentBasisPoints,
        required: threshold.minimumPercentBasisPoints,
        pass: metric.percentBasisPoints >= threshold.minimumPercentBasisPoints,
      },
      {
        rule: 'minimumCovered',
        actual: metric.covered,
        required: threshold.minimumCovered,
        pass: metric.covered >= threshold.minimumCovered,
      },
      {
        rule: 'minimumTotal',
        actual: metric.total,
        required: threshold.minimumTotal,
        pass: metric.total >= threshold.minimumTotal,
      },
      {
        rule: 'maximumUncovered',
        actual: metric.uncovered,
        required: threshold.maximumUncovered,
        pass: metric.uncovered <= threshold.maximumUncovered,
      },
    ]
    checks.push(...metricChecks.map(check => ({ scope, metric: metricName, ...check })))
  }
  return { result: checks.every(check => check.pass) ? 'pass' : 'fail', checks }
}

function evaluatePerFileGate(scope, files, thresholds) {
  return files.map(file => {
    const metrics = Object.fromEntries(METRIC_NAMES.map(metric => {
      const actualPercentBasisPoints = file.metrics[metric].percentBasisPoints
      const requiredPercentBasisPoints = thresholds.perFileMinimumPercentBasisPoints[metric]
      return [metric, {
        actualPercentBasisPoints,
        requiredPercentBasisPoints,
        pass: actualPercentBasisPoints >= requiredPercentBasisPoints,
      }]
    }))
    return {
      scope,
      path: file.path,
      pass: METRIC_NAMES.every(metric => metrics[metric].pass),
      metrics,
    }
  })
}

function evaluateCriticalFileGate(criticalFiles, handwrittenFiles) {
  const filesByPath = new Map(handwrittenFiles.map(file => [file.path, file]))
  return criticalFiles.map(thresholds => {
    const file = filesByPath.get(thresholds.path)
    assert(file !== undefined,
      `critical coverage policy names missing macOS-compiled handwritten source: ${thresholds.path}`)
    const gate = evaluateAggregateGate(`critical:${thresholds.path}`, { metrics: file.metrics }, thresholds)
    return { path: thresholds.path, result: gate.result, checks: gate.checks }
  })
}

function evaluateGate(handwritten, generated, thresholds, handwrittenFiles, generatedFiles) {
  const aggregates = {
    handwritten: evaluateAggregateGate('handwritten', handwritten, thresholds.handwritten),
    generated: evaluateAggregateGate('generated', generated, thresholds.generated),
  }
  const perFileChecks = [
    ...evaluatePerFileGate('handwritten', handwrittenFiles, thresholds.handwritten),
    ...evaluatePerFileGate('generated', generatedFiles, thresholds.generated),
  ]
  const criticalFileChecks = evaluateCriticalFileGate(thresholds.criticalFiles, handwrittenFiles)
  const passed = Object.values(aggregates).every(gate => gate.result === 'pass') &&
    perFileChecks.every(check => check.pass) &&
    criticalFileChecks.every(check => check.result === 'pass')
  return { result: passed ? 'pass' : 'fail', aggregates, perFileChecks, criticalFileChecks }
}

function parseLCOVMetric(lines, prefix, source) {
  const entries = lines.filter(line => line.startsWith(`${prefix}:`))
  assert(entries.length === 1, `LCOV record for ${source} must contain exactly one ${prefix} entry`)
  const match = new RegExp(`^${prefix}:(0|[1-9][0-9]*)$`, 'u').exec(entries[0])
  assert(match !== null, `LCOV record for ${source} has malformed ${prefix}`)
  const value = Number(match[1])
  requireInteger(value, `LCOV ${prefix} for ${source}`, 0)
  return value
}

function validateLCOVRecord(lines, source) {
  const data = []
  const lineIdentifiers = new Set()
  for (const line of lines) {
    if (!line.startsWith('DA:')) continue
    const match = /^DA:([1-9][0-9]*),(0|[1-9][0-9]*)(?:,([A-Za-z0-9+/=]+))?$/u.exec(line)
    assert(match !== null, `LCOV record for ${source} has malformed DA entry: ${line}`)
    const lineNumber = Number(match[1])
    const executionCount = BigInt(match[2])
    requireInteger(lineNumber, `LCOV line identifier for ${source}`, 1)
    assert(executionCount <= 18_446_744_073_709_551_615n,
      `LCOV execution count for ${source} exceeds UInt64`)
    assert(!lineIdentifiers.has(lineNumber),
      `LCOV record for ${source} contains duplicate line identifier ${lineNumber}`)
    lineIdentifiers.add(lineNumber)
    data.push({ lineNumber, executionCount })
  }
  const lineTotal = parseLCOVMetric(lines, 'LF', source)
  const lineCovered = parseLCOVMetric(lines, 'LH', source)
  const functionTotal = parseLCOVMetric(lines, 'FNF', source)
  const functionCovered = parseLCOVMetric(lines, 'FNH', source)
  const coveredData = data.filter(entry => entry.executionCount > 0n).length
  // LLVM can coalesce adjacent source lines into one DA counter, so DA counts
  // are lower bounds rather than exact LF/LH identities.
  assert(data.length <= lineTotal,
    `LCOV record for ${source} has ${data.length} DA entries but LF is ${lineTotal}`)
  assert(coveredData <= lineCovered,
    `LCOV record for ${source} has ${coveredData} covered DA entries but LH is ${lineCovered}`)
  assert(lineCovered <= lineTotal, `LCOV LH exceeds LF for ${source}`)
  assert(functionCovered <= functionTotal, `LCOV FNH exceeds FNF for ${source}`)
  return {
    lines: { total: lineTotal, covered: lineCovered },
    functions: { total: functionTotal, covered: functionCovered },
    maximumLineNumber: data.reduce((maximum, entry) => Math.max(maximum, entry.lineNumber), 0),
  }
}

function physicalLineCount(bytes) {
  if (bytes.length === 0) return 0
  let lines = 0
  for (const byte of bytes) if (byte === 0x0a) lines += 1
  if (bytes[bytes.length - 1] !== 0x0a) lines += 1
  return lines
}

function parseLCOV(text, repositoryRoot, expectedPaths, coverage) {
  const records = []
  let current = []
  for (const line of text.split(/\r?\n/u)) {
    if (line === '' && current.length === 0) continue
    current.push(line)
    if (line === 'end_of_record') {
      const sourceLines = current.filter(value => value.startsWith('SF:'))
      assert(sourceLines.length === 1, 'each LCOV record must contain exactly one SF entry')
      const filename = sourceLines[0].slice(3)
      const recordLabel = filename.length > 0 ? filename : '<empty SF>'
      const lineMetric = validateLCOVRecord(current, recordLabel)
      const lexicalSource = repositoryRelativeFilename(filename, repositoryRoot)
      const source = lexicalSource !== undefined && expectedPaths.includes(lexicalSource)
        ? normalizeCoverageFilename(filename, repositoryRoot)
        : lexicalSource
      records.push({ source, lines: current, lineMetric })
      current = []
    }
  }
  assert(current.length === 0, 'LCOV input ends with an incomplete record')
  const wanted = new Set(expectedPaths)
  const selected = records.filter(record => record.source !== undefined && wanted.has(record.source))
  const selectedPaths = selected.map(record => record.source)
    .sort((left, right) => Buffer.compare(Buffer.from(left), Buffer.from(right)))
  requireSameInventory(selectedPaths, expectedPaths, 'LCOV production-source inventory')
  const duplicateCheck = new Set(selectedPaths)
  assert(duplicateCheck.size === selectedPaths.length, 'LCOV contains duplicate production-source records')
  for (const record of selected) {
    const jsonLines = coverage.files.get(record.source)?.lines
    const jsonFunctions = coverage.files.get(record.source)?.functions
    assert(jsonLines !== undefined, `missing LLVM JSON line summary for LCOV source ${record.source}`)
    assert(jsonFunctions !== undefined, `missing LLVM JSON function summary for LCOV source ${record.source}`)
    assert(record.lineMetric.lines.total === jsonLines.total,
      `LCOV LF for ${record.source} is ${record.lineMetric.lines.total}; LLVM JSON line total is ${jsonLines.total}`)
    assert(record.lineMetric.lines.covered === jsonLines.covered,
      `LCOV LH for ${record.source} is ${record.lineMetric.lines.covered}; LLVM JSON covered lines is ${jsonLines.covered}`)
    assert(record.lineMetric.functions.total === jsonFunctions.total,
      `LCOV FNF for ${record.source} is ${record.lineMetric.functions.total}; LLVM JSON function total is ${jsonFunctions.total}`)
    assert(record.lineMetric.functions.covered === jsonFunctions.covered,
      `LCOV FNH for ${record.source} is ${record.lineMetric.functions.covered}; LLVM JSON covered functions is ${jsonFunctions.covered}`)
    const sourceBytes = readRegularFile(
      resolveRepositoryPath(repositoryRoot, record.source, 'LCOV source file'),
      `LCOV source file ${record.source}`,
    )
    const sourceLineCount = physicalLineCount(sourceBytes)
    assert(record.lineMetric.maximumLineNumber <= sourceLineCount,
      `LCOV DA line ${record.lineMetric.maximumLineNumber} exceeds ${record.source}'s ${sourceLineCount} physical lines`)
  }
  return new Map(selected.map(record => [record.source, record]))
}

function renderLCOV(records, paths) {
  let output = ''
  for (const path of paths) {
    const record = records.get(path)
    assert(record !== undefined, `missing LCOV record for ${path}`)
    output += `${record.lines.map(line => line.startsWith('SF:') ? `SF:${path}` : line).join('\n')}\n`
  }
  return output
}

function atomicWrite(path, contents) {
  const parent = dirname(path)
  let stat
  try {
    stat = lstatSync(parent)
  } catch (error) {
    fail(`cannot inspect output directory ${parent}: ${error.message}`)
  }
  assert(stat.isDirectory() && !stat.isSymbolicLink(), `output directory must be a real directory: ${parent}`)
  try {
    const existing = lstatSync(path)
    assert(!existing.isSymbolicLink(), `refusing to replace symlinked output: ${path}`)
  } catch (error) {
    if (error?.code !== 'ENOENT') throw error
  }
  const temporary = `${path}.tmp-${process.pid}`
  writeFileSync(temporary, contents, { flag: 'wx', mode: 0o644 })
  renameSync(temporary, path)
}

function buildCompletionAttestation(directory) {
  const canonicalDirectory = realpathSync(directory)
  const artifacts = EVIDENCE_FILES.map(path => {
    const bytes = readRegularFile(join(canonicalDirectory, path), `staged evidence ${path}`)
    return { path, bytes: bytes.length, sha256: sha256(bytes) }
  })
  const summary = parseJSON(readRegularFile(join(canonicalDirectory, 'coverage-summary.json'),
    'staged coverage summary'), 'staged coverage summary')
  assert(summary?.gate?.result === 'pass', 'cannot attest a coverage result that did not pass')
  return { schemaVersion: 1, result: 'pass', artifacts }
}

function verifyCompletionAttestation(directory, supplied) {
  requireExactKeys(supplied, ['schemaVersion', 'result', 'artifacts'], 'completion attestation')
  assert(JSON.stringify(supplied) === JSON.stringify(buildCompletionAttestation(directory)),
    'completion attestation does not match the evidence artifact bytes')
}

function fileDetails(paths, coverage) {
  return paths.map(path => ({
    path,
    metrics: Object.fromEntries(METRIC_NAMES.map(metric => {
      const value = coverage.files.get(path)[metric]
      return [metric, {
        ...value,
        percentBasisPoints: percentageBasisPoints(value),
        percent: Number(displayPercent(value)),
      }]
    })),
  }))
}

function renderMarkdown(summary, policy) {
  const status = summary.gate.result === 'pass' ? 'PASS' : 'FAIL'
  const rows = ['| Scope | Files | Lines | Functions | Regions |', '| --- | ---: | ---: | ---: | ---: |']
  for (const [label, key] of [['Handwritten', 'handwritten'], ['Generated', 'generated'], ['All macOS source', 'allSource']]) {
    const scope = summary.coverage[key]
    rows.push(`| ${label} | ${scope.fileCount} | ${scope.metrics.lines.percent.toFixed(2)}% (${scope.metrics.lines.covered}/${scope.metrics.lines.total}) | ${scope.metrics.functions.percent.toFixed(2)}% (${scope.metrics.functions.covered}/${scope.metrics.functions.total}) | ${scope.metrics.regions.percent.toFixed(2)}% (${scope.metrics.regions.covered}/${scope.metrics.regions.total}) |`)
  }
  const policyRows = [
    '| Scope | Metric | Actual | Minimum | Covered | Minimum covered | Uncovered | Maximum uncovered | Total | Minimum total | Result |',
    '| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | :---: |',
  ]
  for (const scopeName of ['handwritten', 'generated']) {
    for (const metric of METRIC_NAMES) {
      const actual = summary.coverage[scopeName].metrics[metric]
      const threshold = policy.gate[scopeName][metric]
      const aggregate = summary.gate.aggregates[scopeName]
      const checks = aggregate.checks.filter(check => check.metric === metric)
      const passed = checks.every(check => check.pass)
      policyRows.push(`| ${scopeName} | ${metric} | ${actual.percent.toFixed(2)}% | ${(threshold.minimumPercentBasisPoints / 100).toFixed(2)}% | ${actual.covered} | ${threshold.minimumCovered} | ${actual.uncovered} | ${threshold.maximumUncovered} | ${actual.total} | ${threshold.minimumTotal} | ${passed ? 'PASS' : 'FAIL'} |`)
    }
  }
  const perFileRows = [
    '| Scope | Metric | Per-file floor | Lowest file | Lowest actual | Result |',
    '| --- | --- | ---: | --- | ---: | :---: |',
  ]
  for (const scopeName of ['handwritten', 'generated']) {
    for (const metric of METRIC_NAMES) {
      const checks = summary.gate.perFileChecks
        .filter(file => file.scope === scopeName)
        .map(file => ({ path: file.path, ...file.metrics[metric] }))
        .sort((left, right) => left.actualPercentBasisPoints - right.actualPercentBasisPoints ||
          Buffer.compare(Buffer.from(left.path), Buffer.from(right.path)))
      assert(checks.length > 0, `${scopeName} per-file coverage evidence is empty`)
      const lowestCheck = checks[0]
      perFileRows.push(`| ${scopeName} | ${metric} | ${(lowestCheck.requiredPercentBasisPoints / 100).toFixed(2)}% | ${lowestCheck.path} | ${(lowestCheck.actualPercentBasisPoints / 100).toFixed(2)}% | ${checks.every(check => check.pass) ? 'PASS' : 'FAIL'} |`)
    }
  }
  const perFileFailures = summary.gate.perFileChecks.filter(check => !check.pass)
  const failureRows = perFileFailures.length === 0
    ? ['All macOS-compiled handwritten and generated files pass every per-file floor.']
    : [
        '| Scope | Failing file | Lines | Functions | Regions |',
        '| --- | --- | ---: | ---: | ---: |',
        ...perFileFailures.map(file => `| ${file.scope} | ${file.path} | ${(file.metrics.lines.actualPercentBasisPoints / 100).toFixed(2)}% | ${(file.metrics.functions.actualPercentBasisPoints / 100).toFixed(2)}% | ${(file.metrics.regions.actualPercentBasisPoints / 100).toFixed(2)}% |`),
      ]
  const criticalRows = summary.gate.criticalFileChecks.length === 0
    ? ['No critical-file ratchets are configured; populate them only from fresh, reviewed evidence.']
    : [
        '| Critical file | Metric | Actual | Minimum | Covered | Minimum covered | Uncovered | Maximum uncovered | Total | Minimum total | Result |',
        '| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | :---: |',
        ...summary.gate.criticalFileChecks.flatMap(file => METRIC_NAMES.map(metric => {
          const checks = file.checks.filter(check => check.metric === metric)
          const byRule = new Map(checks.map(check => [check.rule, check]))
          const percentage = byRule.get('minimumPercentBasisPoints')
          const covered = byRule.get('minimumCovered')
          const uncovered = byRule.get('maximumUncovered')
          const total = byRule.get('minimumTotal')
          assert(percentage && covered && uncovered && total,
            `critical-file evidence is incomplete for ${file.path} ${metric}`)
          return `| ${file.path} | ${metric} | ${(percentage.actual / 100).toFixed(2)}% | ${(percentage.required / 100).toFixed(2)}% | ${covered.actual} | ${covered.required} | ${uncovered.actual} | ${uncovered.required} | ${total.actual} | ${total.required} | ${checks.every(check => check.pass) ? 'PASS' : 'FAIL'} |`
        })),
      ]
  const lowest = [...summary.files.handwritten]
    .sort((left, right) => left.metrics.lines.percentBasisPoints - right.metrics.lines.percentBasisPoints ||
      Buffer.compare(Buffer.from(left.path), Buffer.from(right.path)))
    .slice(0, 10)
    .map(file => `| ${file.path} | ${file.metrics.lines.percent.toFixed(2)}% | ${file.metrics.lines.covered}/${file.metrics.lines.total} |`)
  return [
    '# QVAC Swift coverage gate',
    '',
    `**${status}** — deterministic, fail-closed execution of ${summary.test.executedCount} reviewed unit tests.`,
    '',
    ...rows,
    '',
    'Handwritten and generated production Swift have separate aggregate gates. Generated coverage cannot inflate the handwritten result.',
    '',
    '## Regression policy',
    '',
    ...policyRows,
    '',
    '## Per-file policy',
    '',
    ...perFileRows,
    '',
    ...failureRows,
    '',
    '## Critical-file ratchets',
    '',
    ...criticalRows,
    '',
    '## Lowest handwritten line coverage',
    '',
    '| File | Lines | Covered/total |',
    '| --- | ---: | ---: |',
    ...lowest,
    '',
    `Source revision: \`${summary.source.revision}\` (${summary.source.repositoryState} worktree)`,
    '',
    `Production-source digest: \`${summary.source.digestSHA256}\``,
    '',
    `Unit-test input digest (${summary.test.inputs.fileCount} files): \`${summary.test.inputs.digestSHA256}\``,
    '',
    `Coverage analyzer digest: \`${summary.tooling.analyzer.sha256}\``,
    '',
    `Coverage runner digest: \`${summary.tooling.runner.sha256}\``,
    '',
    `Toolchain: ${summary.toolchain.architecture}; ${summary.toolchain.swift.version}; ${summary.toolchain.xcode.version} (${summary.toolchain.xcode.buildVersion}); ${summary.toolchain.llvm.version}`,
    '',
    `Toolchain evidence digest: \`${summary.toolchain.evidenceSHA256}\``,
    '',
    `Pre-build input-manifest digest: \`${summary.inputManifestSHA256}\``,
    '',
    `Policy digest: \`${summary.policySHA256}\``,
    '',
  ].join('\n')
}

function buildSummary({
  policy,
  policySHA256,
  repositoryRoot,
  llvmDocument,
  llvmLCOV,
  sourceRevision,
  repositoryState,
  repositoryStatusSHA256,
  postSourceRevision,
  postRepositoryState,
  postRepositoryStatusSHA256,
  inputManifest,
  inputManifestSHA256,
  toolchainDocument,
  toolchainSHA256,
  testListing,
  testOutput,
}) {
  assert(/^[0-9a-f]{40}$/u.test(sourceRevision), 'source revision must be a lowercase 40-character Git object ID')
  assert(repositoryState === 'clean' || repositoryState === 'dirty',
    'repository state must be exactly clean or dirty')
  assert(postSourceRevision === sourceRevision, 'Git HEAD changed during coverage collection')
  assert(postRepositoryState === repositoryState, 'repository cleanliness changed during coverage collection')
  assert(postRepositoryStatusSHA256 === repositoryStatusSHA256,
    'repository status changed during coverage collection')
  assert(SHA256.test(inputManifestSHA256), 'pre-build input-manifest digest must be a lowercase SHA-256')
  assert(SHA256.test(toolchainSHA256), 'toolchain evidence digest must be a lowercase SHA-256')
  const expectedInputManifest = buildInputManifest({
    policy, policySHA256, repositoryRoot, sourceRevision, repositoryState, repositoryStatusSHA256,
  })
  verifyInputManifest(inputManifest, expectedInputManifest)
  const toolchain = validateToolchainEvidence(toolchainDocument)
  const scope = buildScope(policy, repositoryRoot)
  const coverage = parseLLVMExport(llvmDocument, repositoryRoot, {
    ...scope,
    sourceRoot: policy.scope.sourceRoot,
  })
  const lcovRecords = parseLCOV(llvmLCOV, repositoryRoot, scope.eligible, coverage)
  const inventory = validateInventory(policy, repositoryRoot)
  const discovered = verifyDiscovery(testListing, policy, inventory)
  const execution = verifyExecution(testOutput, policy, inventory)
  const handwritten = aggregate(scope.handwritten, coverage)
  const generated = aggregate(scope.generated, coverage)
  const allSource = aggregate(scope.eligible, coverage)
  const handwrittenFiles = fileDetails(scope.handwritten, coverage)
  const generatedFiles = fileDetails(scope.generated, coverage)
  const gate = evaluateGate(
    handwritten,
    generated,
    policy.gate,
    handwrittenFiles,
    generatedFiles,
  )
  const productionSourceEvidence = expectedInputManifest.production
  const unitTestInputEvidence = expectedInputManifest.testInputs
  const toolingEvidence = expectedInputManifest.tooling
  const toolingByPath = new Map(toolingEvidence.files.map(file => [file.path, file]))
  assert(toolingByPath.size === TOOLING_FILES.length, 'coverage tooling evidence is incomplete')
  const summary = {
    schemaVersion: 1,
    source: {
      revision: sourceRevision,
      repositoryState,
      repositoryStatusSHA256,
      postRevision: postSourceRevision,
      postRepositoryState,
      postRepositoryStatusSHA256,
      buildInputs: expectedInputManifest.buildInputs,
      digestSHA256: productionSourceEvidence.digestSHA256,
    },
    policySHA256,
    inputManifestSHA256,
    llvmCoverageVersion: coverage.version,
    toolchain: { ...toolchain, evidenceSHA256: toolchainSHA256 },
    test: {
      module: policy.test.module,
      discoveredCount: discovered.length,
      executedCount: execution.passed.length,
      inventorySHA256: inventory.sha256,
      listingSHA256: sha256(Buffer.from(testListing)),
      outputSHA256: sha256(Buffer.from(testOutput)),
      inputs: {
        root: UNIT_TEST_SOURCE_ROOT,
        fileCount: unitTestInputEvidence.files.length,
        digestSHA256: unitTestInputEvidence.digestSHA256,
        files: unitTestInputEvidence.files,
      },
    },
    scope: {
      sourceRoot: policy.scope.sourceRoot,
      handwrittenFileCount: scope.handwritten.length,
      generatedFiles: scope.generated,
      platformExclusions: policy.scope.platformExclusions,
    },
    coverage: { handwritten, generated, allSource },
    gate,
    tooling: {
      analyzer: toolingByPath.get('tools/coverage/analyze-coverage.mjs'),
      runner: toolingByPath.get('tools/coverage/run.sh'),
      digestSHA256: toolingEvidence.digestSHA256,
    },
    files: {
      handwritten: handwrittenFiles,
      generated: generatedFiles,
    },
  }
  return {
    summary,
    markdown: renderMarkdown(summary, policy),
    handwrittenLCOV: renderLCOV(lcovRecords, scope.handwritten),
    allSourceLCOV: renderLCOV(lcovRecords, scope.eligible),
  }
}

function parseArguments(argv) {
  if (argv.length === 1 && argv[0] === '--self-test') return { command: 'self-test', options: {} }
  const [command, ...rest] = argv
  assert(typeof command === 'string', 'missing command')
  const options = {}
  for (let index = 0; index < rest.length; index += 2) {
    const name = rest[index]
    const value = rest[index + 1]
    assert(/^--[a-z][a-z0-9-]*$/u.test(name ?? '') && value !== undefined,
      `invalid option sequence near ${name ?? '<end>'}`)
    assert(options[name] === undefined, `duplicate option: ${name}`)
    options[name] = value
  }
  return { command, options }
}

function requireOptions(options, names) {
  requireExactKeys(options, names.map(name => `--${name}`), 'command options')
  return Object.fromEntries(names.map(name => [name, options[`--${name}`]]))
}

function expectFailure(action, label) {
  try {
    action()
  } catch (error) {
    if (error instanceof CoverageError) return
    throw error
  }
  fail(`self-test expected rejection: ${label}`)
}

function selfTest() {
  const root = realpathSync(mkdtempSync(join(tmpdir(), 'qvac-coverage-self-test-')))
  try {
    const numericOption = parseArguments([
      'probe', '--repository-status-sha256', '0123456789abcdef',
    ])
    assert(numericOption.options['--repository-status-sha256'] === '0123456789abcdef',
      'CLI option parser must accept numeric suffixes used by SHA-256 evidence')
    expectFailure(() => parseArguments(['probe', '--invalid_option', 'value']),
      'malformed CLI option name')

    mkdirSync(join(root, 'Sources/QVACClient/Generated'), { recursive: true })
    mkdirSync(join(root, 'Sources/QVACClient/Internal'), { recursive: true })
    mkdirSync(join(root, 'tools/ci'), { recursive: true })
    mkdirSync(join(root, UNIT_TEST_SOURCE_ROOT), { recursive: true })
    mkdirSync(join(root, UNIT_TEST_SOURCE_ROOT, 'Fixtures'), { recursive: true })
    mkdirSync(join(root, 'tools/coverage'), { recursive: true })
    writeFileSync(join(root, 'Sources/QVACClient/Internal/Main.swift'),
      Array.from({ length: 10 }, (_, index) => `func covered${index}() {}`).join('\n') + '\n')
    writeFileSync(join(root, 'Sources/QVACClient/Internal/iOSOnly.swift'), '#if os(iOS)\nfunc iosOnly() {}\n#endif\n')
    writeFileSync(join(root, 'Sources/QVACClient/Generated/API.generated.swift'),
      Array.from({ length: 5 }, (_, index) => `func generated${index}() {}`).join('\n') + '\n')
    writeFileSync(join(root, UNIT_TEST_SOURCE_ROOT, 'AlphaTests.swift'), 'func testAlphaBody() {}\n')
    writeFileSync(join(root, UNIT_TEST_SOURCE_ROOT, 'TestSupport.swift'), 'let fixture = 42\n')
    writeFileSync(join(root, UNIT_TEST_SOURCE_ROOT, 'Fixtures/input.json'), '{"fixture":true}\n')
    writeFileSync(join(root, TOOLING_FILES[0]), 'analyzer fixture\n')
    writeFileSync(join(root, TOOLING_FILES[1]), 'runner fixture\n')
    writeFileSync(join(root, 'Package.swift'), '// swift-tools-version: 6.0\n')

    const identifiers = ['UnitTests.Alpha/test_one', 'UnitTests.Beta/test_two']
    const inventoryText = `${identifiers.join('\n')}\n`
    writeFileSync(join(root, 'tools/ci/unit-test-inventory.txt'), inventoryText)
    const policy = {
      schemaVersion: 1,
      test: {
        module: 'UnitTests', product: 'PackageTests', expectedCount: 2,
        inventoryPath: 'tools/ci/unit-test-inventory.txt',
        inventorySHA256: sha256(Buffer.from(inventoryText)),
      },
      scope: {
        sourceRoot: 'Sources/QVACClient',
        generatedFiles: ['Sources/QVACClient/Generated/API.generated.swift'],
        platformExclusions: [{
          path: 'Sources/QVACClient/Internal/iOSOnly.swift',
          reason: 'This source is compiled only for the iOS transport target',
        }],
      },
      gate: { handwritten: {
        lines: { minimumPercentBasisPoints: 9000, minimumCovered: 9, minimumTotal: 10, maximumUncovered: 1 },
        functions: { minimumPercentBasisPoints: 10000, minimumCovered: 2, minimumTotal: 2, maximumUncovered: 0 },
        regions: { minimumPercentBasisPoints: 8000, minimumCovered: 4, minimumTotal: 5, maximumUncovered: 1 },
        perFileMinimumPercentBasisPoints: { lines: 7500, functions: 5000, regions: 5000 },
      }, generated: {
        lines: { minimumPercentBasisPoints: 7500, minimumCovered: 4, minimumTotal: 5, maximumUncovered: 1 },
        functions: { minimumPercentBasisPoints: 10000, minimumCovered: 1, minimumTotal: 1, maximumUncovered: 0 },
        regions: { minimumPercentBasisPoints: 5000, minimumCovered: 1, minimumTotal: 2, maximumUncovered: 1 },
        perFileMinimumPercentBasisPoints: { lines: 7500, functions: 7500, regions: 5000 },
      }, criticalFiles: [{
        path: 'Sources/QVACClient/Internal/Main.swift',
        lines: { minimumPercentBasisPoints: 9000, minimumCovered: 9, minimumTotal: 10, maximumUncovered: 1 },
        functions: { minimumPercentBasisPoints: 10000, minimumCovered: 2, minimumTotal: 2, maximumUncovered: 0 },
        regions: { minimumPercentBasisPoints: 8000, minimumCovered: 4, minimumTotal: 5, maximumUncovered: 1 },
      }] },
    }
    validatePolicy(policy)
    const makeSummary = (filename, lines, functions, regions) => ({
      filename,
      summary: {
        lines: { count: lines[0], covered: lines[1], percent: 0 },
        functions: { count: functions[0], covered: functions[1], percent: 0 },
        regions: { count: regions[0], covered: regions[1], notcovered: regions[0] - regions[1], percent: 0 },
      },
    })
    const mainPath = join(root, 'Sources/QVACClient/Internal/Main.swift')
    const generatedPath = join(root, 'Sources/QVACClient/Generated/API.generated.swift')
    const llvmDocument = {
      type: 'llvm.coverage.json.export', version: '3.0.1',
      data: [{ files: [
        makeSummary(mainPath, [10, 9], [2, 2], [5, 4]),
        makeSummary(generatedPath, [5, 4], [1, 1], [2, 1]),
      ] }],
    }
    const lcovRecord = (path, lineHits, functionTotal, functionCovered) =>
      `SF:${path}\n${lineHits.map(([line, hits]) => `DA:${line},${hits}`).join('\n')}\nFNF:${functionTotal}\nFNH:${functionCovered}\nLF:${lineHits.length}\nLH:${lineHits.filter(([, hits]) => hits > 0).length}\nend_of_record\n`
    const lineHits = (total, covered) => Array.from(
      { length: total },
      (_, index) => [index + 1, index < covered ? 1 : 0],
    )
    const llvmLCOV = lcovRecord(mainPath, lineHits(10, 9), 2, 2) +
      lcovRecord(generatedPath, lineHits(5, 4), 1, 1)
    const testListing = `Noise.Other/test_noise\n${identifiers.join('\n')}\n`
    const passingOutput = [
      "Test Case '-[UnitTests.Alpha test_one]' started.",
      "Test Case '-[UnitTests.Alpha test_one]' passed (0.001 seconds).",
      "Test Case '-[UnitTests.Beta test_two]' started.",
      "Test Case '-[UnitTests.Beta test_two]' passed (0.002 seconds).",
      'Executed 2 tests, with 0 failures (0 unexpected) in 0.003 (0.003) seconds',
    ].join('\n')
    const revision = '0123456789012345678901234567890123456789'
    const toolchainDocument = buildToolchainEvidence({
      architecture: 'arm64',
      developerDirectory: '/Applications/Xcode.app/Contents/Developer',
      swiftVersion: 'Apple Swift version 6.3.3 (swiftlang-test clang-test)',
      swiftPath: '/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift',
      xcodeVersion: 'Xcode 26.6',
      xcodeBuildVersion: 'Build version 17F113',
      xcodePath: '/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild',
      llvmVersion: 'Apple LLVM version 21.0.0',
      llvmPath: '/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/llvm-cov',
      nodeVersion: 'v24.0.0', nodePath: '/usr/local/bin/node',
      bashVersion: 'GNU bash, version 3.2.57', bashPath: '/bin/bash',
    })
    const toolchainSHA256 = sha256(Buffer.from(`${JSON.stringify(toolchainDocument, null, 2)}\n`))
    const evidenceFor = (candidatePolicy, repositoryState = 'dirty') => {
      const policySHA256 = sha256(Buffer.from(JSON.stringify(candidatePolicy)))
      const repositoryStatusSHA256 = sha256(Buffer.from(repositoryState === 'dirty' ? ' M fixture\n' : ''))
      const inputManifest = buildInputManifest({
        policy: candidatePolicy, policySHA256, repositoryRoot: root,
        sourceRevision: revision, repositoryState, repositoryStatusSHA256,
      })
      return {
        policySHA256,
        sourceRevision: revision,
        repositoryState,
        repositoryStatusSHA256,
        postSourceRevision: revision,
        postRepositoryState: repositoryState,
        postRepositoryStatusSHA256: repositoryStatusSHA256,
        inputManifest,
        inputManifestSHA256: sha256(Buffer.from(JSON.stringify(inputManifest))),
        toolchainDocument,
        toolchainSHA256,
      }
    }
    const result = buildSummary({
      policy, repositoryRoot: root, llvmDocument, llvmLCOV,
      ...evidenceFor(policy), testListing, testOutput: passingOutput,
    })
    assert(result.summary.gate.result === 'pass', 'valid self-test fixture failed its gate')
    assert(result.summary.coverage.handwritten.metrics.lines.percent === 90, 'line aggregation is incorrect')
    assert(result.summary.coverage.allSource.metrics.lines.covered === 13, 'all-source aggregation is incorrect')
    assert(result.handwrittenLCOV.includes('SF:Sources/QVACClient/Internal/Main.swift'),
      'scoped LCOV did not normalize the source path')
    assert(!result.handwrittenLCOV.includes('Generated'), 'handwritten LCOV retained generated source')
    assert(result.summary.source.repositoryState === 'dirty', 'repository state was not recorded')
    assert(result.summary.test.inputs.fileCount === 3, 'unit-test input inventory is incomplete')
    assert(result.summary.test.inputs.files.every(file => SHA256.test(file.sha256)),
      'unit-test input body digest is malformed')
    assert(result.summary.test.inputs.files.find(file => file.path.endsWith('/AlphaTests.swift'))?.sha256 ===
      sha256(Buffer.from('func testAlphaBody() {}\n')), 'unit-test source body digest is incorrect')
    assert(result.summary.test.inputs.files.find(file => file.path.endsWith('/Fixtures/input.json'))?.sha256 ===
      sha256(Buffer.from('{"fixture":true}\n')), 'unit-test resource body digest is incorrect')
    assert(SHA256.test(result.summary.tooling.analyzer.sha256) && SHA256.test(result.summary.tooling.runner.sha256),
      'coverage tooling digest is malformed')
    assert(result.summary.tooling.analyzer.sha256 === sha256(Buffer.from('analyzer fixture\n')) &&
      result.summary.tooling.runner.sha256 === sha256(Buffer.from('runner fixture\n')),
    'coverage tooling body digest is incorrect')
    assert(result.summary.gate.perFileChecks.length === 2 &&
      result.summary.gate.perFileChecks.every(check => check.pass),
      'valid per-file coverage failed')
    assert(result.summary.gate.criticalFileChecks.length === 1 &&
      result.summary.gate.criticalFileChecks[0].result === 'pass',
    'valid critical-file coverage failed')
    assert(result.summary.gate.aggregates.generated.result === 'pass',
      'valid generated aggregate coverage failed')
    assert(result.markdown.includes('| generated | lines | 80.00%') &&
      result.markdown.includes('| generated | regions | 50.00%'),
    'generated gate is absent from Markdown output')

    const inventory = validateInventory(policy, root)
    verifyDiscovery(testListing, policy, inventory)
    verifyExecution(passingOutput, policy, inventory)
    expectFailure(() => verifyDiscovery('UnitTests.Alpha/test_one\n', policy, inventory), 'missing discovered test')
    expectFailure(() => verifyDiscovery('UnitTests.Alpha/test_one\nUnitTests.Gamma/test_three\n', policy, inventory),
      'equal-count test substitution')
    expectFailure(() => verifyExecution(passingOutput.replace('passed (0.002 seconds).', 'skipped (0.002 seconds).'),
      policy, inventory), 'skipped test')
    expectFailure(() => verifyExecution(passingOutput.replaceAll('Beta', 'Alpha').replaceAll('test_two', 'test_one'),
      policy, inventory), 'duplicate execution')

    const missingCoverage = structuredClone(llvmDocument)
    missingCoverage.data[0].files.pop()
    expectFailure(() => buildSummary({
      policy, repositoryRoot: root, llvmDocument: missingCoverage, llvmLCOV,
      ...evidenceFor(policy, 'clean'),
      testListing, testOutput: passingOutput,
    }), 'missing instrumented production source')

    const regressionPolicies = [
      ['percentage', policy => { policy.gate.handwritten.lines.minimumPercentBasisPoints = 9001 }],
      ['covered count', policy => { policy.gate.handwritten.lines.minimumCovered = 10 }],
      ['total count', policy => { policy.gate.handwritten.lines.minimumTotal = 11 }],
      ['uncovered count', policy => { policy.gate.handwritten.lines.maximumUncovered = 0 }],
    ]
    for (const [label, mutate] of regressionPolicies) {
      const stricterPolicy = structuredClone(policy)
      mutate(stricterPolicy)
      const failed = buildSummary({
        policy: stricterPolicy, repositoryRoot: root, llvmDocument, llvmLCOV,
        ...evidenceFor(stricterPolicy, 'clean'), testListing, testOutput: passingOutput,
      })
      assert(failed.summary.gate.result === 'fail', `${label} regression was accepted`)
    }

    const perFilePolicy = structuredClone(policy)
    perFilePolicy.gate.handwritten.perFileMinimumPercentBasisPoints.lines = 9001
    const perFileFailed = buildSummary({
      policy: perFilePolicy, repositoryRoot: root, llvmDocument, llvmLCOV,
      ...evidenceFor(perFilePolicy, 'clean'), testListing, testOutput: passingOutput,
    })
    assert(perFileFailed.summary.gate.result === 'fail', 'per-file percentage regression was accepted')
    assert(!perFileFailed.summary.gate.perFileChecks[0].metrics.lines.pass,
      'per-file line failure is absent from machine-readable output')
    assert(perFileFailed.markdown.includes('| handwritten | lines | 90.01%') &&
      perFileFailed.markdown.includes('| Sources/QVACClient/Internal/Main.swift |'),
    'per-file failure is absent from Markdown output')

    const generatedPerFilePolicy = structuredClone(policy)
    generatedPerFilePolicy.gate.generated.perFileMinimumPercentBasisPoints.regions = 5001
    const generatedPerFileFailed = buildSummary({
      policy: generatedPerFilePolicy, repositoryRoot: root, llvmDocument, llvmLCOV,
      ...evidenceFor(generatedPerFilePolicy, 'clean'), testListing, testOutput: passingOutput,
    })
    const generatedPerFileCheck = generatedPerFileFailed.summary.gate.perFileChecks
      .find(check => check.scope === 'generated')
    assert(generatedPerFileFailed.summary.gate.result === 'fail' &&
      generatedPerFileCheck?.metrics.regions.pass === false,
    'generated per-file percentage regression was accepted')
    assert(generatedPerFileFailed.markdown.includes('| generated | regions | 50.01%') &&
      generatedPerFileFailed.markdown.includes('| generated | Sources/QVACClient/Generated/API.generated.swift |'),
    'generated per-file failure is absent from Markdown output')

    const criticalPolicy = structuredClone(policy)
    criticalPolicy.gate.criticalFiles[0].lines.maximumUncovered = 0
    const criticalFailed = buildSummary({
      policy: criticalPolicy, repositoryRoot: root, llvmDocument, llvmLCOV,
      ...evidenceFor(criticalPolicy, 'clean'), testListing, testOutput: passingOutput,
    })
    assert(criticalFailed.summary.gate.result === 'fail' &&
      criticalFailed.summary.gate.criticalFileChecks[0].result === 'fail',
    'critical-file absolute regression was accepted')
    assert(criticalFailed.markdown.includes(
      '| Sources/QVACClient/Internal/Main.swift | lines | 90.00% | 90.00% | 9 | 9 | 1 | 0 | 10 | 10 | FAIL |'),
      'critical-file failure is absent from Markdown output')

    const generatedPolicy = structuredClone(policy)
    generatedPolicy.gate.generated.lines.minimumPercentBasisPoints = 8001
    const generatedFailed = buildSummary({
      policy: generatedPolicy, repositoryRoot: root, llvmDocument, llvmLCOV,
      ...evidenceFor(generatedPolicy, 'clean'), testListing, testOutput: passingOutput,
    })
    assert(generatedFailed.summary.gate.result === 'fail' &&
      generatedFailed.summary.gate.aggregates.generated.result === 'fail',
    'generated aggregate regression was accepted')
    assert(generatedFailed.markdown.includes('| generated | lines | 80.00% | 80.01%') &&
      generatedFailed.markdown.includes('| generated | lines | 80.00% | 80.01% | 4 | 4 | 1 | 1 | 5 | 5 | FAIL |'),
    'generated aggregate failure is absent from Markdown output')

    writeFileSync(join(root, 'Sources/QVACClient/Generated/Unreviewed.swift'), 'func hidden() {}\n')
    expectFailure(() => buildScope(policy, root), 'unreviewed generated source')
    rmSync(join(root, 'Sources/QVACClient/Generated/Unreviewed.swift'))

    const mismatchedPolicy = structuredClone(policy)
    mismatchedPolicy.test.inventorySHA256 = '0'.repeat(64)
    expectFailure(() => validateInventory(mismatchedPolicy, root), 'inventory hash mismatch')
    expectFailure(() => parseLCOV(lcovRecord(mainPath, lineHits(10, 9), 2, 2), root,
      ['Sources/QVACClient/Internal/Main.swift', 'Sources/QVACClient/Generated/API.generated.swift'],
      parseLLVMExport(llvmDocument, root, {
        ...buildScope(policy, root), sourceRoot: policy.scope.sourceRoot,
      })),
    'missing LCOV source')
    const parsedCoverage = parseLLVMExport(llvmDocument, root, {
      ...buildScope(policy, root), sourceRoot: policy.scope.sourceRoot,
    })
    const validMainLCOV = lcovRecord(mainPath, lineHits(10, 9), 2, 2)
    expectFailure(() => parseLCOV(validMainLCOV.replace('DA:2,1', 'DA:not-a-line,1'), root,
      ['Sources/QVACClient/Internal/Main.swift'], parsedCoverage), 'malformed DA')
    expectFailure(() => parseLCOV(validMainLCOV.replace('DA:2,1', 'DA:1,1'), root,
      ['Sources/QVACClient/Internal/Main.swift'], parsedCoverage), 'duplicate DA line identifier')
    expectFailure(() => parseLCOV(validMainLCOV.replace('LF:10', 'LF:9'), root,
      ['Sources/QVACClient/Internal/Main.swift'], parsedCoverage), 'inconsistent LF')
    expectFailure(() => parseLCOV(validMainLCOV.replace('LH:9', 'LH:8'), root,
      ['Sources/QVACClient/Internal/Main.swift'], parsedCoverage), 'inconsistent LH')
    expectFailure(() => parseLCOV(validMainLCOV.replace('LF:10', 'LF:10\nLF:10'), root,
      ['Sources/QVACClient/Internal/Main.swift'], parsedCoverage), 'duplicate LF')
    expectFailure(() => parseLCOV(validMainLCOV.replace('LH:9', ''), root,
      ['Sources/QVACClient/Internal/Main.swift'], parsedCoverage), 'missing LH')
    expectFailure(() => parseLCOV(validMainLCOV.replace('LH:9', 'LH:9\nLH:9'), root,
      ['Sources/QVACClient/Internal/Main.swift'], parsedCoverage), 'duplicate LH')
    expectFailure(() => parseLCOV(validMainLCOV.replace('FNF:2', ''), root,
      ['Sources/QVACClient/Internal/Main.swift'], parsedCoverage), 'missing FNF')
    expectFailure(() => parseLCOV(validMainLCOV.replace('FNF:2', 'FNF:2\nFNF:2'), root,
      ['Sources/QVACClient/Internal/Main.swift'], parsedCoverage), 'duplicate FNF')
    expectFailure(() => parseLCOV(validMainLCOV.replace('FNH:2', 'FNH:3'), root,
      ['Sources/QVACClient/Internal/Main.swift'], parsedCoverage), 'FNH exceeds FNF')
    expectFailure(() => parseLCOV(validMainLCOV.replace('FNH:2', 'FNH:1'), root,
      ['Sources/QVACClient/Internal/Main.swift'], parsedCoverage), 'LCOV and LLVM JSON function disagreement')
    expectFailure(() => parseLCOV(validMainLCOV.replace('DA:10,0', 'DA:11,0'), root,
      ['Sources/QVACClient/Internal/Main.swift'], parsedCoverage), 'DA exceeds physical source lines')
    expectFailure(() => parseLCOV(validMainLCOV.replace('DA:9,1', 'DA:9,0').replace('LH:9', 'LH:8'), root,
      ['Sources/QVACClient/Internal/Main.swift'], parsedCoverage), 'LCOV and LLVM JSON disagreement')

    const capturedEvidence = evidenceFor(policy, 'clean')
    const tamperedManifest = structuredClone(capturedEvidence.inputManifest)
    tamperedManifest.testInputs.files[0].sha256 = '0'.repeat(64)
    expectFailure(() => buildSummary({
      policy, repositoryRoot: root, llvmDocument, llvmLCOV,
      ...capturedEvidence, inputManifest: tamperedManifest,
      testListing, testOutput: passingOutput,
    }), 'tampered pre-build input manifest')
    writeFileSync(join(root, UNIT_TEST_SOURCE_ROOT, 'Fixtures/input.json'), '{"fixture":false}\n')
    expectFailure(() => buildSummary({
      policy, repositoryRoot: root, llvmDocument, llvmLCOV,
      ...capturedEvidence, testListing, testOutput: passingOutput,
    }), 'test resource changed after pre-build capture')
    writeFileSync(join(root, UNIT_TEST_SOURCE_ROOT, 'Fixtures/input.json'), '{"fixture":true}\n')
    writeFileSync(join(root, TOOLING_FILES[1]), 'runner changed after capture\n')
    expectFailure(() => buildSummary({
      policy, repositoryRoot: root, llvmDocument, llvmLCOV,
      ...capturedEvidence, testListing, testOutput: passingOutput,
    }), 'coverage runner changed after pre-build capture')
    writeFileSync(join(root, TOOLING_FILES[1]), 'runner fixture\n')
    const invalidToolchain = structuredClone(toolchainDocument)
    invalidToolchain.architecture = '../arm64'
    expectFailure(() => buildSummary({
      policy, repositoryRoot: root, llvmDocument, llvmLCOV,
      ...evidenceFor(policy), toolchainDocument: invalidToolchain,
      testListing, testOutput: passingOutput,
    }), 'malformed toolchain evidence')
    const mismatchedXcodeToolchain = structuredClone(toolchainDocument)
    mismatchedXcodeToolchain.xcode.path = '/usr/bin/xcodebuild'
    expectFailure(() => buildSummary({
      policy, repositoryRoot: root, llvmDocument, llvmLCOV,
      ...evidenceFor(policy), toolchainDocument: mismatchedXcodeToolchain,
      testListing, testOutput: passingOutput,
    }), 'xcodebuild outside selected developer directory')
    expectFailure(() => buildSummary({
      policy, repositoryRoot: root, llvmDocument, llvmLCOV,
      ...evidenceFor(policy), postSourceRevision: 'f'.repeat(40),
      testListing, testOutput: passingOutput,
    }), 'HEAD changed during collection')
    expectFailure(() => buildSummary({
      policy, repositoryRoot: root, llvmDocument, llvmLCOV,
      ...evidenceFor(policy), postRepositoryStatusSHA256: 'f'.repeat(64),
      testListing, testOutput: passingOutput,
    }), 'repository status changed during collection')
    expectFailure(() => buildSummary({
      policy, policySHA256: '0'.repeat(64), repositoryRoot: root,
      llvmDocument, llvmLCOV, sourceRevision: 'short', repositoryState: 'clean',
      testListing, testOutput: passingOutput,
    }), 'short source revision')
    expectFailure(() => buildSummary({
      policy, policySHA256: '0'.repeat(64), repositoryRoot: root,
      llvmDocument, llvmLCOV, sourceRevision: 'A'.repeat(40), repositoryState: 'clean',
      testListing, testOutput: passingOutput,
    }), 'non-lowercase source revision')
    expectFailure(() => buildSummary({
      policy, policySHA256: '0'.repeat(64), repositoryRoot: root,
      llvmDocument, llvmLCOV, sourceRevision: '0123456789012345678901234567890123456789',
      repositoryState: 'modified', testListing, testOutput: passingOutput,
    }), 'invalid repository state')
    const traversalPolicy = structuredClone(policy)
    traversalPolicy.scope.generatedFiles = ['../Outside.generated.swift']
    expectFailure(() => validatePolicy(traversalPolicy), 'coverage scope traversal')
    const invalidPerFilePolicy = structuredClone(policy)
    invalidPerFilePolicy.gate.handwritten.perFileMinimumPercentBasisPoints.lines = 10_001
    expectFailure(() => validatePolicy(invalidPerFilePolicy), 'invalid per-file percentage policy')
    const invalidGeneratedPerFilePolicy = structuredClone(policy)
    invalidGeneratedPerFilePolicy.gate.generated.perFileMinimumPercentBasisPoints.regions = 0
    expectFailure(() => validatePolicy(invalidGeneratedPerFilePolicy),
      'invalid generated per-file percentage policy')
    const missingGeneratedPerFilePolicy = structuredClone(policy)
    delete missingGeneratedPerFilePolicy.gate.generated.perFileMinimumPercentBasisPoints
    expectFailure(() => validatePolicy(missingGeneratedPerFilePolicy),
      'missing generated per-file policy')
    const unknownGeneratedPerFileKeyPolicy = structuredClone(policy)
    unknownGeneratedPerFileKeyPolicy.gate.generated.perFileMinimumPercentBasisPoints.statements = 1
    expectFailure(() => validatePolicy(unknownGeneratedPerFileKeyPolicy),
      'unknown generated per-file metric')
    const missingCriticalFilesPolicy = structuredClone(policy)
    delete missingCriticalFilesPolicy.gate.criticalFiles
    expectFailure(() => validatePolicy(missingCriticalFilesPolicy),
      'missing critical-file policy')
    const unknownCriticalFilePolicy = structuredClone(policy)
    unknownCriticalFilePolicy.gate.criticalFiles[0].path =
      'Sources/QVACClient/Internal/Unknown.swift'
    expectFailure(() => buildSummary({
      policy: unknownCriticalFilePolicy, repositoryRoot: root, llvmDocument, llvmLCOV,
      ...evidenceFor(unknownCriticalFilePolicy, 'clean'), testListing, testOutput: passingOutput,
    }), 'unknown critical-file policy path')
    const generatedCriticalFilePolicy = structuredClone(policy)
    generatedCriticalFilePolicy.gate.criticalFiles[0].path =
      'Sources/QVACClient/Generated/API.generated.swift'
    expectFailure(() => validatePolicy(generatedCriticalFilePolicy),
      'generated source in handwritten critical-file policy')
    const unknownCriticalKeyPolicy = structuredClone(policy)
    unknownCriticalKeyPolicy.gate.criticalFiles[0].note = 'not permitted'
    expectFailure(() => validatePolicy(unknownCriticalKeyPolicy),
      'unknown critical-file policy key')
    const invalidGeneratedPolicy = structuredClone(policy)
    invalidGeneratedPolicy.gate.generated.lines.maximumUncovered = -1
    expectFailure(() => validatePolicy(invalidGeneratedPolicy), 'invalid generated aggregate policy')
    expectFailure(() => decodeUTF8(Buffer.from([0xc3, 0x28]), 'invalid fixture'), 'invalid UTF-8 evidence')
    symlinkSync(join(root, 'Sources'), join(root, 'LinkedSources'))
    expectFailure(() => resolveCanonicalRepositoryPath(root,
      'LinkedSources/QVACClient/Internal/Main.swift', 'symlinked source'), 'intermediate symlink traversal')
    const attestationDirectory = join(root, 'attestation')
    mkdirSync(attestationDirectory)
    for (const path of EVIDENCE_FILES) writeFileSync(join(attestationDirectory, path), `${path}\n`)
    writeFileSync(join(attestationDirectory, 'coverage-summary.json'), '{"gate":{"result":"pass"}}\n')
    const attestation = buildCompletionAttestation(attestationDirectory)
    verifyCompletionAttestation(attestationDirectory, attestation)
    writeFileSync(join(attestationDirectory, 'swift-test-list.txt'), 'tampered\n')
    expectFailure(() => verifyCompletionAttestation(attestationDirectory, attestation),
      'tampered attested evidence')
    process.stdout.write('[coverage-self-test] scope, inventory, execution, LCOV, per-file, critical-file, and anti-regression checks passed\n')
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
}

function main() {
  const { command, options } = parseArguments(process.argv.slice(2))
  if (command === 'self-test') {
    selfTest()
    return
  }
  if (command === 'policy-value') {
    const input = requireOptions(options, ['policy', 'key'])
    const { policy } = loadPolicy(input.policy)
    const allowed = {
      'test.module': policy.test.module,
      'test.product': policy.test.product,
      'test.inventoryPath': policy.test.inventoryPath,
    }
    assert(Object.hasOwn(allowed, input.key), `unsupported policy key: ${input.key}`)
    process.stdout.write(`${allowed[input.key]}\n`)
    return
  }
  if (command === 'capture-inputs') {
    const input = requireOptions(options, [
      'policy', 'repository-root', 'source-revision', 'repository-state', 'repository-status-sha256', 'output',
    ])
    const repositoryRoot = realpathSync(input['repository-root'])
    const { policy, sha256: policySHA256 } = loadPolicy(input.policy)
    const manifest = buildInputManifest({
      policy,
      policySHA256,
      repositoryRoot,
      sourceRevision: input['source-revision'],
      repositoryState: input['repository-state'],
      repositoryStatusSHA256: input['repository-status-sha256'],
    })
    atomicWrite(input.output, `${JSON.stringify(manifest, null, 2)}\n`)
    process.stdout.write(`[coverage] captured ${manifest.production.files.length} production and ${manifest.testInputs.files.length} test input digests\n`)
    return
  }
  if (command === 'capture-toolchain') {
    const input = requireOptions(options, [
      'architecture', 'developer-directory', 'swift-version', 'swift-path', 'xcode-version',
      'xcode-build-version', 'xcode-path', 'llvm-version', 'llvm-path', 'node-version',
      'node-path', 'bash-version', 'bash-path', 'output',
    ])
    const evidence = buildToolchainEvidence({
      architecture: input.architecture,
      developerDirectory: input['developer-directory'],
      swiftVersion: input['swift-version'],
      swiftPath: input['swift-path'],
      xcodeVersion: input['xcode-version'],
      xcodeBuildVersion: input['xcode-build-version'],
      xcodePath: input['xcode-path'],
      llvmVersion: input['llvm-version'],
      llvmPath: input['llvm-path'],
      nodeVersion: input['node-version'], nodePath: input['node-path'],
      bashVersion: input['bash-version'], bashPath: input['bash-path'],
    })
    atomicWrite(input.output, `${JSON.stringify(evidence, null, 2)}\n`)
    process.stdout.write('[coverage] captured structured toolchain evidence\n')
    return
  }
  if (command === 'attest') {
    const input = requireOptions(options, ['directory', 'output'])
    const directory = realpathSync(input.directory)
    assert(dirname(resolve(input.output)) === directory, 'completion attestation must be written inside evidence directory')
    const attestation = buildCompletionAttestation(directory)
    atomicWrite(input.output, `${JSON.stringify(attestation, null, 2)}\n`)
    process.stdout.write(`[coverage] attested ${attestation.artifacts.length} evidence artifacts\n`)
    return
  }
  if (command === 'verify-attestation') {
    const input = requireOptions(options, ['directory', 'attestation'])
    const directory = realpathSync(input.directory)
    verifyCompletionAttestation(directory,
      parseJSON(readRegularFile(input.attestation, 'completion attestation'), 'completion attestation'))
    process.stdout.write('[coverage] completion attestation matches all evidence artifacts\n')
    return
  }
  if (command === 'verify-inventory') {
    const input = requireOptions(options, ['policy', 'repository-root'])
    const repositoryRoot = realpathSync(input['repository-root'])
    const { policy } = loadPolicy(input.policy)
    const inventory = validateInventory(policy, repositoryRoot)
    process.stdout.write(`[coverage] reviewed inventory: ${inventory.identifiers.length} tests, sha256=${inventory.sha256}\n`)
    return
  }
  if (command === 'verify-discovery') {
    const input = requireOptions(options, ['policy', 'repository-root', 'listing'])
    const repositoryRoot = realpathSync(input['repository-root'])
    const { policy } = loadPolicy(input.policy)
    const inventory = validateInventory(policy, repositoryRoot)
    const listing = decodeUTF8(readRegularFile(input.listing, 'swift test listing'), 'swift test listing')
    const discovered = verifyDiscovery(listing, policy, inventory)
    process.stdout.write(`[coverage] discovery matched ${discovered.length} reviewed tests\n`)
    return
  }
  if (command === 'verify-execution') {
    const input = requireOptions(options, ['policy', 'repository-root', 'output'])
    const repositoryRoot = realpathSync(input['repository-root'])
    const { policy } = loadPolicy(input.policy)
    const inventory = validateInventory(policy, repositoryRoot)
    const output = decodeUTF8(readRegularFile(input.output, 'XCTest output'), 'XCTest output')
    verifyExecution(output, policy, inventory)
    process.stdout.write(`[coverage] execution matched ${inventory.identifiers.length} reviewed tests; zero skips/failures\n`)
    return
  }
  if (command === 'summarize') {
    const input = requireOptions(options, [
      'policy', 'repository-root', 'llvm-summary', 'llvm-lcov', 'test-listing', 'test-output', 'source-revision',
      'repository-state', 'repository-status-sha256', 'post-source-revision', 'post-repository-state',
      'post-repository-status-sha256', 'input-manifest', 'toolchain',
      'output-json', 'output-markdown', 'output-handwritten-lcov', 'output-all-source-lcov',
    ])
    const repositoryRoot = realpathSync(input['repository-root'])
    const { policy, sha256: policySHA256 } = loadPolicy(input.policy)
    const llvmDocument = parseJSON(readRegularFile(input['llvm-summary'], 'LLVM summary'), 'LLVM summary')
    const llvmLCOV = decodeUTF8(readRegularFile(input['llvm-lcov'], 'LLVM LCOV'), 'LLVM LCOV')
    const testListing = decodeUTF8(readRegularFile(input['test-listing'], 'swift test listing'), 'swift test listing')
    const testOutput = decodeUTF8(readRegularFile(input['test-output'], 'XCTest output'), 'XCTest output')
    const inputManifestBytes = readRegularFile(input['input-manifest'], 'pre-build input manifest')
    const toolchainBytes = readRegularFile(input.toolchain, 'toolchain evidence')
    const result = buildSummary({
      policy, policySHA256, repositoryRoot, llvmDocument, llvmLCOV,
      sourceRevision: input['source-revision'], repositoryState: input['repository-state'], testListing, testOutput,
      repositoryStatusSHA256: input['repository-status-sha256'],
      postSourceRevision: input['post-source-revision'], postRepositoryState: input['post-repository-state'],
      postRepositoryStatusSHA256: input['post-repository-status-sha256'],
      inputManifest: parseJSON(inputManifestBytes, 'pre-build input manifest'),
      inputManifestSHA256: sha256(inputManifestBytes),
      toolchainDocument: parseJSON(toolchainBytes, 'toolchain evidence'),
      toolchainSHA256: sha256(toolchainBytes),
    })
    atomicWrite(input['output-json'], `${JSON.stringify(result.summary, null, 2)}\n`)
    atomicWrite(input['output-markdown'], result.markdown)
    atomicWrite(input['output-handwritten-lcov'], result.handwrittenLCOV)
    atomicWrite(input['output-all-source-lcov'], result.allSourceLCOV)
    process.stdout.write(result.markdown)
    if (result.summary.gate.result !== 'pass') fail('production coverage is below the reviewed policy')
    return
  }
  fail(`unsupported command: ${command}`)
}

try {
  main()
} catch (error) {
  const message = error instanceof Error ? error.message : String(error)
  process.stderr.write(`[coverage] error: ${message}\n`)
  process.exitCode = 1
}
