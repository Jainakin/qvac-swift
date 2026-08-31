#!/usr/bin/env node

import { createHash } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const [outputPath, workloadPath, ...runPaths] = process.argv.slice(2)
const REPOSITORY_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')

const ORDER_STRATA = ['swift/node', 'node/swift']
const PAIRS_PER_ORDER_STRATUM = 5
const EXPECTED_PAIR_ORDERS = Array.from(
  { length: 10 },
  (_, pair) => ORDER_STRATA[pair % ORDER_STRATA.length],
)
const EXPECTED_ORDER = EXPECTED_PAIR_ORDERS.flatMap(order => order.split('/'))
const FIXED_BUDGET = 1.05
const BOOTSTRAP_SEED = 0x517a9e31
const SHA256_PATTERN = /^[0-9a-f]{64}$/
const SOURCE_COMMIT_PATTERN = /^[0-9a-f]{40}$/
const RUN_SCHEMA_VERSION = 2
const REPORT_SCHEMA_VERSION = 5
const WORKLOAD_CONTRACT = {
  schema_version: 2,
  criterion: 'Streaming completion latency overhead (Swift client vs. JS client on same machine) < 5%.',
  model: {
    name: 'SmolLM2-135M-Instruct-Q4_K_M.gguf',
    source: 'https://huggingface.co/bartowski/SmolLM2-135M-Instruct-GGUF/resolve/d255afaffd3441b95abca9b5cc4c819b93f66936/SmolLM2-135M-Instruct-Q4_K_M.gguf',
    revision: 'd255afaffd3441b95abca9b5cc4c819b93f66936',
    byte_count: 105_454_432,
    sha256: '2e8040ceae7815abe0dcb3540b9995eaa1fa0d2ca9e797d0a635ae4433c68c2d',
    model_type: 'llamacpp-completion',
    config: {
      ctx_size: 2048,
      gpu_layers: 99,
      device: 'gpu',
      parallel: 1,
      verbosity: 0,
    },
  },
  completion: {
    prompt: 'Write the integers from 1 through 300, separated by spaces. Do not summarize or stop early.',
    stream: true,
    emit_raw_deltas: false,
    capture_thinking: false,
    kv_cache: false,
    generation: {
      temp: 0,
      top_k: 1,
      top_p: 1,
      seed: 20_260_831,
      frequency_penalty: 0,
      presence_penalty: 0,
      repeat_penalty: 1,
    },
  },
  preconditioning: {
    predict: 1000,
    completions: 2,
  },
  measurement: {
    predict: 1000,
    completions_per_process: 3,
    process_pairs: 10,
    bootstrap_iterations: 20_000,
    maximum_overhead_ratio: FIXED_BUDGET,
  },
  timeouts: {
    model_load_ms: 180_000,
    completion_idle_ms: 30_000,
    process_watchdog_seconds: 240,
  },
}

const invalidContext = {
  source_commit: sourceCommit(),
  requested_process_runs: runPaths.length,
  expected_process_order: EXPECTED_ORDER.join('/'),
  fixed_maximum_overhead_ratio: FIXED_BUDGET,
}

function sourceCommit() {
  try {
    const value = execFileSync('git', ['rev-parse', 'HEAD'], {
      encoding: 'utf8',
      cwd: REPOSITORY_ROOT,
      stdio: ['ignore', 'pipe', 'ignore'],
    }).trim()
    return /^[0-9a-f]{40}$/.test(value) ? value : 'unknown'
  } catch {
    return 'unknown'
  }
}

function atomicWriteJSON(path, value) {
  const temporary = `${path}.tmp-${process.pid}`
  try {
    writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, { flag: 'wx' })
    renameSync(temporary, path)
  } catch (error) {
    rmSync(temporary, { force: true })
    throw error
  }
}

function requireCondition(condition, message) {
  if (!condition) throw new Error(message)
}

function requireObject(value, name) {
  requireCondition(value !== null && typeof value === 'object' && !Array.isArray(value),
    `${name} must be an object`)
}

function requireExactKeys(value, expectedKeys, name) {
  requireObject(value, name)
  const actual = Object.keys(value).sort()
  const expected = [...expectedKeys].sort()
  requireCondition(JSON.stringify(actual) === JSON.stringify(expected),
    `${name} keys must be exactly ${expected.join(', ')}`)
}

function requireExactValue(actual, expected, name) {
  requireCondition(Object.is(actual, expected), `${name} must be ${JSON.stringify(expected)}`)
}

function validateNumber(value, name, { integer = false, positive = true } = {}) {
  requireCondition(Number.isFinite(value), `${name} must be finite`)
  if (integer) requireCondition(Number.isSafeInteger(value), `${name} must be an integer`)
  if (positive) requireCondition(value > 0, `${name} must be positive`)
}

function validateSHA256(value, name) {
  requireCondition(typeof value === 'string' && SHA256_PATTERN.test(value),
    `${name} must be a lowercase SHA-256`)
}

function stableJSON(value) {
  if (Array.isArray(value)) return `[${value.map(stableJSON).join(',')}]`
  if (value !== null && typeof value === 'object') {
    return `{${Object.keys(value).sort().map(key =>
      `${JSON.stringify(key)}:${stableJSON(value[key])}`).join(',')}}`
  }
  return JSON.stringify(value)
}

function readJSON(path, name) {
  const bytes = readFileSync(path)
  let value
  try {
    value = JSON.parse(bytes)
  } catch (error) {
    throw new Error(`${name} is not valid JSON: ${error.message}`)
  }
  return {
    bytes,
    sha256: createHash('sha256').update(bytes).digest('hex'),
    value,
  }
}

function mean(values) {
  requireCondition(values.length > 0, 'cannot calculate the mean of an empty sample')
  return values.reduce((sum, value) => sum + value, 0) / values.length
}

function geometricMean(values) {
  requireCondition(values.length > 0 && values.every(value => Number.isFinite(value) && value > 0),
    'geometric mean requires positive finite values')
  return Math.exp(mean(values.map(Math.log)))
}

// Empirical nearest-rank quantile. In particular, p99 is an observed latency;
// interpolation must not synthesize a smaller tail value between observations.
function empiricalQuantile(values, probability) {
  requireCondition(values.length > 0, 'cannot calculate a quantile of an empty sample')
  requireCondition(probability > 0 && probability <= 1, 'quantile probability must be in (0, 1]')
  const sorted = [...values].sort((a, b) => a - b)
  return sorted[Math.ceil(sorted.length * probability) - 1]
}

function makeRandomIndex(seed) {
  let state = seed >>> 0
  return length => {
    state ^= state << 13
    state ^= state >>> 17
    state ^= state << 5
    return (state >>> 0) % length
  }
}

// Resample adjacent process pairs as intact clusters within the two fixed order
// strata. Every replicate preserves the designed five Swift-first and five
// Node-first pairs, along with endpoint dependence and temporal matching.
function bootstrapPairedMetrics(pairs, iterations, keys) {
  const randomIndex = makeRandomIndex(BOOTSTRAP_SEED)
  const distributions = Object.fromEntries(keys.map(key => [key, []]))
  const strata = ORDER_STRATA.map(order => {
    const members = pairs.filter(pair => pair.order === order)
    requireCondition(members.length === PAIRS_PER_ORDER_STRATUM,
      `benchmark requires exactly ${PAIRS_PER_ORDER_STRATUM} ${order} pairs`)
    return members
  })
  for (let iteration = 0; iteration < iterations; iteration++) {
    const selected = strata.flatMap(members => Array.from(
      { length: PAIRS_PER_ORDER_STRATUM },
      () => members[randomIndex(members.length)],
    ))
    for (const key of keys) {
      distributions[key].push(geometricMean(selected.map(pair => pair[key])))
    }
  }
  for (const values of Object.values(distributions)) values.sort((a, b) => a - b)
  return distributions
}

function intervalFromSortedBootstrap(values) {
  return [
    values[Math.ceil(values.length * 0.025) - 1],
    values[Math.ceil(values.length * 0.975) - 1],
  ]
}

function metricStatus([lower95, upper95], budget) {
  if (upper95 < budget) return 'pass'
  if (lower95 >= budget) return 'fail'
  return 'inconclusive'
}

function validateWorkload(workload) {
  requireExactKeys(workload,
    ['schema_version', 'criterion', 'model', 'completion', 'preconditioning', 'measurement', 'timeouts'],
    'workload')
  requireExactValue(workload.schema_version, WORKLOAD_CONTRACT.schema_version,
    'workload.schema_version')
  requireExactValue(workload.criterion, WORKLOAD_CONTRACT.criterion, 'workload.criterion')

  requireExactKeys(workload.model,
    ['name', 'source', 'revision', 'byte_count', 'sha256', 'model_type', 'config'],
    'workload.model')
  for (const key of ['name', 'source', 'revision', 'byte_count', 'sha256', 'model_type']) {
    requireExactValue(workload.model[key], WORKLOAD_CONTRACT.model[key], `workload.model.${key}`)
  }
  requireExactKeys(workload.model.config,
    ['ctx_size', 'gpu_layers', 'device', 'parallel', 'verbosity'], 'workload.model.config')
  for (const [key, value] of Object.entries(WORKLOAD_CONTRACT.model.config)) {
    requireExactValue(workload.model.config[key], value, `workload.model.config.${key}`)
  }

  requireExactKeys(workload.completion,
    ['prompt', 'stream', 'emit_raw_deltas', 'capture_thinking', 'kv_cache', 'generation'],
    'workload.completion')
  for (const key of ['prompt', 'stream', 'emit_raw_deltas', 'capture_thinking', 'kv_cache']) {
    requireExactValue(workload.completion[key], WORKLOAD_CONTRACT.completion[key],
      `workload.completion.${key}`)
  }
  requireExactKeys(workload.completion.generation,
    ['temp', 'top_k', 'top_p', 'seed', 'frequency_penalty', 'presence_penalty', 'repeat_penalty'],
    'workload.completion.generation')
  for (const [key, value] of Object.entries(WORKLOAD_CONTRACT.completion.generation)) {
    requireExactValue(workload.completion.generation[key], value,
      `workload.completion.generation.${key}`)
  }

  requireExactKeys(workload.preconditioning, ['predict', 'completions'],
    'workload.preconditioning')
  for (const [key, value] of Object.entries(WORKLOAD_CONTRACT.preconditioning)) {
    requireExactValue(workload.preconditioning[key], value, `workload.preconditioning.${key}`)
  }

  requireExactKeys(workload.measurement,
    ['predict', 'completions_per_process', 'process_pairs', 'bootstrap_iterations',
      'maximum_overhead_ratio'],
    'workload.measurement')
  requireExactValue(workload.measurement.predict, WORKLOAD_CONTRACT.measurement.predict,
    'workload.measurement.predict')
  requireExactValue(workload.measurement.completions_per_process,
    WORKLOAD_CONTRACT.measurement.completions_per_process,
    'workload.measurement.completions_per_process')
  requireExactValue(workload.measurement.process_pairs,
    WORKLOAD_CONTRACT.measurement.process_pairs, 'workload.measurement.process_pairs')
  requireExactValue(workload.measurement.maximum_overhead_ratio, FIXED_BUDGET,
    'workload.measurement.maximum_overhead_ratio')
  requireExactValue(workload.measurement.bootstrap_iterations,
    WORKLOAD_CONTRACT.measurement.bootstrap_iterations,
    'workload.measurement.bootstrap_iterations')

  requireExactKeys(workload.timeouts,
    ['model_load_ms', 'completion_idle_ms', 'process_watchdog_seconds'], 'workload.timeouts')
  for (const [key, value] of Object.entries(WORKLOAD_CONTRACT.timeouts)) {
    requireExactValue(workload.timeouts[key], value, `workload.timeouts.${key}`)
  }
}

function validateToolchain(toolchain, runNumber) {
  const name = `run ${runNumber} toolchain`
  requireExactKeys(toolchain, ['node', 'bare', 'swift', 'host', 'sdk', 'configuration'], name)
  requireExactValue(toolchain.node, 'v22.22.0', `${name}.node`)
  requireExactValue(toolchain.bare, 'v1.31.0', `${name}.bare`)
  requireCondition(typeof toolchain.swift === 'string'
      && /Apple Swift version (?:5\.10(?:\.\d+)?|6(?:\.\d+){0,2})(?:\s|\(|$)/.test(toolchain.swift),
  `${name}.swift must identify Apple Swift 5.10.x or 6.x`)
  requireCondition(typeof toolchain.host === 'string'
      && /^Darwin-[A-Za-z0-9._-]+-arm64$/.test(toolchain.host),
  `${name}.host must identify Darwin arm64`)
  requireExactValue(toolchain.sdk, '0.17.0', `${name}.sdk`)
  requireExactValue(toolchain.configuration, 'release', `${name}.configuration`)
}

function validateTimeoutPolicy(policy, workload, runNumber) {
  const name = `run ${runNumber} timeout_policy`
  requireExactKeys(policy,
    ['model_load_ms', 'completion_idle_ms', 'process_watchdog_seconds'], name)
  for (const [key, expected] of Object.entries(workload.timeouts)) {
    validateNumber(policy[key], `${name}.${key}`, { integer: true })
    requireExactValue(policy[key], expected, `${name}.${key}`)
  }
}

function validatePreconditioning(sample, workload, runNumber, sampleNumber, expectedBackend) {
  const name = `run ${runNumber} preconditioning ${sampleNumber}`
  requireExactKeys(sample, [
    'predict', 'token_count', 'stop_reason', 'generated_tokens', 'emitted_tokens',
    'mean_token_interval_ms', 'content_sha256', 'raw_output_sha256',
    'content_matches_final', 'backend_device',
  ], name)
  requireExactValue(sample.predict, workload.preconditioning.predict, `${name}.predict`)
  requireExactValue(sample.token_count, workload.preconditioning.predict, `${name}.token_count`)
  requireExactValue(sample.stop_reason, 'length', `${name}.stop_reason`)
  requireExactValue(sample.generated_tokens, workload.preconditioning.predict,
    `${name}.generated_tokens`)
  requireExactValue(sample.emitted_tokens, workload.preconditioning.predict,
    `${name}.emitted_tokens`)
  validateNumber(sample.mean_token_interval_ms, `${name}.mean_token_interval_ms`)
  validateSHA256(sample.content_sha256, `${name}.content_sha256`)
  validateSHA256(sample.raw_output_sha256, `${name}.raw_output_sha256`)
  requireExactValue(sample.content_matches_final, true, `${name}.content_matches_final`)
  requireExactValue(sample.backend_device, expectedBackend, `${name}.backend_device`)
}

function validateStats(stats, workload, runNumber, measurementNumber) {
  const name = `run ${runNumber} measurement ${measurementNumber}.stats`
  const numericKeys = [
    'timeToFirstToken', 'tokensPerSecond', 'cacheTokens', 'promptTokens',
    'generatedTokens', 'emittedTokens', 'avgConcurrentSeq',
  ]
  requireExactKeys(stats, [...numericKeys, 'backendDevice'], name)
  for (const key of numericKeys) {
    if (stats[key] !== undefined && stats[key] !== null) {
      validateNumber(stats[key], `${name}.${key}`, { positive: false })
      requireCondition(stats[key] >= 0, `${name}.${key} must be non-negative`)
    }
  }
  requireExactValue(stats.generatedTokens, workload.measurement.predict,
    `${name}.generatedTokens`)
  requireExactValue(stats.emittedTokens, workload.measurement.predict,
    `${name}.emittedTokens`)
  requireExactValue(stats.backendDevice, workload.model.config.device, `${name}.backendDevice`)
}

function validateOrchestration(orchestration, runNumber, expectedClient) {
  const name = `run ${runNumber} orchestration`
  requireExactKeys(orchestration, ['position', 'pair', 'pair_order'], name)
  const pairNumber = Math.ceil(runNumber / 2)
  const expectedPosition = String(runNumber).padStart(2, '0')
  const expectedPair = String(pairNumber).padStart(2, '0')
  const expectedPairOrder = EXPECTED_PAIR_ORDERS[pairNumber - 1]
  requireExactValue(orchestration.position, expectedPosition, `${name}.position`)
  requireExactValue(orchestration.pair, expectedPair, `${name}.pair`)
  requireExactValue(orchestration.pair_order, expectedPairOrder, `${name}.pair_order`)
  requireExactValue(expectedPairOrder.split('/')[(runNumber - 1) % 2], expectedClient,
    `${name} client at position`)
}

function validateMeasurement(measurement, workload, runNumber, measurementNumber) {
  const name = `run ${runNumber} measurement ${measurementNumber}`
  requireExactKeys(measurement, [
    'predict', 'ttft_ms', 'terminal_ms', 'token_arrival_offsets_ms',
    'token_intervals_ms', 'mean_token_interval_ms', 'content_sha256',
    'raw_output_sha256', 'content_matches_final', 'stop_reason', 'stats',
  ], name)
  const expectedTokenCount = workload.measurement.predict
  const expectedIntervalCount = expectedTokenCount - 1
  requireExactValue(measurement.predict, expectedTokenCount, `${name}.predict`)
  requireCondition(Array.isArray(measurement.token_arrival_offsets_ms)
      && measurement.token_arrival_offsets_ms.length === expectedTokenCount,
  `${name}.token_arrival_offsets_ms must contain exactly ${expectedTokenCount} values`)
  requireCondition(Array.isArray(measurement.token_intervals_ms)
      && measurement.token_intervals_ms.length === expectedIntervalCount,
  `${name}.token_intervals_ms must contain exactly ${expectedIntervalCount} values`)
  measurement.token_arrival_offsets_ms.forEach((value, token) =>
    validateNumber(value, `${name}.token_arrival_offsets_ms[${token}]`))
  measurement.token_intervals_ms.forEach((value, token) =>
    validateNumber(value, `${name}.token_intervals_ms[${token}]`))
  for (let token = 1; token < measurement.token_arrival_offsets_ms.length; token++) {
    const derived = measurement.token_arrival_offsets_ms[token]
      - measurement.token_arrival_offsets_ms[token - 1]
    const reported = measurement.token_intervals_ms[token - 1]
    const tolerance = Math.max(1e-9, Math.abs(derived) * 1e-9)
    requireCondition(Math.abs(derived - reported) <= tolerance,
      `${name}.token_intervals_ms[${token - 1}] does not match its arrival offsets`)
  }
  validateNumber(measurement.ttft_ms, `${name}.ttft_ms`)
  validateNumber(measurement.terminal_ms, `${name}.terminal_ms`)
  const firstArrival = measurement.token_arrival_offsets_ms[0]
  requireCondition(Math.abs(measurement.ttft_ms - firstArrival) <= 1e-9,
    `${name}.ttft_ms must equal the first arrival offset`)
  requireCondition(measurement.terminal_ms >= measurement.token_arrival_offsets_ms.at(-1),
    `${name}.terminal_ms must not precede the final token`)
  const calculatedMean = mean(measurement.token_intervals_ms)
  validateNumber(measurement.mean_token_interval_ms, `${name}.mean_token_interval_ms`)
  requireCondition(Math.abs(measurement.mean_token_interval_ms - calculatedMean)
      <= Math.max(1e-12, calculatedMean * 1e-12),
  `${name}.mean_token_interval_ms does not match the complete interval sample`)
  requireExactValue(measurement.stop_reason, 'length', `${name}.stop_reason`)
  requireExactValue(measurement.content_matches_final, true, `${name}.content_matches_final`)
  validateSHA256(measurement.content_sha256, `${name}.content_sha256`)
  validateSHA256(measurement.raw_output_sha256, `${name}.raw_output_sha256`)
  validateStats(measurement.stats, workload, runNumber, measurementNumber)
}

function validateRun(run, workload, workloadSha256, runNumber, expectedClient) {
  const name = `run ${runNumber}`
  requireExactKeys(run, [
    'schema_version', 'status', 'client', 'api_surface', 'workload_sha256',
    'model_sha256', 'source_commit', 'orchestration', 'preconditioning', 'measurements',
    'timeout_policy', 'toolchain',
  ], name)
  requireExactValue(run.schema_version, RUN_SCHEMA_VERSION, `${name}.schema_version`)
  requireExactValue(run.status, 'sample', `${name}.status`)
  requireExactValue(run.client, expectedClient, `${name}.client`)
  const expectedSurface = expectedClient === 'swift'
    ? 'QVACClient.completion(...).events'
    : '@qvac/sdk completion(...).events'
  requireExactValue(run.api_surface, expectedSurface, `${name}.api_surface`)
  requireExactValue(run.workload_sha256, workloadSha256, `${name}.workload_sha256`)
  requireExactValue(run.model_sha256, workload.model.sha256, `${name}.model_sha256`)
  requireCondition(typeof run.source_commit === 'string'
      && SOURCE_COMMIT_PATTERN.test(run.source_commit),
  `${name}.source_commit must be an exact 40-hex commit`)
  requireExactValue(run.source_commit, invalidContext.source_commit, `${name}.source_commit`)
  validateOrchestration(run.orchestration, runNumber, expectedClient)
  validateTimeoutPolicy(run.timeout_policy, workload, runNumber)
  validateToolchain(run.toolchain, runNumber)

  requireCondition(Array.isArray(run.preconditioning)
      && run.preconditioning.length === workload.preconditioning.completions,
  `${name}.preconditioning must contain exactly ${workload.preconditioning.completions} samples`)
  run.preconditioning.forEach((sample, index) => validatePreconditioning(
    sample,
    workload,
    runNumber,
    index + 1,
    workload.model.config.device,
  ))
  const preconditioningIdentity = `${run.preconditioning[0].content_sha256}/${run.preconditioning[0].raw_output_sha256}`
  requireCondition(run.preconditioning.every(sample =>
    `${sample.content_sha256}/${sample.raw_output_sha256}` === preconditioningIdentity),
  `${name}.preconditioning produced different deterministic output`)

  requireCondition(Array.isArray(run.measurements)
      && run.measurements.length === workload.measurement.completions_per_process,
  `${name}.measurements must contain exactly ${workload.measurement.completions_per_process} samples`)
  run.measurements.forEach((measurement, index) =>
    validateMeasurement(measurement, workload, runNumber, index + 1))
  const outputIdentity = `${run.measurements[0].content_sha256}/${run.measurements[0].raw_output_sha256}`
  requireCondition(run.measurements.every(sample =>
    `${sample.content_sha256}/${sample.raw_output_sha256}` === outputIdentity),
  `${name}.measurements produced different deterministic output`)
  requireCondition(outputIdentity === preconditioningIdentity,
    `${name}.preconditioning and measurement output differ`)
  return {
    preconditioningIdentity,
    outputIdentity,
  }
}

function runSummary(run, inputSHA256, index) {
  const intervals = run.measurements.flatMap(measurement => measurement.token_intervals_ms)
  const completionSummaries = run.measurements.map((measurement, measurementIndex) => ({
    measurement: measurementIndex + 1,
    mean_token_interval_ms: mean(measurement.token_intervals_ms),
    p99_token_interval_ms: empiricalQuantile(measurement.token_intervals_ms, 0.99),
    ttft_ms: measurement.ttft_ms,
    terminal_ms: measurement.terminal_ms,
  }))
  return {
    position: index + 1,
    input_sha256: inputSHA256,
    client: run.client,
    mean_token_interval_ms: mean(intervals),
    p99_token_interval_ms: empiricalQuantile(intervals, 0.99),
    measurement_completion_count: run.measurements.length,
    token_interval_count: intervals.length,
    ttft_ms: mean(run.measurements.map(measurement => measurement.ttft_ms)),
    terminal_ms: mean(run.measurements.map(measurement => measurement.terminal_ms)),
    per_completion: completionSummaries,
    backend_device: run.measurements[0].stats.backendDevice,
    content_sha256: run.measurements[0].content_sha256,
    raw_output_sha256: run.measurements[0].raw_output_sha256,
  }
}

function analyze() {
  requireCondition(outputPath && workloadPath,
    'usage: analyze.mjs <result.json> <workload.json> <twenty schema-2 run.json paths>')
  requireCondition(SOURCE_COMMIT_PATTERN.test(invalidContext.source_commit),
    'analyzer requires an exact 40-hex Git source commit at HEAD')
  requireCondition(runPaths.length === EXPECTED_ORDER.length,
    'KR-2 requires exactly ten adjacent alternating Swift/Node process pairs')

  const workloadInput = readJSON(workloadPath, 'workload')
  invalidContext.workload_sha256 = workloadInput.sha256
  validateWorkload(workloadInput.value)
  const workload = workloadInput.value

  const runInputs = runPaths.map((path, index) => readJSON(path, `run ${index + 1}`))
  invalidContext.input_sample_sha256 = runInputs.map(input => input.sha256)
  requireCondition(new Set(invalidContext.input_sample_sha256).size === runInputs.length,
    'every process sample must have unique independently recorded bytes')
  const runs = runInputs.map(input => input.value)
  const observedPairOrders = Array.from({ length: runs.length / 2 }, (_, pairIndex) => {
    const clients = runs.slice(pairIndex * 2, pairIndex * 2 + 2).map(run => run?.client)
    requireCondition([...clients].sort().join('/') === 'node/swift',
      `pair ${pairIndex + 1} must contain exactly one Swift and one Node process`)
    return clients.join('/')
  })
  for (const order of ORDER_STRATA) {
    requireCondition(
      observedPairOrders.filter(observed => observed === order).length === PAIRS_PER_ORDER_STRATUM,
      `benchmark requires exactly ${PAIRS_PER_ORDER_STRATUM} ${order} pairs`,
    )
  }
  requireCondition(runs.map(run => run?.client).join(',') === EXPECTED_ORDER.join(','),
    `benchmark process order must be ${EXPECTED_ORDER.join('/')}`)

  let expectedToolchain
  let preconditioningIdentity
  let outputIdentity
  for (const [index, run] of runs.entries()) {
    const identities = validateRun(
      run,
      workload,
      workloadInput.sha256,
      index + 1,
      EXPECTED_ORDER[index],
    )
    const toolchain = stableJSON(run.toolchain)
    expectedToolchain ??= toolchain
    requireCondition(toolchain === expectedToolchain,
      `run ${index + 1} used a different toolchain`)
    preconditioningIdentity ??= identities.preconditioningIdentity
    requireCondition(identities.preconditioningIdentity === preconditioningIdentity,
      `run ${index + 1} produced different deterministic preconditioning output`)
    outputIdentity ??= identities.outputIdentity
    requireCondition(identities.outputIdentity === outputIdentity,
      `run ${index + 1} produced different deterministic measured output`)
  }

  const summaries = runs.map((run, index) => runSummary(run, runInputs[index].sha256, index))
  const pairs = []
  for (let pairIndex = 0; pairIndex < workload.measurement.process_pairs; pairIndex++) {
    const members = summaries.slice(pairIndex * 2, pairIndex * 2 + 2)
    const swift = members.find(run => run.client === 'swift')
    const node = members.find(run => run.client === 'node')
    requireCondition(swift && node, `pair ${pairIndex + 1} does not contain one Swift and one Node run`)
    pairs.push({
      pair: pairIndex + 1,
      order: members.map(run => run.client).join('/'),
      mean_ratio: swift.mean_token_interval_ms / node.mean_token_interval_ms,
      p99_ratio: swift.p99_token_interval_ms / node.p99_token_interval_ms,
      ttft_ratio: swift.ttft_ms / node.ttft_ms,
      terminal_ratio: swift.terminal_ms / node.terminal_ms,
      swift,
      node,
    })
  }

  const metricKeys = ['mean_ratio', 'p99_ratio', 'ttft_ratio', 'terminal_ratio']
  const bootstrap = bootstrapPairedMetrics(
    pairs,
    workload.measurement.bootstrap_iterations,
    metricKeys,
  )
  const metric = (key, title, primary) => {
    const confidence = intervalFromSortedBootstrap(bootstrap[key])
    const value = {
      title,
      ratio: geometricMean(pairs.map(pair => pair[key])),
      ratio_ci95: confidence,
      primary,
    }
    if (primary) value.status = metricStatus(confidence, FIXED_BUDGET)
    return value
  }
  const metrics = {
    mean_token_interval: metric(
      'mean_ratio',
      'geometric mean of paired per-process pooled arithmetic-mean inter-token latency ratios',
      true,
    ),
    p99_token_interval: metric(
      'p99_ratio',
      'geometric mean of paired per-process pooled empirical nearest-rank p99 inter-token latency ratios',
      true,
    ),
    ttft_diagnostic: metric(
      'ttft_ratio', 'per-process mean time to first public content delta', false),
    terminal_diagnostic: metric(
      'terminal_ratio', 'per-process mean request start to public completionDone event', false),
  }
  const primary = [metrics.mean_token_interval, metrics.p99_token_interval]
  const status = primary.every(value => value.status === 'pass')
    ? 'pass'
    : primary.some(value => value.status === 'fail') ? 'fail' : 'inconclusive'

  const report = {
    schema_version: REPORT_SCHEMA_VERSION,
    status,
    criterion: workload.criterion,
    source_commit: invalidContext.source_commit,
    workload_sha256: workloadInput.sha256,
    prompt_sha256: createHash('sha256').update(workload.completion.prompt).digest('hex'),
    workload,
    runtime_contract: '@qvac/sdk@0.17.0 via tools/runtime/package-lock.json',
    process_order: EXPECTED_ORDER.join('/'),
    process_pairs: workload.measurement.process_pairs,
    statistical_method: {
      experimental_unit: 'adjacent Swift/Node process pair, with allocation stratified by execution order',
      measured_completions_per_process: workload.measurement.completions_per_process,
      intervals_per_process: workload.measurement.completions_per_process
        * (workload.measurement.predict - 1),
      per_process_mean: 'arithmetic mean of every positive inter-contentDelta interval pooled across all three fixed measured completions',
      per_process_p99: 'empirical nearest-rank p99 of every positive inter-contentDelta interval pooled across all three fixed measured completions',
      diagnostic_aggregation: 'arithmetic mean of the three completion-level TTFT or terminal latencies within each process',
      point_estimate: 'geometric mean of ten paired Swift/Node process ratios',
      confidence_interval: 'deterministic order-stratified paired-cluster percentile bootstrap, preserving five Swift/Node and five Node/Swift pairs in every replicate, 2.5th–97.5th percentiles',
      bootstrap_order_strata: Object.fromEntries(
        ORDER_STRATA.map(order => [order, PAIRS_PER_ORDER_STRATUM]),
      ),
      co_primary_decision: 'both 97.5th-percentile upper bounds must be < 1.05',
      bootstrap_seed: `0x${BOOTSTRAP_SEED.toString(16)}`,
      bootstrap_iterations: workload.measurement.bootstrap_iterations,
      exclusions: 'none',
      retries: 0,
      token_interval_definition: 'monotonic-clock time between successive non-empty public contentDelta events; TTFT excluded and reported separately',
    },
    preconditioning_policy: {
      fixed_count: workload.preconditioning.completions,
      tokens_per_completion: workload.preconditioning.predict,
      timing_used_for_selection: false,
      validated_output: preconditioningIdentity,
    },
    measurement_policy: {
      fixed_completions_per_process: workload.measurement.completions_per_process,
      tokens_per_completion: workload.measurement.predict,
      all_completed_measurements_included: true,
    },
    maximum_overhead_ratio: FIXED_BUDGET,
    metrics,
    pairs,
    ordered_process_runs: runs,
    ordered_input_sha256: runInputs.map(input => input.sha256),
    toolchain: runs[0].toolchain,
    backend_device: workload.model.config.device,
    deterministic_output: outputIdentity,
  }
  atomicWriteJSON(outputPath, report)
  console.log(
    `[bench] mean=${metrics.mean_token_interval.ratio.toFixed(6)} `
      + `ci95=[${metrics.mean_token_interval.ratio_ci95.map(value => value.toFixed(6)).join(', ')}] `
      + `p99=${metrics.p99_token_interval.ratio.toFixed(6)} `
      + `ci95=[${metrics.p99_token_interval.ratio_ci95.map(value => value.toFixed(6)).join(', ')}] `
      + `budget=${FIXED_BUDGET} status=${status}`,
  )
  if (status === 'fail') process.exitCode = 1
  if (status === 'inconclusive') process.exitCode = 2
}

try {
  analyze()
} catch (error) {
  const reason = error instanceof Error ? error.message : String(error)
  const invalidReport = {
    schema_version: REPORT_SCHEMA_VERSION,
    status: 'invalid',
    reason,
    ...invalidContext,
  }
  if (outputPath) {
    try {
      atomicWriteJSON(outputPath, invalidReport)
    } catch (writeError) {
      console.error(`[bench] invalid: ${reason}`)
      console.error(`[bench] additionally failed to write invalid evidence: ${writeError.message}`)
      process.exitCode = 3
      process.exit()
    }
  }
  console.error(`[bench] invalid: ${reason}`)
  process.exitCode = 3
}
