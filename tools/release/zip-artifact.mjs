import { createHash } from 'node:crypto'
import { spawnSync } from 'node:child_process'
import {
  closeSync,
  lstatSync,
  mkdtempSync,
  openSync,
  readSync,
  readdirSync,
  rmSync,
  utimesSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'

const fixedTime = new Date('2000-01-01T00:00:00.000Z')
const zipPath = '/usr/bin/zip'
const unzipPath = '/usr/bin/unzip'
const hashBuffer = Buffer.allocUnsafe(1024 * 1024)
const deterministicEnvironment = {
  ...process.env,
  TZ: 'UTC',
  LC_ALL: 'C',
  LANG: 'C',
}

function fail(message) {
  throw new Error(`[zip-artifact] ${message}`)
}

function portablePermissions(metadata, label) {
  const permissions = metadata.mode & 0o7777
  if ((permissions & 0o7000) !== 0) {
    fail(`${label} contains setuid, setgid, or sticky permission bits`)
  }
  return permissions & 0o777
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

function validateRelativePath(path, label) {
  if (path.includes('\n') || path.includes('\r') || path.includes('\\')) {
    fail(`${label} contains a path unsupported by the line-oriented ZIP manifest: ${path}`)
  }
}

function snapshotTree(root, label) {
  const rootMetadata = lstatSync(root)
  if (rootMetadata.isSymbolicLink() || !rootMetadata.isDirectory()) {
    fail(`${label} root must be a real directory`)
  }
  const tree = [{
    path: '',
    type: 'directory',
    permissions: portablePermissions(rootMetadata, `${label} root`),
  }]

  function visit(directory, prefix) {
    for (const name of readdirSync(directory).sort()) {
      const path = join(directory, name)
      const relativePath = prefix ? `${prefix}/${name}` : name
      validateRelativePath(relativePath, label)
      const metadata = lstatSync(path)
      if (metadata.isSymbolicLink()) {
        fail(`symbolic links are forbidden in release artifacts: ${relativePath}`)
      }
      const permissions = portablePermissions(metadata, `${label} ${relativePath}`)
      if (metadata.isDirectory()) {
        tree.push({ path: relativePath, type: 'directory', permissions })
        visit(path, relativePath)
      } else if (metadata.isFile()) {
        tree.push({
          path: relativePath,
          type: 'file',
          permissions,
          byteCount: metadata.size,
          sha256: sha256File(path),
        })
      } else {
        fail(`${label} contains an unsupported filesystem entry: ${relativePath}`)
      }
    }
  }

  visit(root, '')
  return tree
}

function archivePaths(rootName, tree) {
  return tree.map(entry => entry.path ? `${rootName}/${entry.path}` : rootName).sort()
}

function inspectArchive(asset, rootName, expectedPaths) {
  const listing = spawnSync(unzipPath, ['-Z1', asset], {
    encoding: 'utf8',
    env: deterministicEnvironment,
  })
  if (listing.status !== 0) fail(`cannot inspect ${asset}: ${listing.stderr}`)
  const rawPaths = listing.stdout.split('\n').filter(Boolean)
  const archivedPaths = rawPaths.map(rawPath => {
    if (rawPath.startsWith('/') || rawPath.includes('\\')
        || rawPath.includes('\r') || rawPath.includes('\0')) {
      fail(`archive escaped ${rootName}: ${rawPath}`)
    }
    const normalized = rawPath.endsWith('/') ? rawPath.slice(0, -1) : rawPath
    const components = normalized.split('/')
    if (normalized.length === 0 || components.some(component =>
      component.length === 0 || component === '.' || component === '..')
      || (normalized !== rootName && !normalized.startsWith(`${rootName}/`))) {
      fail(`archive escaped ${rootName}: ${rawPath}`)
    }
    return normalized
  })
  if (new Set(archivedPaths).size !== archivedPaths.length) {
    fail(`archive contains duplicate paths for ${rootName}`)
  }
  const actual = [...archivedPaths].sort()
  if (JSON.stringify(actual) !== JSON.stringify(expectedPaths)) {
    const expectedSet = new Set(expectedPaths)
    const actualSet = new Set(actual)
    const missing = expectedPaths.find(path => !actualSet.has(path))
    const unexpected = actual.find(path => !expectedSet.has(path))
    fail(`archive path set differs for ${rootName}: ${missing ? `missing ${missing}` : `unexpected ${unexpected ?? '<unknown>'}`}`)
  }
}

function compareTrees(expected, actual, rootName) {
  if (JSON.stringify(expected) === JSON.stringify(actual)) return
  const expectedByPath = new Map(expected.map(entry => [entry.path, entry]))
  const actualByPath = new Map(actual.map(entry => [entry.path, entry]))
  const paths = [...new Set([...expectedByPath.keys(), ...actualByPath.keys()])].sort()
  const drift = paths.find(path =>
    JSON.stringify(expectedByPath.get(path)) !== JSON.stringify(actualByPath.get(path)))
  fail(`extracted archive differs from staged ${rootName} at ${drift || '<root>'}`)
}

function verifyArchive({ asset, rootName, expectedTree }) {
  const expectedPaths = archivePaths(rootName, expectedTree)
  inspectArchive(asset, rootName, expectedPaths)
  const extractionRoot = mkdtempSync(join(tmpdir(), 'qvac-archive-verification.'))
  try {
    const extraction = spawnSync(unzipPath, ['-qq', resolve(asset), '-d', extractionRoot], {
      encoding: 'utf8',
      env: deterministicEnvironment,
    })
    if (extraction.status !== 0) {
      fail(`cannot extract ${asset} for semantic verification: ${extraction.stderr}`)
    }
    const actualTree = snapshotTree(
      join(extractionRoot, rootName),
      `extracted ${rootName}`,
    )
    compareTrees(expectedTree, actualTree, rootName)
  } finally {
    rmSync(extractionRoot, { recursive: true, force: true })
  }
}

export function verifyPackagedXCFrameworkArchive({ frameworksDir, target, asset }) {
  if (!/^[A-Za-z0-9._@-]+$/.test(target)) fail(`unsafe target: ${target}`)
  const rootName = `${target}.xcframework`
  const expectedTree = snapshotTree(join(frameworksDir, rootName), `staged ${rootName}`)
  verifyArchive({ asset, rootName, expectedTree })
}

export function packageDeterministicXCFramework({ frameworksDir, target, asset }) {
  if (!/^[A-Za-z0-9._@-]+$/.test(target)) fail(`unsafe target: ${target}`)
  const rootName = `${target}.xcframework`
  const sourceRoot = join(frameworksDir, rootName)
  const expectedTree = snapshotTree(sourceRoot, `staged ${rootName}`)
  const paths = archivePaths(rootName, expectedTree)
  for (const relative of [...paths].reverse()) {
    utimesSync(join(frameworksDir, relative), fixedTime, fixedTime)
  }
  const zip = spawnSync(zipPath, ['-X', '-q', asset, '-@'], {
    cwd: frameworksDir,
    input: paths.join('\n') + '\n',
    encoding: 'utf8',
    env: deterministicEnvironment,
  })
  if (zip.status !== 0) fail(`zip failed for ${target}: ${zip.stderr}`)
  verifyArchive({ asset, rootName, expectedTree })
}
