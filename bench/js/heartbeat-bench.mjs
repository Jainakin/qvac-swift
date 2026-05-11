// Node baseline for the heartbeat latency benchmark.
//
// Usage:
//   node bench/js/heartbeat-bench.mjs [iterations]
//
// Output (JSON): same shape as the Swift counterpart so a comparison script can diff them.

import { heartbeat, close } from '@qvac/sdk'

const iterations = parseInt(process.argv[2] || '1000', 10)

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
const min = samples[0]
const max = samples[samples.length - 1]
const mean = samples.reduce((a, b) => a + b, 0) / samples.length
const p50 = samples[Math.floor(samples.length / 2)]
const p99 = samples[Math.floor(samples.length * 0.99)]

console.log(JSON.stringify({
  client: 'node',
  iterations,
  min_ms: min,
  mean_ms: mean,
  p50_ms: p50,
  p99_ms: p99,
  max_ms: max,
}, null, 2))
