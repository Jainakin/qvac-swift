#!/usr/bin/env node

import { execFileSync } from 'node:child_process'
import { copyFileSync, existsSync, lstatSync, mkdirSync, readFileSync, realpathSync, rmSync } from 'node:fs'
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from 'node:path'
import { fileURLToPath } from 'node:url'
import { verifyBundle } from './verify-bundle-provenance.mjs'
import { packageDeterministicXCFramework } from './zip-artifact.mjs'

const scriptDir = dirname(fileURLToPath(import.meta.url))
const repoRoot = resolve(scriptDir, '..', '..')
const frameworksDir = resolve(process.argv[2] ?? '')
const linkSetPath = resolve(process.argv[3] ?? '')
const bundlePath = resolve(process.argv[4] ?? '')
const outputDir = resolve(process.argv[5] ?? '')
if (!process.argv[2] || !process.argv[3] || !process.argv[4] || !process.argv[5]) {
  throw new Error('usage: package-artifacts.mjs <framework-dir> <link-set.json> <bundle> <output-dir>')
}
const generatedFrameworkRoot = resolve(repoRoot, 'tools/runtime/.build')
const expectedFrameworksDir = join(generatedFrameworkRoot, 'artifacts')
const noticesPath = join(repoRoot, 'THIRD_PARTY_NOTICES.md')
const noticeGeneratorPath = join(repoRoot, 'tools/release/generate-third-party-notices.mjs')
const allowedOutputRoots = [
  resolve(repoRoot, 'release-candidate'),
  generatedFrameworkRoot,
]

function isWithin(path, root) {
  const rel = relative(root, path)
  return rel !== '' && !isAbsolute(rel) && rel !== '..' && !rel.startsWith(`..${sep}`)
}

function overlaps(left, right) {
  return left === right || isWithin(left, right) || isWithin(right, left)
}

function assertExistingPathHasNoSymlinkComponents(path, ancestor, label) {
  const rel = relative(ancestor, path)
  if (rel === '..' || rel.startsWith(`..${sep}`)) {
    throw new Error(`[package-artifacts] ${label} escaped ${ancestor}`)
  }
  let cursor = ancestor
  for (const component of rel.split(sep).filter(Boolean)) {
    cursor = join(cursor, component)
    if (!existsSync(cursor)) throw new Error(`[package-artifacts] missing ${label}: ${cursor}`)
    const metadata = lstatSync(cursor)
    if (metadata.isSymbolicLink()) {
      throw new Error(`[package-artifacts] refusing symlink component in ${label}: ${cursor}`)
    }
  }
}

function ensureToolOwnedOutputRoot(root) {
  assertExistingPathHasNoSymlinkComponents(dirname(root), repoRoot, 'output-root parent')
  if (existsSync(root)) {
    const metadata = lstatSync(root)
    if (metadata.isSymbolicLink() || !metadata.isDirectory()) {
      throw new Error(`[package-artifacts] output root must be a real directory: ${root}`)
    }
  } else {
    mkdirSync(root)
  }
  return realpathSync(root)
}

// The zipper normalizes mtimes in place, so the mutable framework input must be
// exactly the real tool-generated artifacts directory. A lexical path below
// `.build` that traverses any symlink is rejected before reading or mutation.
if (frameworksDir !== expectedFrameworksDir) {
  throw new Error(`[package-artifacts] framework input must be exactly ${expectedFrameworksDir}`)
}
assertExistingPathHasNoSymlinkComponents(expectedFrameworksDir, repoRoot, 'framework input')
if (!lstatSync(expectedFrameworksDir).isDirectory()) {
  throw new Error('[package-artifacts] framework input is not a directory')
}
const generatedFrameworkRootCanonical = realpathSync(generatedFrameworkRoot)
const frameworksDirCanonical = realpathSync(expectedFrameworksDir)
if (dirname(frameworksDirCanonical) !== generatedFrameworkRootCanonical) {
  throw new Error('[package-artifacts] canonical framework input escaped the tool-owned build root')
}

// Destructive replacement is restricted to one path-safe direct child of a
// real tool-owned output root. This rules out `..`, symlink intermediates, the
// root itself, and broad ancestors before rmSync can execute.
const outputName = basename(outputDir)
const outputRoot = allowedOutputRoots.find(root => dirname(outputDir) === root)
if (!outputRoot || !/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(outputName)) {
  throw new Error('[package-artifacts] output must be a path-safe direct child of release-candidate/ or tools/runtime/.build/')
}
const outputRootCanonical = ensureToolOwnedOutputRoot(outputRoot)
if (existsSync(outputDir)) {
  const metadata = lstatSync(outputDir)
  if (metadata.isSymbolicLink() || !metadata.isDirectory()) {
    throw new Error(`[package-artifacts] refusing non-directory or symlink output: ${outputDir}`)
  }
}
const outputDirCanonical = join(outputRootCanonical, outputName)
if (existsSync(outputDir) && realpathSync(outputDir) !== outputDirCanonical) {
  throw new Error('[package-artifacts] canonical output escaped its tool-owned root')
}

const canonicalInputs = [
  ['framework input', frameworksDirCanonical],
  ['link-set input', realpathSync(linkSetPath)],
  ['bundle input', realpathSync(bundlePath)],
]

assertExistingPathHasNoSymlinkComponents(noticesPath, repoRoot, 'third-party notices input')
if (!lstatSync(noticesPath).isFile()) {
  throw new Error('[package-artifacts] THIRD_PARTY_NOTICES.md must be a regular file')
}
execFileSync(process.execPath, [noticeGeneratorPath, '--check'], { stdio: 'inherit' })
canonicalInputs.push(['third-party notices input', realpathSync(noticesPath)])
for (const [label, input] of canonicalInputs) {
  if (overlaps(outputDirCanonical, input)) {
    throw new Error(`[package-artifacts] output must not equal, contain, or be contained by ${label}`)
  }
}

const linkSetPathCanonical = canonicalInputs[1][1]
const bundlePathCanonical = canonicalInputs[2][1]
const noticesPathCanonical = canonicalInputs[3][1]
const linkSet = JSON.parse(readFileSync(linkSetPathCanonical, 'utf8'))
if (linkSet.mode !== 'link-set') throw new Error('[package-artifacts] input is not a link-set manifest')
if (!Array.isArray(linkSet.targets) || linkSet.targets.length === 0 || new Set(linkSet.targets).size !== linkSet.targets.length) {
  throw new Error('[package-artifacts] link set must contain unique targets')
}
if (!Number.isSafeInteger(linkSet.stagedTargetCount)
    || !Array.isArray(linkSet.excludedUnreferencedTargets)
    || new Set(linkSet.excludedUnreferencedTargets).size !== linkSet.excludedUnreferencedTargets.length
    || linkSet.stagedTargetCount !== linkSet.targets.length + linkSet.excludedUnreferencedTargets.length
    || linkSet.excludedUnreferencedTargets.some(target => linkSet.targets.includes(target)
      || !/^[A-Za-z0-9._@-]+$/.test(target))) {
  throw new Error('[package-artifacts] link-set staged/excluded closure evidence is inconsistent')
}
const bundle = verifyBundle(bundlePathCanonical)
if (linkSet.bundle?.sha256 !== bundle.sha256) {
  throw new Error('[package-artifacts] link set does not belong to this worker bundle')
}

rmSync(outputDirCanonical, { recursive: true, force: true })
mkdirSync(outputDirCanonical, { recursive: true })
for (const target of linkSet.targets) {
  if (!/^[A-Za-z0-9._@-]+$/.test(target)) throw new Error(`[package-artifacts] unsafe target: ${target}`)
  const rootName = `${target}.xcframework`
  const source = join(frameworksDirCanonical, rootName)
  if (!existsSync(source)) throw new Error(`[package-artifacts] missing ${source}`)
  const asset = join(outputDirCanonical, `${rootName}.zip`)
  packageDeterministicXCFramework({ frameworksDir: frameworksDirCanonical, target, asset })
}

copyFileSync(bundlePathCanonical, join(outputDirCanonical, 'worker.mobile.bundle'))
copyFileSync(noticesPathCanonical, join(outputDirCanonical, 'THIRD_PARTY_NOTICES.md'))
copyFileSync(join(repoRoot, 'tools/runtime/resolution-inventory.json'), join(outputDirCanonical, 'runtime-resolution-inventory.json'))
copyFileSync(join(repoRoot, 'tools/provenance/qvac-sdk.lock.json'), join(outputDirCanonical, 'qvac-sdk-provenance.json'))
console.log(`[package-artifacts] staged ${linkSet.targets.length} deterministic archives + notices/provenance in ${outputDirCanonical}`)
