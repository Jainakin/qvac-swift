#!/usr/bin/env node

import { createHash } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs'

const [outputPath, workloadPath, ...runPaths] = process.argv.slice(2)

const EXPECTED_ORDER = Array.from({ length: 10 }, (_, pair) =>
  pair % 2 === 0 ? ['swift', 'node'] : ['node', 'swift']).flat()
const FIXED_BUDGET = 1.05
const BOOTSTRAP_SEED = 0x517a9e31
const SHA256_PATTERN = /^[0-9a-f]{64}$/
const WORKLOAD_CONTRACT = {
  schema_version: 1,
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
  warmup: {
    predict: 128,
    minimum_completions: 3,
    maximum_completions: 16,
    maximum_recent_mean_ratio: 1.025,
  },
  measurement: {
    predict: 1000,
    process_pairs: 10,
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
      cwd: process.cwd(),
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

// Resample adjacent process pairs as intact clusters. The same selected pairs
// feed every metric in an iteration, preserving both temporal matching and the
// dependence between the two co-primary endpoints.
function bootstrapPairedMetrics(pairs, iterations, keys) {
  const randomIndex = makeRandomIndex(BOOTSTRAP_SEED)
  const distributions = Object.fromEntries(keys.map(key => [key, []]))
  for (let iteration = 0; iteration < iterations; iteration++) {
    const selected = Array.from(
      { length: pairs.length },
      () => pairs[randomIndex(pairs.length)],
    )
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
    ['schema_version', 'criterion', 'model', 'completion', 'warmup', 'measurement', 'timeouts'],
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

  requireExactKeys(workload.warmup,
    ['predict', 'minimum_completions', 'maximum_completions', 'maximum_recent_mean_ratio'],
    'workload.warmup')
  for (const [key, value] of Object.entries(WORKLOAD_CONTRACT.warmup)) {
    requireExactValue(workload.warmup[key], value, `workload.warmup.${key}`)
  }

  requireExactKeys(workload.measurement,
    ['predict', 'process_pairs', 'bootstrap_iterations', 'maximum_overhead_ratio'],
    'workload.measurement')
  requireExactValue(workload.measurement.predict, WORKLOAD_CONTRACT.measurement.predict,
    'workload.measurement.predict')
  requireExactValue(workload.measurement.process_pairs,
    WORKLOAD_CONTRACT.measurement.process_pairs, 'workload.measurement.process_pairs')
  requireExactValue(workload.measurement.maximum_overhead_ratio, FIXED_BUDGET,
    'workload.measurement.maximum_overhead_ratio')
  validateNumber(workload.measurement.bootstrap_iterations,
    'workload.measurement.bootstrap_iterations', { integer: true })
  requireCondition(workload.measurement.bootstrap_iterations >= 20_000
      && workload.measurement.bootstrap_iterations <= 200_000,
  'workload.measurement.bootstrap_iterations must be in 20000...200000')

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

function validateWarmup(warmup, workload, runNumber, warmupNumber, expectedBackend) {
  const name = `run ${runNumber} warmup ${warmupNumber}`
  requireExactKeys(warmup, [
    'predict', 'token_count', 'stop_reason', 'generated_tokens', 'emitted_tokens',
    'mean_token_interval_ms', 'content_sha256', 'raw_output_sha256',
    'content_matches_final', 'backend_device',
  ], name)
  requireExactValue(warmup.predict, workload.warmup.predict, `${name}.predict`)
  requireExactValue(warmup.token_count, workload.warmup.predict, `${name}.token_count`)
  requireExactValue(warmup.stop_reason, 'length', `${name}.stop_reason`)
  requireExactValue(warmup.generated_tokens, workload.warmup.predict, `${name}.generated_tokens`)
  requireExactValue(warmup.emitted_tokens, workload.warmup.predict, `${name}.emitted_tokens`)
  validateNumber(warmup.mean_token_interval_ms, `${name}.mean_token_interval_ms`)
  validateSHA256(warmup.content_sha256, `${name}.content_sha256`)
  validateSHA256(warmup.raw_output_sha256, `${name}.raw_output_sha256`)
  requireExactValue(warmup.content_matches_final, true, `${name}.content_matches_final`)
  requireExactValue(warmup.backend_device, expectedBackend, `${name}.backend_device`)
}

function warmupWindowConverged(warmups, size, threshold) {
  const recent = warmups.slice(-size)
  const means = recent.map(sample => sample.mean_token_interval_ms)
  const sameOutput = recent.every(sample =>
    sample.content_sha256 === recent[0].content_sha256
      && sample.raw_output_sha256 === recent[0].raw_output_sha256)
  return sameOutput && Math.max(...means) / Math.min(...means) <= threshold
}

function validateStats(stats, workload, runNumber) {
  const name = `run ${runNumber} measurement.stats`
  requireObject(stats, name)
  for (const key of [
    'timeToFirstToken', 'tokensPerSecond', 'cacheTokens', 'promptTokens',
    'generatedTokens', 'emittedTokens', 'avgConcurrentSeq',
  ]) {
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

function validateMeasurement(measurement, workload, runNumber) {
  const name = `run ${runNumber} measurement`
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
  validateStats(measurement.stats, workload, runNumber)
}

function validateRun(run, workload, workloadSha256, runNumber, expectedClient) {
  const name = `run ${runNumber}`
  requireExactKeys(run, [
    'schema_version', 'status', 'client', 'api_surface', 'workload_sha256',
    'model_sha256', 'warmups', 'measurement', 'timeout_policy', 'toolchain',
  ], name)
  requireExactValue(run.schema_version, 1, `${name}.schema_version`)
  requireExactValue(run.status, 'sample', `${name}.status`)
  requireExactValue(run.client, expectedClient, `${name}.client`)
  const expectedSurface = expectedClient === 'swift'
    ? 'QVACClient.completion(...).events'
    : '@qvac/sdk completion(...).events'
  requireExactValue(run.api_surface, expectedSurface, `${name}.api_surface`)
  requireExactValue(run.workload_sha256, workloadSha256, `${name}.workload_sha256`)
  requireExactValue(run.model_sha256, workload.model.sha256, `${name}.model_sha256`)
  validateTimeoutPolicy(run.timeout_policy, workload, runNumber)
  validateToolchain(run.toolchain, runNumber)

  requireCondition(Array.isArray(run.warmups)
      && run.warmups.length >= workload.warmup.minimum_completions
      && run.warmups.length <= workload.warmup.maximum_completions,
  `${name}.warmups must contain ${workload.warmup.minimum_completions}...${workload.warmup.maximum_completions} samples`)
  run.warmups.forEach((warmup, index) => validateWarmup(
    warmup,
    workload,
    runNumber,
    index + 1,
    workload.model.config.device,
  ))
  const warmupIdentity = `${run.warmups[0].content_sha256}/${run.warmups[0].raw_output_sha256}`
  requireCondition(run.warmups.every(sample =>
    `${sample.content_sha256}/${sample.raw_output_sha256}` === warmupIdentity),
  `${name}.warmups produced different deterministic output`)

  let firstConvergenceCount
  for (let count = workload.warmup.minimum_completions; count <= run.warmups.length; count++) {
    if (warmupWindowConverged(
      run.warmups.slice(0, count),
      workload.warmup.minimum_completions,
      workload.warmup.maximum_recent_mean_ratio,
    )) {
      firstConvergenceCount = count
      break
    }
  }
  requireCondition(firstConvergenceCount !== undefined,
    `${name}.warmups did not converge within the recorded samples`)
  requireCondition(firstConvergenceCount === run.warmups.length,
    `${name}.warmups continued after first convergence`)

  validateMeasurement(run.measurement, workload, runNumber)
  return {
    warmupIdentity,
    outputIdentity: `${run.measurement.content_sha256}/${run.measurement.raw_output_sha256}`,
  }
}

function runSummary(run, inputSHA256, index) {
  const intervals = run.measurement.token_intervals_ms
  return {
    position: index + 1,
    input_sha256: inputSHA256,
    client: run.client,
    mean_token_interval_ms: mean(intervals),
    p99_token_interval_ms: empiricalQuantile(intervals, 0.99),
    token_interval_count: intervals.length,
    ttft_ms: run.measurement.ttft_ms,
    terminal_ms: run.measurement.terminal_ms,
    backend_device: run.measurement.stats.backendDevice,
    content_sha256: run.measurement.content_sha256,
    raw_output_sha256: run.measurement.raw_output_sha256,
  }
}

function analyze() {
  requireCondition(outputPath && workloadPath,
    'usage: analyze.mjs <result.json> <workload.json> <twenty schema-1 run.json paths>')
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
  requireCondition(runs.map(run => run?.client).join(',') === EXPECTED_ORDER.join(','),
    `benchmark process order must be ${EXPECTED_ORDER.join('/')}`)

  let expectedToolchain
  let warmupIdentity
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
    warmupIdentity ??= identities.warmupIdentity
    requireCondition(identities.warmupIdentity === warmupIdentity,
      `run ${index + 1} produced different deterministic warmup output`)
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
      'geometric mean of paired per-process arithmetic-mean inter-token latency ratios',
      true,
    ),
    p99_token_interval: metric(
      'p99_ratio',
      'geometric mean of paired per-process empirical nearest-rank p99 inter-token latency ratios',
      true,
    ),
    ttft_diagnostic: metric('ttft_ratio', 'time to first public content delta', false),
    terminal_diagnostic: metric(
      'terminal_ratio', 'request start to public completionDone event', false),
  }
  const primary = [metrics.mean_token_interval, metrics.p99_token_interval]
  const status = primary.every(value => value.status === 'pass')
    ? 'pass'
    : primary.some(value => value.status === 'fail') ? 'fail' : 'inconclusive'

  const report = {
    schema_version: 4,
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
      experimental_unit: 'adjacent order-balanced Swift/Node process pair',
      per_process_mean: 'arithmetic mean of every positive inter-contentDelta interval',
      per_process_p99: 'empirical nearest-rank p99 of every positive inter-contentDelta interval',
      point_estimate: 'geometric mean of ten paired Swift/Node process ratios',
      confidence_interval: 'deterministic paired-cluster percentile bootstrap, 2.5th–97.5th percentiles',
      co_primary_decision: 'both 97.5th-percentile upper bounds must be < 1.05',
      bootstrap_seed: `0x${BOOTSTRAP_SEED.toString(16)}`,
      bootstrap_iterations: workload.measurement.bootstrap_iterations,
      exclusions: 'none',
      token_interval_definition: 'monotonic-clock time between successive non-empty public contentDelta events; TTFT excluded and reported separately',
    },
    warmup_policy: {
      convergence_window: workload.warmup.minimum_completions,
      maximum_completions: workload.warmup.maximum_completions,
      maximum_recent_mean_ratio: workload.warmup.maximum_recent_mean_ratio,
      stop_at_first_convergence: true,
      validated_warmup_output: warmupIdentity,
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
    schema_version: 4,
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
