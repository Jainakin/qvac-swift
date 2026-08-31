#!/usr/bin/env node

import assert from 'node:assert/strict'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const scriptDir = dirname(fileURLToPath(import.meta.url))
const root = mkdtempSync(join(tmpdir(), 'qvac-bench-analyzer-'))
try {
  const order = [
    'swift', 'node', 'node', 'swift', 'node', 'swift', 'swift', 'node',
    'node', 'swift', 'swift', 'node', 'swift', 'node', 'node', 'swift',
  ]
  const paths = order.map((client, index) => {
    const base = client === 'swift' ? 1.04 : 1.0
    const result = {
      client,
      iterations: 100,
      warmup_iterations: 10,
      samples_ms: Array.from({ length: 100 }, (_, sample) => base + (sample % 7) * 0.0001),
      timeout_policy: 'outer-owned-process-watchdog-no-per-call-timeout',
      toolchain: {
        node: 'v22.22.0',
        bare: '1.31.0',
        swift: 'Swift version fixture',
        host: 'fixture-arm64',
        watchdog_seconds: 120,
        sdk: '0.17.0',
        configuration: 'release',
      },
    }
    const path = join(root, `run-${index}.json`)
    writeFileSync(path, JSON.stringify(result))
    return path
  })

  const output = join(root, 'result.json')
  const success = spawnSync(process.execPath, [join(scriptDir, 'analyze.mjs'), output, '1.05', ...paths], {
    encoding: 'utf8',
  })
  assert.equal(success.status, 0, success.stderr || success.stdout)
  const report = JSON.parse(readFileSync(output, 'utf8'))
  assert.equal(report.status, 'pass')
  assert.equal(report.timeout_policy.kind, 'outer-owned-process-watchdog-no-per-call-timeout')
  assert.equal(report.timeout_policy.watchdog_seconds, 120)

  const invalid = JSON.parse(readFileSync(paths[0], 'utf8'))
  delete invalid.toolchain.watchdog_seconds
  writeFileSync(paths[0], JSON.stringify(invalid))
  const failure = spawnSync(process.execPath, [join(scriptDir, 'analyze.mjs'), output, '1.05', ...paths], {
    encoding: 'utf8',
  })
  assert.notEqual(failure.status, 0, 'analyzer accepted missing watchdog metadata')
  assert.match(failure.stderr, /lacks exact release toolchain metadata/)

  console.log('[bench-test] equal timeout policy accepted; missing watchdog metadata rejected')
} finally {
  rmSync(root, { recursive: true, force: true })
}
