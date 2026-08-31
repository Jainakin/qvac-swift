#!/usr/bin/env node

import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { spawnSync } from 'node:child_process'
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const scriptDir = dirname(fileURLToPath(import.meta.url))
const repositoryRoot = resolve(scriptDir, '..')
const analyzerPath = join(scriptDir, 'analyze.mjs')
const canonicalWorkloadPath = join(scriptDir, 'workload.json')
const canonicalWorkload = JSON.parse(readFileSync(canonicalWorkloadPath, 'utf8'))
const order = Array.from({ length: 10 }, (_, pair) =>
  pair % 2 === 0 ? ['swift', 'node'] : ['node', 'swift']).flat()
const root = mkdtempSync(join(tmpdir(), 'qvac-bench-analyzer-'))

function clone(value) {
  return JSON.parse(JSON.stringify(value))
}

function sha256(value) {
  return createHash('sha256').update(value).digest('hex')
}

function closeEnough(actual, expected, tolerance = 1e-12) {
  assert.ok(Math.abs(actual - expected) <= tolerance,
    `expected ${actual} to be within ${tolerance} of ${expected}`)
}

function warmupSample(mean = 10) {
  return {
    predict: 128,
    token_count: 128,
    stop_reason: 'length',
    generated_tokens: 128,
    emitted_tokens: 128,
    mean_token_interval_ms: mean,
    content_sha256: sha256('canonical warmup content'),
    raw_output_sha256: sha256('canonical warmup raw output'),
    content_matches_final: true,
    backend_device: 'gpu',
  }
}

function intervalsFor(client, pair, scenario) {
  if (scenario === 'boundary') {
    // 21 / 20 is exactly the contractual 1.05 decision boundary after each
    // per-process arithmetic mean is formed.
    return Array(999).fill(client === 'swift' ? 21 : 20)
  }
  if (scenario === 'inconclusive') {
    const ratio = pair < 5 ? 1.0 : 1.1
    return Array(999).fill(client === 'swift' ? ratio : 1)
  }
  if (scenario === 'p99-regression') {
    if (client === 'node') return Array(999).fill(1)
    return [...Array(979).fill(1), ...Array(20).fill(1.06)]
  }
  const ratio = scenario === 'fail' ? 1.06 : 1.04
  return Array(999).fill(client === 'swift' ? ratio : 1)
}

function sampleFor(client, pair, workloadSha256, scenario) {
  const intervals = intervalsFor(client, pair, scenario)
  // Synthetic process evidence must remain independently identifiable even
  // when a scenario deliberately gives several runs identical interval data.
  const arrivals = [50 + (pair * 0.01) + (client === 'swift' ? 0.001 : 0)]
  for (const interval of intervals) arrivals.push(arrivals.at(-1) + interval)
  const mean = intervals.reduce((sum, value) => sum + value, 0) / intervals.length
  return {
    schema_version: 1,
    status: 'sample',
    client,
    api_surface: client === 'swift'
      ? 'QVACClient.completion(...).events'
      : '@qvac/sdk completion(...).events',
    workload_sha256: workloadSha256,
    model_sha256: canonicalWorkload.model.sha256,
    warmups: [warmupSample(), warmupSample(10.1), warmupSample(10.2)],
    measurement: {
      predict: 1000,
      ttft_ms: arrivals[0],
      terminal_ms: arrivals.at(-1) + 1,
      token_arrival_offsets_ms: arrivals,
      token_intervals_ms: intervals,
      mean_token_interval_ms: mean,
      content_sha256: sha256('canonical measured content'),
      raw_output_sha256: sha256('canonical measured raw output'),
      content_matches_final: true,
      stop_reason: 'length',
      stats: {
        timeToFirstToken: 50,
        tokensPerSecond: 100,
        cacheTokens: 0,
        promptTokens: 25,
        generatedTokens: 1000,
        emittedTokens: 1000,
        avgConcurrentSeq: 1,
        backendDevice: 'gpu',
      },
    },
    timeout_policy: {
      model_load_ms: 180000,
      completion_idle_ms: 30000,
      process_watchdog_seconds: 240,
    },
    toolchain: {
      node: 'v22.22.0',
      bare: 'v1.31.0',
      swift: 'Apple Swift version 5.10 (swiftlang-5.10.0.13 clang-1500.3.9.4)',
      host: 'Darwin-23.6.0-arm64',
      sdk: '0.17.0',
      configuration: 'release',
    },
  }
}

function makeCase(name, {
  scenario = 'pass',
  mutateWorkload,
  mutateSamples,
} = {}) {
  const directory = join(root, name)
  mkdirSync(directory)
  const workload = clone(canonicalWorkload)
  mutateWorkload?.(workload)
  const workloadBytes = `${JSON.stringify(workload, null, 2)}\n`
  const workloadPath = join(directory, 'workload.json')
  writeFileSync(workloadPath, workloadBytes)
  const workloadSha256 = sha256(workloadBytes)
  const samples = order.map((client, index) =>
    sampleFor(client, Math.floor(index / 2), workloadSha256, scenario))
  mutateSamples?.(samples)
  const runPaths = samples.map((sample, index) => {
    const path = join(directory, `run-${String(index + 1).padStart(2, '0')}.json`)
    writeFileSync(path, `${JSON.stringify(sample, null, 2)}\n`)
    return path
  })
  return { directory, workloadPath, runPaths }
}

function runAnalyzer(testCase, outputName = 'result.json', paths = testCase.runPaths) {
  const outputPath = join(testCase.directory, outputName)
  const child = spawnSync(
    process.execPath,
    [analyzerPath, outputPath, testCase.workloadPath, ...paths],
    { cwd: repositoryRoot, encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 },
  )
  let report
  try {
    report = JSON.parse(readFileSync(outputPath, 'utf8'))
  } catch (error) {
    assert.fail(`analyzer did not produce readable evidence: ${error}\n${child.stderr}`)
  }
  return { process: child, report, outputPath }
}

function assertInvalid(result, reasonPattern) {
  assert.equal(result.process.status, 3, result.process.stderr || result.process.stdout)
  assert.equal(result.report.schema_version, 4)
  assert.equal(result.report.status, 'invalid')
  assert.match(result.report.reason, reasonPattern)
  assert.match(result.process.stderr, /\[bench\] invalid:/)
}

try {
  const passCase = makeCase('pass')
  const pass = runAnalyzer(passCase)
  assert.equal(pass.process.status, 0, pass.process.stderr || pass.process.stdout)
  assert.equal(pass.report.schema_version, 4)
  assert.equal(pass.report.status, 'pass')
  assert.equal(pass.report.maximum_overhead_ratio, 1.05)
  assert.equal(pass.report.process_pairs, 10)
  assert.equal(pass.report.process_order, order.join('/'))
  assert.equal(pass.report.ordered_process_runs.length, 20)
  assert.equal(pass.report.ordered_input_sha256.length, 20)
  assert.equal(pass.report.statistical_method.bootstrap_iterations, 20000)
  assert.equal(pass.report.statistical_method.exclusions, 'none')
  assert.equal(pass.report.warmup_policy.stop_at_first_convergence, true)
  assert.equal(pass.report.metrics.mean_token_interval.status, 'pass')
  assert.equal(pass.report.metrics.p99_token_interval.status, 'pass')
  closeEnough(pass.report.metrics.mean_token_interval.ratio, 1.04)
  closeEnough(pass.report.metrics.p99_token_interval.ratio, 1.04)

  const fail = runAnalyzer(makeCase('fail', { scenario: 'fail' }))
  assert.equal(fail.process.status, 1, fail.process.stderr || fail.process.stdout)
  assert.equal(fail.report.status, 'fail')
  assert.equal(fail.report.metrics.mean_token_interval.status, 'fail')
  assert.equal(fail.report.metrics.p99_token_interval.status, 'fail')

  const boundary = runAnalyzer(makeCase('strict-boundary', { scenario: 'boundary' }))
  assert.equal(boundary.process.status, 1, boundary.process.stderr || boundary.process.stdout)
  assert.equal(boundary.report.status, 'fail')
  assert.equal(boundary.report.metrics.mean_token_interval.status, 'fail')
  assert.equal(boundary.report.metrics.p99_token_interval.status, 'fail')
  closeEnough(boundary.report.metrics.mean_token_interval.ratio_ci95[0], 1.05)
  closeEnough(boundary.report.metrics.mean_token_interval.ratio_ci95[1], 1.05)

  const inconclusive = runAnalyzer(makeCase('inconclusive', { scenario: 'inconclusive' }))
  assert.equal(inconclusive.process.status, 2,
    inconclusive.process.stderr || inconclusive.process.stdout)
  assert.equal(inconclusive.report.status, 'inconclusive')
  assert.ok(inconclusive.report.metrics.mean_token_interval.ratio_ci95[0] <= 1.05)
  assert.ok(inconclusive.report.metrics.mean_token_interval.ratio_ci95[1] > 1.05)

  const tailFailure = runAnalyzer(makeCase('p99-regression', { scenario: 'p99-regression' }))
  assert.equal(tailFailure.process.status, 1,
    tailFailure.process.stderr || tailFailure.process.stdout)
  assert.equal(tailFailure.report.status, 'fail')
  assert.equal(tailFailure.report.metrics.mean_token_interval.status, 'pass')
  assert.equal(tailFailure.report.metrics.p99_token_interval.status, 'fail')
  assert.ok(tailFailure.report.metrics.mean_token_interval.ratio < 1.01)
  closeEnough(tailFailure.report.metrics.p99_token_interval.ratio, 1.06)

  const deterministicA = runAnalyzer(passCase, 'deterministic-a.json')
  const deterministicB = runAnalyzer(passCase, 'deterministic-b.json')
  assert.equal(deterministicA.process.status, 0)
  assert.equal(deterministicB.process.status, 0)
  assert.equal(
    readFileSync(deterministicA.outputPath, 'utf8'),
    readFileSync(deterministicB.outputPath, 'utf8'),
    'fixed-seed analysis was not byte deterministic',
  )

  const orderCase = makeCase('order')
  const wrongOrder = [...orderCase.runPaths]
  ;[wrongOrder[0], wrongOrder[1]] = [wrongOrder[1], wrongOrder[0]]
  assertInvalid(runAnalyzer(orderCase, 'result.json', wrongOrder), /process order/)

  assertInvalid(runAnalyzer(makeCase('provenance', {
    mutateSamples: samples => { samples[0].model_sha256 = '0'.repeat(64) },
  })), /model_sha256/)

  assertInvalid(runAnalyzer(makeCase('output-mismatch', {
    mutateSamples: samples => {
      samples[19].measurement.raw_output_sha256 = sha256('different measured output')
    },
  })), /different deterministic measured output/)

  const duplicateInputCase = makeCase('duplicate-input')
  const duplicateInputPaths = [...duplicateInputCase.runPaths]
  const duplicatedSwiftBytes = readFileSync(duplicateInputPaths[0])
  writeFileSync(duplicateInputPaths[2], duplicatedSwiftBytes)
  assertInvalid(runAnalyzer(duplicateInputCase, 'result.json', duplicateInputPaths),
    /unique independently recorded bytes/)

  assertInvalid(runAnalyzer(makeCase('toolchain', {
    mutateSamples: samples => { samples[3].toolchain.node = 'v22.21.0' },
  })), /toolchain\.node/)

  assertInvalid(runAnalyzer(makeCase('timeouts', {
    mutateSamples: samples => { samples[4].timeout_policy.completion_idle_ms += 1 },
  })), /timeout_policy\.completion_idle_ms/)

  assertInvalid(runAnalyzer(makeCase('count', {
    mutateSamples: samples => { samples[5].measurement.token_intervals_ms.pop() },
  })), /must contain exactly 999 values/)

  assertInvalid(runAnalyzer(makeCase('nonfinite', {
    mutateSamples: samples => { samples[6].measurement.token_intervals_ms[10] = null },
  })), /must be finite/)

  assertInvalid(runAnalyzer(makeCase('warmup-convergence', {
    mutateSamples: samples => {
      samples[7].warmups[2].mean_token_interval_ms = 10.3
    },
  })), /warmups did not converge/)

  assertInvalid(runAnalyzer(makeCase('warmup-count-proof', {
    mutateSamples: samples => { samples[8].warmups[0].generated_tokens = 127 },
  })), /generated_tokens/)

  assertInvalid(runAnalyzer(makeCase('post-convergence-warmup', {
    mutateSamples: samples => { samples[9].warmups.push(warmupSample()) },
  })), /continued after first convergence/)

  assertInvalid(runAnalyzer(makeCase('threshold-override', {
    mutateWorkload: workload => { workload.measurement.maximum_overhead_ratio = 1.051 },
  })), /maximum_overhead_ratio/)

  assertInvalid(runAnalyzer(makeCase('recorded-mean-mismatch', {
    mutateSamples: samples => { samples[10].measurement.mean_token_interval_ms += 0.01 },
  })), /does not match the complete interval sample/)

  const atomicInvalidCase = makeCase('atomic-invalid', {
    mutateSamples: samples => { samples[0].warmups[0].token_count = 127 },
  })
  const staleOutput = join(atomicInvalidCase.directory, 'result.json')
  writeFileSync(staleOutput, '{"schema_version":4,"status":"pass"}\n')
  const atomicInvalid = runAnalyzer(atomicInvalidCase)
  assertInvalid(atomicInvalid, /token_count/)
  assert.equal(readdirSync(atomicInvalidCase.directory)
    .filter(name => name.startsWith('result.json.tmp-')).length, 0,
  'atomic evidence write left a temporary file behind')

  console.log(
    '[bench-test] schema-4 pass/fail/inconclusive, strict 5% boundary, co-primary tail gate, deterministic paired bootstrap, atomic invalid evidence, and strict provenance guards passed',
  )
} finally {
  rmSync(root, { recursive: true, force: true })
}
