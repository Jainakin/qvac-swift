#!/usr/bin/env node

import { readFileSync, writeFileSync } from 'node:fs'

const [outputPath, budgetText, ...runPaths] = process.argv.slice(2)
const budget = Number(budgetText)
if (!outputPath || budget !== 1.05 || runPaths.length !== 16) {
  throw new Error('usage: analyze.mjs <result.json> 1.05 <sixteen mirrored-ABBA run.json paths>')
}
const orderedRuns = runPaths.map(path => JSON.parse(readFileSync(path, 'utf8')))
const expectedOrder = [
  'swift', 'node', 'node', 'swift', 'node', 'swift', 'swift', 'node',
  'node', 'swift', 'swift', 'node', 'swift', 'node', 'node', 'swift',
]
if (orderedRuns.map(run => run.client).join(',') !== expectedOrder.join(',')) {
  throw new Error(`benchmark process order must be ${expectedOrder.join('/')}`)
}

const requiredToolchainText = ['node', 'bare', 'swift', 'host']
for (const result of orderedRuns) {
  if (!Array.isArray(result.samples_ms) || result.samples_ms.length < 100) {
    throw new Error(`${result.client ?? 'unknown'} result has fewer than 100 raw samples`)
  }
  if (!Number.isSafeInteger(result.warmup_iterations) || result.warmup_iterations < 1) {
    throw new Error(`${result.client ?? 'unknown'} result does not report warmup iterations`)
  }
  if (result.samples_ms.some(value => !Number.isFinite(value) || value <= 0)) {
    throw new Error(`${result.client ?? 'unknown'} result contains a non-finite/non-positive sample`)
  }
  if (result.timeout_policy !== 'outer-owned-process-watchdog-no-per-call-timeout') {
    throw new Error(`${result.client ?? 'unknown'} result does not use the required equal timeout policy`)
  }
  if (result.toolchain?.sdk !== '0.17.0' || result.toolchain?.configuration !== 'release'
      || requiredToolchainText.some(key => typeof result.toolchain?.[key] !== 'string'
        || result.toolchain[key].length === 0 || result.toolchain[key] === 'unknown')
      || !Number.isSafeInteger(result.toolchain?.watchdog_seconds)
      || result.toolchain.watchdog_seconds < 30 || result.toolchain.watchdog_seconds > 300) {
    throw new Error(`${result.client ?? 'unknown'} result lacks exact release toolchain metadata`)
  }
}

const expectedIterations = orderedRuns[0].iterations
const expectedWarmup = orderedRuns[0].warmup_iterations
const toolchainKeys = ['node', 'bare', 'swift', 'host', 'watchdog_seconds', 'sdk', 'configuration']
const normalizedToolchain = run => JSON.stringify(
  Object.fromEntries(toolchainKeys.map(key => [key, run.toolchain?.[key]])),
)
const expectedToolchain = normalizedToolchain(orderedRuns[0])
if (orderedRuns.some(run => run.iterations !== expectedIterations
    || run.warmup_iterations !== expectedWarmup
    || run.samples_ms.length !== expectedIterations
    || normalizedToolchain(run) !== expectedToolchain)) {
  throw new Error('balanced process runs do not share iteration, warmup, sample, and toolchain metadata')
}

function trimmedMean(values, fraction = 0.1) {
  const sorted = [...values].sort((a, b) => a - b)
  const trim = Math.floor(sorted.length * fraction)
  const kept = sorted.slice(trim, sorted.length - trim)
  return kept.reduce((sum, value) => sum + value, 0) / kept.length
}

let state = 0x517a9e31
function randomIndex(length) {
  state ^= state << 13
  state ^= state >>> 17
  state ^= state << 5
  return (state >>> 0) % length
}

// Preserve within-process autocorrelation by sampling contiguous circular
// blocks, and preserve between-process variance by resampling whole run slots.
const blockLength = 20
function blockResample(values) {
  const output = []
  while (output.length < values.length) {
    const start = randomIndex(values.length)
    for (let offset = 0; offset < blockLength && output.length < values.length; offset++) {
      output.push(values[(start + offset) % values.length])
    }
  }
  return output
}

const swiftRuns = orderedRuns.filter(run => run.client === 'swift')
const nodeRuns = orderedRuns.filter(run => run.client === 'node')
const combine = runs => runs.flatMap(run => run.samples_ms)
const swiftSamples = combine(swiftRuns)
const nodeSamples = combine(nodeRuns)
const point = trimmedMean(swiftSamples) / trimmedMean(nodeSamples)
const ratios = []
for (let iteration = 0; iteration < 5_000; iteration++) {
  const swiftResample = Array.from({ length: swiftRuns.length }, () =>
    blockResample(swiftRuns[randomIndex(swiftRuns.length)].samples_ms)).flat()
  const nodeResample = Array.from({ length: nodeRuns.length }, () =>
    blockResample(nodeRuns[randomIndex(nodeRuns.length)].samples_ms)).flat()
  ratios.push(trimmedMean(swiftResample) / trimmedMean(nodeResample))
}
ratios.sort((a, b) => a - b)
const lower95 = ratios[Math.floor(ratios.length * 0.025)]
const upper95 = ratios[Math.floor(ratios.length * 0.975)]
const status = upper95 <= budget ? 'pass' : lower95 > budget ? 'fail' : 'inconclusive'
const result = {
  schema_version: 3,
  metric: 'ratio of 10%-trimmed public-heartbeat latency means (Swift / Node)',
  bootstrap: {
    iterations: ratios.length,
    confidence_level: 0.95,
    method: 'hierarchical circular block bootstrap across eight processes per implementation',
    block_length_samples: blockLength,
  },
  ratio: point,
  ratio_ci95: [lower95, upper95],
  max_overhead_budget: budget,
  status,
  process_order: expectedOrder.join('/'),
  process_runs_per_implementation: swiftRuns.length,
  temporal_order_uncertainty: 'Balanced process order and hierarchical blocks reduce, but cannot eliminate, hosted-runner scheduling and thermal noise.',
  swift_samples_ms: swiftSamples,
  node_samples_ms: nodeSamples,
  ordered_process_runs: orderedRuns,
  toolchain: orderedRuns[0].toolchain,
  runtime_contract: '@qvac/sdk@0.17.0 via tools/runtime/package-lock.json',
  timeout_policy: {
    kind: 'outer-owned-process-watchdog-no-per-call-timeout',
    watchdog_seconds: orderedRuns[0].toolchain.watchdog_seconds,
    rationale: 'Both public heartbeat paths have no per-call timeout and every measured process is bounded by the same owned-process-tree watchdog.',
  },
}
writeFileSync(outputPath, JSON.stringify(result, null, 2) + '\n')
console.log(`[bench] ratio=${point.toFixed(6)} ci95=[${lower95.toFixed(6)}, ${upper95.toFixed(6)}] budget=${budget} status=${status}`)
if (status === 'fail') process.exitCode = 1
if (status === 'inconclusive') process.exitCode = 2
