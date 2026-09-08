#!/usr/bin/env node

import { createHash } from 'node:crypto'
import {
  chmodSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import {
  packageDeterministicXCFramework,
  verifyPackagedXCFrameworkArchive,
} from './zip-artifact.mjs'

function expectRejected(action, expectedMessage) {
  try {
    action()
  } catch (error) {
    if (String(error).includes(expectedMessage)) return
    throw error
  }
  throw new Error(`archive verifier accepted ${expectedMessage}`)
}

const root = mkdtempSync(join(tmpdir(), 'qvac-zip-repro-'))
try {
  const frameworks = join(root, 'frameworks')
  const fixture = join(frameworks, 'Fixture.xcframework')
  mkdirSync(join(fixture, 'ios-arm64', 'Fixture.framework'), { recursive: true })
  writeFileSync(join(fixture, 'Info.plist'), '<plist><dict/></plist>\n')
  writeFileSync(join(fixture, 'ios-arm64', 'Fixture.framework', 'Fixture'), 'deterministic fixture\n')
  chmodSync(fixture, 0o755)
  chmodSync(join(fixture, 'ios-arm64'), 0o755)
  chmodSync(join(fixture, 'ios-arm64', 'Fixture.framework'), 0o755)
  chmodSync(join(fixture, 'Info.plist'), 0o644)
  chmodSync(join(fixture, 'ios-arm64', 'Fixture.framework', 'Fixture'), 0o644)
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

  const binary = join(fixture, 'ios-arm64', 'Fixture.framework', 'Fixture')
  chmodSync(binary, 0o755)
  expectRejected(
    () => verifyPackagedXCFrameworkArchive({ frameworksDir: frameworks, target: 'Fixture', asset: first }),
    'extracted archive differs from staged Fixture.xcframework',
  )
  chmodSync(binary, 0o644)

  const omittedFromArchive = join(fixture, 'expected-after-packaging')
  writeFileSync(omittedFromArchive, 'must be present\n', { mode: 0o644 })
  expectRejected(
    () => verifyPackagedXCFrameworkArchive({ frameworksDir: frameworks, target: 'Fixture', asset: first }),
    'missing Fixture.xcframework/expected-after-packaging',
  )
  rmSync(omittedFromArchive)

  const infoPlist = join(fixture, 'Info.plist')
  const infoPlistBytes = readFileSync(infoPlist)
  rmSync(infoPlist)
  expectRejected(
    () => verifyPackagedXCFrameworkArchive({ frameworksDir: frameworks, target: 'Fixture', asset: first }),
    'unexpected Fixture.xcframework/Info.plist',
  )
  writeFileSync(infoPlist, infoPlistBytes, { mode: 0o644 })
  verifyPackagedXCFrameworkArchive({ frameworksDir: frameworks, target: 'Fixture', asset: first })
  console.log('[zip-artifact] archive omission, unexpected-entry, and permission drift rejected')

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
