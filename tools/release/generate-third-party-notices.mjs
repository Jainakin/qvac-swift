#!/usr/bin/env node

import { createHash } from 'node:crypto'
import {
  closeSync,
  constants,
  existsSync,
  fstatSync,
  lstatSync,
  mkdtempSync,
  mkdirSync,
  openSync,
  readFileSync,
  readdirSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs'
import { dirname, join, relative, resolve, sep } from 'node:path'
import { tmpdir } from 'node:os'
import { fileURLToPath } from 'node:url'
import { verifyBundle } from './verify-bundle-provenance.mjs'

const scriptDirectory = dirname(fileURLToPath(import.meta.url))
const repositoryRoot = resolve(scriptDirectory, '../..')
const runtimeRoot = resolve(repositoryRoot, 'tools/runtime')
const bundlePath = resolve(repositoryRoot, 'Sources/QVACClient/Resources/worker.mobile.bundle')
const inventoryPath = resolve(runtimeRoot, 'resolution-inventory.json')
const packageLockPath = resolve(runtimeRoot, 'package-lock.json')
const outputPath = resolve(repositoryRoot, 'THIRD_PARTY_NOTICES.md')
const supplementsManifestPath = resolve(scriptDirectory, 'license-supplements.json')
const supplementsRoot = resolve(scriptDirectory, 'license-supplements')
const maximumNoticeBytes = 1024 * 1024
// BareKit is linked into every iOS artifact closure but is not embedded in the
// portable worker bundle. Keep the non-worker native roots explicit so a new
// release cannot silently omit their attribution.
const additionalNativePackagePaths = [
  'node_modules/react-native-bare-kit/package.json',
]

function fail(message) {
  throw new Error(`[third-party-notices] ${message}`)
}

function sha256(value) {
  return createHash('sha256').update(value).digest('hex')
}

function artifactKey(resolved, integrity) {
  return `${resolved}\n${integrity}`
}

function normalizedText(path) {
  const stat = lstatSync(path)
  if (stat.isSymbolicLink() || !stat.isFile()) fail(`notice input must be a regular non-symlink file: ${path}`)
  if (stat.size <= 0 || stat.size > maximumNoticeBytes) fail(`notice input has invalid size: ${path}`)
  const bytes = readFileSync(path)
  const text = bytes.toString('utf8')
  if (Buffer.from(text, 'utf8').compare(bytes) !== 0 || text.includes('\u0000')) {
    fail(`notice input is not canonical UTF-8 text: ${path}`)
  }
  return text.replace(/\r\n?/g, '\n').replace(/[ \t]+$/gm, '').trim() + '\n'
}

function plainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

function assertExactKeys(value, expected, label) {
  if (!plainObject(value)) fail(`${label} must be an object`)
  const actual = Object.keys(value).sort()
  const wanted = [...expected].sort()
  if (actual.length !== wanted.length || actual.some((key, index) => key !== wanted[index])) {
    fail(`${label} has unexpected fields: expected ${wanted.join(', ')}, got ${actual.join(', ')}`)
  }
}

function requireString(value, label) {
  if (typeof value !== 'string' || value.trim() !== value || value.length === 0) {
    fail(`${label} must be a non-empty, trimmed string`)
  }
  return value
}

function assertNoSymlinkComponents(path, root, label) {
  const rel = relative(root, path)
  if (rel === '..' || rel.startsWith(`..${sep}`) || rel === '') {
    fail(`${label} escaped its expected root: ${path}`)
  }
  let cursor = root
  for (const component of rel.split(sep)) {
    cursor = join(cursor, component)
    if (!existsSync(cursor)) fail(`missing ${label}: ${cursor}`)
    if (lstatSync(cursor).isSymbolicLink()) fail(`${label} contains a symlink component: ${cursor}`)
  }
}

function loadLicenseSupplements(
  manifestPath = supplementsManifestPath,
  textRoot = supplementsRoot,
) {
  const rootStat = lstatSync(textRoot)
  if (rootStat.isSymbolicLink() || !rootStat.isDirectory()) {
    fail(`license supplement root must be a regular non-symlink directory: ${textRoot}`)
  }
  const manifestStat = lstatSync(manifestPath)
  if (manifestStat.isSymbolicLink() || !manifestStat.isFile()) {
    fail(`license supplement manifest must be a regular non-symlink file: ${manifestPath}`)
  }
  if (manifestStat.size <= 0 || manifestStat.size > maximumNoticeBytes) {
    fail(`license supplement manifest has invalid size: ${manifestPath}`)
  }

  let manifest
  try { manifest = JSON.parse(normalizedText(manifestPath)) } catch (error) {
    fail(`license supplement manifest is invalid JSON: ${error.message}`)
  }
  assertExactKeys(manifest, ['schemaVersion', 'reviewStatus', 'supplements'], 'license supplement manifest')
  if (manifest.schemaVersion !== 1) fail('unsupported license supplement schema version')
  if (manifest.reviewStatus !== 'maintainer-review-required') {
    fail('license supplement manifest must remain maintainer-review-required')
  }
  if (!Array.isArray(manifest.supplements)) fail('license supplement manifest supplements must be an array')

  const supplements = new Map()
  for (const [index, supplement] of manifest.supplements.entries()) {
    const label = `license supplement ${index}`
    assertExactKeys(
      supplement,
      ['identity', 'declaredLicense', 'packageArtifact', 'text', 'evidence'],
      label,
    )
    const identity = requireString(supplement.identity, `${label}.identity`)
    const declaredLicense = requireString(supplement.declaredLicense, `${label}.declaredLicense`)
    if (identity.lastIndexOf('@') <= 0) fail(`${label}.identity is not a package identity`)
    if (supplements.has(identity)) fail(`duplicate license supplement for ${identity}`)

    assertExactKeys(supplement.packageArtifact, ['resolved', 'integrity'], `${label}.packageArtifact`)
    const resolved = requireString(supplement.packageArtifact.resolved, `${label}.packageArtifact.resolved`)
    const integrity = requireString(supplement.packageArtifact.integrity, `${label}.packageArtifact.integrity`)
    if (!/^https:\/\/registry\.npmjs\.org\/.+\.tgz$/.test(resolved)) {
      fail(`${label}.packageArtifact.resolved is not an immutable npm artifact URL`)
    }
    if (!/^sha512-[A-Za-z0-9+/]+={0,2}$/.test(integrity)) {
      fail(`${label}.packageArtifact.integrity is not a SHA-512 SRI value`)
    }

    assertExactKeys(supplement.text, ['file', 'sha256'], `${label}.text`)
    const filename = requireString(supplement.text.file, `${label}.text.file`)
    const expectedHash = requireString(supplement.text.sha256, `${label}.text.sha256`)
    if (!/^[A-Za-z0-9][A-Za-z0-9._-]*\.txt$/.test(filename)) {
      fail(`${label}.text.file must be a direct .txt child of the supplement directory`)
    }
    if (!/^[0-9a-f]{64}$/.test(expectedHash)) fail(`${label}.text.sha256 is not lowercase SHA-256`)
    const textPath = resolve(textRoot, filename)
    if (dirname(textPath) !== textRoot) fail(`${label}.text.file escaped the supplement directory`)
    assertNoSymlinkComponents(textPath, textRoot, 'license supplement text')
    const text = normalizedText(textPath)
    if (readFileSync(textPath, 'utf8') !== text) {
      fail(`${label}.text.file must already be canonical UTF-8 with LF endings and one final newline`)
    }
    const actualHash = sha256(text)
    if (actualHash !== expectedHash) {
      fail(`${label}.text.sha256 mismatch: expected ${expectedHash}, got ${actualHash}`)
    }

    assertExactKeys(
      supplement.evidence,
      ['kind', 'repository', 'publishedGitHead', 'evidenceRevision', 'note'],
      `${label}.evidence`,
    )
    const kind = requireString(supplement.evidence.kind, `${label}.evidence.kind`)
    if (!['historical-upstream-license', 'spdx-and-repository-authorship'].includes(kind)) {
      fail(`${label}.evidence.kind is unsupported`)
    }
    const repository = requireString(supplement.evidence.repository, `${label}.evidence.repository`)
    if (!/^https:\/\/github\.com\/[^/]+\/[^/]+$/.test(repository)) {
      fail(`${label}.evidence.repository must be a canonical HTTPS GitHub repository URL`)
    }
    const publishedGitHead = requireString(
      supplement.evidence.publishedGitHead,
      `${label}.evidence.publishedGitHead`,
    )
    const evidenceRevision = requireString(
      supplement.evidence.evidenceRevision,
      `${label}.evidence.evidenceRevision`,
    )
    if (!/^[0-9a-f]{40}$/.test(publishedGitHead) || !/^[0-9a-f]{40}$/.test(evidenceRevision)) {
      fail(`${label}.evidence revisions must be lowercase 40-character Git commits`)
    }
    const note = requireString(supplement.evidence.note, `${label}.evidence.note`)
    if (note.length < 80) fail(`${label}.evidence.note is too short to be auditable`)

    supplements.set(identity, {
      identity,
      declaredLicense,
      packageArtifact: { resolved, integrity },
      text: { filename, hash: actualHash, value: text },
      evidence: { kind, repository, publishedGitHead, evidenceRevision, note },
    })
  }
  return supplements
}

function readBundlePackages(path) {
  const bytes = readFileSync(path)
  const firstNewline = bytes.indexOf(0x0a)
  const secondNewline = bytes.indexOf(0x0a, firstNewline + 1)
  if (firstNewline < 1 || secondNewline < 0) fail('worker bundle has invalid header framing')
  let header
  try { header = JSON.parse(bytes.subarray(firstNewline + 1, secondNewline).toString('utf8')) } catch (error) {
    fail(`worker bundle header is invalid: ${error.message}`)
  }
  const bodyOffset = secondNewline + 1
  const packages = []
  for (const [embeddedPath, file] of Object.entries(header.files ?? {})) {
    if (!embeddedPath.endsWith('/package.json') || embeddedPath === '/../../package.json') continue
    if (!Number.isSafeInteger(file.offset) || !Number.isSafeInteger(file.length)
        || file.offset < 0 || file.length <= 0 || bodyOffset + file.offset + file.length > bytes.length) {
      fail(`embedded package metadata has invalid range: ${embeddedPath}`)
    }
    let metadata
    try {
      metadata = JSON.parse(bytes.subarray(
        bodyOffset + file.offset,
        bodyOffset + file.offset + file.length,
      ).toString('utf8'))
    } catch (error) {
      fail(`embedded package metadata is invalid (${embeddedPath}): ${error.message}`)
    }
    // Zod includes export-subpath package.json files without package identity.
    // Their parent zod package is independently included and attributed.
    if (metadata.name === undefined && metadata.version === undefined && metadata.license === undefined) continue
    if (typeof metadata.name !== 'string' || typeof metadata.version !== 'string'
        || typeof metadata.license !== 'string' || metadata.license.length === 0) {
      fail(`embedded package lacks name/version/license metadata: ${embeddedPath}`)
    }
    const prefix = '/../../'
    if (!embeddedPath.startsWith(prefix)) fail(`unexpected embedded package path: ${embeddedPath}`)
    const relativePackagePath = embeddedPath.slice(prefix.length)
    if (!relativePackagePath.startsWith('node_modules/') || relativePackagePath.includes('..')
        || relativePackagePath.includes('\\')) {
      fail(`unsafe embedded package path: ${embeddedPath}`)
    }
    packages.push({ embeddedPath, relativePackagePath, metadata })
  }
  return packages
}

function packageSource(metadata) {
  const repository = typeof metadata.repository === 'string'
    ? metadata.repository
    : metadata.repository?.url
  return metadata.homepage ?? repository ?? ''
}

function authorText(author) {
  if (typeof author === 'string') return author
  if (author && typeof author === 'object') {
    return [author.name, author.email && `<${author.email}>`, author.url]
      .filter(Boolean).join(' ')
  }
  return ''
}

function sorted(values) {
  return [...values].sort((left, right) => left < right ? -1 : left > right ? 1 : 0)
}

function markdownCell(value) {
  return String(value ?? '').replaceAll('|', '\\|').replaceAll('\n', ' ')
}

function indented(text) {
  return text.trimEnd().split('\n').map(line => line.length === 0 ? '' : `    ${line}`).join('\n')
}

function writeOutputSafely(path, contents) {
  let descriptor
  try {
    descriptor = openSync(
      path,
      constants.O_WRONLY | constants.O_CREAT | constants.O_TRUNC | constants.O_NOFOLLOW,
      0o644,
    )
  } catch (error) {
    fail(`refusing unsafe notices output ${path}: ${error.message}`)
  }
  try {
    if (!fstatSync(descriptor).isFile()) fail(`notices output is not a regular file: ${path}`)
    writeFileSync(descriptor, contents, 'utf8')
  } finally {
    closeSync(descriptor)
  }
}

function selfTestOutputSafety() {
  const directory = mkdtempSync(join(tmpdir(), 'qvac-notices-safety-'))
  try {
    const victim = join(directory, 'victim')
    const output = join(directory, 'THIRD_PARTY_NOTICES.md')
    writeFileSync(victim, 'must-survive\n')
    symlinkSync(victim, output)
    let rejected = false
    try { writeOutputSafely(output, 'overwrite\n') } catch { rejected = true }
    if (!rejected || readFileSync(victim, 'utf8') !== 'must-survive\n') {
      fail('symlink-output self-test did not reject the write and preserve its target')
    }
    console.log('[third-party-notices-test] symlink output rejected and victim preserved')

    const fixtureRoot = join(directory, 'license-supplements')
    const fixtureManifestPath = join(directory, 'license-supplements.json')
    const fixtureTextPath = join(fixtureRoot, 'fixture-MIT.txt')
    const fixtureText = 'fixture license text\n'
    mkdirSync(fixtureRoot)
    const fixture = {
      schemaVersion: 1,
      reviewStatus: 'maintainer-review-required',
      supplements: [{
        identity: 'fixture@1.0.0',
        declaredLicense: 'MIT',
        packageArtifact: {
          resolved: 'https://registry.npmjs.org/fixture/-/fixture-1.0.0.tgz',
          integrity: `sha512-${'A'.repeat(86)}==`,
        },
        text: {
          file: 'fixture-MIT.txt',
          sha256: sha256(fixtureText),
        },
        evidence: {
          kind: 'spdx-and-repository-authorship',
          repository: 'https://github.com/example/fixture',
          publishedGitHead: '1'.repeat(40),
          evidenceRevision: '2'.repeat(40),
          note: 'Fixture evidence note is intentionally long enough to exercise strict supplement manifest validation safely.',
        },
      }],
    }
    writeFileSync(fixtureManifestPath, `${JSON.stringify(fixture)}\n`)
    symlinkSync(victim, fixtureTextPath)
    rejected = false
    try { loadLicenseSupplements(fixtureManifestPath, fixtureRoot) } catch { rejected = true }
    if (!rejected || readFileSync(victim, 'utf8') !== 'must-survive\n') {
      fail('symlink supplement self-test did not reject the input and preserve its target')
    }
    rmSync(fixtureTextPath)
    writeFileSync(fixtureTextPath, fixtureText)
    fixture.supplements[0].text.sha256 = '0'.repeat(64)
    writeFileSync(fixtureManifestPath, `${JSON.stringify(fixture)}\n`)
    rejected = false
    try { loadLicenseSupplements(fixtureManifestPath, fixtureRoot) } catch { rejected = true }
    if (!rejected) fail('supplement hash self-test accepted modified text')
    fixture.supplements[0].text.sha256 = sha256(fixtureText)
    writeFileSync(fixtureManifestPath, `${JSON.stringify(fixture)}\n`)
    if (loadLicenseSupplements(fixtureManifestPath, fixtureRoot).size !== 1) {
      fail('valid supplement self-test did not load exactly one entry')
    }
    console.log('[third-party-notices-test] supplements reject symlinks/hash drift and accept exact input')
  } finally {
    rmSync(directory, { recursive: true, force: true })
  }
}

function collectNotices() {
  verifyBundle(bundlePath)
  const inventory = JSON.parse(readFileSync(inventoryPath, 'utf8'))
  const packageLock = JSON.parse(readFileSync(packageLockPath, 'utf8'))
  const supplements = loadLicenseSupplements()
  const inventoryByPath = new Map((inventory.packages ?? []).map(entry => [entry.path, entry]))
  const identities = new Map()
  const textGroups = new Map()
  const packagePayloads = readBundlePackages(bundlePath)

  for (const relativePackagePath of additionalNativePackagePaths) {
    const packageJsonPath = resolve(runtimeRoot, relativePackagePath)
    const rel = relative(runtimeRoot, packageJsonPath)
    if (rel === '..' || rel.startsWith(`..${sep}`) || rel !== relativePackagePath) {
      fail(`unsafe native-closure package path: ${relativePackagePath}`)
    }
    if (!existsSync(packageJsonPath)) {
      fail(`native-closure package metadata is missing: ${relativePackagePath}`)
    }
    const metadata = JSON.parse(readFileSync(packageJsonPath, 'utf8'))
    if (typeof metadata.name !== 'string' || typeof metadata.version !== 'string'
        || typeof metadata.license !== 'string' || metadata.license.length === 0) {
      fail(`native-closure package lacks name/version/license metadata: ${relativePackagePath}`)
    }
    packagePayloads.push({
      embeddedPath: `[native closure]/${relativePackagePath}`,
      relativePackagePath,
      metadata,
    })
  }

  for (const embedded of packagePayloads) {
    const packageJsonPath = resolve(runtimeRoot, embedded.relativePackagePath)
    const packageDirectory = dirname(packageJsonPath)
    const rel = relative(runtimeRoot, packageJsonPath)
    if (rel === '..' || rel.startsWith(`..${sep}`) || !existsSync(packageJsonPath)) {
      fail(`installed package metadata is missing or escaped runtime root: ${embedded.relativePackagePath}`)
    }
    assertNoSymlinkComponents(packageJsonPath, runtimeRoot, 'installed package metadata')
    const packageStat = lstatSync(packageJsonPath)
    if (packageStat.isSymbolicLink() || !packageStat.isFile()) fail(`package metadata is not a regular file: ${packageJsonPath}`)
    const installed = JSON.parse(readFileSync(packageJsonPath, 'utf8'))
    for (const field of ['name', 'version', 'license']) {
      if (installed[field] !== embedded.metadata[field]) {
        fail(`${embedded.relativePackagePath} ${field} differs between worker and exact runtime`)
      }
    }

    const packagePath = dirname(embedded.relativePackagePath)
    const locked = inventoryByPath.get(packagePath)
      ?? packageLock.packages?.[packagePath]
      ?? (inventory.packages ?? []).find(entry => entry.name === installed.name && entry.version === installed.version)
    if (locked?.version !== installed.version || !locked?.resolved || !locked?.integrity) {
      fail(`runtime lock lacks immutable source for ${installed.name}@${installed.version}`)
    }

    const identity = `${installed.name}@${installed.version}`
    const entry = identities.get(identity) ?? {
      name: installed.name,
      version: installed.version,
      license: installed.license,
      author: authorText(installed.author),
      source: packageSource(installed),
      resolved: new Set(),
      paths: new Set(),
      licenseHashes: new Set(),
      noticeHashes: new Set(),
      artifacts: new Set(),
      supplement: undefined,
    }
    if (entry.license !== installed.license) fail(`conflicting license expressions for ${identity}`)
    entry.resolved.add(locked.resolved)
    entry.artifacts.add(artifactKey(locked.resolved, locked.integrity))
    entry.paths.add(packagePath)

    for (const filename of readdirSync(packageDirectory)) {
      const kind = /^(licen[cs]e|copying)(\.|$)/i.test(filename)
        ? 'license'
        : /^notice(\.|$)/i.test(filename) ? 'notice' : undefined
      if (!kind) continue
      const path = join(packageDirectory, filename)
      const text = normalizedText(path)
      const hash = sha256(text)
      const group = textGroups.get(hash) ?? { hash, kind, text, packages: new Set() }
      if (group.kind !== kind || group.text !== text) fail(`notice hash collision for ${identity}/${filename}`)
      group.packages.add(identity)
      textGroups.set(hash, group)
      entry[kind === 'license' ? 'licenseHashes' : 'noticeHashes'].add(hash)
    }
    identities.set(identity, entry)
  }

  const unusedSupplements = new Set(supplements.keys())
  for (const [identity, entry] of identities) {
    const supplement = supplements.get(identity)
    if (!supplement) continue
    unusedSupplements.delete(identity)
    if (entry.license !== supplement.declaredLicense) {
      fail(`license supplement expression differs from exact package metadata for ${identity}`)
    }
    if (!entry.artifacts.has(artifactKey(
      supplement.packageArtifact.resolved,
      supplement.packageArtifact.integrity,
    ))) {
      fail(`license supplement is not bound to the exact locked npm artifact for ${identity}`)
    }
    if (entry.licenseHashes.size !== 0) {
      fail(`license supplement for ${identity} is stale because the exact package now provides license text`)
    }
    entry.supplement = supplement
  }
  if (unusedSupplements.size !== 0) {
    fail(`license supplements do not map to shipped package identities: ${sorted(unusedSupplements).join(', ')}`)
  }

  const uncovered = [...identities.entries()]
    .filter(([, entry]) => entry.licenseHashes.size === 0 && entry.supplement === undefined)
    .map(([identity]) => identity)
  if (uncovered.length !== 0) {
    fail(`shipped packages remain without full license text: ${sorted(uncovered).join(', ')}`)
  }

  return {
    identities: sorted(identities.keys()).map(identity => [identity, identities.get(identity)]),
    textGroups: sorted(textGroups.keys()).map(hash => textGroups.get(hash)),
    supplements: sorted(supplements.keys()).map(identity => supplements.get(identity)),
  }
}

function render() {
  const { identities, textGroups, supplements } = collectNotices()
  const licenseCounts = new Map()
  for (const [, entry] of identities) licenseCounts.set(entry.license, (licenseCounts.get(entry.license) ?? 0) + 1)
  const packageTextCount = identities.filter(([, entry]) => entry.licenseHashes.size !== 0).length
  const supplementedCount = identities.filter(([, entry]) => entry.supplement !== undefined).length
  const lines = [
    '# Third-Party Notices',
    '',
    '> AUTO-GENERATED by `tools/release/generate-third-party-notices.mjs` from',
    '> the exact package metadata embedded in `worker.mobile.bundle`, the explicit',
    '> native artifact closure roots, the lock-verified runtime payload, and the',
    '> pinned supplement manifest in `tools/release/license-supplements.json`.',
    '> Do not edit this file by hand.',
    '',
    'QVACClient includes third-party software in its portable worker and native',
    'artifact closure. This inventory is intentionally conservative and attributes',
    'every named/versioned package embedded by the exact SDK 0.17 worker plus',
    'the additional native closure roots linked into the Swift package.',
    '',
    `Inventory: ${identities.length} unique package identities; ${packageTextCount} include one or more license-text payloads in the exact package; ${supplementedCount} omit a license file and are covered by pinned supplemental texts; 0 remain without full license text.`,
    '',
    'This generated record is engineering evidence, not legal advice. A maintainer',
    'must review the applicable terms—including native libraries and every',
    'supplement below—before setting `license_reviewed=true` and enabling binary',
    'publication.',
    '',
    '## License-expression summary',
    '',
    '| Expression | Packages |',
    '|---|---:|',
    ...sorted(licenseCounts.keys()).map(license => `| ${markdownCell(license)} | ${licenseCounts.get(license)} |`),
    '',
    '## Pinned supplemental license texts',
    '',
    'The exact npm artifacts below declare the shown SPDX license expression but',
    'publish no `LICENSE`, `LICENCE`, or `COPYING` file. The committed supplement',
    'manifest binds each text to the exact npm URL and SRI integrity, its evidence',
    'revisions, and the text SHA-256. These are engineering-prepared attribution',
    'supplements—not files represented as present in the npm tarballs—and require',
    'maintainer/legal review before publication.',
    '',
  ]

  if (supplements.length === 0) {
    lines.push('None.', '')
  } else {
    for (const supplement of supplements) {
      lines.push(
        `### ${supplement.identity} — ${supplement.declaredLicense}`,
        '',
        `Immutable npm artifact: ${supplement.packageArtifact.resolved}`,
        '',
        `Npm SRI: \`${supplement.packageArtifact.integrity}\``,
        '',
        `Supplement text SHA-256: \`${supplement.text.hash}\``,
        '',
        `Evidence basis: \`${supplement.evidence.kind}\``,
        '',
        `Repository: ${supplement.evidence.repository}`,
        '',
        `Published npm gitHead: \`${supplement.evidence.publishedGitHead}\``,
        '',
        `Evidence revision: \`${supplement.evidence.evidenceRevision}\``,
        '',
        `Evidence note: ${supplement.evidence.note}`,
        '',
        indented(supplement.text.value),
        '',
      )
    }
  }

  lines.push(
    '## Unresolved license-text gaps',
    '',
    'None. Generation fails if a shipped package has neither package-provided',
    'license text nor an exact-artifact-bound supplement, or if a supplement is',
    'stale, unused, mismatched, modified, or symlinked.',
    '',
    '## Package inventory',
    '',
    '| Package | Declared license | Immutable npm artifact |',
    '|---|---|---|',
    ...identities.map(([identity, entry]) =>
      `| ${markdownCell(identity)} | ${markdownCell(entry.license)} | ${markdownCell(sorted(entry.resolved).join('<br>'))} |`
    ),
    '',
    '## Included package-provided license and notice texts',
    '',
  )

  for (const group of textGroups) {
    lines.push(
      `### ${group.kind === 'license' ? 'License' : 'Notice'} \`${group.hash}\``,
      '',
      `Applies to: ${sorted(group.packages).map(identity => `\`${identity}\``).join(', ')}`,
      '',
      indented(group.text),
      '',
    )
  }
  return lines.join('\n').replace(/\n{3,}/g, '\n\n').trimEnd() + '\n'
}

const expected = render()
if (process.argv[2] === '--check') {
  if (!existsSync(outputPath)) fail('THIRD_PARTY_NOTICES.md is missing')
  const metadata = lstatSync(outputPath)
  if (metadata.isSymbolicLink() || !metadata.isFile()) {
    fail('THIRD_PARTY_NOTICES.md must be a regular non-symlink file')
  }
  if (readFileSync(outputPath, 'utf8') !== expected) {
    fail('THIRD_PARTY_NOTICES.md is missing or stale; regenerate with this script')
  }
  console.log('[third-party-notices] committed notices are fresh')
} else if (process.argv[2] === '--self-test') {
  selfTestOutputSafety()
} else if (process.argv.length === 2) {
  writeOutputSafely(outputPath, expected)
  console.log(`[third-party-notices] wrote exact embedded-package notices -> ${outputPath}`)
} else {
  fail('usage: generate-third-party-notices.mjs [--check|--self-test]')
}
