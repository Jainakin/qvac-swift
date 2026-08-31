#!/usr/bin/env node

import { createHash } from 'node:crypto'
import { createReadStream, lstatSync, readFileSync, renameSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { completion, loadModel, unloadModel, close } from '@qvac/sdk'

const [workloadPath, modelPath, resultPath] = process.argv.slice(2)
if (!workloadPath || !modelPath || !resultPath) {
  throw new Error('usage: streaming-completion-bench.mjs <workload.json> <model.gguf> <result.json>')
}

const workloadBytes = readFileSync(workloadPath)
const workload = JSON.parse(workloadBytes)
const workloadSha256 = createHash('sha256').update(workloadBytes).digest('hex')
const runtimeRoot = dirname(fileURLToPath(import.meta.url))

function requireCondition(condition, message) {
  if (!condition) throw new Error(message)
}

async function sha256File(path) {
  const hash = createHash('sha256')
  for await (const chunk of createReadStream(path)) hash.update(chunk)
  return hash.digest('hex')
}

function atomicWriteJSON(path, value) {
  const temporary = `${path}.tmp-${process.pid}`
  writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, { flag: 'wx' })
  renameSync(temporary, path)
}

function numberField(value, name) {
  requireCondition(Number.isFinite(value), `${name} must be finite`)
  return value
}

function generationParams(predict) {
  return { ...workload.completion.generation, predict }
}

function validateWorkload() {
  requireCondition(workload.schema_version === 1, 'workload schema_version must be 1')
  requireCondition(
    workload.criterion === 'Streaming completion latency overhead (Swift client vs. JS client on same machine) < 5%.',
    'workload criterion does not match grant KR-2',
  )
  requireCondition(workload.model.model_type === 'llamacpp-completion'
    && workload.model.config.ctx_size === 2048
    && workload.model.config.parallel === 1,
  'workload model configuration violates the fixed KR-2 protocol')
  requireCondition(workload.completion.stream === true
    && workload.completion.emit_raw_deltas === false
    && workload.completion.capture_thinking === false
    && workload.completion.kv_cache === false,
  'workload completion flags violate the fixed KR-2 protocol')
  requireCondition(workload.warmup.predict > 1
    && workload.warmup.minimum_completions >= 3
    && workload.warmup.maximum_completions >= workload.warmup.minimum_completions
    && workload.warmup.maximum_recent_mean_ratio === 1.025,
  'workload warmup policy violates the fixed KR-2 protocol')
  requireCondition(workload.measurement.predict === 1000
    && workload.measurement.process_pairs === 10
    && workload.measurement.bootstrap_iterations >= 20000
    && workload.measurement.maximum_overhead_ratio === 1.05,
  'workload measurement policy violates the fixed KR-2 protocol')
  requireCondition(workload.timeouts.model_load_ms === 180000
    && workload.timeouts.completion_idle_ms === 30000
    && workload.timeouts.process_watchdog_seconds === 240,
  'workload timeout policy violates the fixed KR-2 protocol')
}

async function runCompletion(modelId, predict) {
  const start = performance.now()
  const run = completion({
    modelId,
    history: [{ role: 'user', content: workload.completion.prompt }],
    stream: workload.completion.stream,
    emitRawDeltas: workload.completion.emit_raw_deltas,
    captureThinking: workload.completion.capture_thinking,
    kvCache: workload.completion.kv_cache,
    generationParams: generationParams(predict),
    rpcOptions: { timeout: workload.timeouts.completion_idle_ms },
  })

  const arrivals = []
  let content = ''
  let terminalLatency
  let terminalStopReason
  let previousSequence = -1
  for await (const event of run.events) {
    const now = performance.now()
    requireCondition(Number.isSafeInteger(event.seq) && event.seq === previousSequence + 1,
      `completion event sequence is not contiguous: ${previousSequence} -> ${event.seq}`)
    previousSequence = event.seq
    if (event.type === 'contentDelta') {
      requireCondition(typeof event.text === 'string' && event.text.length > 0,
        'completion emitted an empty content delta')
      arrivals.push(now - start)
      content += event.text
    } else if (event.type === 'completionDone') {
      terminalLatency = now - start
      terminalStopReason = event.stopReason
    } else if (event.type !== 'completionStats') {
      throw new Error(`unexpected completion event type ${String(event.type)} at ${event.seq}`)
    }
  }
  const final = await run.final

  requireCondition(arrivals.length === predict,
    `expected ${predict} non-empty content deltas, got ${arrivals.length}`)
  requireCondition(terminalStopReason === 'length' && final.stopReason === 'length',
    `completion did not stop at the fixed token limit: ${terminalStopReason}/${final.stopReason}`)
  requireCondition(final.stats?.generatedTokens === predict,
    `expected generatedTokens=${predict}, got ${final.stats?.generatedTokens}`)
  requireCondition(final.stats?.emittedTokens === predict,
    `expected emittedTokens=${predict}, got ${final.stats?.emittedTokens}`)
  requireCondition(typeof final.stats?.backendDevice === 'string',
    'completion did not report a backend device')
  requireCondition(typeof terminalLatency === 'number' && terminalLatency >= arrivals.at(-1),
    'completion did not expose a valid terminal event latency')
  requireCondition(content === final.contentText,
    'streamed content does not match CompletionFinal')

  const intervals = arrivals.slice(1).map((value, index) => value - arrivals[index])
  requireCondition(intervals.every(value => Number.isFinite(value) && value > 0),
    'completion produced a non-positive token interval')
  const meanInterval = intervals.reduce((sum, value) => sum + value, 0) / intervals.length
  const contentSha256 = createHash('sha256').update(content).digest('hex')
  const rawSha256 = createHash('sha256').update(final.raw.fullText).digest('hex')

  return {
    predict,
    ttft_ms: numberField(arrivals[0], 'ttft_ms'),
    terminal_ms: numberField(terminalLatency, 'terminal_ms'),
    token_arrival_offsets_ms: arrivals,
    token_intervals_ms: intervals,
    mean_token_interval_ms: meanInterval,
    content_sha256: contentSha256,
    raw_output_sha256: rawSha256,
    content_matches_final: content === final.contentText,
    stop_reason: final.stopReason,
    stats: final.stats,
  }
}

const modelStat = lstatSync(modelPath)
requireCondition(modelStat.isFile() && !modelStat.isSymbolicLink(), 'model fixture must be a regular non-symlink file')
requireCondition(modelStat.size === workload.model.byte_count,
  `model fixture size mismatch: expected ${workload.model.byte_count}, got ${modelStat.size}`)
const modelSha256 = await sha256File(modelPath)
requireCondition(modelSha256 === workload.model.sha256,
  `model fixture SHA-256 mismatch: expected ${workload.model.sha256}, got ${modelSha256}`)

validateWorkload()
const runtimePackage = JSON.parse(readFileSync(join(runtimeRoot, 'package.json'), 'utf8'))
const sdkPackage = JSON.parse(readFileSync(
  join(runtimeRoot, 'node_modules', '@qvac', 'sdk', 'package.json'),
  'utf8',
))
requireCondition(runtimePackage.dependencies?.['@qvac/sdk'] === '0.17.0'
  && runtimePackage.dependencies?.['bare-runtime'] === '1.31.0'
  && sdkPackage.version === '0.17.0',
'benchmark requires the exact @qvac/sdk 0.17.0 and Bare 1.31.0 runtime graph')

let modelId
try {
  modelId = await loadModel({
    modelSrc: modelPath,
    modelType: workload.model.model_type,
    modelConfig: workload.model.config,
  }, { timeout: workload.timeouts.model_load_ms })

  const warmups = []
  let converged = false
  for (let index = 0; index < workload.warmup.maximum_completions; index++) {
    const sample = await runCompletion(modelId, workload.warmup.predict)
    warmups.push({
      predict: sample.predict,
      token_count: sample.token_arrival_offsets_ms.length,
      stop_reason: sample.stop_reason,
      generated_tokens: sample.stats.generatedTokens,
      emitted_tokens: sample.stats.emittedTokens,
      content_matches_final: sample.content_matches_final,
      mean_token_interval_ms: sample.mean_token_interval_ms,
      content_sha256: sample.content_sha256,
      raw_output_sha256: sample.raw_output_sha256,
      backend_device: sample.stats.backendDevice,
    })
    if (warmups.length >= workload.warmup.minimum_completions) {
      const recent = warmups.slice(-workload.warmup.minimum_completions)
      const means = recent.map(sample => sample.mean_token_interval_ms)
      const ratio = Math.max(...means) / Math.min(...means)
      const sameOutput = recent.every(sample =>
        sample.content_sha256 === recent[0].content_sha256
          && sample.raw_output_sha256 === recent[0].raw_output_sha256)
      if (ratio <= workload.warmup.maximum_recent_mean_ratio && sameOutput) {
        converged = true
        break
      }
    }
  }
  requireCondition(converged, 'streaming completion warmup did not converge')

  const measurement = await runCompletion(modelId, workload.measurement.predict)
  atomicWriteJSON(resultPath, {
    schema_version: 1,
    status: 'sample',
    client: 'node',
    api_surface: '@qvac/sdk completion(...).events',
    workload_sha256: workloadSha256,
    model_sha256: modelSha256,
    warmups,
    measurement,
    timeout_policy: {
      model_load_ms: workload.timeouts.model_load_ms,
      completion_idle_ms: workload.timeouts.completion_idle_ms,
      process_watchdog_seconds: workload.timeouts.process_watchdog_seconds,
    },
    toolchain: {
      node: process.env.QVAC_BENCH_NODE_VERSION || process.version,
      bare: process.env.QVAC_BENCH_BARE_VERSION || 'unknown',
      swift: process.env.QVAC_BENCH_SWIFT_VERSION || 'unknown',
      host: process.env.QVAC_BENCH_HOST || `${process.platform}-${process.arch}`,
      sdk: '0.17.0',
      configuration: 'release',
    },
  })
} finally {
  if (modelId) await unloadModel({ modelId })
  await close()
}

// The SDK installs process-level signal hooks for long-lived desktop apps.
// This benchmark is a short-lived owned process and has already awaited model
// unload plus RPC shutdown, so terminate explicitly instead of allowing those
// application hooks to consume the outer watchdog after valid evidence exists.
process.exit(0)
