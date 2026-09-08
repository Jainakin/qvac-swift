#!/usr/bin/env node

import { createHash } from 'node:crypto'
import {
  copyFileSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from 'node:fs'
import { basename, dirname, join, resolve } from 'node:path'
import { tmpdir } from 'node:os'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const scriptDirectory = dirname(fileURLToPath(import.meta.url))
const repositoryRoot = resolve(scriptDirectory, '../..')
const policyPath = join(scriptDirectory, 'ios-native-stress-policy.json')
const maximumLogBytes = 64 * 1024 * 1024
const maximumMetadataBytes = 1024 * 1024

function fail(message) {
  throw new Error(`[ios-native-stress-evidence] ${message}`)
}

function sha256(bytes) {
  return createHash('sha256').update(bytes).digest('hex')
}

function regularFile(path, label, maximumBytes = Number.MAX_SAFE_INTEGER) {
  let stat
  try { stat = lstatSync(path) } catch (error) { fail(`cannot inspect ${label}: ${error.message}`) }
  if (stat.isSymbolicLink() || !stat.isFile()) fail(`${label} must be a regular, non-symlink file`)
  if (stat.size > maximumBytes) fail(`${label} exceeds ${maximumBytes} bytes`)
  return readFileSync(path)
}

function realDirectory(path, label) {
  let stat
  try { stat = lstatSync(path) } catch (error) { fail(`cannot inspect ${label}: ${error.message}`) }
  if (stat.isSymbolicLink() || !stat.isDirectory()) {
    fail(`${label} must be a real, non-symlink directory`)
  }
}

function parseJSON(bytes, label) {
  try { return JSON.parse(bytes.toString('utf8')) } catch (error) { fail(`invalid ${label}: ${error.message}`) }
}

function loadPolicy() {
  const policy = parseJSON(regularFile(policyPath, 'native stress policy', maximumMetadataBytes), 'native stress policy')
  if (policy.schemaVersion !== 1 || policy.scheme !== 'QVACChat-NativeStress'
      || policy.testModule !== 'QVACChatNativeStressTests'
      || typeof policy.patchMarker !== 'string' || policy.patchMarker.length === 0) {
    fail('native stress policy has unsupported identity metadata')
  }
  if (typeof policy.echo?.testIdentity !== 'string'
      || !Number.isSafeInteger(policy.echo?.transferredBytes)
      || !Number.isSafeInteger(policy.echo?.chunkBytes)
      || !Number.isSafeInteger(policy.echo?.uniqueChunkCount)
      || !/^[0-9a-f]{64}$/.test(policy.echo?.sha256)
      || policy.echo?.minimumNativeWriteWouldBlockCount !== 1
      || !Number.isSafeInteger(policy.echo?.raceIterations)
      || !Number.isSafeInteger(policy.echo?.concurrentCloseCallersPerIteration)
      || policy.echo?.requiredCloseReadOverlapIterations !== policy.echo?.raceIterations
      || policy.echo?.requiredFollowerCloseWaitersPerIteration
        !== policy.echo?.concurrentCloseCallersPerIteration - 1) {
    fail('native stress policy has invalid echo/race metadata')
  }
  return policy
}

function loadInventory(policy, mode) {
  const entry = mode === 'regular' ? policy.regular : policy.threadSanitizer
  if (!entry || !Number.isSafeInteger(entry.expectedCount) || entry.expectedCount < 1
      || !/^[0-9a-f]{64}$/.test(entry.inventorySHA256)) {
    fail(`${mode} inventory policy is invalid`)
  }
  const path = resolve(repositoryRoot, entry.inventoryPath)
  if (!path.startsWith(`${repositoryRoot}/`)) fail(`${mode} inventory escapes the repository`)
  const bytes = regularFile(path, `${mode} inventory`, maximumMetadataBytes)
  if (sha256(bytes) !== entry.inventorySHA256) fail(`${mode} inventory SHA-256 does not match policy`)
  const entries = bytes.toString('utf8').split('\n').filter(Boolean)
  if (entries.length !== entry.expectedCount || new Set(entries).size !== entries.length) {
    fail(`${mode} inventory count or uniqueness differs from policy`)
  }
  if (entries.some(value => !/^[A-Za-z_][A-Za-z0-9_]*\/test[A-Za-z0-9_]+$/.test(value))) {
    fail(`${mode} inventory contains an invalid XCTest identity`)
  }
  return { entries, ...entry }
}

function run(command, args, label, maximumBytes = 16 * 1024 * 1024) {
  const result = spawnSync(command, args, { encoding: 'utf8', maxBuffer: maximumBytes })
  if (result.status !== 0) {
    fail(`${label} failed: ${(result.stderr || result.stdout || `status ${result.status}`).trim()}`)
  }
  return result.stdout
}

function collectTestCases(value, output = []) {
  if (Array.isArray(value)) {
    for (const child of value) collectTestCases(child, output)
  } else if (value && typeof value === 'object') {
    if (value.nodeType === 'Test Case') output.push(value)
    for (const child of Object.values(value)) collectTestCases(child, output)
  }
  return output
}

function normalizeTestIdentity(node) {
  if (typeof node.nodeIdentifier !== 'string') fail('test case lacks nodeIdentifier')
  return normalizeIdentity(node.nodeIdentifier)
}

function normalizeIdentity(value) {
  if (typeof value !== 'string') fail('test identity must be a string')
  return value.replace(/\(\)$/, '')
}

function validateResult(result, inventory, expectedPlatform) {
  const cases = collectTestCases(result)
  const identities = cases.map(normalizeTestIdentity).sort()
  const expected = [...inventory.entries].sort()
  if (JSON.stringify(identities) !== JSON.stringify(expected)) {
    fail(`executed tests differ from reviewed inventory: ${JSON.stringify(identities)}`)
  }
  if (cases.some(test => test.result !== 'Passed')) fail('one or more reviewed tests did not pass')
  if (!Array.isArray(result.devices) || result.devices.length !== 1) {
    fail('xcresult must describe exactly one test device')
  }
  const device = result.devices[0]
  const isSimulator = device.platform === 'iOS Simulator'
  if ((expectedPlatform === 'simulator') !== isSimulator) {
    fail(`xcresult platform ${device.platform} does not match requested ${expectedPlatform}`)
  }
  if (expectedPlatform === 'device' && device.platform !== 'iOS') {
    fail(`physical evidence must report platform iOS, got ${device.platform}`)
  }
  if (typeof device.deviceId !== 'string' || device.deviceId.length === 0
      || typeof device.osVersion !== 'string' || !String(device.architecture).startsWith('arm64')) {
    fail('xcresult device identity is incomplete or not arm64')
  }
  return { cases, device }
}

function validateLog(log, mode, inventory, policy) {
  if ((log.match(/\*\* TEST(?: EXECUTE)? SUCCEEDED \*\*/g) || []).length !== 1) {
    fail('xcodebuild log must contain exactly one successful test-execution marker')
  }
  if (/^Test Case .* (?:failed|skipped) /m.test(log)
      || /^Testing failed:/m.test(log)
      || /\*\* TEST (?:FAILED|EXECUTE FAILED) \*\*/.test(log)
      || /Executed 0 tests?/m.test(log)) {
    fail('xcodebuild log contains a failure, skip, or empty run')
  }
  if (!log.includes(`-scheme ${policy.scheme}`) && !log.includes(`"${policy.scheme}"`)) {
    fail(`xcodebuild log does not select ${policy.scheme}`)
  }
  if (!log.includes(`-only-testing:${policy.testModule}`)) {
    fail(`xcodebuild log is not restricted to ${policy.testModule}`)
  }
  if (!log.includes('QVAC_NATIVE_STRESS_TESTING')) {
    fail('native stress test-only compilation condition is absent')
  }
  if (mode === 'thread-sanitizer') {
    const race = inventory.entries[0]
    if (!log.includes(`-only-testing:${policy.testModule}/${race}`)) {
      fail('Thread Sanitizer run is not restricted to the reviewed native race test')
    }
    if (!/-enableThreadSanitizer\s+YES/.test(log)) fail('Thread Sanitizer is not enabled')
    validateThreadSanitizedSwiftTarget(log, 'QVACClient', 'QVACClient')
    validateThreadSanitizedSwiftTarget(
      log,
      'QVACChatNativeStressTests',
      'QVACChat',
    )
    if (!log.includes('libclang_rt.tsan_iossim_dynamic.dylib')) {
      fail('iOS Simulator Thread Sanitizer runtime was not embedded')
    }
    if (/ThreadSanitizer:|(?:WARNING|SUMMARY): ThreadSanitizer|ThreadSanitizer is not supported/i.test(log)) {
      fail('Thread Sanitizer reported a diagnostic or was unavailable')
    }
  } else if (/-enableThreadSanitizer\s+YES/.test(log)) {
    fail('regular memory evidence unexpectedly enabled Thread Sanitizer')
  }
}

function validateThreadSanitizedSwiftTarget(log, target, project) {
  const escapedTarget = target.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  const escapedProject = project.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  const header = new RegExp(
    `^SwiftDriver ${escapedTarget} normal arm64 .* \\(in target '${escapedTarget}' from project '${escapedProject}'\\)$`,
  )
  const lines = log.split('\n')
  const indexes = lines.flatMap((line, index) => header.test(line) ? [index] : [])
  if (indexes.length !== 1) {
    fail(`expected exactly one Swift driver invocation for Thread Sanitizer target ${target}`)
  }
  const command = lines.slice(indexes[0] + 1, indexes[0] + 5)
    .find(line => /^\s+builtin-SwiftDriver -- /.test(line))
  if (!command
      || !new RegExp(`(?:^|\\s)-module-name ${escapedTarget}(?:\\s|$)`).test(command)
      || !/(?:^|\s)-sanitize(?:\\?=|\s+)thread(?:\s|$)/.test(command)
      || !command.includes('/Objects-normal-tsan/')) {
    fail(`Swift target ${target} is not provably Thread Sanitizer-instrumented`)
  }
}

function validateSourceState(suppliedSHA, repositorySHA, status) {
  if (suppliedSHA !== repositorySHA) {
    fail(`supplied source SHA ${suppliedSHA} differs from repository HEAD ${repositorySHA}`)
  }
  if (status.length !== 0) {
    fail('repository contains tracked or untracked source changes; evidence is calibration-only')
  }
}

function findBareKitBinaries(root) {
  const found = []
  function visit(path) {
    const stat = lstatSync(path)
    if (stat.isSymbolicLink()) {
      if (basename(path) === 'BareKit' || basename(path) === 'BareKit.framework') {
        fail(`DerivedData contains a symlinked BareKit product: ${path}`)
      }
      return
    }
    if (!stat.isDirectory()) return
    for (const name of readdirSync(path)) {
      const child = join(path, name)
      const childStat = lstatSync(child)
      if (childStat.isSymbolicLink()) {
        if (name === 'BareKit' || name === 'BareKit.framework') {
          fail(`DerivedData contains a symlinked BareKit product: ${child}`)
        }
        continue
      }
      if (childStat.isDirectory()) visit(child)
      else if (name === 'BareKit' && basename(dirname(child)) === 'BareKit.framework') found.push(child)
    }
  }
  visit(root)
  return found
}

function candidateBinary(candidate, platform) {
  realDirectory(candidate, 'BareKit candidate')
  if (basename(candidate) !== 'BareKit.xcframework') {
    fail('BareKit candidate must be named BareKit.xcframework')
  }
  const info = parseJSON(Buffer.from(run(
    'plutil',
    ['-convert', 'json', '-o', '-', join(candidate, 'Info.plist')],
    'BareKit XCFramework metadata conversion',
    maximumMetadataBytes,
  )), 'BareKit XCFramework metadata')
  if (info.XCFrameworkFormatVersion !== '1.0' || !Array.isArray(info.AvailableLibraries)) {
    fail('BareKit candidate has invalid XCFramework metadata')
  }
  const libraries = info.AvailableLibraries.filter(library => {
    const isSimulator = library?.SupportedPlatformVariant === 'simulator'
    return library?.SupportedPlatform === 'ios'
      && Array.isArray(library.SupportedArchitectures)
      && library.SupportedArchitectures.includes('arm64')
      && ((platform === 'simulator') === isSimulator)
  })
  if (libraries.length !== 1) {
    fail(`BareKit candidate has ${libraries.length} matching arm64 ${platform} slices`)
  }
  const library = libraries[0]
  if (!/^[A-Za-z0-9_.-]+$/.test(library.LibraryIdentifier)
      || library.LibraryPath !== 'BareKit.framework'
      || library.BinaryPath !== 'BareKit.framework/BareKit') {
    fail('BareKit candidate slice paths differ from the reviewed layout')
  }
  const slice = join(candidate, library.LibraryIdentifier)
  realDirectory(slice, `BareKit ${platform} candidate slice`)
  const framework = join(slice, library.LibraryPath)
  realDirectory(framework, `BareKit ${platform} candidate framework`)
  const binary = join(slice, library.BinaryPath)
  return { binary, bytes: regularFile(binary, `BareKit ${platform} candidate binary`) }
}

function normalizeDeviceSigningFields(bytes) {
  const normalized = Buffer.from(bytes)
  let machOffset = 0
  let sliceSize = normalized.length
  if (normalized.length >= 28 && normalized.readUInt32BE(0) === 0xcafebabe) {
    if (normalized.readUInt32BE(4) !== 1
        || normalized.readUInt32BE(8) !== 0x0100000c) {
      fail('device BareKit must be a single-arm64 universal Mach-O')
    }
    machOffset = normalized.readUInt32BE(16)
    sliceSize = normalized.readUInt32BE(20)
    if (machOffset < 28 || sliceSize < 32 || machOffset + sliceSize > normalized.length) {
      fail('device BareKit has an invalid universal arm64 slice extent')
    }
  }
  if (machOffset + 32 > normalized.length
      || normalized.readUInt32LE(machOffset) !== 0xfeedfacf
      || normalized.readUInt32LE(machOffset + 4) !== 0x0100000c) {
    fail('device BareKit has an unsupported Mach-O header')
  }
  const commandCount = normalized.readUInt32LE(machOffset + 16)
  const commandBytes = normalized.readUInt32LE(machOffset + 20)
  let commandOffset = machOffset + 32
  const commandEnd = commandOffset + commandBytes
  const sliceEnd = machOffset + sliceSize
  if (commandEnd > sliceEnd) fail('device BareKit load commands exceed the arm64 slice')
  let linkedit
  for (let index = 0; index < commandCount; index++) {
    if (commandOffset + 8 > commandEnd) fail('device BareKit has truncated load commands')
    const command = normalized.readUInt32LE(commandOffset)
    const commandSize = normalized.readUInt32LE(commandOffset + 4)
    if (commandSize < 8 || commandOffset + commandSize > commandEnd) {
      fail('device BareKit has an invalid load command')
    }
    if (command === 0x19) {
      if (commandSize < 72) fail('device BareKit has a truncated LC_SEGMENT_64 command')
      const segmentName = normalized.subarray(commandOffset + 8, commandOffset + 24)
        .toString('ascii').replace(/\0.*$/, '')
      if (segmentName === '__LINKEDIT') {
        if (linkedit) fail('device BareKit has multiple __LINKEDIT segments')
        const virtualSize = normalized.readBigUInt64LE(commandOffset + 32)
        const fileOffset = normalized.readBigUInt64LE(commandOffset + 40)
        const fileSize = normalized.readBigUInt64LE(commandOffset + 48)
        if (virtualSize < fileSize || virtualSize % 0x4000n !== 0n
            || fileOffset + fileSize > BigInt(sliceSize)) {
          fail('device BareKit has invalid __LINKEDIT extents')
        }
        linkedit = { virtualSize, fileOffset, fileSize }
        // Removing an Xcode device signature demonstrably leaves only this
        // page-rounded virtual extent changed. File size and every other byte
        // remain part of the exact candidate identity.
        normalized.fill(0, commandOffset + 32, commandOffset + 40)
      }
    }
    commandOffset += commandSize
  }
  if (commandOffset !== commandEnd) fail('device BareKit load-command size is inconsistent')
  if (!linkedit) fail('device BareKit must contain exactly one __LINKEDIT segment')
  return { normalized, linkedit }
}

function validateDeviceSigningTransformation(
  candidateBytes,
  unsignedEmbeddedBytes,
  signedEmbeddedLength,
  label,
) {
  if (!Number.isSafeInteger(signedEmbeddedLength)
      || signedEmbeddedLength <= unsignedEmbeddedBytes.length) {
    fail(`signed ${label} does not contain a removable Mach-O signature`)
  }
  if (unsignedEmbeddedBytes.length !== candidateBytes.length) {
    fail(`signature-stripped ${label} length differs from the selected candidate`)
  }
  const candidate = normalizeDeviceSigningFields(candidateBytes)
  const embedded = normalizeDeviceSigningFields(unsignedEmbeddedBytes)
  const signatureByteCount = BigInt(signedEmbeddedLength - unsignedEmbeddedBytes.length)
  const pageBytes = 16n * 1024n
  const expectedVirtualGrowth = ((signatureByteCount + pageBytes - 1n) / pageBytes) * pageBytes
  const virtualGrowth = embedded.linkedit.virtualSize - candidate.linkedit.virtualSize
  if (embedded.linkedit.fileOffset !== candidate.linkedit.fileOffset
      || embedded.linkedit.fileSize !== candidate.linkedit.fileSize
      || virtualGrowth !== expectedVirtualGrowth
      || !embedded.normalized.equals(candidate.normalized)) {
    fail(`signed ${label} differs from the selected candidate outside exact signing fields`)
  }
}

function validateResignedDeviceBinary(candidateBytes, binary) {
  run('codesign', ['--verify', '--strict', dirname(binary)], 'embedded BareKit signature verification')
  const signedBytes = regularFile(binary, 'signed embedded BareKit')
  const temporary = mkdtempSync(join(tmpdir(), 'qvac-barekit-unsign.'))
  try {
    const unsignedCopy = join(temporary, 'BareKit')
    copyFileSync(binary, unsignedCopy)
    run('codesign', ['--remove-signature', unsignedCopy], 'embedded BareKit signature removal')
    const unsignedBytes = regularFile(unsignedCopy, 'unsigned embedded BareKit')
    validateDeviceSigningTransformation(
      candidateBytes,
      unsignedBytes,
      signedBytes.length,
      `built product ${binary}`,
    )
  } finally {
    rmSync(temporary, { recursive: true, force: true })
  }
}

function validateEmbeddedCandidate(candidate, derivedData, platform, patchMarker) {
  const selected = candidateBinary(candidate, platform)
  if (!selected.bytes.includes(Buffer.from(patchMarker))) fail('candidate binary lacks the required patch marker')
  const header = join(dirname(selected.binary), 'Headers', 'BareKit.h')
  const headerText = regularFile(header, 'BareKit candidate header', maximumMetadataBytes).toString('utf8')
  if (!headerText.includes('readWithError:') || !headerText.includes('BareKitQVACPatchLevel')) {
    fail('candidate header lacks the checked read API or patch-level export')
  }
  const expectedSHA256 = sha256(selected.bytes)
  const products = join(derivedData, 'Build', 'Products')
  realDirectory(products, 'DerivedData products')
  const embedded = findBareKitBinaries(products)
  if (embedded.length < 2) fail('DerivedData does not contain app-hosted BareKit products')
  let exactCount = 0
  let resignedCount = 0
  for (const binary of embedded) {
    const bytes = regularFile(binary, 'embedded BareKit binary')
    const isAppEmbedded = (
      (binary.includes('.app/') || binary.includes('.xctest/'))
        && binary.includes('/Frameworks/')
    )
    if (platform === 'device' && isAppEmbedded) {
      validateResignedDeviceBinary(selected.bytes, binary)
      resignedCount += 1
    } else if (sha256(bytes) === expectedSHA256) {
      exactCount += 1
    } else {
      fail(`built product does not contain the selected candidate: ${binary}`)
    }
  }
  if (exactCount < 1) fail('built products contain no byte-exact unsigned BareKit candidate')
  if (platform === 'device' && resignedCount < 1) {
    fail('physical-device products contain no strictly signed app-embedded BareKit candidate')
  }
  return { expectedSHA256, embeddedCount: embedded.length, exactCount, resignedCount }
}

function leastSquaresSlope(samples) {
  const originX = samples[0].transferredBytes
  const originY = samples[0].physicalFootprintBytes
  const points = samples.map(sample => ({
    x: sample.transferredBytes - originX,
    y: sample.physicalFootprintBytes - originY,
  }))
  const meanX = points.reduce((sum, point) => sum + point.x, 0) / points.length
  const meanY = points.reduce((sum, point) => sum + point.y, 0) / points.length
  const numerator = points.reduce(
    (sum, point) => sum + (point.x - meanX) * (point.y - meanY),
    0,
  )
  const denominator = points.reduce(
    (sum, point) => sum + (point.x - meanX) * (point.x - meanX),
    0,
  )
  return Math.max(0, numerator / denominator)
}

function validateMemoryEvidence(evidence, expected) {
  for (const field of [
    'transferredBytes', 'sha256', 'warmupBytes', 'maximumRetainedGrowthBytes',
    'maximumFootprintBytesPerTransferredByte',
  ]) {
    if (evidence[field] !== expected[field]) fail(`memory evidence ${field} differs from policy`)
  }
  if (!Array.isArray(evidence.samples) || evidence.samples.length !== expected.sampleCount) {
    fail('memory evidence sample count differs from policy')
  }
  evidence.samples.forEach((sample, index) => {
    if (sample.transferredBytes !== (index + 1) * expected.sampleIntervalBytes
        || !Number.isSafeInteger(sample.physicalFootprintBytes)
        || sample.physicalFootprintBytes <= 0) {
      fail(`memory evidence sample ${index} is invalid`)
    }
  })
  const first = evidence.samples[0].physicalFootprintBytes
  const last = evidence.samples.at(-1).physicalFootprintBytes
  const retainedGrowth = Math.max(0, last - first)
  const slope = leastSquaresSlope(evidence.samples)
  const slopeTolerance = Math.max(1e-12, Math.abs(slope) * 1e-12)
  if (evidence.observedRetainedGrowthBytes !== retainedGrowth) {
    fail('reported retained growth does not match the independently recomputed value')
  }
  if (!Number.isFinite(evidence.observedFootprintBytesPerTransferredByte)
      || Math.abs(evidence.observedFootprintBytesPerTransferredByte - slope) > slopeTolerance) {
    fail('reported footprint slope does not match the independently recomputed value')
  }
  if (retainedGrowth > expected.maximumRetainedGrowthBytes
      || slope > expected.maximumFootprintBytesPerTransferredByte) {
    fail('memory evidence exceeds its retained-growth or slope ceiling')
  }
  return evidence
}

function exportedJSONAttachment(xcresult, testIdentity, expectedName, label) {
  const exportDirectory = mkdtempSync(join(tmpdir(), 'qvac-native-attachments.'))
  try {
    run('xcrun', [
      'xcresulttool', 'export', 'attachments', '--path', xcresult,
      '--output-path', exportDirectory,
    ], 'xcresult attachment export')
    const manifest = parseJSON(
      regularFile(join(exportDirectory, 'manifest.json'), 'attachment manifest', maximumMetadataBytes),
      'attachment manifest',
    )
    if (!Array.isArray(manifest)) fail('attachment manifest must be an array')
    const matching = manifest.filter(entry => typeof entry?.testIdentifier === 'string'
      && normalizeIdentity(entry.testIdentifier) === testIdentity)
    if (matching.length !== 1 || matching[0].attachments?.length !== 1) {
      fail(`${label} test must retain exactly one evidence attachment`)
    }
    const attachment = matching[0].attachments[0]
    const fileName = attachment.exportedFileName
    if (basename(fileName) !== fileName) fail('attachment manifest contains an unsafe file name')
    const humanName = attachment.suggestedHumanReadableName
    if (typeof humanName !== 'string'
        || !humanName.startsWith(expectedName.replace(/\.json$/, '_'))
        || !humanName.endsWith('.json')) {
      fail(`${label} attachment has an unexpected human-readable name`)
    }
    return parseJSON(
      regularFile(join(exportDirectory, fileName), `${label} evidence attachment`, maximumMetadataBytes),
      `${label} evidence attachment`,
    )
  } finally {
    rmSync(exportDirectory, { recursive: true, force: true })
  }
}

function validateTrafficEvidence(evidence, expected) {
  for (const field of [
    'transferredBytes', 'sha256', 'chunkBytes', 'uniqueChunkCount',
    'raceIterations', 'concurrentCloseCallersPerIteration',
  ]) {
    if (evidence[field] !== expected[field]) fail(`traffic evidence ${field} differs from policy`)
  }
  if (!Number.isSafeInteger(evidence.nativeWriteWouldBlockCount)
      || evidence.nativeWriteWouldBlockCount < expected.minimumNativeWriteWouldBlockCount) {
    fail('traffic evidence did not observe native write backpressure')
  }
  if (!Array.isArray(evidence.raceObservedBytes)
      || evidence.raceObservedBytes.length !== expected.raceIterations
      || evidence.raceObservedBytes.some(value => !Number.isSafeInteger(value) || value <= 0)) {
    fail('traffic evidence does not contain positive byte counts for every close/read race')
  }
  if (!Array.isArray(evidence.raceCloseReadOverlaps)
      || evidence.raceCloseReadOverlaps.length !== expected.requiredCloseReadOverlapIterations
      || evidence.raceCloseReadOverlaps.some(value => value !== true)) {
    fail('traffic evidence does not prove native close/read overlap in every race iteration')
  }
  if (!Array.isArray(evidence.raceObservedFollowerCloseWaiterCounts)
      || evidence.raceObservedFollowerCloseWaiterCounts.length !== expected.raceIterations
      || evidence.raceObservedFollowerCloseWaiterCounts.some(
        value => value !== expected.requiredFollowerCloseWaitersPerIteration,
      )) {
    fail('traffic evidence does not prove every follower close was waiting before barrier release')
  }
  return evidence
}

function validateTrafficAttachment(xcresult, policy) {
  return validateTrafficEvidence(
    exportedJSONAttachment(
      xcresult,
      policy.echo.testIdentity,
      'native-ipc-backpressure-race.json',
      'traffic',
    ),
    policy.echo,
  )
}

function validateMemoryAttachment(xcresult, policy) {
  return validateMemoryEvidence(
    exportedJSONAttachment(
      xcresult,
      policy.memory.testIdentity,
      'native-ipc-memory-plateau.json',
      'memory',
    ),
    policy.memory,
  )
}

function syntheticResult(entries, result = 'Passed', platform = 'iOS Simulator') {
  return {
    devices: [{
      architecture: 'arm64', deviceId: 'SIM-1', deviceName: 'iPhone', osVersion: '17.0', platform,
    }],
    testNodes: entries.map(nodeIdentifier => ({ nodeType: 'Test Case', nodeIdentifier, result })),
  }
}

function expectFailure(action, label) {
  try { action() } catch { return }
  fail(`self-test accepted ${label}`)
}

function writeSyntheticCandidate(root, { includeDevice = true, patched = true } = {}) {
  const candidate = join(root, 'BareKit.xcframework')
  const simulatorLibrary = {
    BinaryPath: 'BareKit.framework/BareKit',
    LibraryIdentifier: 'ios-arm64-simulator',
    LibraryPath: 'BareKit.framework',
    SupportedArchitectures: ['arm64'],
    SupportedPlatform: 'ios',
    SupportedPlatformVariant: 'simulator',
  }
  const deviceLibrary = {
    BinaryPath: 'BareKit.framework/BareKit',
    LibraryIdentifier: 'ios-arm64',
    LibraryPath: 'BareKit.framework',
    SupportedArchitectures: ['arm64'],
    SupportedPlatform: 'ios',
  }
  mkdirSync(candidate, { recursive: true })
  writeFileSync(join(candidate, 'Info.plist'), JSON.stringify({
    AvailableLibraries: includeDevice ? [simulatorLibrary, deviceLibrary] : [simulatorLibrary],
    CFBundlePackageType: 'XFWK',
    XCFrameworkFormatVersion: '1.0',
  }))
  for (const library of includeDevice ? [simulatorLibrary, deviceLibrary] : [simulatorLibrary]) {
    const framework = join(candidate, library.LibraryIdentifier, library.LibraryPath)
    mkdirSync(join(framework, 'Headers'), { recursive: true })
    writeFileSync(
      join(framework, 'Headers', 'BareKit.h'),
      patched ? 'readWithError: BareKitQVACPatchLevel' : 'legacyRead',
    )
    writeFileSync(
      join(candidate, library.LibraryIdentifier, library.BinaryPath),
      patched ? `synthetic ${library.LibraryIdentifier} qvac-bare-kit-2.3.0-ipc-hardening-1` : 'synthetic historical r1',
    )
  }
  return candidate
}

function writeSyntheticEmbeddedProducts(root, bytes) {
  const products = join(root, 'Build', 'Products')
  const paths = [
    join(products, 'Debug-iphonesimulator', 'PackageFrameworks', 'BareKit.framework', 'BareKit'),
    join(products, 'Debug-iphonesimulator', 'QVACChat-iOS.app', 'Frameworks', 'BareKit.framework', 'BareKit'),
  ]
  for (const path of paths) {
    mkdirSync(dirname(path), { recursive: true })
    writeFileSync(path, bytes)
  }
  return paths
}

function syntheticDeviceMachO(linkeditVirtualSize) {
  const machOffset = 32
  const sliceSize = 20 * 1024
  const bytes = Buffer.alloc(machOffset + sliceSize)
  bytes.writeUInt32BE(0xcafebabe, 0)
  bytes.writeUInt32BE(1, 4)
  bytes.writeUInt32BE(0x0100000c, 8)
  bytes.writeUInt32BE(0, 12)
  bytes.writeUInt32BE(machOffset, 16)
  bytes.writeUInt32BE(sliceSize, 20)
  bytes.writeUInt32BE(14, 24)
  bytes.writeUInt32LE(0xfeedfacf, machOffset)
  bytes.writeUInt32LE(0x0100000c, machOffset + 4)
  bytes.writeUInt32LE(6, machOffset + 12)
  bytes.writeUInt32LE(1, machOffset + 16)
  bytes.writeUInt32LE(72, machOffset + 20)
  const command = machOffset + 32
  bytes.writeUInt32LE(0x19, command)
  bytes.writeUInt32LE(72, command + 4)
  bytes.write('__LINKEDIT', command + 8, 'ascii')
  bytes.writeBigUInt64LE(BigInt(linkeditVirtualSize), command + 32)
  bytes.writeBigUInt64LE(4096n, command + 40)
  bytes.writeBigUInt64LE(8192n, command + 48)
  return bytes
}

function selfTest() {
  const policy = loadPolicy()
  const regular = loadInventory(policy, 'regular')
  validateResult(syntheticResult(regular.entries), regular, 'simulator')
  expectFailure(
    () => validateResult(syntheticResult(regular.entries.slice(1)), regular, 'simulator'),
    'an omitted reviewed test',
  )
  expectFailure(
    () => validateResult(syntheticResult(regular.entries, 'Skipped'), regular, 'simulator'),
    'a skipped reviewed test',
  )
  expectFailure(
    () => validateResult(syntheticResult(regular.entries, 'Passed', 'iOS'), regular, 'simulator'),
    'a physical result presented as Simulator evidence',
  )
  const regularLog = [
    `xcodebuild -scheme ${policy.scheme}`,
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) QVAC_NATIVE_STRESS_TESTING',
    `-only-testing:${policy.testModule}`,
    '** TEST SUCCEEDED **',
  ].join('\n')
  validateLog(regularLog, 'regular', regular, policy)
  expectFailure(
    () => validateLog(`${regularLog}\nTest Case synthetic skipped (0 seconds)`, 'regular', regular, policy),
    'a skipped xcodebuild log',
  )
  const race = loadInventory(policy, 'thread-sanitizer')
  const syntheticSwiftDriver = (target, project) => [
    `SwiftDriver ${target} normal arm64 com.apple.xcode.tools.swift.compiler (in target '${target}' from project '${project}')`,
    '    cd /tmp/qvac',
    `    builtin-SwiftDriver -- /xcode/swiftc -module-name ${target} -sanitize\\=thread -output-file-map /tmp/Objects-normal-tsan/arm64/${target}.json`,
  ].join('\n')
  const threadSanitizerLog = [
    `xcodebuild -scheme ${policy.scheme} -enableThreadSanitizer YES`,
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) QVAC_NATIVE_STRESS_TESTING',
    `-only-testing:${policy.testModule}/${race.entries[0]}`,
    syntheticSwiftDriver('QVACClient', 'QVACClient'),
    syntheticSwiftDriver('QVACChatNativeStressTests', 'QVACChat'),
    'libclang_rt.tsan_iossim_dynamic.dylib',
    '** TEST SUCCEEDED **',
  ].join('\n')
  validateLog(threadSanitizerLog, 'thread-sanitizer', race, policy)
  expectFailure(
    () => validateLog([
      `xcodebuild -scheme ${policy.scheme} -enableThreadSanitizer YES`,
      'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) QVAC_NATIVE_STRESS_TESTING',
      `-only-testing:${policy.testModule}/${race.entries[0]}`,
      syntheticSwiftDriver('QVACChatNativeStressTests', 'QVACChat'),
      'libclang_rt.tsan_iossim_dynamic.dylib',
      '** TEST SUCCEEDED **',
    ].join('\n'), 'thread-sanitizer', race, policy),
    'Thread Sanitizer evidence without an instrumented QVACClient target',
  )
  expectFailure(
    () => validateLog([
      `xcodebuild -scheme ${policy.scheme} -enableThreadSanitizer YES`,
      'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) QVAC_NATIVE_STRESS_TESTING',
      `-only-testing:${policy.testModule}/${race.entries[0]}`,
      syntheticSwiftDriver('QVACClient', 'QVACClient'),
      'libclang_rt.tsan_iossim_dynamic.dylib',
      '** TEST SUCCEEDED **',
    ].join('\n'), 'thread-sanitizer', race, policy),
    'Thread Sanitizer evidence without an instrumented native stress test target',
  )

  const memoryEvidence = {
    transferredBytes: policy.memory.transferredBytes,
    sha256: policy.memory.sha256,
    warmupBytes: policy.memory.warmupBytes,
    maximumRetainedGrowthBytes: policy.memory.maximumRetainedGrowthBytes,
    observedRetainedGrowthBytes: 0,
    maximumFootprintBytesPerTransferredByte: policy.memory.maximumFootprintBytesPerTransferredByte,
    observedFootprintBytesPerTransferredByte: 0,
    samples: Array.from({ length: policy.memory.sampleCount }, (_, index) => ({
      transferredBytes: (index + 1) * policy.memory.sampleIntervalBytes,
      physicalFootprintBytes: 64 * 1024 * 1024,
    })),
  }
  validateMemoryEvidence(memoryEvidence, policy.memory)
  expectFailure(
    () => validateMemoryEvidence({ ...memoryEvidence, sha256: '0'.repeat(64) }, policy.memory),
    'a tampered streamed-content digest',
  )
  expectFailure(
    () => validateMemoryEvidence({
      ...memoryEvidence,
      samples: memoryEvidence.samples.map((sample, index) =>
        index === 1 ? { ...sample, transferredBytes: sample.transferredBytes + 1 } : sample),
    }, policy.memory),
    'tampered memory samples',
  )
  expectFailure(
    () => validateMemoryEvidence({ ...memoryEvidence, observedRetainedGrowthBytes: 1 }, policy.memory),
    'a forged retained-memory calculation',
  )
  const trafficEvidence = {
    transferredBytes: policy.echo.transferredBytes,
    sha256: policy.echo.sha256,
    chunkBytes: policy.echo.chunkBytes,
    uniqueChunkCount: policy.echo.uniqueChunkCount,
    nativeWriteWouldBlockCount: 3,
    raceIterations: policy.echo.raceIterations,
    concurrentCloseCallersPerIteration: policy.echo.concurrentCloseCallersPerIteration,
    raceObservedBytes: Array(policy.echo.raceIterations).fill(65_536),
    raceCloseReadOverlaps: Array(policy.echo.raceIterations).fill(true),
    raceObservedFollowerCloseWaiterCounts: Array(policy.echo.raceIterations)
      .fill(policy.echo.requiredFollowerCloseWaitersPerIteration),
  }
  validateTrafficEvidence(trafficEvidence, policy.echo)
  expectFailure(
    () => validateTrafficEvidence({ ...trafficEvidence, sha256: '0'.repeat(64) }, policy.echo),
    'a tampered echo digest',
  )
  expectFailure(
    () => validateTrafficEvidence({ ...trafficEvidence, nativeWriteWouldBlockCount: 0 }, policy.echo),
    'a run without native write backpressure',
  )
  expectFailure(
    () => validateTrafficEvidence({ ...trafficEvidence, raceCloseReadOverlaps: undefined }, policy.echo),
    'missing native close/read overlap evidence',
  )
  expectFailure(
    () => validateTrafficEvidence({
      ...trafficEvidence,
      raceCloseReadOverlaps: trafficEvidence.raceCloseReadOverlaps.map(
        (overlap, index) => index === 4 ? false : overlap,
      ),
    }, policy.echo),
    'a race iteration without native close/read overlap',
  )
  expectFailure(
    () => validateTrafficEvidence({
      ...trafficEvidence,
      raceCloseReadOverlaps: trafficEvidence.raceCloseReadOverlaps.slice(1),
    }, policy.echo),
    'an omitted native close/read overlap iteration',
  )
  expectFailure(
    () => validateTrafficEvidence({
      ...trafficEvidence,
      raceObservedFollowerCloseWaiterCounts: undefined,
    }, policy.echo),
    'missing follower close waiter evidence',
  )
  expectFailure(
    () => validateTrafficEvidence({
      ...trafficEvidence,
      raceObservedFollowerCloseWaiterCounts:
        trafficEvidence.raceObservedFollowerCloseWaiterCounts.map(
          (count, index) => index === 4 ? count - 1 : count,
        ),
    }, policy.echo),
    'a race iteration that released before every follower close registered',
  )
  expectFailure(
    () => validateTrafficEvidence({
      ...trafficEvidence,
      raceObservedFollowerCloseWaiterCounts:
        trafficEvidence.raceObservedFollowerCloseWaiterCounts.slice(1),
    }, policy.echo),
    'an omitted follower close waiter iteration',
  )

  const syntheticSHA = 'a'.repeat(40)
  validateSourceState(syntheticSHA, syntheticSHA, '')
  expectFailure(
    () => validateSourceState(syntheticSHA, 'b'.repeat(40), ''),
    'a spoofed source commit',
  )
  expectFailure(
    () => validateSourceState(syntheticSHA, syntheticSHA, ' M Sources/QVACClient/Foo.swift'),
    'a dirty source checkout',
  )
  const unsignedMachO = syntheticDeviceMachO(16 * 1024)
  const resignedMachO = syntheticDeviceMachO(32 * 1024)
  validateDeviceSigningTransformation(
    unsignedMachO,
    resignedMachO,
    resignedMachO.length + 16 * 1024,
    'synthetic BareKit',
  )
  expectFailure(
    () => validateDeviceSigningTransformation(
      unsignedMachO,
      resignedMachO,
      resignedMachO.length,
      'synthetic BareKit',
    ),
    'a signed product with no removable signature bytes',
  )
  expectFailure(
    () => validateDeviceSigningTransformation(
      unsignedMachO,
      syntheticDeviceMachO(48 * 1024),
      resignedMachO.length + 16 * 1024,
      'synthetic BareKit',
    ),
    'a signing virtual-size change one page larger than the signature requires',
  )
  const tamperedFileSizeMachO = Buffer.from(resignedMachO)
  tamperedFileSizeMachO.writeBigUInt64LE(4096n, 32 + 32 + 48)
  expectFailure(
    () => validateDeviceSigningTransformation(
      unsignedMachO,
      tamperedFileSizeMachO,
      resignedMachO.length + 16 * 1024,
      'synthetic BareKit',
    ),
    'tampered __LINKEDIT file size',
  )
  const invalidMachO = syntheticDeviceMachO(16 * 1024)
  invalidMachO.writeUInt32LE(73, 32 + 20)
  expectFailure(
    () => normalizeDeviceSigningFields(invalidMachO),
    'a Mach-O whose declared load-command size exceeds its commands',
  )

  const fixture = mkdtempSync(join(tmpdir(), 'qvac-native-stress-verifier.'))
  try {
    const candidate = writeSyntheticCandidate(join(fixture, 'r2'))
    const selected = candidateBinary(candidate, 'simulator')
    const derivedData = join(fixture, 'DerivedData')
    const embedded = writeSyntheticEmbeddedProducts(derivedData, selected.bytes)
    validateEmbeddedCandidate(candidate, derivedData, 'simulator', policy.patchMarker)

    writeFileSync(embedded[1], 'stale r1 product')
    expectFailure(
      () => validateEmbeddedCandidate(candidate, derivedData, 'simulator', policy.patchMarker),
      'a stale embedded BareKit binary',
    )
    writeFileSync(embedded[1], selected.bytes)

    const historicalR1 = writeSyntheticCandidate(join(fixture, 'r1'), { patched: false })
    expectFailure(
      () => validateEmbeddedCandidate(historicalR1, derivedData, 'simulator', policy.patchMarker),
      'a historical r1 candidate without the patch marker',
    )

    const simulatorOnly = writeSyntheticCandidate(join(fixture, 'sim-only'), { includeDevice: false })
    expectFailure(
      () => candidateBinary(simulatorOnly, 'device'),
      'a Simulator candidate presented as physical-device evidence',
    )
  } finally {
    rmSync(fixture, { recursive: true, force: true })
  }
  console.log('[ios-native-stress-evidence-self-test] exact inventories/results, zero-skip state, source platform, r1 rejection, and embedded candidate binding verified')
}

function parseArguments(argv) {
  const values = new Map()
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index]
    const value = argv[index + 1]
    if (!key?.startsWith('--') || value === undefined || values.has(key)) fail('invalid or duplicate arguments')
    values.set(key, value)
  }
  const expected = [
    '--mode', '--platform', '--xcresult', '--log', '--derived-data', '--candidate',
    '--source-sha', '--output',
  ]
  if (values.size !== expected.length || expected.some(key => !values.has(key))) {
    fail(`usage: ${expected.join(' <value> ')} <value>`)
  }
  return Object.fromEntries([...values].map(([key, value]) => [key.slice(2), value]))
}

try {
  if (process.argv.length === 3 && process.argv[2] === '--self-test') {
    selfTest()
  } else {
    const args = parseArguments(process.argv.slice(2))
    if (!['regular', 'thread-sanitizer'].includes(args.mode)) fail('mode must be regular or thread-sanitizer')
    if (!['simulator', 'device'].includes(args.platform)) fail('platform must be simulator or device')
    if (args.mode === 'thread-sanitizer' && args.platform !== 'simulator') {
      fail('Thread Sanitizer evidence is Simulator-only')
    }
    if (!/^[0-9a-f]{40}$/.test(args['source-sha'])) fail('source SHA must be a full lowercase Git commit')
    const repositoryHead = run(
      'git',
      ['-C', repositoryRoot, 'rev-parse', '--verify', 'HEAD'],
      'source commit resolution',
      maximumMetadataBytes,
    ).trim()
    const repositoryStatus = run(
      'git',
      ['-C', repositoryRoot, 'status', '--porcelain', '--untracked-files=all'],
      'source checkout status',
      maximumMetadataBytes,
    )
    validateSourceState(args['source-sha'], repositoryHead, repositoryStatus)

    const xcresult = resolve(args.xcresult)
    const logPath = resolve(args.log)
    const derivedData = resolve(args['derived-data'])
    const candidate = resolve(args.candidate)
    const output = resolve(args.output)
    realDirectory(xcresult, 'xcresult bundle')
    realDirectory(derivedData, 'DerivedData')
    const logBytes = regularFile(logPath, 'xcodebuild log', maximumLogBytes)
    const log = logBytes.toString('utf8')
    const policy = loadPolicy()
    const inventory = loadInventory(policy, args.mode)
    validateLog(log, args.mode, inventory, policy)

    const resultText = run('xcrun', [
      'xcresulttool', 'get', 'test-results', 'tests', '--path', xcresult, '--format', 'json',
    ], 'xcresult test extraction')
    const { cases, device } = validateResult(JSON.parse(resultText), inventory, args.platform)
    const candidateEvidence = validateEmbeddedCandidate(
      candidate,
      derivedData,
      args.platform,
      policy.patchMarker,
    )
    const traffic = validateTrafficAttachment(xcresult, policy)
    const memory = args.mode === 'regular' ? validateMemoryAttachment(xcresult, policy) : null

    try {
      const outputStat = lstatSync(output)
      if (outputStat.isSymbolicLink() || outputStat.isDirectory()) fail('output must be a new regular file')
      fail('output file already exists')
    } catch (error) {
      if (error?.code !== 'ENOENT') throw error
    }
    realDirectory(dirname(output), 'output parent')
    const summary = {
      schemaVersion: 1,
      result: 'PASS',
      mode: args.mode,
      platform: args.platform,
      sourceCommit: args['source-sha'],
      candidate: {
        patchMarker: policy.patchMarker,
        selectedBinarySHA256: candidateEvidence.expectedSHA256,
        embeddedProductCount: candidateEvidence.embeddedCount,
        byteExactProductCount: candidateEvidence.exactCount,
        resignedProductCount: candidateEvidence.resignedCount,
      },
      device,
      tests: cases.map(test => ({
        identity: normalizeTestIdentity(test),
        result: test.result,
        durationSeconds: test.durationInSeconds,
      })),
      traffic,
      memory,
      log: { bytes: logBytes.length, sha256: sha256(logBytes) },
    }
    writeFileSync(output, `${JSON.stringify(summary, null, 2)}\n`, { flag: 'wx' })
    console.log(`[ios-native-stress-evidence] PASS mode=${args.mode} platform=${args.platform} tests=${cases.length} candidate-sha256=${candidateEvidence.expectedSHA256}`)
  }
} catch (error) {
  process.stderr.write(`${error.message}\n`)
  process.exitCode = 1
}
