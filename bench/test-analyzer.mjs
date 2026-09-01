#!/usr/bin/env node

import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { execFileSync, spawnSync } from 'node:child_process'
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
const orchestratorSource = readFileSync(join(scriptDir, 'run.sh'), 'utf8')
const nodeHarnessSource = readFileSync(
  join(scriptDir, 'js', 'streaming-completion-bench.mjs'), 'utf8')
const swiftHarnessSource = readFileSync(
  join(repositoryRoot, 'Tests', 'QVACClientIntegrationTests', 'BenchmarkTests.swift'), 'utf8')
const order = Array.from({ length: 10 }, (_, pair) =>
  pair % 2 === 0 ? ['swift', 'node'] : ['node', 'swift']).flat()
const root = mkdtempSync(join(tmpdir(), 'qvac-bench-analyzer-'))
const sourceCommit = execFileSync('git', ['rev-parse', 'HEAD'], {
  cwd: repositoryRoot,
  encoding: 'utf8',
}).trim()
assert.match(sourceCommit, /^[0-9a-f]{40}$/)

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

function geometricMean(values) {
  return Math.exp(values.reduce((sum, value) => sum + Math.log(value), 0) / values.length)
}

function expectedIntactBlockInterval(blockValues) {
  let state = 0x517a9e31 >>> 0
  const randomIndex = length => {
    state ^= state << 13
    state ^= state >>> 17
    state ^= state << 5
    return (state >>> 0) % length
  }
  const distribution = []
  for (let iteration = 0; iteration < 20_000; iteration++) {
    const selected = Array.from(
      { length: 5 },
      () => blockValues[randomIndex(blockValues.length)],
    )
    distribution.push(geometricMean(selected))
  }
  distribution.sort((a, b) => a - b)
  return [distribution[Math.ceil(distribution.length * 0.025) - 1],
    distribution[Math.ceil(distribution.length * 0.975) - 1]]
}

const contentSHA256 = sha256('canonical measured content')
const rawOutputSHA256 = sha256('canonical measured raw output')

function preconditioningSample(mean = 10) {
  return {
    predict: 1000,
    token_count: 1000,
    stop_reason: 'length',
    generated_tokens: 1000,
    emitted_tokens: 1000,
    mean_token_interval_ms: mean,
    content_sha256: contentSHA256,
    raw_output_sha256: rawOutputSHA256,
    content_matches_final: true,
    backend_device: 'gpu',
  }
}

function measurementDefinition(client, pair, scenario, measurementIndex) {
  let tokensPerSecond = 1000
  if (scenario === 'boundary') {
    // Raw public latency is equal. Only the server-normalized factor reaches
    // the exact contractual boundary: 1 / (1000 / 1050) == 1.05.
    tokensPerSecond = client === 'swift' ? 1050 : 1000
    return { intervals: Array(999).fill(1), tokensPerSecond }
  }
  if (scenario === 'normalized-factor-fail') {
    tokensPerSecond = client === 'swift' ? 1060 : 1000
    return { intervals: Array(999).fill(1), tokensPerSecond }
  }
  if (scenario === 'inconclusive') {
    const ratio = pair < 5 ? 1.0 : 1.1
    return { intervals: Array(999).fill(client === 'swift' ? ratio : 1), tokensPerSecond }
  }
  if (scenario === 'p99-regression') {
    const intervals = client === 'node'
      ? Array(999).fill(1)
      : [...Array(979).fill(1), ...Array(20).fill(1.06)]
    return { intervals, tokensPerSecond }
  }
  if (scenario === 'one-measurement-regression') {
    const ratio = client === 'swift' && measurementIndex === 2 ? 1.12 : 1
    return { intervals: Array(999).fill(ratio), tokensPerSecond }
  }
  if (scenario === 'strong-order-effect') {
    const ratio = pair % 2 === 0 ? 0.8 : 1.2
    return { intervals: Array(999).fill(client === 'swift' ? ratio : 1), tokensPerSecond }
  }
  if (scenario === 'backend-throughput-variation') {
    tokensPerSecond = client === 'swift' ? 167 : 115
    const factor = 1.02
    return { intervals: Array(999).fill(factor * 1000 / tokensPerSecond), tokensPerSecond }
  }
  if (scenario === 'raw-mean-diagnostic-regression') {
    if (client === 'node') return { intervals: Array(999).fill(1), tokensPerSecond }
    const intervals = [...Array(998).fill(1), 300.7]
    tokensPerSecond = 1000 / 1.3
    return { intervals, tokensPerSecond }
  }
  if (scenario === 'strong-shared-block-effect') {
    const blockEffects = [0.70, 0.85, 1.00, 1.15, 1.30]
    const ratio = blockEffects[Math.floor(pair / 2)]
    return { intervals: Array(999).fill(client === 'swift' ? ratio : 1), tokensPerSecond }
  }
  const ratio = scenario === 'fail' ? 1.06 : 1.04
  return { intervals: Array(999).fill(client === 'swift' ? ratio : 1), tokensPerSecond }
}

function measurementFor(client, pair, scenario, measurementIndex) {
  const { intervals, tokensPerSecond } = measurementDefinition(
    client,
    pair,
    scenario,
    measurementIndex,
  )
  // Synthetic process evidence must remain independently identifiable even
  // when a scenario deliberately gives several runs identical interval data.
  const arrivals = [
    50 + (pair * 0.01) + (client === 'swift' ? 0.001 : 0) + (measurementIndex * 0.0001),
  ]
  for (const interval of intervals) arrivals.push(arrivals.at(-1) + interval)
  const mean = intervals.reduce((sum, value) => sum + value, 0) / intervals.length
  return {
    predict: 1000,
    ttft_ms: arrivals[0],
    terminal_ms: arrivals.at(-1) + 1,
    token_arrival_offsets_ms: arrivals,
    token_intervals_ms: intervals,
    mean_token_interval_ms: mean,
    content_sha256: contentSHA256,
    raw_output_sha256: rawOutputSHA256,
    content_matches_final: true,
    stop_reason: 'length',
    stats: {
      timeToFirstToken: 50,
      tokensPerSecond,
      cacheTokens: 0,
      promptTokens: 25,
      generatedTokens: 1000,
      emittedTokens: 1000,
      avgConcurrentSeq: 1,
      backendDevice: 'gpu',
    },
  }
}

function sampleFor(client, positionIndex, workloadSha256, scenario) {
  const pair = Math.floor(positionIndex / 2)
  return {
    schema_version: 2,
    status: 'sample',
    client,
    api_surface: client === 'swift'
      ? 'QVACClient.completion(...).events'
      : '@qvac/sdk completion(...).events',
    workload_sha256: workloadSha256,
    model_sha256: canonicalWorkload.model.sha256,
    source_commit: sourceCommit,
    orchestration: {
      position: String(positionIndex + 1).padStart(2, '0'),
      pair: String(pair + 1).padStart(2, '0'),
      pair_order: pair % 2 === 0 ? 'swift/node' : 'node/swift',
    },
    // These intentionally differ by far more than 2.5%. Fixed work is valid;
    // no timing observation is allowed to select or discard later evidence.
    preconditioning: [preconditioningSample(10.425), preconditioningSample(8.862)],
    measurements: Array.from(
      { length: 3 },
      (_, measurementIndex) => measurementFor(client, pair, scenario, measurementIndex),
    ),
    timeout_policy: {
      model_load_ms: 180000,
      completion_rpc_timeout: 'none',
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
    sampleFor(client, index, workloadSha256, scenario))
  mutateSamples?.(samples)
  const runPaths = samples.map((sample, index) => {
    const path = join(directory, `run-${String(index + 1).padStart(2, '0')}.json`)
    writeFileSync(path, `${JSON.stringify(sample, null, 2)}\n`)
    return path
  })
  return { directory, workloadPath, runPaths }
}

function pathsInPairOrder(testCase, pairOrders) {
  const swift = testCase.runPaths.filter((_, index) => order[index] === 'swift')
  const node = testCase.runPaths.filter((_, index) => order[index] === 'node')
  let swiftIndex = 0
  let nodeIndex = 0
  return pairOrders.flatMap(pairOrder => pairOrder === 'swift/node'
    ? [swift[swiftIndex++], node[nodeIndex++]]
    : [node[nodeIndex++], swift[swiftIndex++]])
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
  assert.equal(result.report.schema_version, 6)
  assert.equal(result.report.status, 'invalid')
  assert.match(result.report.reason, reasonPattern)
  assert.match(result.process.stderr, /\[bench\] invalid:/)
}

try {
  const sourceTreeChecks = [...orchestratorSource.matchAll(/^verify_source_tree$/gm)]
  assert.equal(sourceTreeChecks.length, 3,
    'orchestrator must verify source provenance before setup, before analysis, and after analysis')
  assert.ok(sourceTreeChecks[2].index > orchestratorSource.indexOf('ANALYSIS_STATUS=$?'),
    'orchestrator post-analysis provenance check is not after analyzer execution')
  assert.match(orchestratorSource,
    /STAGED_RELATIVE="tools\/runtime\/_qvac_streaming_completion_bench\.mjs"/,
    'orchestrator must name exactly one resolver-local staged harness')
  assert.match(orchestratorSource,
    /if \[\[ "\$\{STAGED_CREATED:-0\}" == "1" \]\]; then[\s\S]*cmp -s "\$STAGED_SOURCE" "\$STAGED"/,
    'owned staged harness must be byte-validated independently of Git ignore rules')
  assert.match(orchestratorSource,
    /"\$\{STAGED_CREATED:-0\}" == "1" \]\][\s\\]*\|\| fail "unowned runtime benchmark stage is present"/,
    'the sole untracked staged-path exception must require invocation ownership')
  assert.match(orchestratorSource,
    /WORKER_SCRIPT="\$NODE_MODULES\/@qvac\/sdk\/dist\/server\/worker\.js"[\s\S]*! -f "\$WORKER_SCRIPT" \|\| -L "\$WORKER_SCRIPT"/,
    'orchestrator must validate the exact packaged QVAC worker')
  assert.match(orchestratorSource,
    /"QVAC_WORKER_PATH=\$WORKER_SCRIPT"/,
    'every process must pin the packaged QVAC worker instead of ambient resolution')
  assert.equal(
    [...orchestratorSource.matchAll(/env -u QVAC_CONFIG_PATH -u QVAC_IPC_SOCKET_PATH -u QVAC_HYPERSWARM_SEED/g)].length,
    2,
    'Swift and Node benchmark processes must both clear ambient QVAC overrides',
  )
  assert.match(orchestratorSource,
    /workload\.schema_version !== 3/,
    'orchestrator must require workload schema 3')
  assert.match(orchestratorSource,
    /normalized_mean_factor_formula[\s\S]*mean_token_interval_ms \/ \(1000 \/ stats\.tokensPerSecond\)/,
    'orchestrator must pin the server-normalized mean formula')
  assert.match(orchestratorSource,
    /normalized_mean_process_aggregation[\s\S]*arithmetic_mean\(exactly_3_completion_factors\)/,
    'orchestrator must pin the three-completion aggregation')
  const nodeCompletionBody = nodeHarnessSource.slice(
    nodeHarnessSource.indexOf('async function runCompletion('),
    nodeHarnessSource.indexOf('\nconst modelStat =', nodeHarnessSource.indexOf('async function runCompletion(')),
  )
  const swiftCompletionBody = swiftHarnessSource.slice(
    swiftHarnessSource.indexOf('    private static func runCompletion('),
    swiftHarnessSource.indexOf('    private static func validate(',
      swiftHarnessSource.indexOf('    private static func runCompletion(')),
  )
  assert.match(canonicalWorkload.timeouts.completion_rpc_timeout, /^none$/,
    'canonical workload must disable the completion RPC timeout symmetrically')
  assert.ok(nodeCompletionBody.includes('const run = completion({')
      && !nodeCompletionBody.includes('rpcOptions'),
  'Node measured completion must rely solely on the common process watchdog')
  assert.ok(swiftCompletionBody.includes('let run = try await client.completion(')
      && /rpcOptions: \.init\(timeout: nil\)/.test(swiftCompletionBody)
      && [...swiftCompletionBody.matchAll(/rpcOptions:/g)].length === 1,
  'Swift measured completion must explicitly disable its production deadline and rely solely on the common process watchdog')
  assert.equal(canonicalWorkload.schema_version, 3)
  assert.equal(
    canonicalWorkload.measurement.normalized_mean_factor_formula,
    'mean_token_interval_ms / (1000 / stats.tokensPerSecond)',
  )
  assert.equal(
    canonicalWorkload.measurement.normalized_mean_process_aggregation,
    'arithmetic_mean(exactly_3_completion_factors)',
  )
  assert.match(nodeCompletionBody,
    /Number\.isFinite\(final\.stats\?\.tokensPerSecond\)[\s\S]*final\.stats\.tokensPerSecond > 0/,
  'Node harness must reject missing, non-finite, and non-positive worker throughput')
  assert.match(swiftCompletionBody,
    /let tokensPerSecond = stats\.tokensPerSecond,[\s\S]*tokensPerSecond\.isFinite,[\s\S]*tokensPerSecond > 0/,
  'Swift harness must reject missing, non-finite, and non-positive worker throughput')

  const passCase = makeCase('pass')
  const pass = runAnalyzer(passCase)
  assert.equal(pass.process.status, 0, pass.process.stderr || pass.process.stdout)
  assert.equal(pass.report.schema_version, 6)
  assert.equal(pass.report.status, 'pass')
  assert.equal(pass.report.maximum_overhead_ratio, 1.05)
  assert.equal(pass.report.source_commit, sourceCommit)
  assert.equal(pass.report.process_blocks, 5)
  assert.equal(pass.report.process_pairs, 10)
  assert.equal(pass.report.process_order, order.join('/'))
  assert.equal(pass.report.ordered_process_runs.length, 20)
  assert.equal(pass.report.ordered_input_sha256.length, 20)
  assert.equal(pass.report.statistical_method.bootstrap_iterations, 20000)
  assert.equal(pass.report.statistical_method.exclusions, 'none')
  assert.equal(pass.report.statistical_method.retries, 0)
  assert.equal(pass.report.statistical_method.measured_completions_per_process, 3)
  assert.equal(pass.report.statistical_method.intervals_per_process, 2997)
  assert.equal(pass.report.statistical_method.bootstrap_block_count, 5)
  assert.equal(pass.report.statistical_method.pairs_per_bootstrap_block, 2)
  assert.deepEqual(pass.report.statistical_method.designed_pair_order_counts, {
    'swift/node': 5,
    'node/swift': 5,
  })
  assert.equal(pass.report.preconditioning_policy.fixed_count, 2)
  assert.equal(pass.report.preconditioning_policy.tokens_per_completion, 1000)
  assert.equal(pass.report.preconditioning_policy.timing_used_for_selection, false)
  assert.equal(pass.report.measurement_policy.fixed_completions_per_process, 3)
  assert.equal(pass.report.measurement_policy.all_completed_measurements_included, true)
  assert.ok(pass.report.ordered_process_runs.every(run =>
    run.preconditioning.length === 2 && run.measurements.length === 3))
  assert.ok(pass.report.pairs.every(pair =>
    pair.swift.token_interval_count === 2997 && pair.node.token_interval_count === 2997))
  assert.equal(pass.report.metrics.normalized_mean_overhead_factor.status, 'pass')
  assert.equal(pass.report.metrics.p99_token_interval.status, 'pass')
  closeEnough(pass.report.metrics.normalized_mean_overhead_factor.ratio, 1.04)
  closeEnough(pass.report.metrics.raw_mean_token_interval_diagnostic.ratio, 1.04)
  closeEnough(pass.report.metrics.p99_token_interval.ratio, 1.04)

  const fail = runAnalyzer(makeCase('fail', { scenario: 'fail' }))
  assert.equal(fail.process.status, 1, fail.process.stderr || fail.process.stdout)
  assert.equal(fail.report.status, 'fail')
  assert.equal(fail.report.metrics.normalized_mean_overhead_factor.status, 'fail')
  assert.equal(fail.report.metrics.p99_token_interval.status, 'fail')

  const boundary = runAnalyzer(makeCase('strict-boundary', { scenario: 'boundary' }))
  assert.equal(boundary.process.status, 1, boundary.process.stderr || boundary.process.stdout)
  assert.equal(boundary.report.status, 'fail')
  assert.equal(boundary.report.metrics.normalized_mean_overhead_factor.status, 'fail')
  assert.equal(boundary.report.metrics.p99_token_interval.status, 'pass')
  closeEnough(boundary.report.metrics.normalized_mean_overhead_factor.ratio_ci95[0], 1.05)
  closeEnough(boundary.report.metrics.normalized_mean_overhead_factor.ratio_ci95[1], 1.05)

  const normalizedFailure = runAnalyzer(makeCase('normalized-factor-fail', {
    scenario: 'normalized-factor-fail',
  }))
  assert.equal(normalizedFailure.process.status, 1,
    normalizedFailure.process.stderr || normalizedFailure.process.stdout)
  assert.equal(normalizedFailure.report.status, 'fail')
  closeEnough(normalizedFailure.report.metrics.normalized_mean_overhead_factor.ratio, 1.06)
  assert.equal(normalizedFailure.report.metrics.normalized_mean_overhead_factor.status, 'fail')
  assert.equal(normalizedFailure.report.metrics.p99_token_interval.status, 'pass')

  const inconclusive = runAnalyzer(makeCase('inconclusive', { scenario: 'inconclusive' }))
  assert.equal(inconclusive.process.status, 2,
    inconclusive.process.stderr || inconclusive.process.stdout)
  assert.equal(inconclusive.report.status, 'inconclusive')
  assert.ok(inconclusive.report.metrics.normalized_mean_overhead_factor.ratio_ci95[0] <= 1.05)
  assert.ok(inconclusive.report.metrics.normalized_mean_overhead_factor.ratio_ci95[1] > 1.05)

  const strongOrderEffect = runAnalyzer(makeCase('strong-order-effect', {
    scenario: 'strong-order-effect',
  }))
  assert.equal(strongOrderEffect.process.status, 0,
    strongOrderEffect.process.stderr || strongOrderEffect.process.stdout)
  const balancedOrderRatio = Math.sqrt(0.8 * 1.2)
  closeEnough(strongOrderEffect.report.metrics.normalized_mean_overhead_factor.ratio,
    balancedOrderRatio)
  closeEnough(strongOrderEffect.report.metrics.normalized_mean_overhead_factor.ratio_ci95[0],
    balancedOrderRatio)
  closeEnough(strongOrderEffect.report.metrics.normalized_mean_overhead_factor.ratio_ci95[1],
    balancedOrderRatio)

  const tailFailure = runAnalyzer(makeCase('p99-regression', { scenario: 'p99-regression' }))
  assert.equal(tailFailure.process.status, 1,
    tailFailure.process.stderr || tailFailure.process.stdout)
  assert.equal(tailFailure.report.status, 'fail')
  assert.equal(tailFailure.report.metrics.normalized_mean_overhead_factor.status, 'pass')
  assert.equal(tailFailure.report.metrics.p99_token_interval.status, 'fail')
  assert.ok(tailFailure.report.metrics.normalized_mean_overhead_factor.ratio < 1.01)
  closeEnough(tailFailure.report.metrics.p99_token_interval.ratio, 1.06)

  const retainedRegression = runAnalyzer(makeCase('one-measurement-regression', {
    scenario: 'one-measurement-regression',
  }))
  assert.equal(retainedRegression.process.status, 1,
    retainedRegression.process.stderr || retainedRegression.process.stdout)
  assert.equal(retainedRegression.report.status, 'fail')
  closeEnough(retainedRegression.report.metrics.normalized_mean_overhead_factor.ratio, 1.04)
  closeEnough(retainedRegression.report.metrics.p99_token_interval.ratio, 1.12)

  const backendVariation = runAnalyzer(makeCase('backend-throughput-variation', {
    scenario: 'backend-throughput-variation',
  }))
  assert.equal(backendVariation.process.status, 0,
    backendVariation.process.stderr || backendVariation.process.stdout)
  assert.equal(backendVariation.report.status, 'pass')
  closeEnough(backendVariation.report.metrics.normalized_mean_overhead_factor.ratio, 1)
  closeEnough(backendVariation.report.metrics.worker_tokens_per_second_diagnostic.ratio,
    167 / 115)
  closeEnough(backendVariation.report.metrics.raw_mean_token_interval_diagnostic.ratio,
    115 / 167)
  assert.equal(backendVariation.report.metrics.p99_token_interval.status, 'pass')
  assert.ok(backendVariation.report.ordered_process_runs.some(run =>
    run.measurements.some(measurement => measurement.stats.tokensPerSecond === 115)))
  assert.ok(backendVariation.report.ordered_process_runs.some(run =>
    run.measurements.some(measurement => measurement.stats.tokensPerSecond === 167)))

  const rawMeanDiagnostic = runAnalyzer(makeCase('raw-mean-diagnostic-regression', {
    scenario: 'raw-mean-diagnostic-regression',
  }))
  assert.equal(rawMeanDiagnostic.process.status, 0,
    rawMeanDiagnostic.process.stderr || rawMeanDiagnostic.process.stdout)
  assert.equal(rawMeanDiagnostic.report.status, 'pass')
  closeEnough(rawMeanDiagnostic.report.metrics.normalized_mean_overhead_factor.ratio, 1)
  closeEnough(rawMeanDiagnostic.report.metrics.raw_mean_token_interval_diagnostic.ratio, 1.3)
  closeEnough(rawMeanDiagnostic.report.metrics.p99_token_interval.ratio, 1)

  const sharedBlockEffects = [0.70, 0.85, 1.00, 1.15, 1.30]
  const sharedBlock = runAnalyzer(makeCase('strong-shared-block-effect', {
    scenario: 'strong-shared-block-effect',
  }))
  assert.equal(sharedBlock.process.status, 2,
    sharedBlock.process.stderr || sharedBlock.process.stdout)
  const expectedBlockCI = expectedIntactBlockInterval(sharedBlockEffects)
  closeEnough(sharedBlock.report.metrics.normalized_mean_overhead_factor.ratio_ci95[0],
    expectedBlockCI[0])
  closeEnough(sharedBlock.report.metrics.normalized_mean_overhead_factor.ratio_ci95[1],
    expectedBlockCI[1])
  closeEnough(sharedBlock.report.metrics.p99_token_interval.ratio_ci95[0], expectedBlockCI[0])
  closeEnough(sharedBlock.report.metrics.p99_token_interval.ratio_ci95[1], expectedBlockCI[1])

  const deterministicA = runAnalyzer(passCase, 'deterministic-a.json')
  const deterministicB = runAnalyzer(passCase, 'deterministic-b.json')
  assert.equal(deterministicA.process.status, 0)
  assert.equal(deterministicB.process.status, 0)
  assert.equal(
    readFileSync(deterministicA.outputPath, 'utf8'),
    readFileSync(deterministicB.outputPath, 'utf8'),
    'fixed-seed analysis was not byte deterministic',
  )

  const noisyPreconditioning = runAnalyzer(makeCase('fixed-noisy-preconditioning', {
    mutateSamples: samples => {
      for (const sample of samples) {
        sample.preconditioning = [
          preconditioningSample(5.576),
          preconditioningSample(10.557),
        ]
      }
    },
  }))
  assert.equal(noisyPreconditioning.process.status, 0,
    noisyPreconditioning.process.stderr || noisyPreconditioning.process.stdout)
  assert.equal(noisyPreconditioning.report.status, 'pass')

  const allocationCase = makeCase('order-allocation')
  const wrongAllocation = [...allocationCase.runPaths]
  ;[wrongAllocation[0], wrongAllocation[1]] = [wrongAllocation[1], wrongAllocation[0]]
  assertInvalid(runAnalyzer(allocationCase, 'result.json', wrongAllocation),
    /requires exactly 5 swift\/node pairs/)

  const orderCase = makeCase('order-sequence')
  const wrongOrder = pathsInPairOrder(orderCase, [
    ...Array(5).fill('swift/node'),
    ...Array(5).fill('node/swift'),
  ])
  assertInvalid(runAnalyzer(orderCase, 'result.json', wrongOrder), /process order/)

  const replayCase = makeCase('same-client-position-replay')
  const replayedPaths = [...replayCase.runPaths]
  ;[replayedPaths[0], replayedPaths[3]] = [replayedPaths[3], replayedPaths[0]]
  assertInvalid(runAnalyzer(replayCase, 'result.json', replayedPaths),
    /orchestration\.position/)

  assertInvalid(runAnalyzer(makeCase('source-commit-tampering', {
    mutateSamples: samples => { samples[0].source_commit = '0'.repeat(40) },
  })), /source_commit/)

  assertInvalid(runAnalyzer(makeCase('orchestration-tampering', {
    mutateSamples: samples => { samples[4].orchestration.pair = '10' },
  })), /orchestration\.pair/)

  assertInvalid(runAnalyzer(makeCase('provenance', {
    mutateSamples: samples => { samples[0].model_sha256 = '0'.repeat(64) },
  })), /model_sha256/)

  assertInvalid(runAnalyzer(makeCase('output-mismatch', {
    mutateSamples: samples => {
      samples[19].measurements[2].raw_output_sha256 = sha256('different measured output')
    },
  })), /measurements produced different deterministic output/)

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
    mutateSamples: samples => { samples[4].timeout_policy.completion_rpc_timeout = '30s' },
  })), /timeout_policy\.completion_rpc_timeout/)

  assertInvalid(runAnalyzer(makeCase('count', {
    mutateSamples: samples => { samples[5].measurements[1].token_intervals_ms.pop() },
  })), /must contain exactly 999 values/)

  assertInvalid(runAnalyzer(makeCase('nonfinite', {
    mutateSamples: samples => { samples[6].measurements[2].token_intervals_ms[10] = null },
  })), /must be finite/)

  assertInvalid(runAnalyzer(makeCase('missing-worker-tps', {
    mutateSamples: samples => { delete samples[6].measurements[2].stats.tokensPerSecond },
  })), /measurement 3\.stats keys must be exactly/)

  assertInvalid(runAnalyzer(makeCase('zero-worker-tps', {
    mutateSamples: samples => { samples[6].measurements[2].stats.tokensPerSecond = 0 },
  })), /tokensPerSecond must be positive/)

  assertInvalid(runAnalyzer(makeCase('preconditioning-output-mismatch', {
    mutateSamples: samples => {
      samples[7].preconditioning[1].raw_output_sha256 = sha256('different preconditioning')
    },
  })), /preconditioning produced different deterministic output/)

  assertInvalid(runAnalyzer(makeCase('preconditioning-count-proof', {
    mutateSamples: samples => { samples[8].preconditioning[0].generated_tokens = 999 },
  })), /generated_tokens/)

  assertInvalid(runAnalyzer(makeCase('extra-preconditioning', {
    mutateSamples: samples => {
      samples[9].preconditioning.push(preconditioningSample())
    },
  })), /preconditioning must contain exactly 2 samples/)

  assertInvalid(runAnalyzer(makeCase('missing-preconditioning', {
    mutateSamples: samples => { samples[9].preconditioning.pop() },
  })), /preconditioning must contain exactly 2 samples/)

  assertInvalid(runAnalyzer(makeCase('missing-measurement', {
    mutateSamples: samples => { samples[10].measurements.pop() },
  })), /measurements must contain exactly 3 samples/)

  assertInvalid(runAnalyzer(makeCase('extra-measurement', {
    mutateSamples: samples => {
      samples[10].measurements.push(clone(samples[10].measurements[0]))
    },
  })), /measurements must contain exactly 3 samples/)

  assertInvalid(runAnalyzer(makeCase('threshold-override', {
    mutateWorkload: workload => { workload.measurement.maximum_overhead_ratio = 1.051 },
  })), /maximum_overhead_ratio/)

  assertInvalid(runAnalyzer(makeCase('normalized-formula-override', {
    mutateWorkload: workload => {
      workload.measurement.normalized_mean_factor_formula = 'mean_token_interval_ms'
    },
  })), /normalized_mean_factor_formula/)

  assertInvalid(runAnalyzer(makeCase('normalized-aggregation-override', {
    mutateWorkload: workload => {
      workload.measurement.normalized_mean_process_aggregation = 'geometric_mean'
    },
  })), /normalized_mean_process_aggregation/)

  assertInvalid(runAnalyzer(makeCase('preconditioning-count-override', {
    mutateWorkload: workload => { workload.preconditioning.completions = 1 },
  })), /preconditioning\.completions/)

  assertInvalid(runAnalyzer(makeCase('measurement-count-override', {
    mutateWorkload: workload => { workload.measurement.completions_per_process = 2 },
  })), /measurement\.completions_per_process/)

  assertInvalid(runAnalyzer(makeCase('bootstrap-count-lower-override', {
    mutateWorkload: workload => { workload.measurement.bootstrap_iterations = 19_999 },
  })), /measurement\.bootstrap_iterations/)

  assertInvalid(runAnalyzer(makeCase('bootstrap-count-upper-override', {
    mutateWorkload: workload => { workload.measurement.bootstrap_iterations = 20_001 },
  })), /measurement\.bootstrap_iterations/)

  assertInvalid(runAnalyzer(makeCase('extra-stats-key', {
    mutateSamples: samples => { samples[11].measurements[2].stats.unexpected = 1 },
  })), /measurement 3\.stats keys must be exactly/)

  assertInvalid(runAnalyzer(makeCase('recorded-mean-mismatch', {
    mutateSamples: samples => { samples[10].measurements[1].mean_token_interval_ms += 0.01 },
  })), /does not match the complete interval sample/)

  const atomicInvalidCase = makeCase('atomic-invalid', {
    mutateSamples: samples => { samples[0].preconditioning[0].token_count = 999 },
  })
  const staleOutput = join(atomicInvalidCase.directory, 'result.json')
  writeFileSync(staleOutput, '{"schema_version":6,"status":"pass"}\n')
  const atomicInvalid = runAnalyzer(atomicInvalidCase)
  assertInvalid(atomicInvalid, /token_count/)
  assert.equal(readdirSync(atomicInvalidCase.directory)
    .filter(name => name.startsWith('result.json.tmp-')).length, 0,
  'atomic evidence write left a temporary file behind')

  console.log(
    '[bench-test] schema-6 server-normalized mean factor, raw p99 co-primary gate, fixed 2+3 completions, strict 5% boundary, intact-ABBA-block bootstrap, backend-variance isolation, atomic invalid evidence, and strict provenance guards passed',
  )
} finally {
  rmSync(root, { recursive: true, force: true })
}
