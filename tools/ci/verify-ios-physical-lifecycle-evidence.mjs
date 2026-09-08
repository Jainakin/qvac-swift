#!/usr/bin/env node

import { createHash } from 'node:crypto'
import {
  copyFileSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from 'node:fs'
import { basename, dirname, join, resolve } from 'node:path'
import { tmpdir } from 'node:os'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import {
  isolatedSourceRootName,
  pinnedXcodeGenExecutableSHA256,
  pinnedXcodeGenVersion,
  reviewedArtifactLockSHA256,
  verifyIsolatedBuildInputs,
} from './verify-ios-build-inputs.mjs'

const scriptDirectory = dirname(fileURLToPath(import.meta.url))
const repositoryRoot = realpathSync(resolve(scriptDirectory, '../..'))
const policyPath = join(scriptDirectory, 'ios-physical-lifecycle-policy.json')
const maximumLogBytes = 128 * 1024 * 1024
const maximumMetadataBytes = 1024 * 1024
const maximumScreenshotBytes = 32 * 1024 * 1024
const uuidPattern = '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}'

function fail(message) {
  throw new Error(`[ios-physical-lifecycle-evidence] ${message}`)
}

function exactKeys(value, expected, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) fail(`${label} must be an object`)
  const actual = Object.keys(value).sort()
  const wanted = [...expected].sort()
  if (JSON.stringify(actual) !== JSON.stringify(wanted)) {
    fail(`${label} keys differ: expected ${wanted.join(', ')}, got ${actual.join(', ')}`)
  }
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
  return realpathSync(path)
}

function strictUTF8(bytes, label) {
  try { return new TextDecoder('utf-8', { fatal: true }).decode(bytes) } catch { fail(`${label} is not UTF-8`) }
}

function parseJSON(bytes, label) {
  try { return JSON.parse(strictUTF8(bytes, label)) } catch (error) { fail(`invalid ${label}: ${error.message}`) }
}

function commandFailure(result, label) {
  const value = result.stderr?.length ? result.stderr : result.stdout
  const detail = Buffer.isBuffer(value) ? strictUTF8(value, `${label} failure output`) : String(value || '')
  fail(`${label} failed: ${detail.trim() || `status ${result.status}`}`)
}

function run(command, args, label, maximumBytes = 16 * 1024 * 1024) {
  const result = spawnSync(command, args, { encoding: 'utf8', maxBuffer: maximumBytes })
  if (result.status !== 0) commandFailure(result, label)
  return result.stdout
}

function loadPolicy() {
  const bytes = regularFile(policyPath, 'physical lifecycle policy', maximumMetadataBytes)
  const policy = parseJSON(bytes, 'physical lifecycle policy')
  exactKeys(policy, [
    'schemaVersion', 'scheme', 'testModule', 'inventoryPath', 'inventorySHA256',
    'expectedTestCount', 'artifactManifestPath', 'artifactManifestSHA256',
    'expectedArtifactCount', 'artifactTreeLockPath', 'artifactTreeLockSHA256',
    'xcodeGenVersion', 'xcodeGenExecutableSHA256',
    'workerBundlePath', 'workerBundleSize',
    'workerBundleSHA256', 'patchMarker', 'requiredAttachments',
  ], 'physical lifecycle policy')
  if (policy.schemaVersion !== 1
      || policy.scheme !== 'QVACChat-PhysicalDevice'
      || policy.testModule !== 'QVACChatPhysicalDeviceTests'
      || policy.inventoryPath !== 'tools/ci/ios-physical-lifecycle-test-inventory.txt'
      || !/^[0-9a-f]{64}$/.test(policy.inventorySHA256)
      || policy.expectedTestCount !== 1
      || policy.artifactManifestPath !== 'tools/release/artifacts.development.json'
      || policy.artifactManifestSHA256 !== '66e2298a6abf2c19b2af9c0411aea5d6c77c5a81a4a9b70d7e89447c51ed708b'
      || policy.expectedArtifactCount !== 38
      || policy.artifactTreeLockPath !== 'tools/ci/ios-local-artifact-tree-lock.json'
      || policy.artifactTreeLockSHA256 !== reviewedArtifactLockSHA256
      || policy.xcodeGenVersion !== pinnedXcodeGenVersion
      || policy.xcodeGenExecutableSHA256 !== pinnedXcodeGenExecutableSHA256
      || policy.workerBundlePath !== 'Sources/QVACClient/Resources/worker.mobile.bundle'
      || policy.workerBundleSize !== 11_495_184
      || policy.workerBundleSHA256 !== '3d17393e67b0ed6830a5dad2f575b9d8835589a4eed321629ff2f514066cd769'
      || policy.patchMarker !== 'qvac-bare-kit-2.3.0-ipc-hardening-1'
      || JSON.stringify(policy.requiredAttachments) !== JSON.stringify([
        '01-launched',
        '02-model-load-outcome',
        '03-completion-outcome',
        '04-unloaded',
      ])) {
    fail('physical lifecycle policy has unsupported metadata')
  }
  return { policy, bytes }
}

function loadInventory(policy) {
  const path = resolve(repositoryRoot, policy.inventoryPath)
  if (!path.startsWith(`${repositoryRoot}/`)) fail('physical lifecycle inventory escapes the repository')
  const bytes = regularFile(path, 'physical lifecycle inventory', maximumMetadataBytes)
  if (sha256(bytes) !== policy.inventorySHA256) fail('physical lifecycle inventory SHA-256 differs from policy')
  const text = strictUTF8(bytes, 'physical lifecycle inventory')
  if (!text.endsWith('\n') || text.includes('\r')) fail('physical lifecycle inventory must be LF-terminated')
  const entries = text.split('\n').filter(Boolean)
  if (entries.length !== policy.expectedTestCount || new Set(entries).size !== entries.length) {
    fail('physical lifecycle inventory count or uniqueness differs from policy')
  }
  if (entries.some(entry => !/^[A-Za-z_][A-Za-z0-9_]*\/test[A-Za-z0-9_]+$/.test(entry))) {
    fail('physical lifecycle inventory contains an invalid XCTest identity')
  }
  return { entries, bytes }
}

function loadArtifactInventory(policy) {
  const path = resolve(repositoryRoot, policy.artifactManifestPath)
  if (!path.startsWith(`${repositoryRoot}/`)) fail('development artifact manifest escapes the repository')
  const bytes = regularFile(path, 'development artifact manifest', maximumMetadataBytes)
  if (sha256(bytes) !== policy.artifactManifestSHA256) {
    fail('development artifact manifest SHA-256 differs from policy')
  }
  const manifest = parseJSON(bytes, 'development artifact manifest')
  if (manifest.schemaVersion !== 2
      || manifest.mode !== 'development'
      || manifest.releaseEligible !== false
      || manifest.frameworkRoot !== 'tools/runtime/.build/artifacts'
      || !Array.isArray(manifest.targets)
      || manifest.targets.length !== policy.expectedArtifactCount
      || new Set(manifest.targets).size !== manifest.targets.length
      || manifest.targets.some(target => !/^[A-Za-z0-9_.-]+$/.test(target))) {
    fail('development artifact manifest does not describe the reviewed 38-target closure')
  }
  return { targets: [...manifest.targets].sort(), bytes }
}

function normalizeIdentity(value) {
  if (typeof value !== 'string') fail('test identity must be a string')
  return value.replace(/\(\)$/, '')
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

function validateDevice(device, expectedDeviceID, label) {
  if (!device || typeof device !== 'object'
      || device.platform !== 'iOS'
      || device.architecture !== 'arm64'
      || device.deviceId !== expectedDeviceID
      || typeof device.deviceName !== 'string' || device.deviceName.length === 0
      || typeof device.modelName !== 'string' || device.modelName.length === 0
      || typeof device.osVersion !== 'string' || device.osVersion.length === 0
      || typeof device.osBuildNumber !== 'string' || device.osBuildNumber.length === 0) {
    fail(`${label} does not prove the requested arm64 physical iOS device`)
  }
  return device
}

function validateTestResults(result, inventory, expectedDeviceID) {
  if (!Array.isArray(result.devices) || result.devices.length !== 1) {
    fail('xcresult tests document must describe exactly one device')
  }
  const device = validateDevice(result.devices[0], expectedDeviceID, 'xcresult tests device')
  const cases = collectTestCases(result)
  const identities = cases.map(test => normalizeIdentity(test.nodeIdentifier)).sort()
  const expected = [...inventory.entries].sort()
  if (JSON.stringify(identities) !== JSON.stringify(expected)) {
    fail(`executed tests differ from reviewed inventory: ${JSON.stringify(identities)}`)
  }
  if (cases.some(test => test.result !== 'Passed'
      || !Number.isFinite(test.durationInSeconds) || test.durationInSeconds <= 0)) {
    fail('the reviewed physical lifecycle test did not produce a timed pass')
  }
  if (!Array.isArray(result.testPlanConfigurations) || result.testPlanConfigurations.length !== 1) {
    fail('xcresult tests document must contain exactly one test-plan configuration')
  }
  return { cases, device }
}

function validateSummary(summary, expectedDeviceID) {
  if (summary.result !== 'Passed'
      || summary.totalTestCount !== 1
      || summary.passedTests !== 1
      || summary.failedTests !== 0
      || summary.skippedTests !== 0
      || summary.expectedFailures !== 0
      || !Array.isArray(summary.testFailures) || summary.testFailures.length !== 0
      || !Array.isArray(summary.devicesAndConfigurations)
      || summary.devicesAndConfigurations.length !== 1
      || !Number.isFinite(summary.startTime)
      || !Number.isFinite(summary.finishTime)
      || summary.startTime <= 0
      || summary.finishTime <= summary.startTime) {
    fail('xcresult summary is not an exact one-test, zero-skip pass')
  }
  const entry = summary.devicesAndConfigurations[0]
  if (entry.passedTests !== 1 || entry.failedTests !== 0
      || entry.skippedTests !== 0 || entry.expectedFailures !== 0) {
    fail('xcresult device summary is not an exact one-test, zero-skip pass')
  }
  return {
    device: validateDevice(entry.device, expectedDeviceID, 'xcresult summary device'),
    startTime: summary.startTime,
    finishTime: summary.finishTime,
  }
}

function escapeRegularExpression(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

function invocationBlock(log) {
  const marker = 'Command line invocation:\n'
  const first = log.indexOf(marker)
  if (first < 0 || log.indexOf(marker, first + marker.length) >= 0) {
    fail('xcodebuild log must contain exactly one command-line invocation')
  }
  const block = log.slice(first + marker.length).split('\n\n', 1)[0]
    .split('\n').map(line => line.trim()).filter(Boolean).join(' ')
  if (!/(?:^|\/)xcodebuild(?:\s|$)/.test(block)) {
    fail('xcodebuild command-line invocation is malformed')
  }
  return block
}

function invocationSelectsExactlyOnce(invocation, flag, value) {
  const escapedFlag = escapeRegularExpression(flag)
  const escapedValue = escapeRegularExpression(value)
  const flagCount = (invocation.match(new RegExp(
    `(?:^|\\s)${escapedFlag}(?=\\s|$)`,
    'g',
  )) || []).length
  return flagCount === 1 && new RegExp(
    `(?:^|\\s)${escapedFlag}\\s+(?:"${escapedValue}"|'${escapedValue}'|${escapedValue})(?:\\s|$)`,
  ).test(invocation)
}

function invocationAssignsExactlyOnce(invocation, setting, value) {
  const escapedSetting = escapeRegularExpression(setting)
  const escapedValue = escapeRegularExpression(value)
  const assignmentCount = (invocation.match(new RegExp(
    `(?:^|\\s)["']?${escapedSetting}\\s*=`,
    'g',
  )) || []).length
  return assignmentCount === 1 && new RegExp(
    `(?:^|\\s)["']?${escapedSetting}\\s*=\\s*${escapedValue}["']?(?:\\s|$)`,
  ).test(invocation)
}

function invocationTokenCount(invocation, token) {
  const escapedToken = escapeRegularExpression(token)
  return (invocation.match(new RegExp(
    `(?:^|\\s)["']?${escapedToken}["']?(?=\\s|$)`,
    'g',
  )) || []).length
}

function validateLog(
  log,
  policy,
  inventory,
  expectedDeviceID,
  expectedTeam,
  expectedProject,
  expectedResult,
  expectedDerivedData,
  allowProvisioningUpdates,
  allowDeviceRegistration,
) {
  const invocation = invocationBlock(log)
  const identity = `${policy.testModule}/${inventory.entries[0]}`
  if ((log.match(/\*\* TEST(?: EXECUTE)? SUCCEEDED \*\*/g) || []).length !== 1) {
    fail('xcodebuild log must contain exactly one successful test-execution marker')
  }
  if (/^Test Case .* (?:failed|skipped) /m.test(log)
      || /^Testing failed:/m.test(log)
      || /\*\* TEST (?:FAILED|EXECUTE FAILED) \*\*/.test(log)
      || /Executed 0 tests?/m.test(log)) {
    fail('xcodebuild log contains a failure, skip, or empty run')
  }
  if (!invocationSelectsExactlyOnce(invocation, '-scheme', policy.scheme)) {
    fail(`xcodebuild log does not select ${policy.scheme}`)
  }
  const onlyTesting = invocation.match(/-only-testing:[^\s"]+/g) || []
  if (onlyTesting.length !== 1 || onlyTesting[0] !== `-only-testing:${identity}`) {
    fail('xcodebuild log is not restricted to the exact reviewed physical lifecycle test')
  }
  if (/-skip-testing:/.test(invocation)) fail('xcodebuild log contains an unreviewed skip-testing selector')
  if (!invocationSelectsExactlyOnce(invocation, '-destination', `platform=iOS,id=${expectedDeviceID}`)
      || !invocationSelectsExactlyOnce(invocation, '-project', expectedProject)
      || !invocationSelectsExactlyOnce(invocation, '-resultBundlePath', expectedResult)
      || !invocationSelectsExactlyOnce(invocation, '-derivedDataPath', expectedDerivedData)) {
    fail('xcodebuild invocation does not bind the physical destination and isolated output paths')
  }
  if (!invocationAssignsExactlyOnce(invocation, 'DEVELOPMENT_TEAM', expectedTeam)
      || !invocationAssignsExactlyOnce(invocation, 'CODE_SIGN_STYLE', 'Automatic')
      || invocationTokenCount(invocation, '-allowProvisioningUpdates')
        !== Number(allowProvisioningUpdates)
      || invocationTokenCount(invocation, '-allowProvisioningDeviceRegistration')
        !== Number(allowDeviceRegistration)) {
    fail('xcodebuild invocation does not bind the reviewed signing configuration')
  }
  if (!log.includes('Debug-iphoneos')) fail('xcodebuild log does not contain a physical iOS product build')
  if (invocation.includes('-enableThreadSanitizer')) {
    fail('physical lifecycle evidence unexpectedly enabled Thread Sanitizer')
  }
}

function validateSourceState(suppliedSHA, repositorySHA, status) {
  if (suppliedSHA !== repositorySHA) {
    fail(`supplied source SHA ${suppliedSHA} differs from repository HEAD ${repositorySHA}`)
  }
  if (status.length !== 0) fail('repository contains source changes; evidence is calibration-only')
}

function validateWorkspaceState(derivedData, sourceRoot, artifactInventory) {
  const workspaceStateBytes = regularFile(
    join(derivedData, 'SourcePackages', 'workspace-state.json'),
    'SwiftPM workspace state',
    maximumMetadataBytes,
  )
  const state = parseJSON(workspaceStateBytes, 'SwiftPM workspace state')
  if (state.version !== 7 || !state.object || typeof state.object !== 'object'
      || !Array.isArray(state.object.artifacts)
      || !Array.isArray(state.object.dependencies) || state.object.dependencies.length !== 0
      || !Array.isArray(state.object.prebuilts) || state.object.prebuilts.length !== 0) {
    fail('SwiftPM workspace state has an unsupported schema or external dependencies')
  }
  const artifacts = state.object.artifacts
  const names = artifacts.map(artifact => artifact?.targetName).sort()
  if (artifacts.length !== artifactInventory.targets.length
      || JSON.stringify(names) !== JSON.stringify(artifactInventory.targets)) {
    fail('resolved SwiftPM artifacts differ from the reviewed 38-target closure')
  }
  const stagedRoot = realDirectory(
    join(sourceRoot, 'tools', 'runtime', '.build', 'artifacts'),
    'isolated staged artifact root',
  )
  for (const artifact of artifacts) {
    if (!artifact || typeof artifact !== 'object'
        || artifact.source?.type !== 'local'
        || artifact.packageRef?.identity !== isolatedSourceRootName
        || artifact.packageRef?.kind !== 'root'
        || artifact.packageRef?.name !== isolatedSourceRootName
        || artifact.kind?.xcframework === undefined) {
      fail(`resolved artifact ${artifact?.targetName ?? '<unknown>'} is not a local root-package XCFramework`)
    }
    let packageLocation
    let artifactPath
    try {
      packageLocation = realpathSync(artifact.packageRef.location)
      artifactPath = realpathSync(artifact.path)
    } catch (error) {
      fail(`cannot resolve SwiftPM artifact ${artifact.targetName}: ${error.message}`)
    }
    if (packageLocation !== sourceRoot) {
      fail(`resolved artifact ${artifact.targetName} belongs to a different package checkout`)
    }
    const expectedPath = realDirectory(
      join(stagedRoot, `${artifact.targetName}.xcframework`),
      `isolated ${artifact.targetName} artifact`,
    )
    if (artifactPath !== expectedPath || !artifactPath.startsWith(`${stagedRoot}/`)) {
      fail(`resolved artifact ${artifact.targetName} escapes the isolated staged closure`)
    }
  }
  return { byteCount: workspaceStateBytes.length, sha256: sha256(workspaceStateBytes) }
}

function validateLockState(document, expectedDeviceID) {
  if (!document || typeof document !== 'object' || Array.isArray(document)
      || !document.info || !document.result) {
    fail('device lock-state evidence must contain info and result objects')
  }
  if (document.info.jsonVersion !== 3
      || document.info.outcome !== 'success'
      || document.info.commandType !== 'devicectl.device.info.lockState'
      || !Array.isArray(document.info.arguments)) {
    fail('device lock-state command did not complete successfully with JSON schema v3')
  }
  const deviceArguments = document.info.arguments.flatMap((argument, index, arguments_) =>
    argument === '--device' && index + 1 < arguments_.length ? [arguments_[index + 1]] : [])
  if (deviceArguments.length !== 1 || deviceArguments[0] !== expectedDeviceID) {
    fail('device lock-state evidence does not bind the requested destination identifier')
  }
  exactKeys(
    document.result,
    ['deviceIdentifier', 'passcodeRequired', 'unlockedSinceBoot'],
    'device lock-state result',
  )
  if (!new RegExp(`^${uuidPattern}$`).test(document.result.deviceIdentifier)
      || document.result.unlockedSinceBoot !== true
      || document.result.passcodeRequired !== false) {
    fail('physical device must be unlocked now and must have been unlocked since boot')
  }
  return {
    coreDeviceIdentifier: document.result.deviceIdentifier,
    unlockedSinceBoot: true,
    passcodeRequired: false,
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

function candidateBinary(candidate) {
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
  const libraries = info.AvailableLibraries.filter(library =>
    library?.SupportedPlatform === 'ios'
      && library?.SupportedPlatformVariant === undefined
      && Array.isArray(library.SupportedArchitectures)
      && JSON.stringify(library.SupportedArchitectures) === JSON.stringify(['arm64']))
  if (libraries.length !== 1) fail(`BareKit candidate has ${libraries.length} matching arm64 device slices`)
  const library = libraries[0]
  if (!/^[A-Za-z0-9_.-]+$/.test(library.LibraryIdentifier)
      || library.LibraryPath !== 'BareKit.framework'
      || library.BinaryPath !== 'BareKit.framework/BareKit') {
    fail('BareKit candidate device slice paths differ from the reviewed layout')
  }
  const slice = join(candidate, library.LibraryIdentifier)
  realDirectory(slice, 'BareKit device candidate slice')
  const framework = join(slice, library.LibraryPath)
  realDirectory(framework, 'BareKit device candidate framework')
  const binary = join(slice, library.BinaryPath)
  return { binary, bytes: regularFile(binary, 'BareKit device candidate binary') }
}

function normalizeDeviceSigningFields(bytes) {
  const normalized = Buffer.from(bytes)
  let machOffset = 0
  let sliceSize = normalized.length
  if (normalized.length >= 28 && normalized.readUInt32BE(0) === 0xcafebabe) {
    if (normalized.readUInt32BE(4) !== 1 || normalized.readUInt32BE(8) !== 0x0100000c) {
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
        normalized.fill(0, commandOffset + 32, commandOffset + 40)
      }
    }
    commandOffset += commandSize
  }
  if (commandOffset !== commandEnd) fail('device BareKit load-command size is inconsistent')
  if (!linkedit) fail('device BareKit must contain exactly one __LINKEDIT segment')
  return { normalized, linkedit }
}

function validateDeviceSigningTransformation(candidateBytes, unsignedEmbeddedBytes, signedLength, label) {
  if (!Number.isSafeInteger(signedLength) || signedLength <= unsignedEmbeddedBytes.length) {
    fail(`signed ${label} does not contain a removable Mach-O signature`)
  }
  if (unsignedEmbeddedBytes.length !== candidateBytes.length) {
    fail(`signature-stripped ${label} length differs from the selected candidate`)
  }
  const candidate = normalizeDeviceSigningFields(candidateBytes)
  const embedded = normalizeDeviceSigningFields(unsignedEmbeddedBytes)
  const signatureByteCount = BigInt(signedLength - unsignedEmbeddedBytes.length)
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
  const temporary = mkdtempSync(join(tmpdir(), 'qvac-physical-barekit-unsign.'))
  try {
    const unsignedCopy = join(temporary, 'BareKit')
    copyFileSync(binary, unsignedCopy)
    run('codesign', ['--remove-signature', unsignedCopy], 'embedded BareKit signature removal')
    const unsignedBytes = regularFile(unsignedCopy, 'unsigned embedded BareKit')
    validateDeviceSigningTransformation(candidateBytes, unsignedBytes, signedBytes.length, `built product ${binary}`)
  } finally {
    rmSync(temporary, { recursive: true, force: true })
  }
}

function validateEmbeddedCandidate(candidate, derivedData, patchMarker) {
  const selected = candidateBinary(candidate)
  if (!selected.bytes.includes(Buffer.from(patchMarker))) fail('candidate binary lacks the required patch marker')
  const header = join(dirname(selected.binary), 'Headers', 'BareKit.h')
  const headerText = strictUTF8(
    regularFile(header, 'BareKit candidate header', maximumMetadataBytes),
    'BareKit candidate header',
  )
  if (!headerText.includes('readWithError:') || !headerText.includes('BareKitQVACPatchLevel')) {
    fail('candidate header lacks the checked read API or patch-level export')
  }
  const expectedSHA256 = sha256(selected.bytes)
  const products = join(derivedData, 'Build', 'Products')
  realDirectory(products, 'DerivedData products')
  const binaries = findBareKitBinaries(products)
  if (binaries.length < 2) fail('DerivedData does not contain app-hosted BareKit products')
  let exactCount = 0
  let resignedCount = 0
  for (const binary of binaries) {
    const bytes = regularFile(binary, 'embedded BareKit binary')
    const appEmbedded = (binary.includes('.app/') || binary.includes('.xctest/'))
      && binary.includes('/Frameworks/')
    if (appEmbedded) {
      validateResignedDeviceBinary(selected.bytes, binary)
      resignedCount += 1
    } else if (sha256(bytes) === expectedSHA256) {
      exactCount += 1
    } else {
      fail(`built product does not contain the selected candidate: ${binary}`)
    }
  }
  if (exactCount < 1) fail('built products contain no byte-exact unsigned BareKit candidate')
  if (resignedCount < 1) fail('built products contain no strictly signed app-embedded BareKit candidate')
  return { expectedSHA256, embeddedCount: binaries.length, exactCount, resignedCount }
}

function validatePNG(bytes, label) {
  const signature = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10])
  if (bytes.length < 45 || !bytes.subarray(0, 8).equals(signature)) fail(`${label} is not a PNG`)
  let offset = 8
  let width
  let height
  let sawEnd = false
  let chunkIndex = 0
  while (offset < bytes.length) {
    if (offset + 12 > bytes.length) fail(`${label} has a truncated PNG chunk`)
    const length = bytes.readUInt32BE(offset)
    const end = offset + 12 + length
    if (end > bytes.length) fail(`${label} has a PNG chunk outside the file`)
    const type = bytes.subarray(offset + 4, offset + 8).toString('ascii')
    if (chunkIndex === 0) {
      if (type !== 'IHDR' || length !== 13) fail(`${label} lacks a valid first IHDR chunk`)
      width = bytes.readUInt32BE(offset + 8)
      height = bytes.readUInt32BE(offset + 12)
      if (width === 0 || height === 0 || width > 16_384 || height > 16_384) {
        fail(`${label} has invalid screenshot dimensions`)
      }
    }
    if (type === 'IEND') {
      if (length !== 0 || end !== bytes.length) fail(`${label} has an invalid terminal IEND chunk`)
      sawEnd = true
    }
    offset = end
    chunkIndex += 1
  }
  if (!sawEnd) fail(`${label} lacks a terminal IEND chunk`)
  return { width, height }
}

function attachmentBaseName(humanName, required) {
  if (typeof humanName !== 'string') fail('screenshot attachment lacks a human-readable name')
  const matches = required.filter(base => new RegExp(
    `^${escapeRegularExpression(base)}_[0-9]+_${uuidPattern}\\.png$`,
  ).test(humanName))
  if (matches.length !== 1) fail(`unexpected screenshot attachment name: ${humanName}`)
  return matches[0]
}

function validateAttachmentManifest(
  manifest,
  exportDirectory,
  policy,
  inventory,
  expectedDeviceID,
  testInterval,
) {
  if (!Array.isArray(manifest) || manifest.length !== 1) {
    fail('attachment manifest must contain exactly one test entry')
  }
  const entry = manifest[0]
  if (normalizeIdentity(entry.testIdentifier) !== inventory.entries[0]
      || typeof entry.testIdentifierURL !== 'string'
      || !entry.testIdentifierURL.includes(inventory.entries[0])) {
    fail('attachments are not bound to the reviewed physical lifecycle test')
  }
  if (!Array.isArray(entry.attachments)
      || entry.attachments.length !== policy.requiredAttachments.length) {
    fail('physical lifecycle test must retain exactly four screenshot attachments')
  }
  const seenNames = new Set()
  const seenFiles = new Set()
  const evidence = []
  for (const attachment of entry.attachments) {
    const base = attachmentBaseName(attachment.suggestedHumanReadableName, policy.requiredAttachments)
    if (seenNames.has(base)) fail(`duplicate screenshot attachment: ${base}`)
    seenNames.add(base)
    if (attachment.configurationName !== 'Test Scheme Action'
        || attachment.deviceId !== expectedDeviceID
        || attachment.isAssociatedWithFailure !== false
        || !Number.isFinite(attachment.timestamp)
        || attachment.timestamp < testInterval.startTime
        || attachment.timestamp > testInterval.finishTime) {
      fail(`screenshot attachment ${base} has invalid XCTest metadata`)
    }
    const fileName = attachment.exportedFileName
    if (typeof fileName !== 'string' || basename(fileName) !== fileName
        || !new RegExp(`^${uuidPattern}\\.png$`).test(fileName)
        || seenFiles.has(fileName)) {
      fail(`screenshot attachment ${base} has an unsafe or duplicate exported file name`)
    }
    seenFiles.add(fileName)
    const bytes = regularFile(join(exportDirectory, fileName), `${base} screenshot`, maximumScreenshotBytes)
    const dimensions = validatePNG(bytes, `${base} screenshot`)
    evidence.push({
      name: base,
      timestamp: attachment.timestamp,
      byteCount: bytes.length,
      sha256: sha256(bytes),
      ...dimensions,
    })
  }
  if (JSON.stringify([...seenNames].sort()) !== JSON.stringify([...policy.requiredAttachments].sort())) {
    fail('screenshot attachment inventory differs from policy')
  }
  const ordered = evidence.sort((left, right) => left.name.localeCompare(right.name))
  for (let index = 1; index < ordered.length; index++) {
    if (ordered[index].timestamp <= ordered[index - 1].timestamp) {
      fail('lifecycle screenshot timestamps do not prove the reviewed execution order')
    }
  }
  return ordered
}

function validateAttachments(xcresult, policy, inventory, expectedDeviceID, testInterval) {
  const exportDirectory = mkdtempSync(join(tmpdir(), 'qvac-physical-attachments.'))
  try {
    run('xcrun', [
      'xcresulttool', 'export', 'attachments', '--path', xcresult, '--output-path', exportDirectory,
    ], 'xcresult attachment export')
    const manifestBytes = regularFile(
      join(exportDirectory, 'manifest.json'),
      'xcresult attachment manifest',
      maximumMetadataBytes,
    )
    return {
      manifestSHA256: sha256(manifestBytes),
      screenshots: validateAttachmentManifest(
        parseJSON(manifestBytes, 'xcresult attachment manifest'),
        exportDirectory,
        policy,
        inventory,
        expectedDeviceID,
        testInterval,
      ),
    }
  } finally {
    rmSync(exportDirectory, { recursive: true, force: true })
  }
}

function parseArguments(argv, expected) {
  if (argv.length !== expected.length * 2) fail('invalid argument count')
  const values = new Map()
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index]
    const value = argv[index + 1]
    if (!expected.includes(key) || values.has(key) || value === undefined || value.length === 0) {
      fail('invalid or duplicate arguments')
    }
    values.set(key, value)
  }
  if (values.size !== expected.length) fail(`usage: ${expected.join(' <value> ')} <value>`)
  return Object.fromEntries([...values].map(([key, value]) => [key.slice(2), value]))
}

function expectFailure(action, label) {
  try { action() } catch { return }
  fail(`self-test accepted ${label}`)
}

function syntheticDevice(deviceID, platform = 'iOS') {
  return {
    architecture: 'arm64',
    deviceId: deviceID,
    deviceName: 'iPhone',
    modelName: 'Verification Fixture',
    osBuildNumber: '21A1',
    osVersion: '17.0',
    platform,
  }
}

function syntheticTestResults(identity, deviceID, result = 'Passed', platform = 'iOS') {
  return {
    devices: [syntheticDevice(deviceID, platform)],
    testNodes: [{
      nodeType: 'Test Case',
      nodeIdentifier: `${identity}()`,
      result,
      durationInSeconds: 4,
    }],
    testPlanConfigurations: [{ configurationId: '1', configurationName: 'Test Scheme Action' }],
  }
}

function syntheticSummary(deviceID) {
  return {
    result: 'Passed', totalTestCount: 1, passedTests: 1, failedTests: 0,
    skippedTests: 0, expectedFailures: 0, testFailures: [],
    startTime: 0.5,
    finishTime: 5,
    devicesAndConfigurations: [{
      device: syntheticDevice(deviceID),
      passedTests: 1, failedTests: 0, skippedTests: 0, expectedFailures: 0,
    }],
  }
}

function syntheticLockState(deviceID, overrides = {}) {
  return {
    info: {
      arguments: [
        'devicectl', 'device', 'info', 'lockState', '--device', deviceID,
        '--json-output', '/tmp/lock.json', '--quiet',
      ],
      commandType: 'devicectl.device.info.lockState',
      environment: { TERM: 'dumb' },
      jsonVersion: 3,
      outcome: 'success',
      version: '1',
    },
    result: {
      deviceIdentifier: '11111111-2222-3333-4444-555555555555',
      passcodeRequired: false,
      unlockedSinceBoot: true,
      ...overrides,
    },
  }
}

function syntheticWorkspaceStateFixture(root, artifactInventory) {
  const unresolvedSourceRoot = join(root, isolatedSourceRootName)
  const derivedData = join(root, 'DerivedData')
  mkdirSync(unresolvedSourceRoot, { recursive: true })
  const sourceRoot = realpathSync(unresolvedSourceRoot)
  const stagedRoot = join(sourceRoot, 'tools', 'runtime', '.build', 'artifacts')
  const workspaceStatePath = join(derivedData, 'SourcePackages', 'workspace-state.json')
  mkdirSync(stagedRoot, { recursive: true })
  mkdirSync(dirname(workspaceStatePath), { recursive: true })

  const artifacts = artifactInventory.targets.map(targetName => {
    const path = join(stagedRoot, `${targetName}.xcframework`)
    mkdirSync(path)
    return {
      kind: { xcframework: {} },
      packageRef: {
        identity: isolatedSourceRootName,
        kind: 'root',
        location: sourceRoot,
        name: isolatedSourceRootName,
      },
      path,
      source: { type: 'local' },
      targetName,
    }
  })
  const state = {
    object: { artifacts, dependencies: [], prebuilts: [] },
    version: 7,
  }
  const write = document => writeFileSync(
    workspaceStatePath,
    `${JSON.stringify(document)}\n`,
  )
  write(state)
  return { derivedData, sourceRoot, state, write }
}

function pngChunk(type, data) {
  const chunk = Buffer.alloc(12 + data.length)
  chunk.writeUInt32BE(data.length, 0)
  chunk.write(type, 4, 'ascii')
  data.copy(chunk, 8)
  return chunk
}

function syntheticPNG() {
  const header = Buffer.alloc(13)
  header.writeUInt32BE(1178, 0)
  header.writeUInt32BE(2556, 4)
  header[8] = 8
  header[9] = 6
  return Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    pngChunk('IHDR', header),
    pngChunk('IEND', Buffer.alloc(0)),
  ])
}

function syntheticAttachmentFixture(root, policy, inventory, deviceID) {
  const attachments = policy.requiredAttachments.map((name, index) => {
    const uuid = `00000000-0000-0000-0000-${String(index + 1).padStart(12, '0')}`
    const exportedFileName = `${uuid}.png`
    writeFileSync(join(root, exportedFileName), syntheticPNG())
    return {
      configurationName: 'Test Scheme Action',
      deviceId: deviceID,
      deviceName: 'iPhone',
      exportedFileName,
      isAssociatedWithFailure: false,
      suggestedHumanReadableName: `${name}_0_${uuid}.png`,
      timestamp: index + 1,
    }
  })
  return [{
    attachments,
    testIdentifier: `${inventory.entries[0]}()`,
    testIdentifierURL: `test://com.apple.xcode/QVACChat/${inventory.entries[0]}`,
  }]
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
  const { policy } = loadPolicy()
  const inventory = loadInventory(policy)
  const artifactInventory = loadArtifactInventory(policy)
  const deviceID = '00000000-0000000000000001'
  const identity = inventory.entries[0]
  validateTestResults(syntheticTestResults(identity, deviceID), inventory, deviceID)
  validateSummary(syntheticSummary(deviceID), deviceID)
  expectFailure(
    () => validateTestResults(syntheticTestResults(identity, deviceID, 'Skipped'), inventory, deviceID),
    'a skipped physical lifecycle test',
  )
  expectFailure(
    () => validateTestResults(syntheticTestResults(identity, deviceID, 'Passed', 'iOS Simulator'), inventory, deviceID),
    'Simulator evidence',
  )
  expectFailure(
    () => validateTestResults(syntheticTestResults(identity, 'WRONG-DEVICE'), inventory, deviceID),
    'a different physical device',
  )
  const wrongArchitecture = syntheticTestResults(identity, deviceID)
  wrongArchitecture.devices[0].architecture = 'arm64e'
  expectFailure(
    () => validateTestResults(wrongArchitecture, inventory, deviceID),
    'a non-arm64 result architecture',
  )
  const untimed = syntheticTestResults(identity, deviceID)
  delete untimed.testNodes[0].durationInSeconds
  expectFailure(() => validateTestResults(untimed, inventory, deviceID), 'an untimed test result')
  const extra = syntheticTestResults(identity, deviceID)
  extra.testNodes.push({ nodeType: 'Test Case', nodeIdentifier: 'OtherTests/testOther', result: 'Passed' })
  expectFailure(() => validateTestResults(extra, inventory, deviceID), 'an extra unreviewed test')
  expectFailure(
    () => validateSummary({ ...syntheticSummary(deviceID), totalTestCount: 0, passedTests: 0 }, deviceID),
    'an empty xcresult summary',
  )

  const expectedProject = '/tmp/qvac/source/Examples/QVACChat/QVACChat.xcodeproj'
  const expectedResult = '/tmp/qvac/evidence/physical-lifecycle.xcresult'
  const expectedDerivedData = '/tmp/qvac/DerivedData'
  const developmentTeam = 'ABCDEFGHIJ'
  const invocation = [
    'Command line invocation:',
    `    /xcode/xcodebuild -project ${expectedProject} -scheme ${policy.scheme} -destination "platform=iOS,id=${deviceID}" -derivedDataPath ${expectedDerivedData} -resultBundlePath ${expectedResult} "-only-testing:${policy.testModule}/${identity}" CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=${developmentTeam} -allowProvisioningUpdates test`,
    '',
  ].join('\n')
  const log = [
    invocation,
    '/tmp/DerivedData/Build/Products/Debug-iphoneos/QVACChat-iOS.app',
    '** TEST SUCCEEDED **',
  ].join('\n')
  const validatePhysicalLog = value => validateLog(
    value,
    policy,
    inventory,
    deviceID,
    developmentTeam,
    expectedProject,
    expectedResult,
    expectedDerivedData,
    true,
    false,
  )
  validatePhysicalLog(log)
  expectFailure(
    () => validatePhysicalLog(log.replace('** TEST SUCCEEDED **', 'Test Case synthetic skipped (0 seconds)\n** TEST SUCCEEDED **')),
    'a skipped xcodebuild log',
  )
  expectFailure(
    () => validatePhysicalLog(log.replace(deviceID, 'WRONG-DEVICE')),
    'a log for another destination',
  )
  expectFailure(
    () => validatePhysicalLog(log.replace(
      `-only-testing:${policy.testModule}/${identity}`,
      `-only-testing:${policy.testModule}/${identity} -only-testing:OtherTests/testOther`,
    )),
    'an extra only-testing selector',
  )
  for (const [needle, override, label] of [
    [`-project ${expectedProject}`, `-project ${expectedProject} -project /tmp/other/QVACChat.xcodeproj`, 'duplicate project'],
    [`-scheme ${policy.scheme}`, `-scheme ${policy.scheme} -scheme OtherScheme`, 'duplicate scheme'],
    [`-destination "platform=iOS,id=${deviceID}"`, `-destination "platform=iOS,id=${deviceID}" -destination "platform=iOS,id=OTHER-DEVICE"`, 'duplicate destination'],
    [`-derivedDataPath ${expectedDerivedData}`, `-derivedDataPath ${expectedDerivedData} -derivedDataPath /tmp/other/DerivedData`, 'duplicate DerivedData path'],
    [`-resultBundlePath ${expectedResult}`, `-resultBundlePath ${expectedResult} -resultBundlePath /tmp/other/result.xcresult`, 'duplicate result bundle path'],
    [`DEVELOPMENT_TEAM=${developmentTeam}`, `DEVELOPMENT_TEAM=${developmentTeam} DEVELOPMENT_TEAM=ZZZZZZZZZZ`, 'duplicate development team'],
    ['CODE_SIGN_STYLE=Automatic', 'CODE_SIGN_STYLE=Automatic CODE_SIGN_STYLE=Manual', 'duplicate signing style'],
    ['-allowProvisioningUpdates', '-allowProvisioningUpdates -allowProvisioningUpdates', 'duplicate provisioning flag'],
  ]) {
    expectFailure(
      () => validatePhysicalLog(log.replace(needle, override)),
      `a log with a ${label} override`,
    )
  }

  validateLockState(syntheticLockState(deviceID), deviceID)
  expectFailure(
    () => validateLockState(syntheticLockState(deviceID, { passcodeRequired: true }), deviceID),
    'a currently locked device',
  )
  expectFailure(
    () => validateLockState(syntheticLockState(deviceID, { unlockedSinceBoot: false }), deviceID),
    'a device not unlocked since boot',
  )
  expectFailure(
    () => validateLockState(syntheticLockState('WRONG-DEVICE'), deviceID),
    'lock evidence for another destination',
  )

  const workspaceFixtureRoot = mkdtempSync(join(tmpdir(), 'qvac-workspace-state-verifier.'))
  try {
    const fixture = syntheticWorkspaceStateFixture(workspaceFixtureRoot, artifactInventory)
    validateWorkspaceState(fixture.derivedData, fixture.sourceRoot, artifactInventory)
    const expectWorkspaceFailure = (mutate, label) => {
      const state = structuredClone(fixture.state)
      mutate(state)
      fixture.write(state)
      expectFailure(
        () => validateWorkspaceState(fixture.derivedData, fixture.sourceRoot, artifactInventory),
        label,
      )
    }
    expectWorkspaceFailure(
      state => { state.object.artifacts[0].packageRef.identity = 'qvac-swift' },
      'the pre-isolation package identity',
    )
    expectWorkspaceFailure(
      state => { state.object.artifacts[0].packageRef.name = 'qvac-swift' },
      'the pre-isolation package name',
    )
    expectWorkspaceFailure(
      state => { state.object.artifacts[0].source.type = 'remote' },
      'a non-local artifact source',
    )
    expectWorkspaceFailure(
      state => { state.object.artifacts[0].packageRef.kind = 'remoteSourceControl' },
      'a non-root package reference',
    )
    expectWorkspaceFailure(
      state => { state.object.artifacts[0].kind = { artifactBundle: {} } },
      'a non-XCFramework artifact',
    )
    expectWorkspaceFailure(
      state => { state.object.dependencies = [{ identity: 'unreviewed' }] },
      'an external SwiftPM dependency',
    )
    expectWorkspaceFailure(
      state => { state.object.prebuilts = [{ identity: 'unreviewed' }] },
      'an external SwiftPM prebuilt',
    )
    expectWorkspaceFailure(
      state => { state.object.artifacts[0].targetName = 'unreviewed-target' },
      'an artifact outside the reviewed target inventory',
    )
    const otherPackage = join(workspaceFixtureRoot, 'other-package')
    mkdirSync(otherPackage)
    expectWorkspaceFailure(
      state => { state.object.artifacts[0].packageRef.location = otherPackage },
      'an artifact attributed to another package checkout',
    )
    const outsideArtifact = join(workspaceFixtureRoot, 'outside.xcframework')
    mkdirSync(outsideArtifact)
    expectWorkspaceFailure(
      state => { state.object.artifacts[0].path = outsideArtifact },
      'an artifact outside the isolated staged closure',
    )
  } finally {
    rmSync(workspaceFixtureRoot, { recursive: true, force: true })
  }

  const fixture = mkdtempSync(join(tmpdir(), 'qvac-physical-lifecycle-verifier.'))
  try {
    const manifest = syntheticAttachmentFixture(fixture, policy, inventory, deviceID)
    const interval = { startTime: 0.5, finishTime: 5 }
    validateAttachmentManifest(manifest, fixture, policy, inventory, deviceID, interval)
    const missing = structuredClone(manifest)
    missing[0].attachments.pop()
    expectFailure(
      () => validateAttachmentManifest(missing, fixture, policy, inventory, deviceID, interval),
      'a missing lifecycle screenshot',
    )
    const duplicate = structuredClone(manifest)
    duplicate[0].attachments[3].suggestedHumanReadableName =
      duplicate[0].attachments[2].suggestedHumanReadableName
    expectFailure(
      () => validateAttachmentManifest(duplicate, fixture, policy, inventory, deviceID, interval),
      'a duplicate lifecycle screenshot',
    )
    const wrongAttachmentDevice = structuredClone(manifest)
    wrongAttachmentDevice[0].attachments[0].deviceId = 'WRONG-DEVICE'
    expectFailure(
      () => validateAttachmentManifest(wrongAttachmentDevice, fixture, policy, inventory, deviceID, interval),
      'a screenshot from another device',
    )
    const failureAttachment = structuredClone(manifest)
    failureAttachment[0].attachments[0].isAssociatedWithFailure = true
    expectFailure(
      () => validateAttachmentManifest(failureAttachment, fixture, policy, inventory, deviceID, interval),
      'a failure-associated screenshot',
    )
    const outOfOrder = structuredClone(manifest)
    outOfOrder[0].attachments[2].timestamp = outOfOrder[0].attachments[1].timestamp
    expectFailure(
      () => validateAttachmentManifest(outOfOrder, fixture, policy, inventory, deviceID, interval),
      'out-of-order lifecycle screenshots',
    )
    const outsideRun = structuredClone(manifest)
    outsideRun[0].attachments[0].timestamp = interval.finishTime + 1
    expectFailure(
      () => validateAttachmentManifest(outsideRun, fixture, policy, inventory, deviceID, interval),
      'a screenshot outside the test interval',
    )
    const unsafe = structuredClone(manifest)
    unsafe[0].attachments[0].exportedFileName = '../outside.png'
    expectFailure(
      () => validateAttachmentManifest(unsafe, fixture, policy, inventory, deviceID, interval),
      'an unsafe attachment file name',
    )
    const invalidPNG = structuredClone(manifest)
    const invalidName = invalidPNG[0].attachments[0].exportedFileName
    writeFileSync(join(fixture, invalidName), 'not a screenshot')
    expectFailure(
      () => validateAttachmentManifest(invalidPNG, fixture, policy, inventory, deviceID, interval),
      'an invalid PNG attachment',
    )
  } finally {
    rmSync(fixture, { recursive: true, force: true })
  }

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
    'an over-broad signing-field normalization',
  )
  const tamperedFileSize = Buffer.from(resignedMachO)
  tamperedFileSize.writeBigUInt64LE(4096n, 32 + 32 + 48)
  expectFailure(
    () => validateDeviceSigningTransformation(
      unsignedMachO,
      tamperedFileSize,
      resignedMachO.length + 16 * 1024,
      'synthetic BareKit',
    ),
    'a tampered __LINKEDIT file size',
  )
  const sourceSHA = 'a'.repeat(40)
  validateSourceState(sourceSHA, sourceSHA, '')
  expectFailure(() => validateSourceState(sourceSHA, 'b'.repeat(40), ''), 'a spoofed source commit')
  expectFailure(() => validateSourceState(sourceSHA, sourceSHA, ' M Package.swift'), 'a dirty source tree')
  console.log('[ios-physical-lifecycle-evidence-self-test] exact test/device/screenshots, lock state, SwiftPM closure, source binding, and signing normalization verified')
}

function validateLockStateFile(path, expectedDeviceID) {
  if (!/^[A-Za-z0-9-]{8,64}$/.test(expectedDeviceID)) fail('device ID has invalid syntax')
  const bytes = regularFile(resolve(path), 'device lock-state evidence', maximumMetadataBytes)
  return { bytes, evidence: validateLockState(parseJSON(bytes, 'device lock-state evidence'), expectedDeviceID) }
}

try {
  if (process.argv.length === 3 && process.argv[2] === '--self-test') {
    selfTest()
  } else if (process.argv.length === 6 && process.argv[2] === '--validate-lock-state') {
    const args = parseArguments(process.argv.slice(2), ['--validate-lock-state', '--device-id'])
    validateLockStateFile(args['validate-lock-state'], args['device-id'])
    console.log(`[ios-physical-lifecycle-evidence] unlocked device preflight PASS device=${args['device-id']}`)
  } else {
    const expected = [
      '--xcresult', '--log', '--derived-data', '--candidate', '--source-archive',
      '--source-root', '--source-sha', '--device-id', '--device-lock-state',
      '--candidate-log', '--development-team', '--allow-provisioning-updates',
      '--allow-provisioning-device-registration', '--xcodegen', '--output',
    ]
    const args = parseArguments(process.argv.slice(2), expected)
    if (!/^[0-9a-f]{40}$/.test(args['source-sha'])) fail('source SHA must be a full lowercase Git commit')
    if (!/^[A-Za-z0-9-]{8,64}$/.test(args['device-id'])) fail('device ID has invalid syntax')
    if (!/^[A-Z0-9]{10}$/.test(args['development-team'])) fail('development team has invalid syntax')
    if (!['true', 'false'].includes(args['allow-provisioning-updates'])
        || !['true', 'false'].includes(args['allow-provisioning-device-registration'])) {
      fail('provisioning policy arguments must be true or false')
    }
    const allowProvisioningUpdates = args['allow-provisioning-updates'] === 'true'
    const allowDeviceRegistration = args['allow-provisioning-device-registration'] === 'true'
    if (allowDeviceRegistration && !allowProvisioningUpdates) {
      fail('device registration requires provisioning updates')
    }
    const repositoryHead = run(
      'git', ['-C', repositoryRoot, 'rev-parse', '--verify', 'HEAD'],
      'source commit resolution', maximumMetadataBytes,
    ).trim()
    const repositoryStatus = run(
      'git', ['-C', repositoryRoot, 'status', '--porcelain', '--untracked-files=all'],
      'source checkout status', maximumMetadataBytes,
    )
    validateSourceState(args['source-sha'], repositoryHead, repositoryStatus)

    const xcresult = realDirectory(resolve(args.xcresult), 'xcresult bundle')
    const derivedData = realDirectory(resolve(args['derived-data']), 'DerivedData')
    const candidate = realDirectory(resolve(args.candidate), 'BareKit candidate')
    const sourceRoot = realDirectory(resolve(args['source-root']), 'isolated source root')
    const output = resolve(args.output)
    const outputParent = realDirectory(dirname(output), 'output parent')
    if (outputParent === repositoryRoot || outputParent.startsWith(`${repositoryRoot}/`)) {
      fail('evidence output must be outside the source repository')
    }
    try {
      const stat = lstatSync(output)
      if (stat.isSymbolicLink() || stat.isDirectory()) fail('output must be a new regular file')
      fail('output file already exists')
    } catch (error) {
      if (error?.code !== 'ENOENT') throw error
    }

    const { policy, bytes: policyBytes } = loadPolicy()
    const inventory = loadInventory(policy)
    const artifactInventory = loadArtifactInventory(policy)
    const buildInputs = verifyIsolatedBuildInputs({
      sourceArchive: resolve(args['source-archive']),
      sourceRoot,
      sourceCommit: args['source-sha'],
      xcodegen: resolve(args.xcodegen),
    })
    const worker = regularFile(
      join(sourceRoot, policy.workerBundlePath),
      'isolated mobile worker bundle',
      policy.workerBundleSize,
    )
    if (worker.length !== policy.workerBundleSize || sha256(worker) !== policy.workerBundleSHA256) {
      fail('isolated mobile worker bundle differs from the reviewed SDK 0.17.0 bundle')
    }
    const workspaceState = validateWorkspaceState(derivedData, sourceRoot, artifactInventory)
    const lockState = validateLockStateFile(args['device-lock-state'], args['device-id'])
    const logBytes = regularFile(resolve(args.log), 'xcodebuild log', maximumLogBytes)
    const log = strictUTF8(logBytes, 'xcodebuild log')
    const expectedProject = join(sourceRoot, 'Examples', 'QVACChat', 'QVACChat.xcodeproj')
    validateLog(
      log,
      policy,
      inventory,
      args['device-id'],
      args['development-team'],
      expectedProject,
      xcresult,
      derivedData,
      allowProvisioningUpdates,
      allowDeviceRegistration,
    )
    const candidateLogBytes = regularFile(
      resolve(args['candidate-log']),
      'candidate verification log',
      maximumLogBytes,
    )
    const candidateLog = strictUTF8(candidateLogBytes, 'candidate verification log')
    const reproducedCandidateLog = run(
      'node',
      [join(repositoryRoot, 'tools', 'native', 'bare-kit', 'verify.mjs'), '--artifact', candidate],
      'BareKit candidate verification reproduction',
      maximumLogBytes,
    )
    if (candidateLog.trimEnd() !== reproducedCandidateLog.trimEnd()) {
      fail('candidate verification log cannot be reproduced from the selected XCFramework')
    }

    const testsDocument = parseJSON(Buffer.from(run('xcrun', [
      'xcresulttool', 'get', 'test-results', 'tests', '--path', xcresult, '--format', 'json',
    ], 'xcresult tests extraction')), 'xcresult tests')
    const summaryDocument = parseJSON(Buffer.from(run('xcrun', [
      'xcresulttool', 'get', 'test-results', 'summary', '--path', xcresult, '--format', 'json',
    ], 'xcresult summary extraction')), 'xcresult summary')
    const results = validateTestResults(testsDocument, inventory, args['device-id'])
    const summary = validateSummary(summaryDocument, args['device-id'])
    if (JSON.stringify(results.device) !== JSON.stringify(summary.device)) {
      fail('xcresult tests and summary documents disagree about the physical device')
    }
    const attachments = validateAttachments(
      xcresult,
      policy,
      inventory,
      args['device-id'],
      summary,
    )
    const candidateEvidence = validateEmbeddedCandidate(candidate, derivedData, policy.patchMarker)

    const finalStatus = run(
      'git', ['-C', repositoryRoot, 'status', '--porcelain', '--untracked-files=all'],
      'final source checkout status', maximumMetadataBytes,
    )
    validateSourceState(args['source-sha'], repositoryHead, finalStatus)
    const evidence = {
      schemaVersion: 1,
      result: 'PASS',
      sourceCommit: args['source-sha'],
      sourceArchiveSHA256: buildInputs.sourceArchive.sha256,
      buildInputs: {
        effectiveSourceTree: buildInputs.effectiveSourceTree,
        generatedProject: buildInputs.generatedProject,
        xcodeGen: buildInputs.xcodeGen,
        artifactClosure: buildInputs.artifactClosure,
      },
      policySHA256: sha256(policyBytes),
      inventorySHA256: sha256(inventory.bytes),
      artifactManifestSHA256: sha256(artifactInventory.bytes),
      signing: {
        style: 'Automatic',
        developmentTeam: args['development-team'],
        allowProvisioningUpdates,
        allowProvisioningDeviceRegistration: allowDeviceRegistration,
      },
      workspaceState,
      candidate: {
        patchMarker: policy.patchMarker,
        selectedDeviceBinarySHA256: candidateEvidence.expectedSHA256,
        embeddedProductCount: candidateEvidence.embeddedCount,
        byteExactProductCount: candidateEvidence.exactCount,
        resignedProductCount: candidateEvidence.resignedCount,
      },
      device: results.device,
      lockState: {
        ...lockState.evidence,
        sha256: sha256(lockState.bytes),
      },
      tests: results.cases.map(test => ({
        identity: normalizeIdentity(test.nodeIdentifier),
        result: test.result,
        durationSeconds: test.durationInSeconds,
      })),
      attachments,
      log: { byteCount: logBytes.length, sha256: sha256(logBytes) },
      candidateVerificationLog: {
        byteCount: candidateLogBytes.length,
        sha256: sha256(candidateLogBytes),
      },
    }
    writeFileSync(output, `${JSON.stringify(evidence, null, 2)}\n`, { flag: 'wx' })
    console.log(`[ios-physical-lifecycle-evidence] PASS device=${args['device-id']} candidate-sha256=${candidateEvidence.expectedSHA256}`)
  }
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error))
  process.exit(1)
}
