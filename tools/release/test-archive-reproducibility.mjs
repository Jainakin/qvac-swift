#!/usr/bin/env node

import { createHash } from 'node:crypto'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { packageDeterministicXCFramework } from './zip-artifact.mjs'

const root = mkdtempSync(join(tmpdir(), 'qvac-zip-repro-'))
try {
  const frameworks = join(root, 'frameworks')
  const fixture = join(frameworks, 'Fixture.xcframework')
  mkdirSync(join(fixture, 'ios-arm64', 'Fixture.framework'), { recursive: true })
  writeFileSync(join(fixture, 'Info.plist'), '<plist><dict/></plist>\n')
  writeFileSync(join(fixture, 'ios-arm64', 'Fixture.framework', 'Fixture'), 'deterministic fixture\n')
  const first = join(root, 'kolkata.zip')
  const second = join(root, 'los-angeles.zip')

  process.env.TZ = 'Asia/Kolkata'
  packageDeterministicXCFramework({ frameworksDir: frameworks, target: 'Fixture', asset: first })
  process.env.TZ = 'America/Los_Angeles'
  packageDeterministicXCFramework({ frameworksDir: frameworks, target: 'Fixture', asset: second })

  const digest = path => createHash('sha256').update(readFileSync(path)).digest('hex')
  const firstHash = digest(first)
  const secondHash = digest(second)
  if (firstHash !== secondHash) throw new Error(`timezone-dependent archives: ${firstHash} != ${secondHash}`)
  console.log(`[zip-artifact] timezone-independent fixture sha256=${firstHash}`)

  const outside = join(root, 'outside-do-not-touch')
  writeFileSync(outside, 'outside fixture\n')
  const before = statSync(outside).mtimeMs
  symlinkSync(outside, join(fixture, 'escape'))
  let rejected = false
  try {
    packageDeterministicXCFramework({
      frameworksDir: frameworks,
      target: 'Fixture',
      asset: join(root, 'must-not-exist.zip'),
    })
  } catch (error) {
    rejected = String(error).includes('symbolic links are forbidden')
  }
  if (!rejected) throw new Error('symlink escape fixture was not rejected')
  if (readFileSync(outside, 'utf8') !== 'outside fixture\n' || statSync(outside).mtimeMs !== before) {
    throw new Error('symlink target outside the XCFramework was mutated')
  }
  console.log('[zip-artifact] symlink escape rejected before metadata mutation')
} finally {
  rmSync(root, { recursive: true, force: true })
}
