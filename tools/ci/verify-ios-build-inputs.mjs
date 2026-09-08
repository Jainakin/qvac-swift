#!/usr/bin/env node

import { createHash } from 'node:crypto'
import {
  chmodSync,
  closeSync,
  copyFileSync,
  lstatSync,
  mkdtempSync,
  mkdirSync,
  openSync,
  readFileSync,
  readSync,
  readdirSync,
  realpathSync,
  rmSync,
  symlinkSync,
  utimesSync,
  writeFileSync,
} from 'node:fs'
import { basename, dirname, join, resolve } from 'node:path'
import { tmpdir } from 'node:os'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const scriptDirectory = dirname(fileURLToPath(import.meta.url))
const repositoryRoot = realpathSync(resolve(scriptDirectory, '../..'))
const artifactLockPath = join(scriptDirectory, 'ios-local-artifact-tree-lock.json')
const artifactManifestPath = join(repositoryRoot, 'tools/release/artifacts.development.json')
const maximumMetadataBytes = 1024 * 1024
const maximumSourceArchiveBytes = 512 * 1024 * 1024
const hashBuffer = Buffer.allocUnsafe(1024 * 1024)
const sourceTreeAlgorithm = 'qvac-canonical-source-tree-v1'
const artifactTreeAlgorithm = 'qvac-canonical-signed-xcframework-v1'
const artifactMapAlgorithm = 'qvac-canonical-ios-artifact-map-v1'
const maximumResidualSigningVirtualBytes = 1024n * 1024n
const codeSignPath = '/usr/bin/codesign'

// Updated together with ios-local-artifact-tree-lock.json after an explicit
// review of a newly staged SDK closure.
export const reviewedArtifactLockSHA256 =
  'e65402fd2c00c7fa3bfe491367461b8e63f2168bf0a22d91ff8b99db60436aa0'
export const pinnedXcodeGenVersion = '2.46.0'
export const pinnedXcodeGenExecutableSHA256 =
  '8774da746668bc18fe74e54cbaf10f2631a1fb05947cd374179aa912f14f99db'

function fail(message) {
  throw new Error(`[ios-build-inputs] ${message}`)
}

function sha256(bytes) {
  return createHash('sha256').update(bytes).digest('hex')
}

function portablePermissions(stat, label) {
  const permissions = stat.mode & 0o7777
  if ((permissions & 0o7000) !== 0) {
    fail(`${label} contains setuid, setgid, or sticky permission bits`)
  }
  return permissions & 0o777
}

function canonicalEntriesSHA256(entries, algorithm) {
  const manifest = Buffer.from(`${JSON.stringify(entries)}\n`)
  return sha256(Buffer.concat([Buffer.from(`${algorithm}\0`), manifest]))
}

function exactKeys(value, expected, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    fail(`${label} must be an object`)
  }
  const actual = Object.keys(value).sort()
  const wanted = [...expected].sort()
  if (JSON.stringify(actual) !== JSON.stringify(wanted)) {
    fail(`${label} keys differ: expected ${wanted.join(', ')}, got ${actual.join(', ')}`)
  }
}

function realDirectory(path, label) {
  let stat
  try { stat = lstatSync(path) } catch (error) { fail(`cannot inspect ${label}: ${error.message}`) }
  if (stat.isSymbolicLink() || !stat.isDirectory()) {
    fail(`${label} must be a real, non-symlink directory`)
  }
  portablePermissions(stat, label)
  return realpathSync(path)
}

function regularFile(path, label, maximumBytes = Number.MAX_SAFE_INTEGER) {
  let stat
  try { stat = lstatSync(path) } catch (error) { fail(`cannot inspect ${label}: ${error.message}`) }
  if (stat.isSymbolicLink() || !stat.isFile()) {
    fail(`${label} must be a regular, non-symlink file`)
  }
  portablePermissions(stat, label)
  if (stat.size > maximumBytes) fail(`${label} exceeds ${maximumBytes} bytes`)
  return { bytes: readFileSync(path), stat }
}

function run(command, args, label, options = {}) {
  const result = spawnSync(command, args, {
    encoding: 'utf8',
    maxBuffer: 16 * 1024 * 1024,
    ...options,
  })
  if (result.status !== 0) {
    const detail = String(result.stderr || result.stdout || `status ${result.status}`).trim()
    fail(`${label} failed: ${detail}`)
  }
  return result.stdout
}

function validateAdHocSignatureMetadata(metadata, entitlementDisplay, label) {
  if (!/^Signature=adhoc$/m.test(metadata)
      || !/^TeamIdentifier=not set$/m.test(metadata)
      || !/^Internal requirements count=0(?:\s|$)/m.test(metadata)
      || !/^CodeDirectory .*flags=.*\(adhoc\)/m.test(metadata)) {
    fail(`${label} must use the reviewed ad-hoc, no-team signature identity`)
  }
  const entitlementLines = entitlementDisplay.split('\n')
    .map(line => line.trim())
    .filter(line => line.length > 0 && !line.startsWith('warning:'))
  if (entitlementLines.length !== 1 || !entitlementLines[0].startsWith('Executable=')) {
    fail(`${label} must not contain code-signing entitlements`)
  }
}

function verifyAdHocSignature(path, label) {
  const display = spawnSync(codeSignPath, ['-d', '--verbose=4', path], {
    encoding: 'utf8',
    maxBuffer: 1024 * 1024,
  })
  if (display.status !== 0) {
    fail(`${label} signature metadata inspection failed`)
  }
  const entitlements = spawnSync(codeSignPath, ['-d', '--entitlements', '-', path], {
    encoding: 'utf8',
    maxBuffer: 1024 * 1024,
  })
  if (entitlements.status !== 0) {
    fail(`${label} entitlement inspection failed`)
  }
  validateAdHocSignatureMetadata(
    `${display.stdout}${display.stderr}`,
    `${entitlements.stdout}${entitlements.stderr}`,
    label,
  )
}

function sha256File(path) {
  const hash = createHash('sha256')
  const descriptor = openSync(path, 'r')
  try {
    for (;;) {
      const count = readSync(descriptor, hashBuffer, 0, hashBuffer.length, null)
      if (count === 0) break
      hash.update(hashBuffer.subarray(0, count))
    }
  } finally {
    closeSync(descriptor)
  }
  return hash.digest('hex')
}

export function snapshotCanonicalTree(root, label = 'tree', options = {}) {
  const canonicalRoot = realDirectory(resolve(root), label)
  const entries = []
  const excluded = options.excludeRelativePaths ?? []
  if (!Array.isArray(excluded)
      || excluded.some(path => typeof path !== 'string'
        || path.length === 0 || path.startsWith('/') || path.includes('..'))) {
    fail(`${label} canonical-tree exclusions are invalid`)
  }

  function isExcluded(relativePath) {
    return excluded.some(path => relativePath === path || relativePath.startsWith(`${path}/`))
  }

  function visit(directory, prefix) {
    const names = readdirSync(directory).sort()
    for (const name of names) {
      const path = join(directory, name)
      const relativePath = prefix.length === 0 ? name : `${prefix}/${name}`
      if (isExcluded(relativePath)) continue
      const stat = lstatSync(path)
      if (stat.isSymbolicLink()) fail(`${label} contains a symlink: ${relativePath}`)
      if (stat.isDirectory()) {
        entries.push({
          path: relativePath,
          type: 'directory',
          permissions: portablePermissions(stat, `${label} ${relativePath}`),
        })
        visit(path, relativePath)
      } else if (stat.isFile()) {
        entries.push({
          path: relativePath,
          type: 'file',
          permissions: portablePermissions(stat, `${label} ${relativePath}`),
          byteCount: stat.size,
          sha256: sha256File(path),
        })
      } else {
        fail(`${label} contains an unsupported filesystem entry: ${relativePath}`)
      }
    }
  }

  visit(canonicalRoot, '')
  return {
    root: canonicalRoot,
    entries,
    algorithm: sourceTreeAlgorithm,
    treeSHA256: canonicalEntriesSHA256(entries, sourceTreeAlgorithm),
  }
}

function sameSnapshot(left, right) {
  return JSON.stringify(left.entries) === JSON.stringify(right.entries)
}

function isMachOMagic(bytes) {
  if (bytes.length < 4) return false
  const magic = bytes.readUInt32BE(0)
  return magic === 0xcafebabe
    || magic === 0xcafebabf
    || magic === 0xfeedfacf
    || magic === 0xcffaedfe
    || magic === 0xfeedface
    || magic === 0xcefaedfe
}

function machOSlices(bytes, label) {
  if (bytes.length < 4) fail(`${label} is a truncated Mach-O`)
  const bigEndianMagic = bytes.readUInt32BE(0)
  if (bigEndianMagic === 0xcafebabf) fail(`${label} uses unsupported FAT_MAGIC_64`)
  if (bigEndianMagic === 0xbebafeca || bigEndianMagic === 0xbfbafeca) {
    fail(`${label} uses an unsupported byte-swapped fat header`)
  }
  if (bigEndianMagic !== 0xcafebabe) {
    if (bytes.readUInt32LE(0) !== 0xfeedfacf) {
      fail(`${label} must contain only little-endian MH_MAGIC_64 slices`)
    }
    return [{ offset: 0, size: bytes.length, cpuType: bytes.readInt32LE(4) }]
  }

  if (bytes.length < 8) fail(`${label} has a truncated fat header`)
  const count = bytes.readUInt32BE(4)
  if (count < 1 || count > 8 || 8 + count * 20 > bytes.length) {
    fail(`${label} has an invalid fat-architecture table`)
  }
  const tableEnd = 8 + count * 20
  const slices = []
  for (let index = 0; index < count; index++) {
    const entry = 8 + index * 20
    const cpuType = bytes.readInt32BE(entry)
    const offset = bytes.readUInt32BE(entry + 8)
    const size = bytes.readUInt32BE(entry + 12)
    const alignment = bytes.readUInt32BE(entry + 16)
    if (alignment > 30 || offset < tableEnd || size < 32
        || offset + size > bytes.length
        || offset % (2 ** alignment) !== 0) {
      fail(`${label} has an invalid fat slice extent`)
    }
    if (bytes.readUInt32LE(offset) !== 0xfeedfacf
        || bytes.readInt32LE(offset + 4) !== cpuType) {
      fail(`${label} fat metadata disagrees with its MH_MAGIC_64 slice`)
    }
    slices.push({ offset, size, cpuType })
  }
  const ordered = [...slices].sort((left, right) => left.offset - right.offset)
  for (let index = 1; index < ordered.length; index++) {
    if (ordered[index - 1].offset + ordered[index - 1].size > ordered[index].offset) {
      fail(`${label} contains overlapping fat slices`)
    }
  }
  return slices
}

function machOPageSize(cpuType, label) {
  if (cpuType === 0x0100000c) return 0x4000n
  if (cpuType === 0x01000007) return 0x1000n
  fail(`${label} contains an unsupported Mach-O CPU type`)
}

function validateSignedMachO(bytes, label) {
  for (const slice of machOSlices(bytes, label)) {
    const commandCount = bytes.readUInt32LE(slice.offset + 16)
    const commandBytes = bytes.readUInt32LE(slice.offset + 20)
    let commandOffset = slice.offset + 32
    const commandEnd = commandOffset + commandBytes
    const sliceEnd = slice.offset + slice.size
    if (commandCount > 16_384 || commandEnd > sliceEnd) {
      fail(`${label} has an invalid signed Mach-O load-command table`)
    }
    let linkedit = null
    let codeSignature = null
    for (let index = 0; index < commandCount; index++) {
      if (commandOffset + 8 > commandEnd) fail(`${label} has truncated signed load commands`)
      const command = bytes.readUInt32LE(commandOffset)
      const commandSize = bytes.readUInt32LE(commandOffset + 4)
      if (commandSize < 8 || commandOffset + commandSize > commandEnd) {
        fail(`${label} has an invalid signed Mach-O load command`)
      }
      if (command === 0x19) {
        if (commandSize < 72) fail(`${label} has a truncated signed LC_SEGMENT_64`)
        const segment = bytes.subarray(commandOffset + 8, commandOffset + 24)
          .toString('ascii').replace(/\0.*$/, '')
        if (segment === '__LINKEDIT') {
          if (linkedit !== null) fail(`${label} has multiple signed __LINKEDIT segments`)
          linkedit = {
            virtualSize: bytes.readBigUInt64LE(commandOffset + 32),
            fileOffset: bytes.readBigUInt64LE(commandOffset + 40),
            fileSize: bytes.readBigUInt64LE(commandOffset + 48),
          }
        }
      } else if (command === 0x1d) {
        if (commandSize !== 16 || codeSignature !== null) {
          fail(`${label} has an invalid or duplicate LC_CODE_SIGNATURE`)
        }
        codeSignature = {
          dataOffset: BigInt(bytes.readUInt32LE(commandOffset + 8)),
          dataSize: BigInt(bytes.readUInt32LE(commandOffset + 12)),
        }
      }
      commandOffset += commandSize
    }
    if (commandOffset !== commandEnd || linkedit === null || codeSignature === null) {
      fail(`${label} must contain exactly one signed __LINKEDIT and LC_CODE_SIGNATURE per slice`)
    }
    // codesign lays out these iOS device and Simulator signatures on 16 KiB
    // pages for both arm64 and x86_64 slices. The unsigned canonical form below
    // uses each architecture's runtime page size after the signature is gone.
    machOPageSize(slice.cpuType, label)
    const signingPageSize = 0x4000n
    const canonicalVirtualSize = (
      (linkedit.fileSize + signingPageSize - 1n) / signingPageSize
    ) * signingPageSize
    const signatureEnd = codeSignature.dataOffset + codeSignature.dataSize
    if (codeSignature.dataSize === 0n
        || linkedit.virtualSize !== canonicalVirtualSize
        || linkedit.fileOffset + linkedit.fileSize !== BigInt(slice.size)
        || codeSignature.dataOffset < linkedit.fileOffset
        || signatureEnd !== BigInt(slice.size)
        || signatureEnd > linkedit.fileOffset + linkedit.fileSize) {
      fail(`${label} has non-canonical signed __LINKEDIT or code-signature extents`)
    }
  }
}

function normalizeUnsignedMachOLinkedit(bytes, label) {
  const normalized = Buffer.from(bytes)
  for (const slice of machOSlices(normalized, label)) {
    const sliceEnd = slice.offset + slice.size
    const commandCount = normalized.readUInt32LE(slice.offset + 16)
    const commandBytes = normalized.readUInt32LE(slice.offset + 20)
    let commandOffset = slice.offset + 32
    const commandEnd = commandOffset + commandBytes
    if (commandCount > 16_384 || commandEnd > sliceEnd) {
      fail(`${label} has an invalid Mach-O load-command table`)
    }
    let linkeditCount = 0
    for (let index = 0; index < commandCount; index++) {
      if (commandOffset + 8 > commandEnd) fail(`${label} has truncated Mach-O load commands`)
      const command = normalized.readUInt32LE(commandOffset)
      const commandSize = normalized.readUInt32LE(commandOffset + 4)
      if (commandSize < 8 || commandOffset + commandSize > commandEnd) {
        fail(`${label} has an invalid Mach-O load command`)
      }
      if (command === 0x1d) {
        fail(`${label} still contains LC_CODE_SIGNATURE after signature removal`)
      }
      if (command === 0x19) {
        if (commandSize < 72) fail(`${label} has a truncated LC_SEGMENT_64`)
        const segment = normalized.subarray(commandOffset + 8, commandOffset + 24)
          .toString('ascii').replace(/\0.*$/, '')
        if (segment === '__LINKEDIT') {
          linkeditCount += 1
          const fileOffset = normalized.readBigUInt64LE(commandOffset + 40)
          const fileSize = normalized.readBigUInt64LE(commandOffset + 48)
          const virtualSize = normalized.readBigUInt64LE(commandOffset + 32)
          const pageSize = machOPageSize(slice.cpuType, label)
          const canonicalVirtualSize = ((fileSize + pageSize - 1n) / pageSize) * pageSize
          if (fileSize > virtualSize
              || virtualSize < canonicalVirtualSize
              || virtualSize - canonicalVirtualSize > maximumResidualSigningVirtualBytes
              || virtualSize % pageSize !== 0n
              || fileOffset + fileSize !== BigInt(slice.size)) {
            fail(`${label} has invalid unsigned __LINKEDIT extents`)
          }
          // Apple signing can retain a page-rounded virtual-size increment after
          // signature removal. Re-derive the minimum valid unsigned extent from
          // the still-bound file size rather than ignoring this dyld field.
          normalized.writeBigUInt64LE(canonicalVirtualSize, commandOffset + 32)
        }
      }
      commandOffset += commandSize
    }
    if (commandOffset !== commandEnd || linkeditCount !== 1) {
      fail(`${label} must contain exactly one well-formed __LINKEDIT segment per slice`)
    }
  }
  return normalized
}

function canonicalMachO(path, label, temporaryDirectory, index) {
  const { bytes: signedBytes } = regularFile(path, `signed ${label}`, 512 * 1024 * 1024)
  validateSignedMachO(signedBytes, label)
  const temporary = join(temporaryDirectory, `mach-o-${index}`)
  copyFileSync(path, temporary)
  run(codeSignPath, ['--remove-signature', temporary], `${label} signature removal`)
  const { bytes } = regularFile(temporary, `signature-stripped ${label}`, 512 * 1024 * 1024)
  const normalized = normalizeUnsignedMachOLinkedit(bytes, label)
  const cpuTypes = machOSlices(normalized, label).map(slice => slice.cpuType)
  return {
    byteCount: normalized.length,
    sha256: sha256(normalized),
    cpuTypes,
  }
}

function validateSignatureEnvelope(directory, relativePath, label) {
  const directoryStat = lstatSync(directory)
  if (directoryStat.isSymbolicLink() || !directoryStat.isDirectory()
      || portablePermissions(directoryStat, `${label} ${relativePath}`) !== 0o755) {
    fail(`${label} signature envelope directories must be real mode-0755 directories`)
  }
  for (const name of readdirSync(directory).sort()) {
    const entryPath = join(directory, name)
    const entryRelativePath = `${relativePath}/${name}`
    const stat = lstatSync(entryPath)
    if (stat.isSymbolicLink()) fail(`${label} contains a symlink: ${entryRelativePath}`)
    const permissions = portablePermissions(stat, `${label} ${entryRelativePath}`)
    if (stat.isDirectory()) {
      validateSignatureEnvelope(entryPath, entryRelativePath, label)
    } else if (!stat.isFile() || permissions !== 0o644) {
      fail(`${label} signature envelope files must be regular mode-0644 files`)
    }
  }
}

export function snapshotCanonicalArtifactTree(root, label = 'iOS artifact') {
  const canonicalRoot = realDirectory(resolve(root), label)
  run(codeSignPath, ['--verify', '--strict', canonicalRoot], `${label} signature verification`)
  verifyAdHocSignature(canonicalRoot, label)
  const temporary = mkdtempSync(join(tmpdir(), 'qvac-artifact-canonicalization.'))
  const rootStat = lstatSync(canonicalRoot)
  if (portablePermissions(rootStat, label) !== 0o755) {
    fail(`${label} root directory must have mode 0755`)
  }
  const entries = []
  const verifiedFrameworks = new Set()
  const machOTopology = []
  let machOCount = 0

  function visit(directory, prefix) {
    for (const name of readdirSync(directory).sort()) {
      const path = join(directory, name)
      const relativePath = prefix.length === 0 ? name : `${prefix}/${name}`
      const stat = lstatSync(path)
      if (stat.isSymbolicLink()) fail(`${label} contains a symlink: ${relativePath}`)
      const permissions = portablePermissions(stat, `${label} ${relativePath}`)
      if (name === '_CodeSignature') {
        if (!stat.isDirectory()) fail(`${label} has a non-directory signature envelope`)
        validateSignatureEnvelope(path, relativePath, label)
        continue
      }
      if (stat.isDirectory()) {
        if (name.endsWith('.framework')) {
          run(codeSignPath, ['--verify', '--strict', path], `${label} framework signature verification`)
          verifyAdHocSignature(path, `${label} framework`)
          verifiedFrameworks.add(path)
        }
        entries.push({
          path: relativePath,
          type: 'directory',
          permissions,
        })
        visit(path, relativePath)
      } else if (stat.isFile()) {
        const descriptor = openSync(path, 'r')
        let prefixBytes
        try {
          prefixBytes = Buffer.alloc(Math.min(4, stat.size))
          if (prefixBytes.length > 0) readSync(descriptor, prefixBytes, 0, prefixBytes.length, 0)
        } finally {
          closeSync(descriptor)
        }
        let digest
        if (isMachOMagic(prefixBytes)) {
          const framework = dirname(path)
          if (!basename(framework).endsWith('.framework') || !verifiedFrameworks.has(framework)) {
            fail(`${label} contains a Mach-O outside a verified framework: ${relativePath}`)
          }
          digest = canonicalMachO(path, `${label} ${relativePath}`, temporary, machOCount)
          machOTopology.push({ path: relativePath, cpuTypes: digest.cpuTypes })
          delete digest.cpuTypes
          machOCount += 1
        } else {
          digest = { byteCount: stat.size, sha256: sha256File(path) }
        }
        entries.push({
          path: relativePath,
          type: 'file',
          permissions,
          ...digest,
        })
      } else {
        fail(`${label} contains an unsupported filesystem entry: ${relativePath}`)
      }
    }
  }

  try {
    visit(canonicalRoot, '')
    const target = basename(canonicalRoot).replace(/\.xcframework$/, '')
    const expectedTopology = [
      {
        path: `ios-arm64/${target}.framework/${target}`,
        cpuTypes: [0x0100000c],
      },
      {
        path: `ios-arm64_x86_64-simulator/${target}.framework/${target}`,
        cpuTypes: [0x0100000c, 0x01000007],
      },
    ]
    machOTopology.sort((left, right) => left.path.localeCompare(right.path))
    expectedTopology.sort((left, right) => left.path.localeCompare(right.path))
    if (JSON.stringify(machOTopology) !== JSON.stringify(expectedTopology)) {
      fail(`${label} Mach-O topology differs from the reviewed device/Simulator closure`)
    }
    return {
      root: canonicalRoot,
      entries,
      machOCount,
      algorithm: artifactTreeAlgorithm,
      treeSHA256: canonicalEntriesSHA256(entries, artifactTreeAlgorithm),
    }
  } finally {
    rmSync(temporary, { recursive: true, force: true })
  }
}

export function verifyPinnedXcodeGen(path) {
  if (typeof path !== 'string' || !path.startsWith('/')) fail('XcodeGen path must be absolute')
  const canonical = realpathSync(resolve(path))
  const { stat } = regularFile(canonical, 'pinned XcodeGen executable', 128 * 1024 * 1024)
  if ((stat.mode & 0o111) === 0) fail('pinned XcodeGen must be executable')
  const executableSHA256 = sha256File(canonical)
  if (executableSHA256 !== pinnedXcodeGenExecutableSHA256) {
    fail('XcodeGen executable SHA-256 differs from the reviewed 2.46.0 binary')
  }
  const version = run(canonical, ['--version'], 'XcodeGen version inspection').trim()
  if (version !== `Version: ${pinnedXcodeGenVersion}`) {
    fail(`XcodeGen ${pinnedXcodeGenVersion} is required`)
  }
  return { version: pinnedXcodeGenVersion, executableSHA256 }
}

export function verifySourceArchiveCommit(sourceArchive, sourceCommit) {
  if (!/^[0-9a-f]{40}$/.test(sourceCommit)) fail('source commit must be a full lowercase SHA')
  const canonicalArchive = resolve(sourceArchive)
  const { bytes } = regularFile(
    canonicalArchive,
    'isolated source archive',
    maximumSourceArchiveBytes,
  )
  const fixture = mkdtempSync(join(tmpdir(), 'qvac-source-archive-reproduction.'))
  try {
    const reproduced = join(fixture, 'source.tar')
    run(
      'git',
      ['-C', repositoryRoot, 'archive', '--format=tar', '--output', reproduced, sourceCommit],
      'source archive reproduction',
    )
    const { bytes: reproducedBytes } = regularFile(
      reproduced,
      'reproduced source archive',
      maximumSourceArchiveBytes,
    )
    if (!bytes.equals(reproducedBytes)) {
      fail('isolated source archive differs from the exact repository commit')
    }
    return { byteCount: bytes.length, sha256: sha256(bytes) }
  } finally {
    rmSync(fixture, { recursive: true, force: true })
  }
}

export function verifyIsolatedBuildInputs({
  sourceArchive,
  sourceRoot,
  sourceCommit,
  xcodegen,
}) {
  const archive = verifySourceArchiveCommit(sourceArchive, sourceCommit)
  const canonicalSourceRoot = realDirectory(resolve(sourceRoot), 'isolated source root')
  if (canonicalSourceRoot === repositoryRoot
      || canonicalSourceRoot.startsWith(`${repositoryRoot}/`)) {
    fail('isolated source root must be outside the repository')
  }
  const xcodeGenEvidence = verifyPinnedXcodeGen(xcodegen)
  const runtimeBuild = realDirectory(
    join(canonicalSourceRoot, 'tools', 'runtime', '.build'),
    'isolated runtime build root',
  )
  const runtimeBuildEntries = readdirSync(runtimeBuild).sort()
  if (JSON.stringify(runtimeBuildEntries) !== JSON.stringify(['artifacts'])) {
    fail('isolated runtime build root may contain only the staged artifact closure')
  }
  const artifactClosure = verifyNonBareArtifactClosure(
    join(runtimeBuild, 'artifacts'),
    { requireExactRoot: true },
  )

  const fixture = mkdtempSync(join(tmpdir(), 'qvac-isolated-source-reproduction.'))
  try {
    const expectedRoot = join(fixture, 'source')
    mkdirSync(expectedRoot)
    run(
      'tar',
      ['-xf', resolve(sourceArchive), '-C', expectedRoot],
      'source archive extraction',
    )
    copyFileSync(
      join(expectedRoot, 'Package.swift.dev'),
      join(expectedRoot, 'Package.swift'),
    )
    const expectedExample = join(expectedRoot, 'Examples', 'QVACChat')
    run(xcodegen, ['generate'], 'independent Xcode project generation', { cwd: expectedExample })

    const expected = snapshotCanonicalTree(expectedRoot, 'reproduced isolated source')
    const actual = snapshotCanonicalTree(canonicalSourceRoot, 'isolated build source', {
      excludeRelativePaths: ['tools/runtime/.build'],
    })
    if (!sameSnapshot(expected, actual)) {
      const expectedByPath = new Map(expected.entries.map(entry => [entry.path, entry]))
      const actualByPath = new Map(actual.entries.map(entry => [entry.path, entry]))
      const paths = [...new Set([...expectedByPath.keys(), ...actualByPath.keys()])].sort()
      const drift = paths.find(path =>
        JSON.stringify(expectedByPath.get(path)) !== JSON.stringify(actualByPath.get(path)))
      fail(`isolated build source differs from the exact effective source tree at ${drift ?? '<unknown>'}`)
    }
    const generatedProject = snapshotCanonicalTree(
      join(canonicalSourceRoot, 'Examples', 'QVACChat', 'QVACChat.xcodeproj'),
      'isolated generated Xcode project',
    )
    return {
      sourceArchive: archive,
      effectiveSourceTree: {
        entryCount: actual.entries.length,
        treeSHA256: actual.treeSHA256,
      },
      generatedProject: {
        entryCount: generatedProject.entries.length,
        treeSHA256: generatedProject.treeSHA256,
      },
      xcodeGen: xcodeGenEvidence,
      artifactClosure,
    }
  } finally {
    rmSync(fixture, { recursive: true, force: true })
  }
}

function loadDevelopmentArtifactTargets() {
  const { bytes: manifestBytes } = regularFile(
    artifactManifestPath,
    'SDK 0.17.0 development artifact manifest',
    maximumMetadataBytes,
  )
  let artifactManifest
  try { artifactManifest = JSON.parse(manifestBytes.toString('utf8')) } catch (error) {
    fail(`invalid SDK 0.17.0 development artifact manifest: ${error.message}`)
  }
  if (!Array.isArray(artifactManifest.targets)
      || artifactManifest.targets.length !== 38
      || artifactManifest.targets.some(target =>
        typeof target !== 'string' || !/^[A-Za-z0-9_.-]+$/.test(target))
      || new Set(artifactManifest.targets).size !== artifactManifest.targets.length
      || artifactManifest.targets.filter(target => target === 'BareKit').length !== 1) {
    fail('SDK 0.17.0 development artifact manifest has an invalid target closure')
  }
  const manifestTargets = artifactManifest.targets
    .filter(target => target !== 'BareKit')
    .sort()
  return manifestTargets
}

function formatArtifactLock(lock) {
  const artifacts = lock.artifacts.map((artifact, index) => {
    const suffix = index + 1 === lock.artifacts.length ? '' : ','
    return `    { "target": ${JSON.stringify(artifact.target)}, "treeSHA256": ${JSON.stringify(artifact.treeSHA256)} }${suffix}`
  }).join('\n')
  return [
    '{',
    `  "schemaVersion": ${lock.schemaVersion},`,
    `  "algorithm": ${JSON.stringify(lock.algorithm)},`,
    '  "artifacts": [',
    artifacts,
    '  ]',
    '}',
    '',
  ].join('\n')
}

export function generateArtifactLock(root) {
  const canonicalRoot = realDirectory(resolve(root), 'artifact-lock source root')
  const targets = loadDevelopmentArtifactTargets()
  const artifacts = targets.map(target => {
    const name = `${target}.xcframework`
    const snapshot = snapshotCanonicalArtifactTree(
      join(canonicalRoot, name),
      `artifact-lock source ${name}`,
    )
    return { target, treeSHA256: snapshot.treeSHA256 }
  })
  return formatArtifactLock({
    schemaVersion: 1,
    algorithm: artifactTreeAlgorithm,
    artifacts,
  })
}

function loadArtifactLock() {
  const { bytes } = regularFile(
    artifactLockPath,
    'iOS local-artifact tree lock',
    maximumMetadataBytes,
  )
  if (sha256(bytes) !== reviewedArtifactLockSHA256) {
    fail('iOS local-artifact tree lock SHA-256 differs from the reviewed value')
  }
  let lock
  try { lock = JSON.parse(bytes.toString('utf8')) } catch (error) {
    fail(`invalid iOS local-artifact tree lock: ${error.message}`)
  }
  exactKeys(lock, ['schemaVersion', 'algorithm', 'artifacts'], 'iOS local-artifact tree lock')
  if (lock.schemaVersion !== 1
      || lock.algorithm !== artifactTreeAlgorithm
      || !Array.isArray(lock.artifacts) || lock.artifacts.length !== 37) {
    fail('iOS local-artifact tree lock has unsupported metadata')
  }
  const targets = []
  for (const artifact of lock.artifacts) {
    exactKeys(artifact, ['target', 'treeSHA256'], 'iOS local-artifact lock entry')
    if (typeof artifact.target !== 'string'
        || !/^[A-Za-z0-9_.-]+$/.test(artifact.target)
        || artifact.target === 'BareKit'
        || !/^[0-9a-f]{64}$/.test(artifact.treeSHA256)) {
      fail('iOS local-artifact tree lock contains an invalid entry')
    }
    targets.push(artifact.target)
  }
  const sorted = [...targets].sort()
  if (new Set(targets).size !== targets.length
      || JSON.stringify(targets) !== JSON.stringify(sorted)) {
    fail('iOS local-artifact tree lock targets must be unique and sorted')
  }
  const manifestTargets = loadDevelopmentArtifactTargets()
  if (JSON.stringify(targets) !== JSON.stringify(manifestTargets)) {
    fail('iOS local-artifact lock targets differ from the SDK 0.17.0 development manifest')
  }
  const aggregateBytes = Buffer.from(
    `${artifactMapAlgorithm}\0${JSON.stringify(lock.artifacts)}\n`,
  )
  return {
    ...lock,
    bytes,
    lockSHA256: sha256(bytes),
    aggregateSHA256: sha256(aggregateBytes),
  }
}

function validateExactArtifactRootNames(actualNames, targets) {
  const requiredNames = [...targets.map(target => `${target}.xcframework`), 'BareKit.xcframework']
    .sort()
  if (JSON.stringify([...actualNames].sort()) !== JSON.stringify(requiredNames)) {
    fail('isolated iOS artifact root differs from the reviewed 38-target closure')
  }
}

export function verifyNonBareArtifactClosure(root, { requireExactRoot = true } = {}) {
  const canonicalRoot = realDirectory(resolve(root), 'staged iOS artifact root')
  const lock = loadArtifactLock()
  if (requireExactRoot) {
    validateExactArtifactRootNames(readdirSync(canonicalRoot), lock.artifacts.map(({ target }) => target))
  }
  const artifacts = lock.artifacts.map(expected => {
    const name = `${expected.target}.xcframework`
    const path = join(canonicalRoot, name)
    const snapshot = snapshotCanonicalArtifactTree(path, `iOS artifact ${name}`)
    if (snapshot.treeSHA256 !== expected.treeSHA256) {
      fail(`iOS artifact ${name} differs from its reviewed canonical tree digest`)
    }
    return {
      target: expected.target,
      treeSHA256: snapshot.treeSHA256,
      entryCount: snapshot.entries.length,
    }
  })
  return {
    schemaVersion: 1,
    algorithm: lock.algorithm,
    aggregateAlgorithm: artifactMapAlgorithm,
    lockSHA256: lock.lockSHA256,
    aggregateSHA256: lock.aggregateSHA256,
    artifactCount: artifacts.length,
    artifacts,
  }
}

function expectFailure(action, label) {
  try { action() } catch { return }
  fail(`self-test accepted ${label}`)
}

function syntheticSignedMachO(virtualSize = 0x8000n) {
  const bytes = Buffer.alloc(0x6000)
  bytes.writeUInt32LE(0xfeedfacf, 0)
  bytes.writeInt32LE(0x0100000c, 4)
  bytes.writeUInt32LE(2, 16)
  bytes.writeUInt32LE(88, 20)
  const segment = 32
  bytes.writeUInt32LE(0x19, segment)
  bytes.writeUInt32LE(72, segment + 4)
  bytes.write('__LINKEDIT', segment + 8, 'ascii')
  bytes.writeBigUInt64LE(virtualSize, segment + 32)
  bytes.writeBigUInt64LE(0x1000n, segment + 40)
  bytes.writeBigUInt64LE(0x5000n, segment + 48)
  const signature = segment + 72
  bytes.writeUInt32LE(0x1d, signature)
  bytes.writeUInt32LE(16, signature + 4)
  bytes.writeUInt32LE(0x5800, signature + 8)
  bytes.writeUInt32LE(0x800, signature + 12)
  return bytes
}

function syntheticUnsignedMachO(virtualSize = 0x8000n) {
  const bytes = Buffer.alloc(0x4000)
  bytes.writeUInt32LE(0xfeedfacf, 0)
  bytes.writeInt32LE(0x0100000c, 4)
  bytes.writeUInt32LE(1, 16)
  bytes.writeUInt32LE(72, 20)
  const segment = 32
  bytes.writeUInt32LE(0x19, segment)
  bytes.writeUInt32LE(72, segment + 4)
  bytes.write('__LINKEDIT', segment + 8, 'ascii')
  bytes.writeBigUInt64LE(virtualSize, segment + 32)
  bytes.writeBigUInt64LE(0x1000n, segment + 40)
  bytes.writeBigUInt64LE(0x3000n, segment + 48)
  return bytes
}

function selfTest() {
  const fixture = mkdtempSync(join(tmpdir(), 'qvac-ios-build-inputs.'))
  try {
    expectFailure(
      () => portablePermissions({ mode: 0o104755 }, 'synthetic special mode'),
      'a synthetic setuid permission bit',
    )
    const adHocMetadata = [
      'CodeDirectory v=20100 size=190 flags=0x2(adhoc)',
      'Signature=adhoc',
      'TeamIdentifier=not set',
      'Internal requirements count=0 size=12',
    ].join('\n')
    validateAdHocSignatureMetadata(adHocMetadata, 'Executable=/tmp/Example', 'synthetic signature')
    expectFailure(
      () => validateAdHocSignatureMetadata(
        adHocMetadata.replace('Signature=adhoc', 'Signature=Apple Development: Example'),
        'Executable=/tmp/Example',
        'synthetic signature',
      ),
      'a non-ad-hoc artifact signature',
    )
    expectFailure(
      () => validateAdHocSignatureMetadata(
        adHocMetadata,
        'Executable=/tmp/Example\n<plist><dict><key>application-identifier</key></dict></plist>',
        'synthetic signature',
      ),
      'artifact signature entitlements',
    )
    validateSignedMachO(syntheticSignedMachO(), 'synthetic signed Mach-O')
    expectFailure(
      () => validateSignedMachO(syntheticSignedMachO(0xc000n), 'inflated synthetic signed Mach-O'),
      'an aligned but inflated signed __LINKEDIT virtual size',
    )
    const nonterminalSignature = syntheticSignedMachO()
    nonterminalSignature.writeUInt32LE(0x400, 32 + 72 + 12)
    expectFailure(
      () => validateSignedMachO(nonterminalSignature, 'nonterminal synthetic signature'),
      'a nonterminal LC_CODE_SIGNATURE extent',
    )
    const normalizedUnsigned = normalizeUnsignedMachOLinkedit(
      syntheticUnsignedMachO(),
      'synthetic unsigned Mach-O',
    )
    if (normalizedUnsigned.readBigUInt64LE(32 + 32) !== 0x4000n) {
      fail('unsigned Mach-O normalization did not derive __LINKEDIT virtual size from file size')
    }
    const first = join(fixture, 'first')
    const second = join(fixture, 'second')
    mkdirSync(join(first, 'nested'), { recursive: true })
    mkdirSync(join(second, 'nested'), { recursive: true })
    writeFileSync(join(first, 'nested', 'payload'), 'reviewed\n')
    writeFileSync(join(second, 'nested', 'payload'), 'reviewed\n')
    const baseline = snapshotCanonicalTree(first, 'synthetic baseline')
    const copy = snapshotCanonicalTree(second, 'synthetic copy')
    if (baseline.treeSHA256 !== copy.treeSHA256) fail('canonical tree digest is not reproducible')
    const payload = join(second, 'nested', 'payload')
    utimesSync(payload, new Date(1_234_567_000), new Date(1_234_567_000))
    if (baseline.treeSHA256 !== snapshotCanonicalTree(second, 'mtime-mutated copy').treeSHA256) {
      fail('canonical tree digest must ignore filesystem timestamps')
    }
    run('/usr/bin/xattr', ['-w', 'com.qvac.canonical-self-test', 'ignored', payload], 'xattr self-test setup')
    if (baseline.treeSHA256 !== snapshotCanonicalTree(second, 'xattr-mutated copy').treeSHA256) {
      fail('canonical tree digest must ignore filesystem extended attributes')
    }
    run('/usr/bin/xattr', ['-d', 'com.qvac.canonical-self-test', payload], 'xattr self-test cleanup')
    chmodSync(payload, 0o755)
    if (baseline.treeSHA256 === snapshotCanonicalTree(second, 'mode-mutated copy').treeSHA256) {
      fail('canonical tree digest ignored executable-mode mutation')
    }
    const nested = join(second, 'nested')
    chmodSync(nested, 0o1755)
    expectFailure(
      () => snapshotCanonicalTree(second, 'special-mode copy'),
      'a directory with sticky permission',
    )
    chmodSync(nested, 0o755)
    chmodSync(payload, 0o644)
    const emptyDirectory = join(second, 'empty')
    mkdirSync(emptyDirectory)
    if (baseline.treeSHA256 === snapshotCanonicalTree(second, 'empty-directory copy').treeSHA256) {
      fail('canonical tree digest ignored an empty-directory mutation')
    }
    rmSync(emptyDirectory, { recursive: true })
    const symlink = join(second, 'link')
    symlinkSync(payload, symlink)
    expectFailure(() => snapshotCanonicalTree(second, 'symlink copy'), 'a symlink')
    rmSync(symlink)
    const fifo = join(second, 'fifo')
    run('/usr/bin/mkfifo', [fifo], 'FIFO self-test setup')
    expectFailure(() => snapshotCanonicalTree(second, 'FIFO copy'), 'a special filesystem entry')
    rmSync(fifo)
    writeFileSync(join(second, 'nested', 'payload'), 'mutated\n')
    if (baseline.treeSHA256 === snapshotCanonicalTree(second, 'mutated copy').treeSHA256) {
      fail('canonical tree digest ignored file-content mutation')
    }
    writeFileSync(join(second, 'nested', 'payload'), 'reviewed\n')
    writeFileSync(join(second, 'extra'), '')
    if (baseline.treeSHA256 === snapshotCanonicalTree(second, 'extra copy').treeSHA256) {
      fail('canonical tree digest ignored path-set mutation')
    }
    const artifactEntries = [{
      path: 'ios-arm64/Example.framework/Example',
      type: 'file',
      permissions: 0o644,
      byteCount: 128,
      sha256: '0'.repeat(64),
    }]
    const artifactDigest = canonicalEntriesSHA256(artifactEntries, artifactTreeAlgorithm)
    const executableArtifactEntries = structuredClone(artifactEntries)
    executableArtifactEntries[0].permissions = 0o755
    if (artifactDigest === canonicalEntriesSHA256(executableArtifactEntries, artifactTreeAlgorithm)) {
      fail('artifact canonical digest ignored executable-mode mutation')
    }
    const renamedArtifactEntries = structuredClone(artifactEntries)
    renamedArtifactEntries[0].path = 'ios-arm64/Example.framework/Injected'
    if (artifactDigest === canonicalEntriesSHA256(renamedArtifactEntries, artifactTreeAlgorithm)) {
      fail('artifact canonical digest ignored path mutation')
    }
    if (artifactDigest === canonicalEntriesSHA256(artifactEntries, sourceTreeAlgorithm)) {
      fail('canonical tree algorithms are not domain-separated')
    }
    validateExactArtifactRootNames(
      ['BareKit.xcframework', 'Example.xcframework'],
      ['Example'],
    )
    expectFailure(
      () => validateExactArtifactRootNames(
        ['BareKit.xcframework', 'Example.xcframework', 'Injected.xcframework'],
        ['Example'],
      ),
      'an unexpected isolated artifact-root entry',
    )

    const expectedSource = join(fixture, 'expected-source')
    const actualSource = join(fixture, 'actual-source')
    for (const root of [expectedSource, actualSource]) {
      mkdirSync(join(root, 'Sources'), { recursive: true })
      mkdirSync(join(root, 'Examples', 'QVACChat', 'QVACChat.xcodeproj'), { recursive: true })
      writeFileSync(join(root, 'Sources', 'Client.swift'), 'struct Client {}\n')
      writeFileSync(
        join(root, 'Examples', 'QVACChat', 'QVACChat.xcodeproj', 'project.pbxproj'),
        'reviewed project\n',
      )
    }
    const expectedSourceSnapshot = snapshotCanonicalTree(expectedSource, 'synthetic source')
    let actualSourceSnapshot = snapshotCanonicalTree(actualSource, 'synthetic isolated source')
    if (!sameSnapshot(expectedSourceSnapshot, actualSourceSnapshot)) {
      fail('identical synthetic source trees differ')
    }
    writeFileSync(join(actualSource, 'Sources', 'Client.swift'), 'struct FakeClient {}\n')
    actualSourceSnapshot = snapshotCanonicalTree(actualSource, 'mutated synthetic source')
    if (sameSnapshot(expectedSourceSnapshot, actualSourceSnapshot)) {
      fail('full-source comparison ignored SDK source mutation')
    }
    writeFileSync(join(actualSource, 'Sources', 'Client.swift'), 'struct Client {}\n')
    writeFileSync(
      join(actualSource, 'Examples', 'QVACChat', 'QVACChat.xcodeproj', 'project.pbxproj'),
      'mutated project\n',
    )
    actualSourceSnapshot = snapshotCanonicalTree(actualSource, 'mutated synthetic project')
    if (sameSnapshot(expectedSourceSnapshot, actualSourceSnapshot)) {
      fail('full-source comparison ignored generated-project mutation')
    }

    let rejectedUnpinnedGenerator = false
    try { verifyPinnedXcodeGen(process.execPath) } catch { rejectedUnpinnedGenerator = true }
    if (!rejectedUnpinnedGenerator) fail('XcodeGen pin accepted an unrelated executable')
  } finally {
    rmSync(fixture, { recursive: true, force: true })
  }
  const lock = loadArtifactLock()
  if (!Buffer.from(formatArtifactLock(lock)).equals(lock.bytes)) {
    fail('artifact-lock generator does not reproduce the committed lock bytes')
  }
  console.log('[ios-build-inputs-self-test] artifact, source, generated-project, and XcodeGen mutation gates verified')
}

function parseExactArguments(argv, expected) {
  if (argv.length !== expected.length * 2) fail('invalid argument count')
  const values = new Map()
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index]
    const value = argv[index + 1]
    if (!expected.includes(key) || values.has(key) || !value) fail('invalid or duplicate arguments')
    values.set(key, value)
  }
  return Object.fromEntries([...values].map(([key, value]) => [key.slice(2), value]))
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    if (process.argv.length === 3 && process.argv[2] === '--self-test') {
      selfTest()
    } else if (process.argv.length === 5
        && process.argv[2] === '--generate-artifact-lock'
        && process.argv[3] === '--artifact-root') {
      if (!process.argv[4].startsWith('/')) fail('artifact root must be absolute')
      process.stdout.write(generateArtifactLock(process.argv[4]))
    } else if ((process.argv.length === 4 || process.argv.length === 5)
        && process.argv[2] === '--artifact-root'
        && (process.argv.length === 4
          || process.argv[4] === '--allow-unreferenced-root-entries')) {
      if (!process.argv[3].startsWith('/')) fail('artifact root must be absolute')
      const evidence = verifyNonBareArtifactClosure(process.argv[3], {
        requireExactRoot: process.argv.length === 4,
      })
      console.log(`[ios-build-inputs] PASS artifacts=${evidence.artifactCount} aggregate-sha256=${evidence.aggregateSHA256}`)
    } else {
      const args = parseExactArguments(process.argv.slice(2), [
        '--source-archive', '--source-root', '--source-sha', '--xcodegen',
      ])
      for (const key of ['source-archive', 'source-root', 'xcodegen']) {
        if (!args[key].startsWith('/')) fail(`${key} must be absolute`)
      }
      const evidence = verifyIsolatedBuildInputs({
        sourceArchive: args['source-archive'],
        sourceRoot: args['source-root'],
        sourceCommit: args['source-sha'],
        xcodegen: args.xcodegen,
      })
      console.log(`[ios-build-inputs] PASS source-tree=${evidence.effectiveSourceTree.treeSHA256} artifacts=${evidence.artifactClosure.aggregateSHA256}`)
    }
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error))
    process.exit(1)
  }
}
