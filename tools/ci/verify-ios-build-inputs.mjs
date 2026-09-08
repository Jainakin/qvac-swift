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
const artifactTreeAlgorithm = 'qvac-canonical-signed-xcframework-v2'
const artifactMapAlgorithm = 'qvac-canonical-ios-artifact-map-v1'
const codeSignPath = '/usr/bin/codesign'
const maximumCodeSignatureBytes = 1024n * 1024n
const maximumSignatureEnvelopeEntries = 64
const maximumSignatureEnvelopeDepth = 4
const maximumSignatureEnvelopeTotalBytes = 4 * 1024 * 1024

// Updated together with ios-local-artifact-tree-lock.json after an explicit
// review of a newly staged SDK closure.
export const reviewedArtifactLockSHA256 =
  '3943408b1d6485b6a376c28ab79b744ffc4fd03fe54fb6b561b19ea15e6f137d'
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
      || !/^CodeDirectory [^\r\n]*\bflags=0x2\(adhoc\)(?:\s|$)/m.test(metadata)) {
    fail(`${label} must use the reviewed ad-hoc, no-team signature identity`)
  }
  const entitlementLines = entitlementDisplay.split('\n')
    .map(line => line.trim())
    .filter(line => line.length > 0 && !line.startsWith('warning:'))
  if (entitlementLines.length !== 1 || !entitlementLines[0].startsWith('Executable=')) {
    fail(`${label} must not contain code-signing entitlements`)
  }
}

function verifyAdHocSignature(path, label, architecture) {
  const architectureArguments = architecture === undefined
    ? []
    : ['--architecture', architecture]
  const display = spawnSync(codeSignPath, [
    '-d', '--verbose=4', ...architectureArguments, path,
  ], {
    encoding: 'utf8',
    maxBuffer: 1024 * 1024,
  })
  if (display.status !== 0) {
    fail(`${label} signature metadata inspection failed`)
  }
  const entitlements = spawnSync(codeSignPath, [
    '-d', ...architectureArguments, '--entitlements', '-', path,
  ], {
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
    if (bytes.length < 32) fail(`${label} has a truncated 64-bit Mach-O header`)
    if (bytes.readUInt32LE(0) !== 0xfeedfacf) {
      fail(`${label} must contain only little-endian MH_MAGIC_64 slices`)
    }
    return [{
      offset: 0,
      size: bytes.length,
      cpuType: bytes.readInt32LE(4),
      cpuSubtype: bytes.readInt32LE(8),
      alignment: null,
    }]
  }

  if (bytes.length < 8) fail(`${label} has a truncated fat header`)
  const count = bytes.readUInt32BE(4)
  if (count < 1 || count > 8 || 8 + count * 20 > bytes.length) {
    fail(`${label} has an invalid fat-architecture table`)
  }
  const tableEnd = 8 + count * 20
  const slices = []
  const architectureTuples = new Set()
  for (let index = 0; index < count; index++) {
    const entry = 8 + index * 20
    const cpuType = bytes.readInt32BE(entry)
    const cpuSubtype = bytes.readInt32BE(entry + 4)
    const offset = bytes.readUInt32BE(entry + 8)
    const size = bytes.readUInt32BE(entry + 12)
    const alignment = bytes.readUInt32BE(entry + 16)
    if (alignment > 30 || offset < tableEnd || size < 32
        || offset + size > bytes.length
        || offset % (2 ** alignment) !== 0) {
      fail(`${label} has an invalid fat slice extent`)
    }
    if (bytes.readUInt32LE(offset) !== 0xfeedfacf
        || bytes.readInt32LE(offset + 4) !== cpuType
        || bytes.readInt32LE(offset + 8) !== cpuSubtype) {
      fail(`${label} fat metadata disagrees with its MH_MAGIC_64 slice`)
    }
    const architectureTuple = `${cpuType}:${cpuSubtype}`
    if (architectureTuples.has(architectureTuple)) {
      fail(`${label} contains a duplicate fat architecture tuple`)
    }
    architectureTuples.add(architectureTuple)
    slices.push({ offset, size, cpuType, cpuSubtype, alignment })
  }
  const ordered = [...slices].sort((left, right) => left.offset - right.offset)
  if (ordered.some((slice, index) => slice !== slices[index])) {
    fail(`${label} fat architecture table is not in slice order`)
  }
  let previousEnd = tableEnd
  for (let index = 1; index < ordered.length; index++) {
    if (ordered[index - 1].offset + ordered[index - 1].size > ordered[index].offset) {
      fail(`${label} contains overlapping fat slices`)
    }
  }
  for (const slice of ordered) {
    const alignmentBytes = 2 ** slice.alignment
    const minimalOffset = Math.ceil(previousEnd / alignmentBytes) * alignmentBytes
    if (slice.offset !== minimalOffset) {
      fail(`${label} contains a non-minimal fat-slice offset`)
    }
    for (let offset = previousEnd; offset < slice.offset; offset++) {
      if (bytes[offset] !== 0) fail(`${label} contains non-zero fat-slice padding`)
    }
    previousEnd = slice.offset + slice.size
  }
  if (previousEnd !== bytes.length) {
    fail(`${label} contains trailing fat padding`)
  }
  return slices
}

function machOPageSize(cpuType, label) {
  if (cpuType === 0x0100000c) return 0x4000n
  if (cpuType === 0x01000007) return 0x1000n
  fail(`${label} contains an unsupported Mach-O CPU type`)
}

function codeSignArchitecture(cpuType, label) {
  if (cpuType === 0x0100000c) return 'arm64'
  if (cpuType === 0x01000007) return 'x86_64'
  fail(`${label} contains an unsupported code-signing architecture`)
}

function roundedUp(value, alignment) {
  return ((value + alignment - 1n) / alignment) * alignment
}

function linkeditRanges(command, label) {
  const type = command.readUInt32LE(0)
  const ranges = []
  function add(offset, size, description) {
    if (size === 0n) return
    ranges.push({ offset, size, description })
  }
  function uint32(offset) {
    return BigInt(command.readUInt32LE(offset))
  }

  if (type === 0x2) { // LC_SYMTAB
    if (command.length !== 24) fail(`${label} has malformed LC_SYMTAB metadata`)
    add(uint32(8), uint32(12) * 16n, 'symbol table')
    add(uint32(16), uint32(20), 'string table')
  } else if (type === 0xb) { // LC_DYSYMTAB
    if (command.length !== 80) fail(`${label} has malformed LC_DYSYMTAB metadata`)
    add(uint32(32), uint32(36) * 8n, 'table of contents')
    add(uint32(40), uint32(44) * 56n, '64-bit module table')
    add(uint32(48), uint32(52) * 4n, 'external reference table')
    add(uint32(56), uint32(60) * 4n, 'indirect symbol table')
    add(uint32(64), uint32(68) * 8n, 'external relocation table')
    add(uint32(72), uint32(76) * 8n, 'local relocation table')
  } else if (type === 0x22 || type === 0x80000022) { // LC_DYLD_INFO[_ONLY]
    if (command.length !== 48) fail(`${label} has malformed LC_DYLD_INFO metadata`)
    for (let offset = 8; offset <= 40; offset += 8) {
      add(uint32(offset), uint32(offset + 4), 'dyld info')
    }
  } else if (type === 0x16) { // LC_TWOLEVEL_HINTS
    if (command.length !== 16) fail(`${label} has malformed LC_TWOLEVEL_HINTS metadata`)
    add(uint32(8), uint32(12) * 4n, 'two-level hints')
  } else if ([
    0x1e, // LC_SEGMENT_SPLIT_INFO
    0x26, // LC_FUNCTION_STARTS
    0x29, // LC_DATA_IN_CODE
    0x2b, // LC_DYLIB_CODE_SIGN_DRS
    0x2e, // LC_LINKER_OPTIMIZATION_HINT
    0x36, // LC_ATOM_INFO
    0x37, // LC_FUNCTION_VARIANTS
    0x38, // LC_FUNCTION_VARIANT_FIXUPS
    0x3a, // LC_LAZY_LOAD_DYLIB_INFO
    0x80000033, // LC_DYLD_EXPORTS_TRIE
    0x80000034, // LC_DYLD_CHAINED_FIXUPS
  ].includes(type)) {
    if (command.length !== 16) fail(`${label} has malformed linkedit-data metadata`)
    add(uint32(8), uint32(12), 'linkedit data')
  } else if (![
    0x19, // LC_SEGMENT_64
    0x1b, // LC_UUID
    0x1d, // LC_CODE_SIGNATURE
    0x2a, // LC_SOURCE_VERSION
    0x2c, // LC_ENCRYPTION_INFO_64
    0x32, // LC_BUILD_VERSION
    0xc, // LC_LOAD_DYLIB
    0xd, // LC_ID_DYLIB
    0x8000001c, // LC_RPATH
  ].includes(type)) {
    fail(`${label} has unsupported load command 0x${type.toString(16)}`)
  }
  return ranges
}

function parseSignedMachOSlice(bytes, slice, label) {
  if (bytes.readUInt32LE(slice.offset + 12) !== 6) {
    fail(`${label} must be an MH_DYLIB`)
  }
  const sliceEnd = slice.offset + slice.size
  const commandCount = bytes.readUInt32LE(slice.offset + 16)
  const commandBytes = bytes.readUInt32LE(slice.offset + 20)
  let commandOffset = slice.offset + 32
  const commandEnd = commandOffset + commandBytes
  if (commandCount < 2 || commandCount > 16_384 || commandEnd > sliceEnd) {
    fail(`${label} has an invalid signed Mach-O load-command table`)
  }
  const commands = []
  let linkeditIndex = -1
  let linkedit = null
  let codeSignatureIndex = -1
  let codeSignature = null
  const segments = []
  for (let index = 0; index < commandCount; index++) {
    if (commandOffset + 8 > commandEnd) fail(`${label} has truncated signed load commands`)
    const command = bytes.readUInt32LE(commandOffset)
    const commandSize = bytes.readUInt32LE(commandOffset + 4)
    if (commandSize < 8 || commandSize % 8 !== 0
        || commandOffset + commandSize > commandEnd) {
      fail(`${label} has an invalid signed Mach-O load command`)
    }
    commands.push(Buffer.from(bytes.subarray(commandOffset, commandOffset + commandSize)))
    if (command === 0x19) {
      if (commandSize < 72) fail(`${label} has a truncated signed LC_SEGMENT_64`)
      const segment = bytes.subarray(commandOffset + 8, commandOffset + 24)
        .toString('ascii').replace(/\0.*$/, '')
      const sectionCount = bytes.readUInt32LE(commandOffset + 64)
      if (commandSize !== 72 + sectionCount * 80) {
        fail(`${label} has inconsistent LC_SEGMENT_64 section metadata`)
      }
      const segmentMetadata = {
        name: segment,
        fileOffset: bytes.readBigUInt64LE(commandOffset + 40),
        fileSize: bytes.readBigUInt64LE(commandOffset + 48),
      }
      if (segmentMetadata.fileOffset + segmentMetadata.fileSize > BigInt(slice.size)) {
        fail(`${label} has an LC_SEGMENT_64 outside its slice`)
      }
      segments.push(segmentMetadata)
      if (segment === '__LINKEDIT') {
        if (linkedit !== null) fail(`${label} has multiple signed __LINKEDIT segments`)
        if (commandSize !== 72 || sectionCount !== 0) {
          fail(`${label} __LINKEDIT must be a sectionless 72-byte LC_SEGMENT_64`)
        }
        linkeditIndex = index
        linkedit = {
          virtualSize: bytes.readBigUInt64LE(commandOffset + 32),
          fileOffset: segmentMetadata.fileOffset,
          fileSize: segmentMetadata.fileSize,
        }
      }
    } else if (command === 0x1d) {
      if (commandSize !== 16 || codeSignature !== null) {
        fail(`${label} has an invalid or duplicate LC_CODE_SIGNATURE`)
      }
      codeSignatureIndex = index
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
  const fileSegments = segments
    .filter(segment => segment.fileSize > 0n)
    .sort((left, right) => Number(left.fileOffset - right.fileOffset))
  for (let index = 1; index < fileSegments.length; index++) {
    const previous = fileSegments[index - 1]
    if (previous.fileOffset + previous.fileSize > fileSegments[index].fileOffset) {
      fail(`${label} contains overlapping LC_SEGMENT_64 file extents`)
    }
  }
  if (segments.some(segment => segment.name !== '__LINKEDIT'
      && segment.fileOffset + segment.fileSize > linkedit.fileOffset)) {
    fail(`${label} __LINKEDIT is not the terminal file segment`)
  }

  let linkeditContentEnd = linkedit.fileOffset
  for (const command of commands) {
    for (const range of linkeditRanges(command, label)) {
      const end = range.offset + range.size
      if (range.offset < linkedit.fileOffset || end > codeSignature.dataOffset) {
        fail(`${label} ${range.description} lies outside unsigned __LINKEDIT content`)
      }
      if (end > linkeditContentEnd) linkeditContentEnd = end
    }
  }

  // These ad-hoc iOS signatures use a 16 KiB signing page on both device and
  // Simulator slices. Canonicalization below removes that envelope and derives
  // the unsigned architecture-specific virtual extent itself.
  machOPageSize(slice.cpuType, label)
  const signingPageSize = 0x4000n
  const signedVirtualSize = roundedUp(linkedit.fileSize, signingPageSize)
  const signatureEnd = codeSignature.dataOffset + codeSignature.dataSize
  if (codeSignature.dataSize === 0n
      || codeSignature.dataSize > maximumCodeSignatureBytes
      || linkedit.virtualSize !== signedVirtualSize
      || linkedit.fileOffset + linkedit.fileSize !== BigInt(slice.size)
      || linkedit.fileOffset < BigInt(commandEnd - slice.offset)
      || codeSignature.dataOffset < linkedit.fileOffset
      || codeSignature.dataOffset < BigInt(commandEnd - slice.offset)
      || codeSignature.dataOffset !== roundedUp(linkeditContentEnd, 16n)
      || signatureEnd !== BigInt(slice.size)
      || signatureEnd > linkedit.fileOffset + linkedit.fileSize) {
    fail(`${label} has non-canonical signed __LINKEDIT or code-signature extents`)
  }
  for (let offset = Number(linkeditContentEnd); offset < Number(codeSignature.dataOffset); offset++) {
    if (bytes[slice.offset + offset] !== 0) {
      fail(`${label} contains non-zero code-signature alignment padding`)
    }
  }
  return {
    commandBytes,
    commandCount,
    commands,
    linkedit,
    linkeditIndex,
    codeSignature,
    codeSignatureIndex,
    linkeditContentEnd,
  }
}

function validateSignedMachO(bytes, label) {
  const slices = machOSlices(bytes, label)
  for (const slice of slices) parseSignedMachOSlice(bytes, slice, label)
  return slices
}

function canonicalizeSignedMachOSlice(bytes, slice, label) {
  const parsed = parseSignedMachOSlice(bytes, slice, label)
  const unsignedSize = Number(parsed.linkeditContentEnd)
  const normalized = Buffer.from(bytes.subarray(slice.offset, slice.offset + unsignedSize))
  normalized.writeUInt32LE(parsed.commandCount - 1, 16)
  normalized.writeUInt32LE(parsed.commandBytes - 16, 20)

  // Rebuild the load-command table without LC_CODE_SIGNATURE. Its position is
  // not stable across linker outputs, so merely zeroing the command would leave
  // otherwise equivalent binaries with different bytes.
  let commandOffset = 32
  let linkeditOffset = -1
  normalized.fill(0, commandOffset, commandOffset + parsed.commandBytes)
  for (let index = 0; index < parsed.commands.length; index++) {
    if (index === parsed.codeSignatureIndex) continue
    if (index === parsed.linkeditIndex) linkeditOffset = commandOffset
    parsed.commands[index].copy(normalized, commandOffset)
    commandOffset += parsed.commands[index].length
  }
  if (commandOffset !== 32 + parsed.commandBytes - 16 || linkeditOffset < 0) {
    fail(`${label} could not rebuild its unsigned load-command table`)
  }

  const unsignedLinkeditSize = parsed.linkeditContentEnd - parsed.linkedit.fileOffset
  const pageSize = machOPageSize(slice.cpuType, label)
  const canonicalVirtualSize = roundedUp(unsignedLinkeditSize, pageSize)
  normalized.writeBigUInt64LE(canonicalVirtualSize, linkeditOffset + 32)
  normalized.writeBigUInt64LE(unsignedLinkeditSize, linkeditOffset + 48)
  return normalized
}

function canonicalizeSignedMachO(bytes, label) {
  const slices = validateSignedMachO(bytes, label)
  const normalizedSlices = slices.map((slice, index) => ({
    ...slice,
    bytes: canonicalizeSignedMachOSlice(bytes, slice, `${label} slice ${index}`),
  }))
  if (normalizedSlices.length === 1 && normalizedSlices[0].alignment === null) {
    return { bytes: normalizedSlices[0].bytes, cpuTypes: [normalizedSlices[0].cpuType] }
  }

  const headerSize = 8 + normalizedSlices.length * 20
  let canonicalSize = headerSize
  for (const slice of normalizedSlices) {
    const alignmentBytes = 2 ** slice.alignment
    canonicalSize = Math.ceil(canonicalSize / alignmentBytes) * alignmentBytes
    slice.canonicalOffset = canonicalSize
    canonicalSize += slice.bytes.length
  }
  if (canonicalSize > 512 * 1024 * 1024) fail(`${label} canonical Mach-O exceeds 512 MiB`)
  const normalized = Buffer.alloc(canonicalSize)
  normalized.writeUInt32BE(0xcafebabe, 0)
  normalized.writeUInt32BE(normalizedSlices.length, 4)
  for (let index = 0; index < normalizedSlices.length; index++) {
    const slice = normalizedSlices[index]
    const entry = 8 + index * 20
    normalized.writeInt32BE(slice.cpuType, entry)
    normalized.writeInt32BE(slice.cpuSubtype, entry + 4)
    normalized.writeUInt32BE(slice.canonicalOffset, entry + 8)
    normalized.writeUInt32BE(slice.bytes.length, entry + 12)
    normalized.writeUInt32BE(slice.alignment, entry + 16)
    slice.bytes.copy(normalized, slice.canonicalOffset)
  }
  return { bytes: normalized, cpuTypes: normalizedSlices.map(slice => slice.cpuType) }
}

function canonicalMachO(path, label) {
  const { bytes: signedBytes } = regularFile(path, `signed ${label}`, 512 * 1024 * 1024)
  const normalized = canonicalizeSignedMachO(signedBytes, label)
  return {
    byteCount: normalized.bytes.length,
    sha256: sha256(normalized.bytes),
    cpuTypes: normalized.cpuTypes,
  }
}

function validateSignatureEnvelope(
  directory,
  relativePath,
  label,
  state = { entryCount: 0, totalBytes: 0 },
  depth = 0,
) {
  if (depth > maximumSignatureEnvelopeDepth) {
    fail(`${label} signature envelope nesting exceeds ${maximumSignatureEnvelopeDepth}`)
  }
  const directoryStat = lstatSync(directory)
  if (directoryStat.isSymbolicLink() || !directoryStat.isDirectory()
      || portablePermissions(directoryStat, `${label} ${relativePath}`) !== 0o755) {
    fail(`${label} signature envelope directories must be real mode-0755 directories`)
  }
  for (const name of readdirSync(directory).sort()) {
    state.entryCount += 1
    if (state.entryCount > maximumSignatureEnvelopeEntries) {
      fail(`${label} signature envelope exceeds ${maximumSignatureEnvelopeEntries} entries`)
    }
    const entryPath = join(directory, name)
    const entryRelativePath = `${relativePath}/${name}`
    const stat = lstatSync(entryPath)
    if (stat.isSymbolicLink()) fail(`${label} contains a symlink: ${entryRelativePath}`)
    const permissions = portablePermissions(stat, `${label} ${entryRelativePath}`)
    if (stat.isDirectory()) {
      validateSignatureEnvelope(entryPath, entryRelativePath, label, state, depth + 1)
    } else if (!stat.isFile() || permissions !== 0o644) {
      fail(`${label} signature envelope files must be regular mode-0644 files`)
    } else if (stat.size > maximumMetadataBytes) {
      fail(`${label} signature envelope file exceeds ${maximumMetadataBytes} bytes`)
    } else {
      state.totalBytes += stat.size
      if (state.totalBytes > maximumSignatureEnvelopeTotalBytes) {
        fail(
          `${label} signature envelope exceeds ${maximumSignatureEnvelopeTotalBytes} total bytes`,
        )
      }
    }
  }
}

export function snapshotCanonicalArtifactTree(root, label = 'iOS artifact') {
  const canonicalRoot = realDirectory(resolve(root), label)
  run(
    codeSignPath,
    ['--verify', '--strict', '--all-architectures', canonicalRoot],
    `${label} signature verification`,
  )
  verifyAdHocSignature(canonicalRoot, label)
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
          run(
            codeSignPath,
            ['--verify', '--strict', '--all-architectures', path],
            `${label} framework signature verification`,
          )
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
          digest = canonicalMachO(path, `${label} ${relativePath}`)
          for (const cpuType of digest.cpuTypes) {
            const architecture = codeSignArchitecture(cpuType, `${label} ${relativePath}`)
            verifyAdHocSignature(
              framework,
              `${label} framework ${architecture} slice`,
              architecture,
            )
          }
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
      fail(
        `iOS artifact ${name} differs from its reviewed canonical tree digest: `
        + `expected=${expected.treeSHA256} actual=${snapshot.treeSHA256} `
        + `actualEntries=${JSON.stringify(snapshot.entries)}`,
      )
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

function syntheticSignedMachO({
  cpuType = 0x0100000c,
  cpuSubtype = 0,
  signatureSize = 0x800,
  signatureFill = 0xa5,
  signatureCommandIndex = 1,
  virtualSize,
} = {}) {
  const linkeditOffset = 0x1000
  const contentEnd = 0x57f8
  const signatureOffset = 0x5800
  const totalSize = signatureOffset + signatureSize
  const bytes = Buffer.alloc(totalSize)
  bytes.writeUInt32LE(0xfeedfacf, 0)
  bytes.writeInt32LE(cpuType, 4)
  bytes.writeInt32LE(cpuSubtype, 8)
  bytes.writeUInt32LE(6, 12)
  bytes.writeUInt32LE(3, 16)
  bytes.writeUInt32LE(112, 20)
  bytes[0x800] = 0x42
  bytes.fill(0x31, 0x5010, contentEnd)
  bytes.fill(signatureFill, signatureOffset)

  const segment = Buffer.alloc(72)
  segment.writeUInt32LE(0x19, 0)
  segment.writeUInt32LE(72, 4)
  segment.write('__LINKEDIT', 8, 'ascii')
  const signedFileSize = BigInt(totalSize - linkeditOffset)
  segment.writeBigUInt64LE(virtualSize ?? roundedUp(signedFileSize, 0x4000n), 32)
  segment.writeBigUInt64LE(BigInt(linkeditOffset), 40)
  segment.writeBigUInt64LE(signedFileSize, 48)

  const symbols = Buffer.alloc(24)
  symbols.writeUInt32LE(0x2, 0)
  symbols.writeUInt32LE(24, 4)
  symbols.writeUInt32LE(0x5000, 8)
  symbols.writeUInt32LE(1, 12)
  symbols.writeUInt32LE(0x5010, 16)
  symbols.writeUInt32LE(contentEnd - 0x5010, 20)

  const signature = Buffer.alloc(16)
  signature.writeUInt32LE(0x1d, 0)
  signature.writeUInt32LE(16, 4)
  signature.writeUInt32LE(signatureOffset, 8)
  signature.writeUInt32LE(signatureSize, 12)

  if (signatureCommandIndex !== 1 && signatureCommandIndex !== 2) {
    fail('synthetic signature command index is invalid')
  }
  const commands = signatureCommandIndex === 1
    ? [segment, signature, symbols]
    : [segment, symbols, signature]
  let commandOffset = 32
  for (const command of commands) {
    command.copy(bytes, commandOffset)
    commandOffset += command.length
  }
  return bytes
}

function syntheticFatMachO(signedSlices, alignments = signedSlices.map(() => 14)) {
  if (signedSlices.length !== alignments.length || signedSlices.length < 1) {
    fail('synthetic fat Mach-O input is invalid')
  }
  const headerSize = 8 + signedSlices.length * 20
  let size = headerSize
  const slices = signedSlices.map((slice, index) => {
    const alignment = alignments[index]
    size = Math.ceil(size / (2 ** alignment)) * (2 ** alignment)
    const offset = size
    size += slice.length
    return {
      alignment,
      bytes: slice,
      cpuType: slice.readInt32LE(4),
      cpuSubtype: slice.readInt32LE(8),
      offset,
    }
  })
  const bytes = Buffer.alloc(size)
  bytes.writeUInt32BE(0xcafebabe, 0)
  bytes.writeUInt32BE(slices.length, 4)
  for (let index = 0; index < slices.length; index++) {
    const slice = slices[index]
    const entry = 8 + index * 20
    bytes.writeInt32BE(slice.cpuType, entry)
    bytes.writeInt32BE(slice.cpuSubtype, entry + 4)
    bytes.writeUInt32BE(slice.offset, entry + 8)
    bytes.writeUInt32BE(slice.bytes.length, entry + 12)
    bytes.writeUInt32BE(slice.alignment, entry + 16)
    slice.bytes.copy(bytes, slice.offset)
  }
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
        adHocMetadata.replace('flags=0x2(adhoc)', 'flags=0x10002(adhoc)'),
        'Executable=/tmp/Example',
        'synthetic signature',
      ),
      'additional code-signing flags on an ad-hoc signature',
    )
    expectFailure(
      () => validateAdHocSignatureMetadata(
        adHocMetadata,
        'Executable=/tmp/Example\n<plist><dict><key>application-identifier</key></dict></plist>',
        'synthetic signature',
      ),
      'artifact signature entitlements',
    )
    if (codeSignArchitecture(0x0100000c, 'synthetic arm64') !== 'arm64'
        || codeSignArchitecture(0x01000007, 'synthetic x86_64') !== 'x86_64') {
      fail('Mach-O CPU types did not map to explicit code-signing architectures')
    }
    expectFailure(
      () => codeSignArchitecture(0x01000012, 'synthetic unsupported CPU'),
      'an unsupported code-signing CPU type',
    )
    const oversizedSignatureEnvelope = join(fixture, 'oversized-signature-envelope')
    mkdirSync(oversizedSignatureEnvelope)
    writeFileSync(
      join(oversizedSignatureEnvelope, 'CodeResources'),
      Buffer.alloc(maximumMetadataBytes + 1),
    )
    expectFailure(
      () => validateSignatureEnvelope(
        oversizedSignatureEnvelope,
        '_CodeSignature',
        'oversized synthetic signature envelope',
      ),
      'an oversized excluded signature-envelope file',
    )
    rmSync(oversizedSignatureEnvelope, { recursive: true })
    const aggregateSignatureEnvelope = join(fixture, 'aggregate-signature-envelope')
    mkdirSync(aggregateSignatureEnvelope)
    const maximumEnvelopeFile = Buffer.alloc(maximumMetadataBytes)
    for (let index = 0; index < 5; index++) {
      writeFileSync(join(aggregateSignatureEnvelope, `CodeResource-${index}`), maximumEnvelopeFile)
    }
    expectFailure(
      () => validateSignatureEnvelope(
        aggregateSignatureEnvelope,
        '_CodeSignature',
        'aggregate-oversized synthetic signature envelope',
      ),
      'an aggregate-oversized excluded signature envelope',
    )
    rmSync(aggregateSignatureEnvelope, { recursive: true })
    const excessiveEntryEnvelope = join(fixture, 'excessive-entry-signature-envelope')
    mkdirSync(excessiveEntryEnvelope)
    for (let index = 0; index <= maximumSignatureEnvelopeEntries; index++) {
      writeFileSync(join(excessiveEntryEnvelope, `CodeResource-${index}`), '')
    }
    expectFailure(
      () => validateSignatureEnvelope(
        excessiveEntryEnvelope,
        '_CodeSignature',
        'excessive-entry synthetic signature envelope',
      ),
      'an excluded signature envelope with excessive entries',
    )
    rmSync(excessiveEntryEnvelope, { recursive: true })
    const deeplyNestedEnvelope = join(fixture, 'deep-signature-envelope')
    let nestedEnvelope = deeplyNestedEnvelope
    mkdirSync(nestedEnvelope)
    for (let depth = 0; depth <= maximumSignatureEnvelopeDepth; depth++) {
      nestedEnvelope = join(nestedEnvelope, `nested-${depth}`)
      mkdirSync(nestedEnvelope)
    }
    expectFailure(
      () => validateSignatureEnvelope(
        deeplyNestedEnvelope,
        '_CodeSignature',
        'deeply nested synthetic signature envelope',
      ),
      'an excessively nested excluded signature envelope',
    )
    rmSync(deeplyNestedEnvelope, { recursive: true })
    const compactSignature = syntheticSignedMachO({
      signatureSize: 0x800,
      signatureFill: 0xa5,
      signatureCommandIndex: 1,
    })
    const expandedSignature = syntheticSignedMachO({
      signatureSize: 0x5000,
      signatureFill: 0x3c,
      signatureCommandIndex: 2,
    })
    validateSignedMachO(compactSignature, 'synthetic signed Mach-O')
    const compactCanonical = canonicalizeSignedMachO(
      compactSignature,
      'compact-signature synthetic Mach-O',
    )
    const expandedCanonical = canonicalizeSignedMachO(
      expandedSignature,
      'expanded-signature synthetic Mach-O',
    )
    if (!compactCanonical.bytes.equals(expandedCanonical.bytes)) {
      fail('canonical Mach-O depends on signature size, bytes, or load-command position')
    }
    if (compactCanonical.bytes.length !== 0x57f8
        || compactCanonical.bytes.readUInt32LE(16) !== 2
        || compactCanonical.bytes.readUInt32LE(20) !== 96) {
      fail('canonical Mach-O did not remove signature metadata and alignment padding')
    }

    const signatureMutation = Buffer.from(compactSignature)
    signatureMutation[signatureMutation.length - 1] ^= 0xff
    if (!canonicalizeSignedMachO(
      signatureMutation,
      'signature-byte-mutated synthetic Mach-O',
    ).bytes.equals(compactCanonical.bytes)) {
      fail('canonical Mach-O depends on signature-envelope bytes')
    }
    const payloadMutation = Buffer.from(compactSignature)
    payloadMutation[0x800] ^= 0xff
    if (canonicalizeSignedMachO(
      payloadMutation,
      'payload-mutated synthetic Mach-O',
    ).bytes.equals(compactCanonical.bytes)) {
      fail('canonical Mach-O ignored executable payload mutation')
    }
    const loadCommandMutation = Buffer.from(compactSignature)
    loadCommandMutation[32 + 56] ^= 0x1
    if (canonicalizeSignedMachO(
      loadCommandMutation,
      'load-command-mutated synthetic Mach-O',
    ).bytes.equals(compactCanonical.bytes)) {
      fail('canonical Mach-O ignored retained load-command mutation')
    }
    const thinSubtypeMutation = syntheticSignedMachO({ cpuSubtype: 1 })
    if (canonicalizeSignedMachO(
      thinSubtypeMutation,
      'CPU-subtype-mutated thin Mach-O',
    ).bytes.equals(compactCanonical.bytes)) {
      fail('canonical thin Mach-O ignored CPU-subtype mutation')
    }

    const x86Compact = syntheticSignedMachO({
      cpuType: 0x01000007,
      cpuSubtype: 3,
      signatureSize: 0x800,
      signatureCommandIndex: 1,
    })
    const x86Expanded = syntheticSignedMachO({
      cpuType: 0x01000007,
      cpuSubtype: 3,
      signatureSize: 0x1000,
      signatureFill: 0x6d,
      signatureCommandIndex: 2,
    })
    const compactFat = syntheticFatMachO([compactSignature, x86Compact])
    const expandedFat = syntheticFatMachO([expandedSignature, x86Expanded])
    const compactFatCanonical = canonicalizeSignedMachO(
      compactFat,
      'compact-layout synthetic fat Mach-O',
    )
    if (!compactFatCanonical.bytes.equals(canonicalizeSignedMachO(
      expandedFat,
      'expanded-layout synthetic fat Mach-O',
    ).bytes)) {
      fail('canonical fat Mach-O depends on signed slice sizes or offsets')
    }
    expectFailure(
      () => validateSignedMachO(
        syntheticSignedMachO({ virtualSize: 0xc000n }),
        'inflated synthetic signed Mach-O',
      ),
      'an aligned but inflated signed __LINKEDIT virtual size',
    )
    const nonterminalSignature = Buffer.from(compactSignature)
    nonterminalSignature.writeUInt32LE(0x400, 32 + 72 + 12)
    expectFailure(
      () => validateSignedMachO(nonterminalSignature, 'nonterminal synthetic signature'),
      'a nonterminal LC_CODE_SIGNATURE extent',
    )
    const malformedCommandSize = Buffer.from(compactSignature)
    malformedCommandSize.writeUInt32LE(12, 32 + 72 + 4)
    expectFailure(
      () => validateSignedMachO(malformedCommandSize, 'malformed-command synthetic Mach-O'),
      'a non-8-byte-aligned Mach-O command size',
    )
    const malformedCommandCount = Buffer.from(compactSignature)
    malformedCommandCount.writeUInt32LE(4, 16)
    expectFailure(
      () => validateSignedMachO(malformedCommandCount, 'malformed-count synthetic Mach-O'),
      'a Mach-O command count inconsistent with sizeofcmds',
    )
    const malformedLinkeditSections = Buffer.from(compactSignature)
    malformedLinkeditSections.writeUInt32LE(1, 32 + 64)
    expectFailure(
      () => validateSignedMachO(
        malformedLinkeditSections,
        'sectioned-linkedit synthetic Mach-O',
      ),
      'a sectioned or inconsistently sized __LINKEDIT segment',
    )
    const overlappingLinkedit = Buffer.from(compactSignature)
    overlappingLinkedit.writeBigUInt64LE(0n, 32 + 40)
    overlappingLinkedit.writeBigUInt64LE(BigInt(overlappingLinkedit.length), 32 + 48)
    expectFailure(
      () => validateSignedMachO(overlappingLinkedit, 'overlapping-linkedit synthetic Mach-O'),
      'a __LINKEDIT segment overlapping the load-command table',
    )
    const nonDylib = Buffer.from(compactSignature)
    nonDylib.writeUInt32LE(2, 12)
    expectFailure(
      () => validateSignedMachO(nonDylib, 'non-dylib synthetic Mach-O'),
      'a signed Mach-O that is not MH_DYLIB',
    )
    const unsupportedCommand = Buffer.from(compactSignature)
    unsupportedCommand.writeUInt32LE(0x40, 32 + 72 + 16)
    expectFailure(
      () => validateSignedMachO(unsupportedCommand, 'unsupported-command synthetic Mach-O'),
      'an unsupported Mach-O load command',
    )
    const nonzeroSignaturePadding = Buffer.from(compactSignature)
    nonzeroSignaturePadding[0x57f8] = 1
    expectFailure(
      () => validateSignedMachO(nonzeroSignaturePadding, 'nonzero-padding synthetic Mach-O'),
      'non-zero signature-alignment padding',
    )
    const nonzeroFatGap = Buffer.from(compactFat)
    nonzeroFatGap[48] = 1
    expectFailure(
      () => validateSignedMachO(nonzeroFatGap, 'nonzero-gap synthetic fat Mach-O'),
      'non-zero fat-slice padding',
    )
    const nonzeroFatTrailing = Buffer.concat([compactFat, Buffer.from([1])])
    expectFailure(
      () => validateSignedMachO(nonzeroFatTrailing, 'trailing-byte synthetic fat Mach-O'),
      'trailing fat padding',
    )
    const zeroFatTrailing = Buffer.concat([compactFat, Buffer.alloc(16)])
    expectFailure(
      () => validateSignedMachO(zeroFatTrailing, 'zero-trailing synthetic fat Mach-O'),
      'zero trailing fat padding',
    )
    const duplicateArchitecture = Buffer.from(compactFat)
    const secondSliceOffset = duplicateArchitecture.readUInt32BE(28 + 8)
    duplicateArchitecture.writeInt32BE(0x0100000c, 28)
    duplicateArchitecture.writeInt32BE(0, 28 + 4)
    duplicateArchitecture.writeInt32LE(0x0100000c, secondSliceOffset + 4)
    duplicateArchitecture.writeInt32LE(0, secondSliceOffset + 8)
    expectFailure(
      () => validateSignedMachO(duplicateArchitecture, 'duplicate-architecture fat Mach-O'),
      'a duplicate fat architecture tuple',
    )
    const subtypeMismatch = Buffer.from(compactFat)
    subtypeMismatch.writeInt32BE(1, 8 + 4)
    expectFailure(
      () => validateSignedMachO(subtypeMismatch, 'subtype-mismatched fat Mach-O'),
      'fat metadata that disagrees with its slice CPU subtype',
    )
    const alignmentMutation = syntheticFatMachO([compactSignature, x86Compact], [13, 14])
    if (canonicalizeSignedMachO(
      alignmentMutation,
      'alignment-mutated synthetic fat Mach-O',
    ).bytes.equals(compactFatCanonical.bytes)) {
      fail('canonical fat Mach-O ignored architecture alignment mutation')
    }
    const subtypeMutationFat = syntheticFatMachO([
      syntheticSignedMachO({ cpuSubtype: 1 }),
      x86Compact,
    ])
    if (canonicalizeSignedMachO(
      subtypeMutationFat,
      'subtype-mutated synthetic fat Mach-O',
    ).bytes.equals(compactFatCanonical.bytes)) {
      fail('canonical fat Mach-O ignored CPU-subtype mutation')
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
