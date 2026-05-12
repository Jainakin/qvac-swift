// Node baseline for the heartbeat latency benchmark.
//
// Usage:
//   node bench/js/heartbeat-bench.mjs [iterations] [resultPath]
//
// Output: writes JSON to resultPath (default: ./node-result.json). The SDK's
// runtime logging would otherwise contaminate the captured stdout, so we
// deliberately do NOT print the JSON result to stdout.

import { heartbeat, close } from '@qvac/sdk'
import { writeFileSync } from 'node:fs'

const iterations = parseInt(process.argv[2] || '1000', 10)
const resultPath = process.argv[3] || './node-result.json'

// Warm up — first call spawns the worker.
await heartbeat()

const samples = []
for (let i = 0; i < iterations; i++) {
  const start = performance.now()
  await heartbeat()
  samples.push(performance.now() - start)
}

await close()

samples.sort((a, b) => a - b)
const result = {
  client:    'node',
  iterations,
  min_ms:    samples[0],
  mean_ms:   samples.reduce((a, b) => a + b, 0) / samples.length,
  p50_ms:    samples[Math.floor(samples.length / 2)],
  p99_ms:    samples[Math.floor(samples.length * 0.99)],
  max_ms:    samples[samples.length - 1],
}

writeFileSync(resultPath, JSON.stringify(result, null, 2))
console.error(`[node-bench] wrote ${resultPath}`)
