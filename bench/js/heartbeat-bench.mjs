// Node baseline for the heartbeat latency benchmark.
//
// Usage:
//   node bench/js/heartbeat-bench.mjs [iterations] [warmupIterations] [resultPath]
//
// Output: writes JSON to resultPath (default: ./node-result.json). The SDK's
// runtime logging would otherwise contaminate the captured stdout, so we
// deliberately do NOT print the JSON result to stdout.

import { heartbeat, close } from '@qvac/sdk'
import { writeFileSync } from 'node:fs'

const iterations = parseInt(process.argv[2] || '1000', 10)
const warmupIterations = parseInt(process.argv[3] || '50', 10)
const resultPath = process.argv[4] || './node-result.json'
if (!Number.isSafeInteger(iterations) || iterations < 100) throw new Error('iterations must be an integer >= 100')
if (!Number.isSafeInteger(warmupIterations) || warmupIterations < 1) throw new Error('warmupIterations must be positive')

const samples = []
try {
  // Worker startup is not a per-request cost. Warm the same public SDK path.
  for (let i = 0; i < warmupIterations; i++) {
    const response = await heartbeat()
    if (!Number.isFinite(response?.number)) throw new Error('invalid heartbeat response during warmup')
  }
  for (let i = 0; i < iterations; i++) {
    const start = performance.now()
    const response = await heartbeat()
    const elapsed = performance.now() - start
    if (!Number.isFinite(response?.number) || !Number.isFinite(elapsed) || elapsed <= 0) {
      throw new Error('invalid heartbeat response/sample')
    }
    samples.push(elapsed)
  }
} finally {
  await close()
}

const sorted = [...samples].sort((a, b) => a - b)
const result = {
  client:    'node',
  iterations,
  warmup_iterations: warmupIterations,
  min_ms:    sorted[0],
  mean_ms:   samples.reduce((a, b) => a + b, 0) / samples.length,
  p50_ms:    sorted[Math.floor(sorted.length / 2)],
  p99_ms:    sorted[Math.floor(sorted.length * 0.99)],
  max_ms:    sorted[sorted.length - 1],
  samples_ms: samples,
  api_surface: '@qvac/sdk.heartbeat()',
  timeout_policy: 'outer-owned-process-watchdog-no-per-call-timeout',
  toolchain: {
    node: process.env.QVAC_BENCH_NODE_VERSION || process.version,
    bare: process.env.QVAC_BENCH_BARE_VERSION || 'unknown',
    swift: process.env.QVAC_BENCH_SWIFT_VERSION || 'unknown',
    host: process.env.QVAC_BENCH_HOST || `${process.platform}-${process.arch}`,
    watchdog_seconds: Number(process.env.QVAC_BENCH_PROCESS_TIMEOUT_SECONDS || -1),
    sdk: '0.17.0',
    configuration: 'release',
  },
}

writeFileSync(resultPath, JSON.stringify(result, null, 2))
console.error(`[node-bench] wrote ${resultPath}`)
