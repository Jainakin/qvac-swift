#!/usr/bin/env node

import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import {
  appendFileSync,
  copyFileSync,
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from 'node:path'
import { fileURLToPath } from 'node:url'

const toolDirectory = dirname(fileURLToPath(import.meta.url))
const lockName = 'provenance.lock.json'
const expectedPatchPaths = [
  'CMakeLists.txt',
  'apple/BareKit/BareKit.h',
  'apple/BareKit/BareKit.m',
  'shared/posix/ipc.c',
]
const expectedHistoricalR1Hashes = new Set([
  '45efd5ab07d5df185f679a7422f7ef1068c00c8dbbe3f1ca26ef7eece4ebe20d',
  '072006007278fa3bdf0ca4d1cec1d2c6972b8e1f0655c7a11f44551423f91b29',
])
const expectedModuleMapSHA256 = '05864530e635c81092e55151c5fe3bf5348cea5912aecb11420f078c9a97b619'
const expectedPatchMarker = 'qvac-bare-kit-2.3.0-ipc-hardening-1'
const expectedPatchSHA256 = 'd8513ef4b411767719a6f10997408c6075a85bd7d171efd25d8076ea0e4683d2'
const expectedPatchedTreeSHA256 = 'b4eb3c53ddfb09545bfdd0dbc126f259581bdfd1a36268bc1b2fa29ff7e46d5a'
const expectedBuilderLockSHA256 = '1cde446d0351b7547f6dce7adf70e69470b253b12e155db8bce221400b7bd09c'
const expectedNativeClosureSHA256 = 'a456eeaf612132a3b6af1433640fdcf64ab715ef95dc18e99f740270700065b8'
const expectedThreadSanitizerRuntime = '@rpath/libclang_rt.tsan_iossim_dynamic.dylib'
const requiredThreadSanitizerSources = [
  'apple/BareKit/BareKit.m',
  'shared/posix/ipc.c',
]
const expectedPatchedInputs = {
  'CMakeLists.txt': '9328a3c1e9286bd49260adfd658aaa80ee64d9bf0aeba3d36047f3ae8eb4d33e',
  'apple/BareKit/BareKit.h': '316d203c4d1b54a942f7f5e7d9f0e299a755dcddecdf8c8a54af287d0d479ba2',
  'apple/BareKit/BareKit.m': 'e231b9a37f0de87637817c2d8ca48bf3c63524a118647707ffa94bea622975e6',
  'shared/posix/ipc.c': 'efa3f9a4272c9fef334ae4687d0435e4816a7352f1f80027fb9e94deaa6c69ab',
}
const expectedPatchClaims = [
  'Retry interrupted POSIX IPC reads and writes before exposing an error.',
  'Expose non-would-block read failures as NSError without consuming uninitialized data.',
  'Return read NSData with conventional non-owning Objective-C method semantics.',
  'Report synchronous and callback-based write failures without constructing invalid byte ranges.',
  'Own callback-based write state until completion or callback teardown under manual reference counting.',
  'Copy callbacks before invocation and release replaced or closed callbacks under manual reference counting.',
  'Make close idempotent and prevent callback or descriptor use after close begins.',
  'Resolve the Bare runtime by its exact 1.29.4 commit rather than a movable tag.',
]
const expectedActivationRequirements = [
  'Build and verify this byte-bound candidate twice from clean locked-toolchain roots; require byte-identical output or record and review every nondeterministic field.',
  'Run the complete iOS lifecycle, backpressure, memory, and real-worker suite against the candidate on simulator and physical device.',
  'Include the exact patch, provenance lock, and generated dependency-closure evidence in candidate evidence and bind them by SHA-256 in the release manifest.',
  "Resolve the repository's separate privacy and native-license publication blockers.",
  'Generate and commit the URL-backed Package.swift from the verified dry-run r2-or-later candidate, require complete CI on that exact source commit, then have the publishing maintainer publish the rebuilt byte-identical assets under the reserved immutable tag only after a separately reviewed removal of the publication kill switch.',
]

function fail(message) {
  throw new Error(`[bare-kit] ${message}`)
}

function sha256Bytes(bytes) {
  return createHash('sha256').update(bytes).digest('hex')
}

function sha256(path) {
  return sha256Bytes(readFileSync(path))
}

function stableJSON(value) {
  if (Array.isArray(value)) return `[${value.map(stableJSON).join(',')}]`
  if (value !== null && typeof value === 'object') {
    return `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${stableJSON(value[key])}`).join(',')}}`
  }
  return JSON.stringify(value)
}

function requireHexDigest(value, length, label) {
  if (typeof value !== 'string' || !new RegExp(`^[0-9a-f]{${length}}$`).test(value)) {
    fail(`${label} must be a lowercase ${length}-character hexadecimal digest`)
  }
}

function exactKeys(value, keys, label) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) fail(`${label} must be an object`)
  const actual = Object.keys(value).sort()
  const expected = [...keys].sort()
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    fail(`${label} keys differ: expected ${expected.join(', ')}, got ${actual.join(', ')}`)
  }
}

function requireRegularFile(path, label) {
  if (!existsSync(path)) fail(`missing ${label}: ${path}`)
  const metadata = lstatSync(path)
  if (metadata.isSymbolicLink() || !metadata.isFile() || metadata.size === 0) {
    fail(`${label} must be a non-empty regular, non-symlink file: ${path}`)
  }
  return metadata
}

function requireDirectory(path, label) {
  if (!existsSync(path)) fail(`missing ${label}: ${path}`)
  const metadata = lstatSync(path)
  if (metadata.isSymbolicLink() || !metadata.isDirectory()) {
    fail(`${label} must be a real, non-symlink directory: ${path}`)
  }
  return realpathSync(path)
}

function safeRelativePath(value, label) {
  if (typeof value !== 'string' || value.length === 0 || isAbsolute(value) || value.includes('\\')) {
    fail(`unsafe ${label}: ${String(value)}`)
  }
  const components = value.split('/')
  if (components.some(component => component === '' || component === '.' || component === '..')) {
    fail(`unsafe ${label}: ${value}`)
  }
  return value
}

function pathInside(root, relativePath, label) {
  const candidate = resolve(root, safeRelativePath(relativePath, label))
  const rel = relative(root, candidate)
  if (rel === '' || rel === '..' || rel.startsWith(`..${sep}`)) fail(`${label} escaped ${root}`)
  return candidate
}

function readJSON(path, label) {
  requireRegularFile(path, label)
  try {
    return JSON.parse(readFileSync(path, 'utf8'))
  } catch (error) {
    fail(`${label} is not valid JSON: ${error.message}`)
  }
}

function run(command, arguments_, options = {}) {
  try {
    return execFileSync(command, arguments_, { encoding: 'utf8', ...options })
  } catch (error) {
    const detail = String(error.stderr || error.stdout || error.message).trim()
    fail(`${command} ${arguments_.join(' ')} failed${detail ? `: ${detail}` : ''}`)
  }
}

function validateLock(lock) {
  exactKeys(
    lock,
    [
      'schemaVersion',
      'component',
      'upstreamVersion',
      'upstream',
      'runtime',
      'nativeClosure',
      'patch',
      'buildToolchain',
      'candidate',
    ],
    'provenance lock',
  )
  if (lock.schemaVersion !== 2 || lock.component !== 'BareKit' || lock.upstreamVersion !== '2.3.0') {
    fail('provenance lock must describe BareKit 2.3.0 schema v2')
  }

  exactKeys(
    lock.upstream,
    ['repository', 'tag', 'tagObject', 'commit', 'tree', 'contentSHA256', 'license', 'inputs'],
    'upstream',
  )
  if (lock.upstream.repository !== 'https://github.com/holepunchto/bare-kit.git'
      || lock.upstream.tag !== 'v2.3.0'
      || lock.upstream.tagObject !== 'afa4a27a345627dadb542f651d71501c1e290347'
      || lock.upstream.commit !== '264ebb068d23ca5c5168ed92ea1a0ce85b12259d'
      || lock.upstream.tree !== '671900a0af3d1ab8f3542c0f785904a3aa6aa97b'
      || lock.upstream.contentSHA256 !== '6924a86b5512a96b02908bc953da5226677e68855e525b25846ecac00997cac1'
      || lock.upstream.license !== 'Apache-2.0') {
    fail('upstream identity differs from the reviewed BareKit v2.3.0 source')
  }
  const expectedInputPaths = [
    'CMakeLists.txt',
    'LICENSE',
    'NOTICE',
    'apple/BareKit/BareKit.h',
    'apple/BareKit/BareKit.m',
    'package-lock.json',
    'shared/posix/ipc.c',
  ]
  exactKeys(lock.upstream.inputs, expectedInputPaths, 'upstream inputs')

  exactKeys(lock.runtime, ['version', 'commit'], 'Bare runtime')
  if (lock.runtime.version !== '1.29.4'
      || lock.runtime.commit !== '5cf8db08c17a433a2f05b25e397a7ebcdcf5a158') {
    fail('Bare runtime is not the reviewed 1.29.4 commit')
  }

  exactKeys(lock.nativeClosure, ['sources', 'prebuiltArchiveMirror'], 'native closure')
  const sourceDirectories = [
    'github+google+boringssl-src',
    'github+holepunchto+bare-src',
    'github+holepunchto+libbase64-src',
    'github+holepunchto+libhex-src',
    'github+holepunchto+libjs-src',
    'github+holepunchto+liblog-src',
    'github+holepunchto+libnapi-src',
    'github+holepunchto+librlimit-src',
    'github+holepunchto+liburl-src',
    'github+holepunchto+libutf-src',
    'github+libuv+libuv-src',
  ]
  exactKeys(lock.nativeClosure.sources, sourceDirectories, 'native closure sources')
  for (const directory of sourceDirectories) {
    const source = lock.nativeClosure.sources[directory]
    exactKeys(source, ['repository', 'commit', 'tree'], `native closure source ${directory}`)
    if (typeof source.repository !== 'string'
        || !/^https:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\.git$/.test(source.repository)) {
      fail(`native closure source ${directory} has an invalid repository`)
    }
    requireHexDigest(source.commit, 40, `${directory} commit`)
    requireHexDigest(source.tree, 40, `${directory} tree`)
  }
  const mirror = lock.nativeClosure.prebuiltArchiveMirror
  exactKeys(mirror, ['driveKey', 'checkout', 'targets'], 'prebuilt archive mirror')
  if (mirror.driveKey !== 'krmguqnh75rud4iieqgmzyqoza415cbu68payoww65ii9fzt5n4o'
      || mirror.checkout !== 133) {
    fail('prebuilt archive mirror identity differs from the reviewed Bare input')
  }
  const mirrorTargets = ['ios-arm64', 'ios-arm64-simulator', 'ios-x64-simulator']
  exactKeys(mirror.targets, mirrorTargets, 'prebuilt archive mirror targets')
  for (const target of mirrorTargets) {
    exactKeys(mirror.targets[target], ['libc++.a', 'libjs.a', 'libv8.a'], `prebuilt archive ${target}`)
    for (const [name, digest] of Object.entries(mirror.targets[target])) {
      requireHexDigest(digest, 64, `prebuilt archive ${target}/${name}`)
    }
  }
  if (sha256Bytes(Buffer.from(stableJSON(lock.nativeClosure))) !== expectedNativeClosureSHA256) {
    fail('native dependency closure differs from the reviewed source and prebuilt inputs')
  }

  exactKeys(lock.patch, ['file', 'sha256', 'patchedTreeSHA256', 'patchedInputs', 'claims'], 'patch')
  if (lock.patch.file !== 'bare-kit-2.3.0-qvac.patch'
      || lock.patch.sha256 !== expectedPatchSHA256
      || lock.patch.patchedTreeSHA256 !== expectedPatchedTreeSHA256) {
    fail('patch identity differs from the reviewed hardening patch')
  }
  exactKeys(lock.patch.patchedInputs, expectedPatchPaths, 'patched inputs')
  for (const [path, expectedHash] of Object.entries(expectedPatchedInputs)) {
    if (lock.patch.patchedInputs[path] !== expectedHash) {
      fail(`patched input identity differs for ${path}`)
    }
  }
  if (JSON.stringify(lock.patch.claims) !== JSON.stringify(expectedPatchClaims)) {
    fail('patch claims differ from the reviewed hardening scope')
  }

  exactKeys(
    lock.buildToolchain,
    ['node', 'xcode', 'developerDirectory', 'compiler', 'bareMake', 'packageLockSHA256'],
    'toolchain',
  )
  exactKeys(lock.buildToolchain.bareMake, ['version', 'integrity'], 'bare-make tool')
  if (lock.buildToolchain.node !== '22.22.0'
      || lock.buildToolchain.xcode !== '16.4'
      || lock.buildToolchain.developerDirectory !== '/Applications/Xcode_16.4.app/Contents/Developer'
      || lock.buildToolchain.compiler !== 'apple-clang-from-xcode'
      || lock.buildToolchain.bareMake.version !== '1.8.0'
      || lock.buildToolchain.bareMake.integrity
        !== 'sha512-IUBNn2B2YIebhXE6Slw9bSmOYItS2cJBy1cVNqWs1yrzuxXbCbPS43NoV/gUEVOy+2KYfPIAmsuv4f+GZ5MR/A=='
      || lock.buildToolchain.packageLockSHA256 !== expectedBuilderLockSHA256) {
    fail('build toolchain differs from the reviewed exact versions')
  }

  exactKeys(lock.candidate, ['revisionFloor', 'architectures', 'activationStatus', 'activationRequirements'], 'candidate')
  exactKeys(lock.candidate.architectures, ['device', 'simulator'], 'candidate architectures')
  if (lock.candidate.revisionFloor !== 2
      || JSON.stringify(lock.candidate.architectures.device) !== JSON.stringify(['arm64'])
      || JSON.stringify(lock.candidate.architectures.simulator) !== JSON.stringify(['arm64', 'x86_64'])
      || lock.candidate.activationStatus !== 'blocked'
      || JSON.stringify(lock.candidate.activationRequirements) !== JSON.stringify(expectedActivationRequirements)) {
    fail('candidate must remain blocked with the complete r2 activation gate')
  }
  return lock
}

function validatePackageLock(directory, lock) {
  const packagePath = join(directory, 'package.json')
  const packageLockPath = join(directory, 'package-lock.json')
  const packageJSON = readJSON(packagePath, 'builder package.json')
  const packageLock = readJSON(packageLockPath, 'builder package-lock.json')
  if (sha256(packageLockPath) !== lock.buildToolchain.packageLockSHA256) fail('builder package-lock SHA-256 changed')
  exactKeys(packageJSON.dependencies ?? {}, ['bare-make'], 'builder dependencies')
  if (packageJSON.engines?.node !== lock.buildToolchain.node
      || packageJSON.dependencies['bare-make'] !== lock.buildToolchain.bareMake.version) {
    fail('builder package.json differs from the pinned toolchain')
  }
  if (packageLock.lockfileVersion !== 3
      || JSON.stringify(packageLock.packages?.['']?.dependencies) !== JSON.stringify(packageJSON.dependencies)
      || packageLock.packages?.['']?.engines?.node !== lock.buildToolchain.node) {
    fail('builder package-lock root differs from package.json')
  }
  const bareMake = packageLock.packages?.['node_modules/bare-make']
  if (bareMake?.version !== lock.buildToolchain.bareMake.version
      || bareMake?.integrity !== lock.buildToolchain.bareMake.integrity
      || bareMake?.resolved !== `https://registry.npmjs.org/bare-make/-/bare-make-${bareMake.version}.tgz`) {
    fail('package-lock does not contain the exact reviewed bare-make artifact')
  }
  for (const [path, metadata] of Object.entries(packageLock.packages ?? {})) {
    if (!path) continue
    if (typeof metadata.version !== 'string' || !/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(metadata.version)) {
      fail(`${path} has a non-exact version`)
    }
    if (typeof metadata.resolved !== 'string' || !metadata.resolved.startsWith('https://registry.npmjs.org/')) {
      fail(`${path} is not resolved from the immutable npm registry artifact URL`)
    }
    if (typeof metadata.integrity !== 'string' || !metadata.integrity.startsWith('sha512-')) {
      fail(`${path} has no npm integrity`)
    }
  }
}

function addedPatchLines(patchText) {
  return patchText.split('\n')
    .filter(line => line.startsWith('+') && !line.startsWith('+++'))
    .map(line => line.slice(1))
    .join('\n')
}

function validatePatch(directory, lock) {
  const patchPath = join(directory, lock.patch.file)
  requireRegularFile(patchPath, 'BareKit patch')
  const patchBytes = readFileSync(patchPath)
  if (sha256Bytes(patchBytes) !== lock.patch.sha256) fail('BareKit patch SHA-256 changed')
  if (patchBytes.includes(13)) fail('BareKit patch must use LF line endings')
  const patchText = patchBytes.toString('utf8')
  const paths = [...patchText.matchAll(/^\+\+\+ b\/(.+)$/gm)].map(match => match[1])
  if (JSON.stringify(paths) !== JSON.stringify(expectedPatchPaths)) {
    fail(`patch path inventory differs: ${paths.join(', ')}`)
  }
  if (/^(?:new file mode|deleted file mode|rename from|rename to|Binary files) /m.test(patchText)) {
    fail('patch may modify only the reviewed existing text files')
  }
  const added = addedPatchLines(patchText)
  const requiredSemantics = [
    `fetch_package("github:holepunchto/bare#${lock.runtime.commit}")`,
    `FOUNDATION_EXPORT NSString *_Nonnull const BareKitQVACPatchLevel;`,
    `NSString *const BareKitQVACPatchLevel = @"${expectedPatchMarker}";`,
    '- (NSData *_Nullable)readWithError:(NSError *_Nullable *_Nullable)error;',
    'while (res < 0 && errno == EINTR);',
    'return [NSData dataWithBytes:data length:len];',
    'assert(err >= 0 || err == bare_ipc_would_block || err == bare_ipc_error);',
    '@interface BareIPCWriteContext : NSObject',
    'NSInteger written = [ipc write:context.remaining];',
    'completion(bare_ipc__posix_error(errorCode));',
    '[context release];',
    'errno = EBADF;',
    '[previous release];',
    '[readable release];',
    '[writable release];',
    '[self close];',
  ]
  for (const semantic of requiredSemantics) {
    if (!added.includes(semantic)) fail(`patch is missing required semantic: ${semantic}`)
  }
  if (added.split('while (res < 0 && errno == EINTR);').length - 1 !== 2) {
    fail('patch must retry EINTR in both POSIX read and write')
  }
}

function verifyRepository(directory = toolDirectory) {
  const lock = validateLock(readJSON(join(directory, lockName), 'BareKit provenance lock'))
  validatePackageLock(directory, lock)
  validatePatch(directory, lock)
  console.log(`[bare-kit] patch ${lock.patch.sha256} binds ${lock.upstream.commit} / Bare ${lock.runtime.commit}`)
  console.log(`[bare-kit] native closure ${expectedNativeClosureSHA256} binds ${Object.keys(lock.nativeClosure.sources).length} source repositories`)
  console.log(`[bare-kit] builder bare-make ${lock.buildToolchain.bareMake.version} / Node ${lock.buildToolchain.node}`)
  console.log('[bare-kit] activation remains blocked pending every reviewed requirement and explicit publication-kill-switch removal')
  return lock
}

function verifyHashes(root, hashes, label) {
  for (const [relativePath, expectedHash] of Object.entries(hashes)) {
    const path = pathInside(root, relativePath, `${label} path`)
    requireRegularFile(path, `${label} ${relativePath}`)
    const actual = sha256(path)
    if (actual !== expectedHash) fail(`${label} ${relativePath} SHA-256 mismatch: expected ${expectedHash}, got ${actual}`)
  }
}

function git(source, arguments_) {
  return run('git', ['-C', source, ...arguments_]).trim()
}

function workingTreeDigest(source) {
  const paths = execFileSync('git', ['-C', source, 'ls-files', '-z'])
    .toString('utf8').split('\0').filter(Boolean).sort()
  const hash = createHash('sha256')
  for (const path of paths) {
    const bytes = readFileSync(pathInside(source, path, 'tracked source path'))
    hash.update(path)
    hash.update('\0')
    hash.update(String(bytes.length))
    hash.update('\0')
    hash.update(bytes)
  }
  return hash.digest('hex')
}

// Git's optional hunk-heading text is produced by version- and
// installation-specific userdiff attributes. It is not consumed by `git apply`,
// and Git installations can describe the same Objective-C hunk with different
// method/function labels. The comparison preserves every path, blob ID, mode,
// range, and payload byte while excluding only that non-semantic suffix.
function canonicalPatchForComparison(patchText) {
  return patchText.replace(
    /^(@@ -[0-9]+(?:,[0-9]+)? \+[0-9]+(?:,[0-9]+)? @@)(?: .*)?$/gm,
    '$1',
  )
}

function reviewedPatchDiff(source, paths = expectedPatchPaths) {
  return run('git', [
    '-C', source, '-c', 'diff.suppressBlankEmpty=false', 'diff', '--full-index',
    '--no-ext-diff', '--no-textconv', '--no-renames', '--no-color', '--unified=3',
    '--diff-algorithm=myers', '--indent-heuristic', '--src-prefix=a/', '--dst-prefix=b/',
    '--', ...paths,
  ])
}

function verifySource(sourcePath, state, lock) {
  const source = requireDirectory(resolve(sourcePath), 'BareKit source checkout')
  if (!['upstream', 'patched'].includes(state)) fail(`invalid source state: ${state}`)
  if (git(source, ['rev-parse', 'HEAD']) !== lock.upstream.commit) fail('source checkout HEAD differs from pinned commit')
  if (git(source, ['rev-parse', 'HEAD^{tree}']) !== lock.upstream.tree) fail('source checkout tree differs from pinned tree')
  if (git(source, ['rev-parse', `refs/tags/${lock.upstream.tag}`]) !== lock.upstream.tagObject
      || git(source, ['rev-parse', `refs/tags/${lock.upstream.tag}^{commit}`]) !== lock.upstream.commit) {
    fail('source checkout does not contain the exact annotated v2.3.0 tag object')
  }
  const origin = git(source, ['remote', 'get-url', 'origin']).replace(/\/$/, '').replace(/\.git$/, '')
  if (origin !== lock.upstream.repository.replace(/\.git$/, '')) fail(`unexpected source origin: ${origin}`)

  if (state === 'upstream') {
    verifyHashes(source, lock.upstream.inputs, 'upstream input')
    if (git(source, ['status', '--porcelain', '--untracked-files=no']) !== '') fail('upstream source has tracked modifications')
    if (workingTreeDigest(source) !== lock.upstream.contentSHA256) fail('complete upstream source SHA-256 changed')
  } else {
    const hashes = { ...lock.upstream.inputs, ...lock.patch.patchedInputs }
    verifyHashes(source, hashes, 'patched input')
    const changed = git(source, ['diff', '--name-only', 'HEAD', '--']).split('\n').filter(Boolean)
    if (JSON.stringify(changed) !== JSON.stringify(expectedPatchPaths)) {
      fail(`patched checkout changed unexpected paths: ${changed.join(', ')}`)
    }
    run('git', ['-C', source, 'diff', '--check'])
    const actualPatch = reviewedPatchDiff(source)
    const expectedPatch = readFileSync(join(toolDirectory, lock.patch.file), 'utf8')
    if (canonicalPatchForComparison(actualPatch) !== canonicalPatchForComparison(expectedPatch)) {
      fail('patched checkout canonical diff differs from the reviewed patch')
    }
    if (workingTreeDigest(source) !== lock.patch.patchedTreeSHA256) fail('complete patched source SHA-256 changed')
  }
  console.log(`[bare-kit] verified ${state} source ${lock.upstream.commit}`)
}

function normalizedGitOrigin(value) {
  return value.trim().replace(/\/$/, '').replace(/\.git$/, '')
}

function writeNativeClosureEvidence(path, evidence) {
  const evidenceRoots = [
    join(toolDirectory, '.build', 'evidence'),
    join(toolDirectory, '.build', 'tsan', 'evidence'),
  ].filter(existsSync).map(root => requireDirectory(root, 'native closure evidence root'))
  const output = resolve(path)
  if (!evidenceRoots.includes(dirname(output))
      || !/^[A-Za-z0-9][A-Za-z0-9._-]*\.json$/.test(basename(output))) {
    fail('native closure evidence must be a direct JSON child of a tool-owned build evidence directory')
  }
  if (existsSync(output)) {
    const metadata = lstatSync(output)
    if (metadata.isSymbolicLink() || !metadata.isFile()) {
      fail(`native closure evidence output must be a regular, non-symlink file: ${output}`)
    }
  }
  writeFileSync(output, `${JSON.stringify(evidence, null, 2)}\n`)
}

function verifyNativeClosure(buildPath, target, lock, evidencePath) {
  const build = requireDirectory(resolve(buildPath), 'generated BareKit build')
  const dependencies = requireDirectory(join(build, '_deps'), 'generated BareKit dependencies')
  const expectedSourceNames = Object.keys(lock.nativeClosure.sources).sort()
  const actualSourceNames = readdirSync(dependencies, { withFileTypes: true })
    .map(entry => entry.name)
    .filter(name => name.endsWith('-src'))
    .sort()
  if (JSON.stringify(actualSourceNames) !== JSON.stringify(expectedSourceNames)) {
    fail(`native source closure differs: expected ${expectedSourceNames.join(', ')}, got ${actualSourceNames.join(', ')}`)
  }

  const verifiedSources = {}
  for (const name of expectedSourceNames) {
    const expected = lock.nativeClosure.sources[name]
    const source = requireDirectory(join(dependencies, name), `native source ${name}`)
    const actualCommit = git(source, ['rev-parse', 'HEAD'])
    const actualTree = git(source, ['rev-parse', 'HEAD^{tree}'])
    const actualOrigin = git(source, ['remote', 'get-url', 'origin'])
    if (actualCommit !== expected.commit || actualTree !== expected.tree) {
      fail(`${name} resolved to ${actualCommit}/${actualTree}; expected ${expected.commit}/${expected.tree}`)
    }
    if (normalizedGitOrigin(actualOrigin) !== normalizedGitOrigin(expected.repository)) {
      fail(`${name} resolved from unexpected origin: ${actualOrigin}`)
    }
    const status = git(source, ['status', '--porcelain'])
    if (status !== '') fail(`${name} contains generated, untracked, or modified source: ${status}`)
    const submodules = git(source, ['submodule', 'status', '--recursive'])
    if (submodules !== '') fail(`${name} contains an unreviewed Git submodule closure: ${submodules}`)
    verifiedSources[name] = {
      repository: expected.repository,
      commit: actualCommit,
      tree: actualTree,
    }
  }

  const mirror = lock.nativeClosure.prebuiltArchiveMirror
  if (!Object.hasOwn(mirror.targets, target)) fail(`unsupported native closure target: ${target}`)
  const archiveRoot = requireDirectory(
    join(dependencies, 'github+holepunchto+bare-build', target),
    `prebuilt archive ${target}`,
  )
  const expectedArchiveNames = Object.keys(mirror.targets[target]).sort()
  const actualArchiveNames = readdirSync(archiveRoot, { withFileTypes: true })
    .map(entry => entry.name)
    .sort()
  if (JSON.stringify(actualArchiveNames) !== JSON.stringify(expectedArchiveNames)) {
    fail(`prebuilt archive ${target} inventory differs: expected ${expectedArchiveNames.join(', ')}, got ${actualArchiveNames.join(', ')}`)
  }
  verifyHashes(archiveRoot, mirror.targets[target], `prebuilt archive ${target}`)

  const evidence = {
    schemaVersion: 1,
    component: 'BareKit native dependency closure',
    upstreamCommit: lock.upstream.commit,
    provenanceLockSHA256: sha256(join(toolDirectory, lockName)),
    nativeClosureSHA256: expectedNativeClosureSHA256,
    target,
    sources: verifiedSources,
    prebuiltArchiveMirror: {
      driveKey: mirror.driveKey,
      checkout: mirror.checkout,
      files: mirror.targets[target],
    },
  }
  if (evidencePath) writeNativeClosureEvidence(evidencePath, evidence)
  console.log(`[bare-kit] verified ${target} native closure (${expectedSourceNames.length} sources, ${expectedArchiveNames.length} prebuilt archives)`)
  return evidence
}

function validateNativeClosureSliceEvidence(document, expectedTarget, lock) {
  exactKeys(
    document,
    [
      'schemaVersion',
      'component',
      'upstreamCommit',
      'provenanceLockSHA256',
      'nativeClosureSHA256',
      'target',
      'sources',
      'prebuiltArchiveMirror',
    ],
    `native closure evidence ${expectedTarget}`,
  )
  if (document.schemaVersion !== 1
      || document.component !== 'BareKit native dependency closure'
      || document.upstreamCommit !== lock.upstream.commit
      || document.provenanceLockSHA256 !== sha256(join(toolDirectory, lockName))
      || document.nativeClosureSHA256 !== expectedNativeClosureSHA256
      || document.target !== expectedTarget
      || stableJSON(document.sources) !== stableJSON(lock.nativeClosure.sources)) {
    fail(`native closure evidence ${expectedTarget} does not match the reviewed provenance lock`)
  }
  exactKeys(
    document.prebuiltArchiveMirror,
    ['driveKey', 'checkout', 'files'],
    `native closure evidence ${expectedTarget} mirror`,
  )
  const mirror = lock.nativeClosure.prebuiltArchiveMirror
  if (document.prebuiltArchiveMirror.driveKey !== mirror.driveKey
      || document.prebuiltArchiveMirror.checkout !== mirror.checkout
      || stableJSON(document.prebuiltArchiveMirror.files) !== stableJSON(mirror.targets[expectedTarget])) {
    fail(`native closure evidence ${expectedTarget} has mismatched prebuilt archives`)
  }
  return document
}

function expectedAggregateEvidence(lock) {
  const mirror = lock.nativeClosure.prebuiltArchiveMirror
  return {
    schemaVersion: 1,
    component: 'BareKit native dependency closure',
    upstreamCommit: lock.upstream.commit,
    provenanceLockSHA256: sha256(join(toolDirectory, lockName)),
    nativeClosureSHA256: expectedNativeClosureSHA256,
    sources: lock.nativeClosure.sources,
    targets: Object.fromEntries(
      Object.keys(mirror.targets).sort().map(target => [target, {
        driveKey: mirror.driveKey,
        checkout: mirror.checkout,
        files: mirror.targets[target],
      }]),
    ),
  }
}

function validateAggregateEvidence(document, lock) {
  exactKeys(
    document,
    [
      'schemaVersion',
      'component',
      'upstreamCommit',
      'provenanceLockSHA256',
      'nativeClosureSHA256',
      'sources',
      'targets',
    ],
    'aggregate native closure evidence',
  )
  if (stableJSON(document) !== stableJSON(expectedAggregateEvidence(lock))) {
    fail('aggregate native closure evidence does not match the reviewed provenance lock')
  }
  return document
}

function aggregateNativeClosureEvidence(directoryPath, outputPath, lock) {
  const directory = requireDirectory(resolve(directoryPath), 'native closure slice evidence')
  const targets = Object.keys(lock.nativeClosure.prebuiltArchiveMirror.targets).sort()
  const expectedNames = targets.map(target => `${target}.json`)
  const actualNames = readdirSync(directory, { withFileTypes: true }).map(entry => entry.name).sort()
  if (JSON.stringify(actualNames) !== JSON.stringify(expectedNames)) {
    fail(`native closure evidence inventory differs: expected ${expectedNames.join(', ')}, got ${actualNames.join(', ')}`)
  }
  for (const target of targets) {
    validateNativeClosureSliceEvidence(
      readJSON(join(directory, `${target}.json`), `native closure evidence ${target}`),
      target,
      lock,
    )
  }

  const expectedOutput = join(toolDirectory, '.build', 'bare-kit-native-closure.json')
  const output = resolve(outputPath)
  if (output !== expectedOutput) fail(`aggregate evidence output must be exactly ${expectedOutput}`)
  if (existsSync(output)) {
    const metadata = lstatSync(output)
    if (metadata.isSymbolicLink() || !metadata.isFile()) {
      fail(`aggregate evidence output must be a regular, non-symlink file: ${output}`)
    }
  }
  writeFileSync(output, `${JSON.stringify(expectedAggregateEvidence(lock), null, 2)}\n`)
  console.log(`[bare-kit] aggregated ${targets.length} verified native closure slices: ${output}`)
}

function verifyAggregateEvidence(path, lock) {
  const document = readJSON(resolve(path), 'aggregate native closure evidence')
  validateAggregateEvidence(document, lock)
  console.log(`[bare-kit] verified aggregate native closure evidence: ${resolve(path)}`)
}

function parsePlist(path, label) {
  requireRegularFile(path, label)
  try {
    return JSON.parse(run('plutil', ['-convert', 'json', '-o', '-', path]))
  } catch (error) {
    fail(`${label} is invalid: ${error.message}`)
  }
}

function validateDistributableSanitizerAbsence(loadCommands, undefinedSymbols, kind) {
  if (loadCommands.includes('libclang_rt.tsan_') || undefinedSymbols.includes('__tsan_')) {
    fail(`${kind} distributable candidate unexpectedly contains Thread Sanitizer instrumentation`)
  }
}

function verifyArtifact(artifactPath, lock) {
  const artifact = requireDirectory(resolve(artifactPath), 'BareKit XCFramework')
  if (basename(artifact) !== 'BareKit.xcframework') fail('candidate must be named BareKit.xcframework')
  const info = parsePlist(join(artifact, 'Info.plist'), 'XCFramework Info.plist')
  if (info.XCFrameworkFormatVersion !== '1.0' || !Array.isArray(info.AvailableLibraries)) {
    fail('invalid XCFramework metadata')
  }
  const expected = [
    { kind: 'device', architectures: ['arm64'] },
    { kind: 'simulator', architectures: ['arm64', 'x86_64'] },
  ]
  const libraries = info.AvailableLibraries.map(library => ({
    raw: library,
    kind: library.SupportedPlatformVariant === 'simulator' ? 'simulator' : 'device',
    architectures: [...(library.SupportedArchitectures ?? [])].sort(),
  })).sort((left, right) => left.kind.localeCompare(right.kind))
  if (libraries.length !== 2
      || JSON.stringify(libraries.map(({ kind, architectures }) => ({ kind, architectures })))
        !== JSON.stringify(expected)) {
    fail('candidate must contain exactly arm64 device and arm64/x86_64 simulator slices')
  }

  const sliceEvidence = []
  for (const { raw: library, kind, architectures } of libraries) {
    if (library.SupportedPlatform !== 'ios'
        || (kind === 'device' && library.SupportedPlatformVariant !== undefined)) {
      fail(`invalid ${kind} platform metadata`)
    }
    const identifier = safeRelativePath(library.LibraryIdentifier, `${kind} LibraryIdentifier`)
    const libraryPath = safeRelativePath(library.LibraryPath, `${kind} LibraryPath`)
    const framework = pathInside(artifact, `${identifier}/${libraryPath}`, `${kind} framework`)
    requireDirectory(framework, `${kind} framework`)
    const header = join(framework, 'Headers', 'BareKit.h')
    const moduleMap = join(framework, 'Modules', 'module.modulemap')
    if (sha256(header) !== lock.patch.patchedInputs['apple/BareKit/BareKit.h']) {
      fail(`${kind} framework header is not the patched header`)
    }
    if (sha256(moduleMap) !== expectedModuleMapSHA256) fail(`${kind} framework module map changed`)
    const frameworkInfo = parsePlist(join(framework, 'Info.plist'), `${kind} framework Info.plist`)
    if (frameworkInfo.CFBundleIdentifier !== 'to.holepunch.bare.kit'
        || frameworkInfo.CFBundleShortVersionString !== lock.upstreamVersion
        || frameworkInfo.CFBundleVersion !== lock.upstreamVersion) {
      fail(`${kind} framework identity differs from BareKit ${lock.upstreamVersion}`)
    }
    const binaryRelative = safeRelativePath(library.BinaryPath ?? `${libraryPath}/BareKit`, `${kind} BinaryPath`)
    const binary = pathInside(artifact, `${identifier}/${binaryRelative}`, `${kind} binary`)
    requireRegularFile(binary, `${kind} binary`)
    const actualArchitectures = run('lipo', ['-archs', binary]).trim().split(/\s+/).sort()
    if (JSON.stringify(actualArchitectures) !== JSON.stringify(architectures)) {
      fail(`${kind} binary architectures differ: ${actualArchitectures.join(', ')}`)
    }
    const binaryHash = sha256(binary)
    if (expectedHistoricalR1Hashes.has(binaryHash)) fail(`${kind} binary is the unpatched historical r1 BareKit`)
    const symbols = run('nm', ['-gj', binary])
    if (!symbols.split('\n').includes('_BareKitQVACPatchLevel')) fail(`${kind} binary lacks the patch marker symbol`)
    const strings = run('strings', [binary])
    if (!strings.includes(expectedPatchMarker) || !strings.includes('readWithError:')) {
      fail(`${kind} binary lacks the checked-read patch markers`)
    }
    const loadCommands = run('otool', ['-L', binary])
    const undefinedSymbols = run('nm', ['-u', '-j', binary])
    validateDistributableSanitizerAbsence(loadCommands, undefinedSymbols, kind)
    sliceEvidence.push({ kind, architectures, sha256: binaryHash })
  }
  console.log(`[bare-kit] verified patched XCFramework: ${sliceEvidence.map(slice => `${slice.kind}=${slice.sha256}`).join(' ')}`)
  return sliceEvidence
}

function commandText(entry) {
  if (typeof entry?.command === 'string' && entry.command.length > 0
      && entry.arguments === undefined) {
    return entry.command.replaceAll('\\=', '=')
  }
  if (Array.isArray(entry?.arguments) && entry.arguments.length > 0
      && entry.arguments.every(argument => typeof argument === 'string')
      && entry.command === undefined) {
    return entry.arguments.join(' ')
  }
  fail('compile command must contain exactly one non-empty command or arguments representation')
}

function containsCommandToken(command, token) {
  return command.split(/\s+/).includes(token)
}

function validateThreadSanitizerCompileCommands(document, sourceRoot) {
  if (!Array.isArray(document) || document.length === 0) {
    fail('Thread Sanitizer compile_commands.json must be a non-empty array')
  }
  const root = resolve(sourceRoot)
  const compiledSources = []
  for (const [index, entry] of document.entries()) {
    if (typeof entry?.directory !== 'string' || entry.directory.length === 0
        || typeof entry?.file !== 'string' || entry.file.length === 0) {
      fail(`compile command ${index} has no directory or source file`)
    }
    const source = resolve(entry.directory, entry.file)
    const relativeSource = relative(root, source).split(sep).join('/')
    if (relativeSource === '' || relativeSource === '..' || relativeSource.startsWith('../')) {
      fail(`compile command ${index} source escaped the pinned checkout: ${entry.file}`)
    }
    if (!/\.(?:c|cc|cpp|cxx|m|mm)$/i.test(relativeSource)) continue

    const command = commandText(entry)
    if (!/(?:^|\s)(?:\S*\/)?clang(?:\+\+)?(?:\s|$)/.test(command)
        || !containsCommandToken(command, '-c')) {
      fail(`native compile evidence is not an actual Clang compilation: ${relativeSource}`)
    }
    if (containsCommandToken(command, '-fno-sanitize=thread')) {
      fail(`native compilation explicitly disabled Thread Sanitizer for ${relativeSource}`)
    }
    if (!containsCommandToken(command, '-fsanitize=thread')) {
      fail(`native compilation is not Thread Sanitizer-instrumented: ${relativeSource}`)
    }
    if (!/(?:^|[\s=])arm64-apple-ios\d+(?:\.\d+)*-simulator(?:\s|$)/.test(command)) {
      fail(`native compilation is not for the arm64 iOS Simulator: ${relativeSource}`)
    }
    compiledSources.push(relativeSource)
  }

  if (compiledSources.length === 0) fail('Thread Sanitizer build contains no C-family compilation units')
  for (const requiredSource of requiredThreadSanitizerSources) {
    if (!compiledSources.includes(requiredSource)) {
      fail(`Thread Sanitizer compile command inventory is missing ${requiredSource}`)
    }
  }
  const sortedSources = [...new Set(compiledSources)].sort((left, right) =>
    Buffer.compare(Buffer.from(left, 'utf8'), Buffer.from(right, 'utf8')))
  return {
    count: compiledSources.length,
    inventorySHA256: sha256Bytes(Buffer.from(`${sortedSources.join('\n')}\n`)),
    requiredSources: Object.fromEntries(requiredThreadSanitizerSources.map(source => [source, true])),
  }
}

function validateThreadSanitizerBinaryEvidence({ architectures, symbols, loadCommands, strings }) {
  if (architectures.trim() !== 'arm64') {
    fail(`Thread Sanitizer candidate must contain only arm64, got: ${architectures.trim()}`)
  }
  const symbolSet = new Set(symbols.split('\n').map(symbol => symbol.trim()).filter(Boolean))
  if (!symbolSet.has('___tsan_func_entry') || !symbolSet.has('___tsan_func_exit')) {
    fail('Thread Sanitizer candidate lacks function-entry/exit instrumentation symbols')
  }
  if (![...symbolSet].some(symbol => /^___tsan_(?:read|write)\d+$/.test(symbol))) {
    fail('Thread Sanitizer candidate lacks instrumented memory-access symbols')
  }
  const runtimePattern = new RegExp(
    `cmd LC_LOAD_DYLIB[\\s\\S]{0,256}name ${expectedThreadSanitizerRuntime.replaceAll('.', '\\.')}(?: |$)`,
  )
  if (!runtimePattern.test(loadCommands)) {
    fail(`Thread Sanitizer candidate lacks the ${expectedThreadSanitizerRuntime} load command`)
  }
  if (!strings.includes(expectedPatchMarker) || !strings.includes('readWithError:')) {
    fail('Thread Sanitizer candidate lacks the checked-read patch markers')
  }
  return {
    runtimeLoadCommand: expectedThreadSanitizerRuntime,
    sanitizerSymbols: [...symbolSet].filter(symbol => symbol.startsWith('___tsan_')).sort(),
  }
}

function writeThreadSanitizerEvidence(path, evidence) {
  const expectedOutput = join(toolDirectory, '.build', 'tsan', 'bare-kit-tsan-evidence.json')
  const output = resolve(path)
  if (output !== expectedOutput) {
    fail(`Thread Sanitizer evidence output must be exactly ${expectedOutput}`)
  }
  if (existsSync(output)) {
    const metadata = lstatSync(output)
    if (metadata.isSymbolicLink() || !metadata.isFile()) {
      fail(`Thread Sanitizer evidence output must be a regular, non-symlink file: ${output}`)
    }
  }
  writeFileSync(output, `${JSON.stringify(evidence, null, 2)}\n`)
}

function verifyThreadSanitizerArtifact(
  artifactPath,
  compileCommandsPath,
  sourceRootPath,
  evidencePath,
  lock,
) {
  const artifact = requireDirectory(resolve(artifactPath), 'BareKit Thread Sanitizer XCFramework')
  if (basename(artifact) !== 'BareKit.xcframework') {
    fail('Thread Sanitizer candidate must be named BareKit.xcframework')
  }
  const sourceRoot = requireDirectory(resolve(sourceRootPath), 'patched BareKit source checkout')
  verifySource(sourceRoot, 'patched', lock)

  const info = parsePlist(join(artifact, 'Info.plist'), 'Thread Sanitizer XCFramework Info.plist')
  if (info.XCFrameworkFormatVersion !== '1.0'
      || !Array.isArray(info.AvailableLibraries)
      || info.AvailableLibraries.length !== 1) {
    fail('Thread Sanitizer candidate must contain exactly one XCFramework library')
  }
  const library = info.AvailableLibraries[0]
  if (library.SupportedPlatform !== 'ios'
      || library.SupportedPlatformVariant !== 'simulator'
      || JSON.stringify(library.SupportedArchitectures) !== JSON.stringify(['arm64'])) {
    fail('Thread Sanitizer candidate must contain exactly one arm64 iOS Simulator slice')
  }

  const identifier = safeRelativePath(library.LibraryIdentifier, 'Thread Sanitizer LibraryIdentifier')
  const libraryPath = safeRelativePath(library.LibraryPath, 'Thread Sanitizer LibraryPath')
  const framework = pathInside(artifact, `${identifier}/${libraryPath}`, 'Thread Sanitizer framework')
  requireDirectory(framework, 'Thread Sanitizer framework')
  const header = join(framework, 'Headers', 'BareKit.h')
  const moduleMap = join(framework, 'Modules', 'module.modulemap')
  if (sha256(header) !== lock.patch.patchedInputs['apple/BareKit/BareKit.h']) {
    fail('Thread Sanitizer framework header is not the patched header')
  }
  if (sha256(moduleMap) !== expectedModuleMapSHA256) {
    fail('Thread Sanitizer framework module map changed')
  }
  const frameworkInfo = parsePlist(join(framework, 'Info.plist'), 'Thread Sanitizer framework Info.plist')
  if (frameworkInfo.CFBundleIdentifier !== 'to.holepunch.bare.kit'
      || frameworkInfo.CFBundleShortVersionString !== lock.upstreamVersion
      || frameworkInfo.CFBundleVersion !== lock.upstreamVersion) {
    fail(`Thread Sanitizer framework identity differs from BareKit ${lock.upstreamVersion}`)
  }

  const binaryRelative = safeRelativePath(
    library.BinaryPath ?? `${libraryPath}/BareKit`,
    'Thread Sanitizer BinaryPath',
  )
  const binary = pathInside(artifact, `${identifier}/${binaryRelative}`, 'Thread Sanitizer binary')
  requireRegularFile(binary, 'Thread Sanitizer binary')
  const binaryEvidence = validateThreadSanitizerBinaryEvidence({
    architectures: run('lipo', ['-archs', binary]),
    symbols: run('nm', ['-u', '-j', binary]),
    loadCommands: run('otool', ['-l', binary]),
    strings: run('strings', [binary]),
  })

  const compileCommandsFile = resolve(compileCommandsPath)
  const compileCommands = readJSON(compileCommandsFile, 'Thread Sanitizer compile commands')
  const compilationEvidence = validateThreadSanitizerCompileCommands(compileCommands, sourceRoot)
  const evidence = {
    schemaVersion: 1,
    component: 'BareKit native Thread Sanitizer simulator candidate',
    purpose: 'ci-test-only',
    distributable: false,
    upstreamCommit: lock.upstream.commit,
    patchSHA256: lock.patch.sha256,
    provenanceLockSHA256: sha256(join(toolDirectory, lockName)),
    nativeClosureSHA256: expectedNativeClosureSHA256,
    target: 'arm64-apple-ios-simulator',
    instrumentationScope: {
      sourceCompiledCFamilyUnits: true,
      prebuiltArchives: false,
      uninstrumentedPrebuiltArchives: Object.keys(
        lock.nativeClosure.prebuiltArchiveMirror.targets['ios-arm64-simulator'],
      ).sort(),
    },
    artifact: {
      binarySHA256: sha256(binary),
      architectures: ['arm64'],
      runtimeLoadCommand: binaryEvidence.runtimeLoadCommand,
      sanitizerSymbols: binaryEvidence.sanitizerSymbols,
    },
    compilation: {
      compileCommandsSHA256: sha256(compileCommandsFile),
      instrumentedUnitCount: compilationEvidence.count,
      instrumentedUnitInventorySHA256: compilationEvidence.inventorySHA256,
      requiredSources: compilationEvidence.requiredSources,
    },
  }
  if (evidencePath) writeThreadSanitizerEvidence(evidencePath, evidence)
  console.log(`[bare-kit] verified simulator-only native Thread Sanitizer candidate: binary=${evidence.artifact.binarySHA256} units=${evidence.compilation.instrumentedUnitCount}`)
  return evidence
}

function verifyToolchain(lock) {
  if (process.versions.node !== lock.buildToolchain.node) {
    fail(`Node ${process.versions.node} is active; expected ${lock.buildToolchain.node}`)
  }
  if (process.env.DEVELOPER_DIR !== lock.buildToolchain.developerDirectory) {
    fail(`DEVELOPER_DIR must be ${lock.buildToolchain.developerDirectory}`)
  }
  const xcodeVersion = run('xcodebuild', ['-version']).split('\n')[0]
  if (xcodeVersion !== `Xcode ${lock.buildToolchain.xcode}`) fail(`expected Xcode ${lock.buildToolchain.xcode}, got ${xcodeVersion}`)
  const bareMakePackage = readJSON(join(toolDirectory, 'node_modules', 'bare-make', 'package.json'), 'installed bare-make')
  if (bareMakePackage.version !== lock.buildToolchain.bareMake.version) {
    fail(`installed bare-make ${bareMakePackage.version} differs from the lock`)
  }
  run('npm', ['ls', '--all', '--prefix', toolDirectory], { stdio: 'pipe' })
  console.log(`[bare-kit] exact build toolchain Node ${process.versions.node} / ${xcodeVersion}`)
}

function expectFailure(action, pattern) {
  assert.throws(action, pattern)
}

function selfTest() {
  const lock = verifyRepository()
  const fixture = mkdtempSync(join(tmpdir(), 'qvac-bare-kit-verifier-'))
  try {
    for (const name of [lockName, lock.patch.file, 'package.json', 'package-lock.json']) {
      copyFileSync(join(toolDirectory, name), join(fixture, name))
    }
    assert.doesNotThrow(() => verifyRepository(fixture))
    appendFileSync(join(fixture, lock.patch.file), '\n# tampered\n')
    expectFailure(() => verifyRepository(fixture), /patch SHA-256 changed/)

    const hashFixture = join(fixture, 'hashes')
    mkdirSync(hashFixture)
    writeFileSync(join(hashFixture, 'input'), 'reviewed bytes\n')
    assert.doesNotThrow(() => verifyHashes(hashFixture, { input: sha256(join(hashFixture, 'input')) }, 'fixture'))
    writeFileSync(join(hashFixture, 'input'), 'changed bytes\n')
    expectFailure(() => verifyHashes(hashFixture, { input: '0'.repeat(64) }, 'fixture'), /SHA-256 mismatch/)

    const appleGitPatch = [
      'diff --git a/apple/BareKit/BareKit.m b/apple/BareKit/BareKit.m',
      'index 1111111..2222222 100644',
      '--- a/apple/BareKit/BareKit.m',
      '+++ b/apple/BareKit/BareKit.m',
      '@@ -10,2 +10,3 @@ - (void)poll:(int)events;',
      ' unchanged',
      '+reviewed',
      ' unchanged',
      '',
    ].join('\n')
    const upstreamGitPatch = appleGitPatch.replace(
      '@@ -10,2 +10,3 @@ - (void)poll:(int)events;',
      '@@ -10,2 +10,3 @@ bare_worklet__on_push(bare_worklet_t *worklet)',
    )
    assert.equal(
      canonicalPatchForComparison(appleGitPatch),
      canonicalPatchForComparison(upstreamGitPatch),
    )
    assert.notEqual(
      canonicalPatchForComparison(appleGitPatch),
      canonicalPatchForComparison(upstreamGitPatch.replace('-10,2', '-11,2')),
    )
    assert.notEqual(
      canonicalPatchForComparison(appleGitPatch),
      canonicalPatchForComparison(upstreamGitPatch.replace('+reviewed', '+different')),
    )
    for (const alteredMetadataPatch of [
      upstreamGitPatch.replace('2222222', '3333333'),
      upstreamGitPatch.replace('100644', '100755'),
      upstreamGitPatch.replace('b/apple/BareKit/BareKit.m', 'b/apple/BareKit/Other.m'),
    ]) {
      assert.notEqual(
        canonicalPatchForComparison(appleGitPatch),
        canonicalPatchForComparison(alteredMetadataPatch),
      )
    }

    const gitDiffFixture = join(fixture, 'git-diff')
    mkdirSync(gitDiffFixture)
    run('git', ['-C', gitDiffFixture, 'init', '--quiet'])
    writeFileSync(join(gitDiffFixture, 'blank.txt'), 'alpha\n\nomega\n')
    run('git', ['-C', gitDiffFixture, 'add', 'blank.txt'])
    run('git', [
      '-C', gitDiffFixture,
      '-c', 'user.name=QVAC verifier',
      '-c', 'user.email=verifier@invalid.example',
      'commit', '--quiet', '-m', 'fixture',
    ])
    writeFileSync(join(gitDiffFixture, 'blank.txt'), 'alpha\n\nreviewed\nomega\n')
    run('git', ['-C', gitDiffFixture, 'config', 'diff.suppressBlankEmpty', 'true'])
    assert.match(reviewedPatchDiff(gitDiffFixture, ['blank.txt']), /\n \n/)

    const badLock = structuredClone(lock)
    badLock.candidate.activationStatus = 'ready'
    expectFailure(() => validateLock(badLock), /must remain blocked/)
    const weakenedGate = structuredClone(lock)
    weakenedGate.candidate.activationRequirements[0] = 'Ship it.'
    expectFailure(() => validateLock(weakenedGate), /complete r2 activation gate/)
    const substitutedNativeSource = structuredClone(lock)
    substitutedNativeSource.nativeClosure.sources['github+holepunchto+libuv-src'] =
      substitutedNativeSource.nativeClosure.sources['github+libuv+libuv-src']
    delete substitutedNativeSource.nativeClosure.sources['github+libuv+libuv-src']
    expectFailure(() => validateLock(substitutedNativeSource), /native closure sources keys differ/)
    const changedPrebuiltArchive = structuredClone(lock)
    changedPrebuiltArchive.nativeClosure.prebuiltArchiveMirror.targets['ios-arm64']['libv8.a'] = '0'.repeat(64)
    expectFailure(() => validateLock(changedPrebuiltArchive), /native dependency closure differs/)
    const aggregateEvidence = expectedAggregateEvidence(lock)
    assert.doesNotThrow(() => validateAggregateEvidence(aggregateEvidence, lock))
    const alteredAggregateEvidence = structuredClone(aggregateEvidence)
    alteredAggregateEvidence.targets['ios-arm64'].files['libv8.a'] = '0'.repeat(64)
    expectFailure(
      () => validateAggregateEvidence(alteredAggregateEvidence, lock),
      /does not match the reviewed provenance lock/,
    )
    const substitutedPatch = structuredClone(lock)
    substitutedPatch.patch.sha256 = '0'.repeat(64)
    expectFailure(() => validateLock(substitutedPatch), /reviewed hardening patch/)
    const extraKey = structuredClone(lock)
    extraKey.unreviewed = true
    expectFailure(() => validateLock(extraKey), /keys differ/)
    writeFileSync(join(fixture, 'not-an-xcframework'), 'x')
    expectFailure(() => verifyArtifact(join(fixture, 'not-an-xcframework'), lock), /directory/)

    assert.doesNotThrow(() => validateDistributableSanitizerAbsence(
      '/usr/lib/libSystem.B.dylib\n',
      '_objc_msgSend\n',
      'simulator',
    ))
    expectFailure(
      () => validateDistributableSanitizerAbsence(
        '@rpath/libclang_rt.tsan_iossim_dynamic.dylib\n',
        '_objc_msgSend\n',
        'simulator',
      ),
      /distributable candidate unexpectedly contains Thread Sanitizer instrumentation/,
    )
    expectFailure(
      () => validateDistributableSanitizerAbsence(
        '/usr/lib/libSystem.B.dylib\n',
        '___tsan_func_entry\n',
        'device',
      ),
      /distributable candidate unexpectedly contains Thread Sanitizer instrumentation/,
    )

    const sourceRoot = join(fixture, 'source')
    const buildRoot = join(sourceRoot, 'build')
    const compileCommands = [
      {
        directory: buildRoot,
        file: join(sourceRoot, 'shared/posix/ipc.c'),
        command: `clang -target arm64-apple-ios14.0-simulator -fno-omit-frame-pointer -fsanitize=thread -c ${join(sourceRoot, 'shared/posix/ipc.c')}`,
      },
      {
        directory: buildRoot,
        file: join(sourceRoot, 'apple/BareKit/BareKit.m'),
        arguments: [
          'clang',
          '-target',
          'arm64-apple-ios14.0-simulator',
          '-fno-omit-frame-pointer',
          '-fsanitize=thread',
          '-c',
          join(sourceRoot, 'apple/BareKit/BareKit.m'),
        ],
      },
    ]
    assert.doesNotThrow(() => validateThreadSanitizerCompileCommands(compileCommands, sourceRoot))
    const unsanitizedObjectiveC = structuredClone(compileCommands)
    unsanitizedObjectiveC[1].arguments = unsanitizedObjectiveC[1].arguments
      .filter(argument => argument !== '-fsanitize=thread')
    expectFailure(
      () => validateThreadSanitizerCompileCommands(unsanitizedObjectiveC, sourceRoot),
      /not Thread Sanitizer-instrumented: apple\/BareKit\/BareKit\.m/,
    )
    const deviceTarget = structuredClone(compileCommands)
    deviceTarget[0].command = deviceTarget[0].command.replace('-simulator', '')
    expectFailure(
      () => validateThreadSanitizerCompileCommands(deviceTarget, sourceRoot),
      /not for the arm64 iOS Simulator/,
    )
    const disabledSanitizer = structuredClone(compileCommands)
    disabledSanitizer[0].command += ' -fno-sanitize=thread'
    expectFailure(
      () => validateThreadSanitizerCompileCommands(disabledSanitizer, sourceRoot),
      /explicitly disabled Thread Sanitizer/,
    )
    const missingPatchedUnit = compileCommands.slice(1)
    expectFailure(
      () => validateThreadSanitizerCompileCommands(missingPatchedUnit, sourceRoot),
      /missing shared\/posix\/ipc\.c/,
    )
    const nonCompilerEvidence = structuredClone(compileCommands)
    nonCompilerEvidence[0].command = nonCompilerEvidence[0].command.replace('clang ', 'echo ')
    expectFailure(
      () => validateThreadSanitizerCompileCommands(nonCompilerEvidence, sourceRoot),
      /not an actual Clang compilation/,
    )

    const binaryEvidence = {
      architectures: 'arm64\n',
      symbols: '___tsan_func_entry\n___tsan_func_exit\n___tsan_read8\n',
      loadCommands: `Load command 12\n          cmd LC_LOAD_DYLIB\n      cmdsize 80\n         name ${expectedThreadSanitizerRuntime} (offset 24)\n`,
      strings: `${expectedPatchMarker}\nreadWithError:\n`,
    }
    assert.doesNotThrow(() => validateThreadSanitizerBinaryEvidence(binaryEvidence))
    expectFailure(
      () => validateThreadSanitizerBinaryEvidence({
        ...binaryEvidence,
        symbols: binaryEvidence.symbols.replace('___tsan_read8\n', ''),
      }),
      /lacks instrumented memory-access symbols/,
    )
    expectFailure(
      () => validateThreadSanitizerBinaryEvidence({
        ...binaryEvidence,
        loadCommands: binaryEvidence.loadCommands.replace(expectedThreadSanitizerRuntime, '@rpath/not-tsan.dylib'),
      }),
      /lacks the @rpath\/libclang_rt\.tsan_iossim_dynamic\.dylib load command/,
    )
    expectFailure(
      () => validateThreadSanitizerBinaryEvidence({ ...binaryEvidence, architectures: 'arm64 x86_64\n' }),
      /must contain only arm64/,
    )
  } finally {
    rmSync(fixture, { recursive: true, force: true })
  }
  console.log('[bare-kit] verifier self-test passed (tamper, schema, closure, hash, portable hunk headings, activation, artifact shape, sanitizer isolation, native TSan compile invocations, symbols, and load-command rejection)')
}

function option(name) {
  const index = process.argv.indexOf(name)
  return index === -1 ? undefined : process.argv[index + 1]
}

const knownFlags = new Set([
  '--check',
  '--self-test',
  '--source',
  '--state',
  '--artifact',
  '--toolchain',
  '--native-closure',
  '--target',
  '--evidence',
  '--aggregate-evidence',
  '--output',
  '--verify-evidence',
  '--thread-sanitizer-artifact',
  '--compile-commands',
  '--source-root',
  '--tsan-evidence',
])
for (let index = 2; index < process.argv.length; index++) {
  const argument = process.argv[index]
  if (!knownFlags.has(argument)) fail(`unknown argument: ${argument}`)
  if ([
    '--source',
    '--state',
    '--artifact',
    '--native-closure',
    '--target',
    '--evidence',
    '--aggregate-evidence',
    '--output',
    '--verify-evidence',
    '--thread-sanitizer-artifact',
    '--compile-commands',
    '--source-root',
    '--tsan-evidence',
  ].includes(argument)) index++
}

if (process.argv.includes('--self-test')) {
  if (process.argv.length !== 3) fail('--self-test cannot be combined with other options')
  selfTest()
} else {
  const lock = verifyRepository()
  const source = option('--source')
  const state = option('--state')
  if ((source === undefined) !== (state === undefined)) fail('--source and --state must be provided together')
  if (source) verifySource(source, state, lock)
  const artifact = option('--artifact')
  if (artifact) verifyArtifact(artifact, lock)
  const nativeClosure = option('--native-closure')
  const target = option('--target')
  const evidence = option('--evidence')
  if ((nativeClosure === undefined) !== (target === undefined)) {
    fail('--native-closure and --target must be provided together')
  }
  if (evidence !== undefined && nativeClosure === undefined) {
    fail('--evidence requires --native-closure and --target')
  }
  if (nativeClosure) verifyNativeClosure(nativeClosure, target, lock, evidence)
  const evidenceDirectory = option('--aggregate-evidence')
  const output = option('--output')
  if ((evidenceDirectory === undefined) !== (output === undefined)) {
    fail('--aggregate-evidence and --output must be provided together')
  }
  if (evidenceDirectory) aggregateNativeClosureEvidence(evidenceDirectory, output, lock)
  const aggregateEvidence = option('--verify-evidence')
  if (aggregateEvidence) verifyAggregateEvidence(aggregateEvidence, lock)
  const threadSanitizerArtifact = option('--thread-sanitizer-artifact')
  const compileCommands = option('--compile-commands')
  const sourceRoot = option('--source-root')
  const threadSanitizerEvidence = option('--tsan-evidence')
  const threadSanitizerInputs = [threadSanitizerArtifact, compileCommands, sourceRoot]
  if (threadSanitizerInputs.some(value => value === undefined)
      && threadSanitizerInputs.some(value => value !== undefined)) {
    fail('--thread-sanitizer-artifact, --compile-commands, and --source-root must be provided together')
  }
  if (threadSanitizerEvidence !== undefined && threadSanitizerArtifact === undefined) {
    fail('--tsan-evidence requires --thread-sanitizer-artifact')
  }
  if (artifact && threadSanitizerArtifact) {
    fail('--artifact and --thread-sanitizer-artifact are mutually exclusive')
  }
  if (threadSanitizerArtifact) {
    verifyThreadSanitizerArtifact(
      threadSanitizerArtifact,
      compileCommands,
      sourceRoot,
      threadSanitizerEvidence,
      lock,
    )
  }
  if (process.argv.includes('--toolchain')) verifyToolchain(lock)
}
