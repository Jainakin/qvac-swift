#!/usr/bin/env node

import { createHash } from 'node:crypto'
import { lstatSync, readFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { TextDecoder } from 'node:util'

const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../..')
const policyPath = resolve(repositoryRoot, 'tools/coverage/ios-transport-policy.json')
const reviewedInventoryPath = resolve(repositoryRoot, 'tools/ci/ios-smoke-test-inventory.txt')
const maximumLogBytes = 128 * 1024 * 1024
const maximumMetadataBytes = 1024 * 1024
const clientTarget = 'QVACClient'
const testTarget = 'QVACiOSSmokeTests'
const threadSanitizerRuntime = 'libclang_rt.tsan_iossim_dynamic.dylib'

function fail(message) {
  throw new Error(`[ios-test-log] ${message}`)
}

function regularBytes(path, label, maximumBytes) {
  let metadata
  try {
    metadata = lstatSync(path)
  } catch (error) {
    fail(`${label} is unavailable: ${error.message}`)
  }
  if (!metadata.isFile() || metadata.isSymbolicLink()) {
    fail(`${label} must be a regular non-symlink file`)
  }
  if (metadata.size === 0) fail(`${label} is empty`)
  if (metadata.size > maximumBytes) {
    fail(`${label} is ${metadata.size} bytes; maximum is ${maximumBytes}`)
  }
  return readFileSync(path)
}

function strictUTF8(bytes, label) {
  try {
    return new TextDecoder('utf-8', { fatal: true }).decode(bytes)
  } catch {
    fail(`${label} is not valid UTF-8`)
  }
}

function sha256(bytes) {
  return createHash('sha256').update(bytes).digest('hex')
}

function parseJSON(bytes, label) {
  try {
    return JSON.parse(strictUTF8(bytes, label))
  } catch (error) {
    if (error.message.startsWith('[ios-test-log]')) throw error
    fail(`${label} is not valid JSON: ${error.message}`)
  }
}

function parseInventory(bytes, testPolicy) {
  const digest = sha256(bytes)
  if (digest !== testPolicy.inventorySHA256) {
    fail(`reviewed inventory SHA-256 is ${digest}; expected ${testPolicy.inventorySHA256}`)
  }

  const text = strictUTF8(bytes, 'reviewed iOS test inventory')
  if (text.includes('\r') || !text.endsWith('\n')) {
    fail('reviewed inventory must use LF line endings and end with one newline')
  }
  const entries = text.slice(0, -1).split('\n')
  const identifier = /^[A-Za-z_][A-Za-z0-9_]*\/test[A-Za-z0-9_]+$/
  if (entries.length !== testPolicy.expectedCount || entries.some(entry => !identifier.test(entry))) {
    fail(`reviewed inventory must contain exactly ${testPolicy.expectedCount} valid identities`)
  }

  const sorted = [...entries].sort((left, right) =>
    Buffer.compare(Buffer.from(left, 'ascii'), Buffer.from(right, 'ascii')))
  if (entries.some((entry, index) => entry !== sorted[index])) {
    fail('reviewed inventory is not in canonical bytewise order')
  }
  if (new Set(entries).size !== entries.length) {
    fail('reviewed inventory contains a duplicate identity')
  }
  return { entries, digest }
}

function loadReviewMetadata() {
  const policyBytes = regularBytes(policyPath, 'iOS coverage policy', maximumMetadataBytes)
  const policy = parseJSON(policyBytes, 'iOS coverage policy')
  const testPolicy = policy?.test
  if (policy?.schemaVersion !== 2 ||
      testPolicy?.module !== 'QVACiOSSmokeTests' ||
      !Number.isSafeInteger(testPolicy.expectedCount) ||
      testPolicy.expectedCount <= 0 ||
      testPolicy.inventoryPath !== 'tools/ci/ios-smoke-test-inventory.txt' ||
      typeof testPolicy.inventorySHA256 !== 'string' ||
      !/^[0-9a-f]{64}$/.test(testPolicy.inventorySHA256)) {
    fail('iOS coverage policy has unsupported or unsafe test metadata')
  }

  const inventoryBytes = regularBytes(
    reviewedInventoryPath,
    'reviewed iOS test inventory',
    maximumMetadataBytes,
  )
  const inventory = parseInventory(inventoryBytes, testPolicy)
  return {
    module: testPolicy.module,
    expectedCount: testPolicy.expectedCount,
    entries: inventory.entries,
    inventorySHA256: inventory.digest,
  }
}

function escapedRegex(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

function requireExactInventory(actual, expected, label) {
  if (new Set(actual).size !== actual.length) {
    fail(`${label} contains a duplicate test identity`)
  }
  const sorted = [...actual].sort((left, right) =>
    Buffer.compare(Buffer.from(left, 'ascii'), Buffer.from(right, 'ascii')))
  if (JSON.stringify(sorted) !== JSON.stringify(expected)) {
    const expectedSet = new Set(expected)
    const actualSet = new Set(sorted)
    const missing = expected.filter(identity => !actualSet.has(identity))
    const unexpected = sorted.filter(identity => !expectedSet.has(identity))
    fail(`${label} differs from the reviewed inventory; missing=${missing.join(',') || 'none'}; unexpected=${unexpected.join(',') || 'none'}`)
  }
}

function testCaseInventory(log, module, state) {
  const modulePattern = escapedRegex(module)
  const pattern = new RegExp(
    `^Test Case '-\\[${modulePattern}\\.([A-Za-z_][A-Za-z0-9_]*) (test[A-Za-z0-9_]+)\\]' ${state === 'started' ? 'started\\.' : 'passed \\(\\d+(?:\\.\\d+)? seconds\\)\\.'}$`,
    'gm',
  )
  const matches = [...log.matchAll(pattern)]
  const allStateLines = log.match(new RegExp(`^Test Case .* ${state === 'started' ? 'started\\.' : 'passed \\(.* seconds\\)\\.'}$`, 'gm')) ?? []
  if (matches.length !== allStateLines.length) {
    fail(`xcodebuild log contains an unrecognized or out-of-module ${state} test case`)
  }
  return matches.map(match => `${match[1]}/${match[2]}`)
}

function commandFollowingHeader(log, headerPattern, commandPrefix, label) {
  const lines = log.split('\n')
  const headerIndexes = []
  for (const [index, line] of lines.entries()) {
    if (headerPattern.test(line)) headerIndexes.push(index)
  }
  if (headerIndexes.length !== 1) {
    fail(`${label} build header must appear exactly once; observed ${headerIndexes.length}`)
  }
  const nearby = lines.slice(headerIndexes[0] + 1, headerIndexes[0] + 6)
  const commands = nearby.filter(line => line.startsWith(commandPrefix))
  if (commands.length !== 1) fail(`${label} build header has no unique compiler/linker invocation`)
  return commands[0].replaceAll('\\=', '=')
}

function hasToken(command, token) {
  return command.split(/\s+/).includes(token)
}

function requireSwiftThreadSanitizerCompilation(log, target) {
  const targetPattern = escapedRegex(target)
  const header = new RegExp(
    `^SwiftDriver ${targetPattern} normal arm64 com\\.apple\\.xcode\\.tools\\.swift\\.compiler \\(in target '${targetPattern}' from project '[A-Za-z0-9_.-]+'\\)$`,
  )
  const command = commandFollowingHeader(
    log,
    header,
    '    builtin-SwiftDriver -- ',
    `${target} Swift`,
  )
  if (!command.includes('/swiftc ') || !hasToken(command, '-sanitize=thread')) {
    fail(`${target} Swift compiler invocation is not Thread Sanitizer-instrumented`)
  }
  if (!new RegExp(`(?:^|\\s)-module-name ${targetPattern}(?:\\s|$)`).test(command)) {
    fail(`${target} Swift compiler invocation has the wrong module identity`)
  }
  if (!/(?:^|\s)-target arm64-apple-ios\d+(?:\.\d+)*-simulator(?:\s|$)/.test(command)) {
    fail(`${target} Swift compiler invocation is not for the arm64 iOS Simulator`)
  }
}

function requireThreadSanitizerTestLink(log) {
  const header = new RegExp(
    `^Ld .*/${testTarget}\\.xctest/${testTarget} normal \\(in target '${testTarget}' from project '[A-Za-z0-9_.-]+'\\)$`,
  )
  const command = commandFollowingHeader(
    log,
    header,
    '    /',
    `${testTarget} link`,
  )
  if (!command.includes('/clang ') || !hasToken(command, '-fsanitize=thread')) {
    fail(`${testTarget} linker invocation is not Thread Sanitizer-instrumented`)
  }
  if (!/(?:^|\s)-target arm64-apple-ios\d+(?:\.\d+)*-simulator(?:\s|$)/.test(command)) {
    fail(`${testTarget} linker invocation is not for the arm64 iOS Simulator`)
  }
  if (!/(?:^|\s)-framework BareKit(?:\s|$)/.test(command)) {
    fail(`${testTarget} linker invocation does not link the activated BareKit framework`)
  }
  if (!new RegExp(`(?:^|\\s)-o \\S*/${testTarget}\\.xctest/${testTarget}(?:\\s|$)`).test(command)) {
    fail(`${testTarget} linker invocation has the wrong output`)
  }
}

function requireThreadSanitizerRuntimeCopy(log) {
  const runtimePattern = escapedRegex(threadSanitizerRuntime)
  const copyHeader = new RegExp(
    `^Copy \\S*/${testTarget}\\.xctest/Frameworks/${runtimePattern} \\S*/${runtimePattern} \\(in target '${testTarget}' from project '[A-Za-z0-9_.-]+'\\)$`,
    'gm',
  )
  const headers = log.match(copyHeader) ?? []
  if (headers.length !== 1) {
    fail(`${threadSanitizerRuntime} copy step must appear exactly once; observed ${headers.length}`)
  }
  const copyInvocation = new RegExp(
    `^    builtin-copy .*\\S*/${runtimePattern} \\S*/${testTarget}\\.xctest/Frameworks$`,
    'gm',
  )
  const invocations = log.match(copyInvocation) ?? []
  if (invocations.length !== 1) {
    fail(`${threadSanitizerRuntime} was not copied into the XCTest bundle`)
  }
}

function validateThreadSanitizerLog(log, review) {
  if (log.includes('\0')) fail('xcodebuild log contains a NUL byte')

  const successMarkers = log.match(/^\*\* TEST SUCCEEDED \*\*$/gm) ?? []
  if (successMarkers.length !== 1) {
    fail(`xcodebuild must report TEST SUCCEEDED exactly once; observed ${successMarkers.length}`)
  }
  if (!/(?:^|[ \t])-enableThreadSanitizer[ \t]+YES(?:[ \t]|$)/m.test(log)) {
    fail('xcodebuild invocation did not enable Thread Sanitizer')
  }
  const onlyTesting = new RegExp(`-only-testing:${escapedRegex(review.module)}(?:["' \t]|$)`)
  if (!onlyTesting.test(log)) {
    fail(`xcodebuild invocation was not restricted to ${review.module}`)
  }
  requireSwiftThreadSanitizerCompilation(log, clientTarget)
  requireSwiftThreadSanitizerCompilation(log, testTarget)
  requireThreadSanitizerTestLink(log)
  requireThreadSanitizerRuntimeCopy(log)
  if (/ThreadSanitizer:|(?:WARNING|SUMMARY): ThreadSanitizer|ThreadSanitizer is not supported/i.test(log)) {
    fail('Thread Sanitizer reported a diagnostic or was unavailable')
  }
  if (/^Test Case .*\]' (?:failed|skipped) /m.test(log) ||
      /^Test Suite .* failed at /m.test(log) ||
      /^\*\* TEST FAILED \*\*$/m.test(log) ||
      /^Testing failed:/m.test(log) ||
      /Executed 0 tests?/m.test(log) ||
      /Executed \d+ tests?, with [1-9]\d* tests? skipped/m.test(log)) {
    fail('XCTest reported a failure, skip, or empty run')
  }

  const started = testCaseInventory(log, review.module, 'started')
  const passed = testCaseInventory(log, review.module, 'passed')
  if (started.length !== review.expectedCount || passed.length !== review.expectedCount) {
    fail(`expected ${review.expectedCount} started and passed tests; observed started=${started.length} passed=${passed.length}`)
  }
  requireExactInventory(started, review.entries, 'started test inventory')
  requireExactInventory(passed, review.entries, 'passed test inventory')

  const aggregate = new RegExp(
    `^[ \\t]*Executed ${review.expectedCount} tests?, with 0 failures \\(0 unexpected\\)`,
    'm',
  )
  if (!aggregate.test(log)) {
    fail(`XCTest did not report an exact ${review.expectedCount}-test zero-failure aggregate`)
  }
}

function fixtureLog(review, entries = review.entries) {
  const cases = entries.flatMap(identity => {
    const [testClass, method] = identity.split('/')
    return [
      `Test Case '-[${review.module}.${testClass} ${method}]' started.`,
      `Test Case '-[${review.module}.${testClass} ${method}]' passed (0.001 seconds).`,
    ]
  })
  return [
    'Command line invocation:',
    `    /usr/bin/xcodebuild -scheme QVACiOSSmokeHarness-Package -enableThreadSanitizer YES "-only-testing:${review.module}" test`,
    '',
    `SwiftDriver ${clientTarget} normal arm64 com.apple.xcode.tools.swift.compiler (in target '${clientTarget}' from project '${clientTarget}')`,
    '    cd /tmp/qvac/Tests/QVACiOSSmokeHarness/.swiftpm/xcode',
    `    builtin-SwiftDriver -- /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc -module-name ${clientTarget} -sanitize\\=thread -target arm64-apple-ios17.0-simulator -output-file-map /tmp/dd/Objects-normal-tsan/arm64/${clientTarget}-OutputFileMap.json`,
    '',
    `Copy /tmp/dd/Build/Products/Debug-iphonesimulator/${testTarget}.xctest/Frameworks/${threadSanitizerRuntime} /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/clang/16/lib/darwin/${threadSanitizerRuntime} (in target '${testTarget}' from project 'QVACiOSSmokeHarness')`,
    '    cd /tmp/qvac/Tests/QVACiOSSmokeHarness',
    `    builtin-copy -exclude .DS_Store /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/clang/16/lib/darwin/${threadSanitizerRuntime} /tmp/dd/Build/Products/Debug-iphonesimulator/${testTarget}.xctest/Frameworks`,
    '',
    `SwiftDriver ${testTarget} normal arm64 com.apple.xcode.tools.swift.compiler (in target '${testTarget}' from project 'QVACiOSSmokeHarness')`,
    '    cd /tmp/qvac/Tests/QVACiOSSmokeHarness/.swiftpm/xcode',
    `    builtin-SwiftDriver -- /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc -module-name ${testTarget} -sanitize\\=thread -target arm64-apple-ios17.0-simulator -output-file-map /tmp/dd/Objects-normal-tsan/arm64/${testTarget}-OutputFileMap.json`,
    '',
    `Ld /tmp/dd/Build/Products/Debug-iphonesimulator/${testTarget}.xctest/${testTarget} normal (in target '${testTarget}' from project 'QVACiOSSmokeHarness')`,
    '    cd /tmp/qvac/Tests/QVACiOSSmokeHarness',
    `    /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang -target arm64-apple-ios17.0-simulator -bundle -fsanitize\\=thread -framework BareKit -o /tmp/dd/Build/Products/Debug-iphonesimulator/${testTarget}.xctest/${testTarget}`,
    '',
    ...cases,
    `\t Executed ${review.expectedCount} tests, with 0 failures (0 unexpected) in 0.100 seconds`,
    '** TEST SUCCEEDED **',
    '',
  ].join('\n')
}

function expectFailure(action, label, expectedMessage) {
  try {
    action()
  } catch (error) {
    if (expectedMessage && !error.message.includes(expectedMessage)) {
      fail(`${label} failed for the wrong reason: ${error.message}`)
    }
    return
  }
  fail(`self-test accepted ${label}`)
}

function selfTest() {
  const review = loadReviewMetadata()
  const valid = fixtureLog(review)
  validateThreadSanitizerLog(valid, review)

  expectFailure(
    () => validateThreadSanitizerLog(valid.replace('-enableThreadSanitizer YES ', ''), review),
    'a run without Thread Sanitizer',
    'did not enable Thread Sanitizer',
  )
  expectFailure(
    () => validateThreadSanitizerLog(
      valid.replace(`-module-name ${clientTarget} -sanitize\\=thread`, `-module-name ${clientTarget}`),
      review,
    ),
    'a client compiled without Thread Sanitizer',
    `${clientTarget} Swift compiler invocation is not Thread Sanitizer-instrumented`,
  )
  expectFailure(
    () => validateThreadSanitizerLog(
      valid.replace(`-module-name ${testTarget} -sanitize\\=thread`, `-module-name ${testTarget}`),
      review,
    ),
    'a test target compiled without Thread Sanitizer',
    `${testTarget} Swift compiler invocation is not Thread Sanitizer-instrumented`,
  )
  expectFailure(
    () => validateThreadSanitizerLog(
      valid.replace(
        `-module-name ${clientTarget} -sanitize\\=thread -target arm64-apple-ios17.0-simulator`,
        `-module-name ${clientTarget} -sanitize\\=thread -target arm64-apple-ios17.0`,
      ),
      review,
    ),
    'a client compiled for a device instead of the simulator',
    `${clientTarget} Swift compiler invocation is not for the arm64 iOS Simulator`,
  )
  expectFailure(
    () => validateThreadSanitizerLog(
      valid.replace('-bundle -fsanitize\\=thread -framework BareKit', '-bundle -framework BareKit'),
      review,
    ),
    'a test bundle linked without Thread Sanitizer',
    `${testTarget} linker invocation is not Thread Sanitizer-instrumented`,
  )
  expectFailure(
    () => validateThreadSanitizerLog(
      valid.replace('-framework BareKit -o ', '-o '),
      review,
    ),
    'a test bundle not linked to BareKit',
    'does not link the activated BareKit framework',
  )
  expectFailure(
    () => validateThreadSanitizerLog(
      valid.replaceAll(threadSanitizerRuntime, 'libclang_rt.asan_iossim_dynamic.dylib'),
      review,
    ),
    'a run without the iOS Simulator TSan runtime',
    `${threadSanitizerRuntime} copy step must appear exactly once`,
  )
  expectFailure(
    () => validateThreadSanitizerLog(
      valid.replace(new RegExp(`^    builtin-copy .*${escapedRegex(threadSanitizerRuntime)}.*$`, 'm'), ''),
      review,
    ),
    'a named TSan runtime that was not embedded',
    `${threadSanitizerRuntime} was not copied into the XCTest bundle`,
  )
  expectFailure(
    () => validateThreadSanitizerLog(valid.replace(`-only-testing:${review.module}`, '-only-testing:OtherTests'), review),
    'a run with the wrong test filter',
    `was not restricted to ${review.module}`,
  )
  expectFailure(
    () => validateThreadSanitizerLog(valid.replace('** TEST SUCCEEDED **', 'WARNING: ThreadSanitizer: data race\n** TEST SUCCEEDED **'), review),
    'a sanitizer diagnostic',
    'reported a diagnostic',
  )
  expectFailure(
    () => validateThreadSanitizerLog(valid.replace('** TEST SUCCEEDED **\n', ''), review),
    'a missing success marker',
    'TEST SUCCEEDED exactly once',
  )

  const first = review.entries[0]
  const [firstClass, firstMethod] = first.split('/')
  const passLine = `Test Case '-[${review.module}.${firstClass} ${firstMethod}]' passed (0.001 seconds).`
  expectFailure(
    () => validateThreadSanitizerLog(valid.replace(passLine, `Test Case '-[${review.module}.${firstClass} ${firstMethod}]' skipped (0.001 seconds).`), review),
    'a skipped reviewed test',
    'failure, skip, or empty run',
  )
  expectFailure(
    () => validateThreadSanitizerLog(valid.replace(passLine, `Test Case '-[${review.module}.${firstClass} ${firstMethod}]' failed (0.001 seconds).`), review),
    'a failed reviewed test',
    'failure, skip, or empty run',
  )

  const substituted = [...review.entries]
  substituted[substituted.length - 1] = 'SubstitutedTests/testUnexpected'
  expectFailure(
    () => validateThreadSanitizerLog(fixtureLog(review, substituted), review),
    'an equal-count identity substitution',
    'differs from the reviewed inventory',
  )

  const duplicate = [...review.entries]
  duplicate[duplicate.length - 1] = duplicate[0]
  expectFailure(
    () => validateThreadSanitizerLog(fixtureLog(review, duplicate), review),
    'duplicate execution with one missing test',
    'duplicate test identity',
  )

  const missing = fixtureLog(review).replace(passLine, '')
  expectFailure(
    () => validateThreadSanitizerLog(missing, review),
    'a missing pass record',
    `expected ${review.expectedCount} started and passed tests`,
  )

  const badHashPolicy = {
    expectedCount: review.expectedCount,
    inventorySHA256: '0'.repeat(64),
  }
  const realInventory = regularBytes(
    reviewedInventoryPath,
    'reviewed iOS test inventory',
    maximumMetadataBytes,
  )
  expectFailure(
    () => parseInventory(realInventory, badHashPolicy),
    'reviewed inventory hash drift',
    'inventory SHA-256',
  )

  console.log(`[ios-test-log-self-test] exact ${review.expectedCount}-test inventory, client/test compile instrumentation, test-link instrumentation, iOS Simulator TSan runtime copy, test filtering, sanitizer diagnostics, failures, skips, omissions, substitutions, duplicates, and hash drift are verified`)
}

try {
  const args = process.argv.slice(2)
  if (args.length === 1 && args[0] === '--self-test') {
    selfTest()
  } else if (args.length === 2 && args[0] === '--thread-sanitizer') {
    const review = loadReviewMetadata()
    const logBytes = regularBytes(resolve(args[1]), 'xcodebuild test log', maximumLogBytes)
    const log = strictUTF8(logBytes, 'xcodebuild test log')
    validateThreadSanitizerLog(log, review)
    console.log(`[ios-test-log] PASS mode=thread-sanitizer module=${review.module} tests=${review.expectedCount} inventory-sha256=${review.inventorySHA256} log-bytes=${logBytes.length} log-sha256=${sha256(logBytes)}`)
  } else {
    fail('usage: verify-ios-test-log.mjs --thread-sanitizer <xcodebuild.log> | --self-test')
  }
} catch (error) {
  process.stderr.write(`${error.message}\n`)
  process.exitCode = 1
}
