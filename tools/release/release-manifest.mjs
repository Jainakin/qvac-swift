import { createHash } from 'node:crypto'
import { readFileSync } from 'node:fs'

const targetPattern = /^[A-Za-z0-9._@-]+$/
const hashPattern = /^[0-9a-f]{64}$/
const commitPattern = /^[0-9a-f]{40}$/
const artifactTagPattern = /^artifacts-sdk-0\.17\.0-r[1-9][0-9]*$/
const authoritativeCommit = 'e8b440665a053a9efe852f04c3601da44f0d55d8'

function fail(message) {
  throw new Error(`[release-manifest] ${message}`)
}

export function sha256(path) {
  return createHash('sha256').update(readFileSync(path)).digest('hex')
}

export function validateReleaseManifest(manifest) {
  if (manifest?.schemaVersion !== 2 || manifest?.mode !== 'release') fail('expected schemaVersion 2 release manifest')
  if (!artifactTagPattern.test(manifest.artifactTag ?? '')) fail(`invalid artifactTag: ${manifest.artifactTag}`)
  if (!commitPattern.test(manifest.sourceCommit ?? '')) fail(`invalid sourceCommit: ${manifest.sourceCommit}`)
  if (manifest.sdk?.version !== '0.17.0') fail(`expected SDK 0.17.0, got ${manifest.sdk?.version}`)
  if (manifest.sdk?.sourceCommit !== authoritativeCommit) fail(`expected authoritative SDK commit ${authoritativeCommit}`)
  if (!/^sha512-[A-Za-z0-9+/]+={0,2}$/.test(manifest.sdk?.npmIntegrity ?? '')) fail('invalid npm SRI')
  if (!hashPattern.test(manifest.sdk?.runtimeInventorySHA256 ?? '')) fail('invalid runtime inventory SHA-256')

  const bundle = manifest.bundle
  if (bundle?.assetName !== 'worker.mobile.bundle') fail('unexpected worker bundle asset name')
  if (bundle?.embeddedSDKVersion !== '0.17.0') fail(`worker embeds SDK ${bundle?.embeddedSDKVersion ?? 'unknown'}, not 0.17.0`)
  if (!Number.isSafeInteger(bundle?.size) || bundle.size <= 0) fail('invalid worker size')
  if (!hashPattern.test(bundle?.sha256 ?? '')) fail('invalid worker SHA-256')
  if (typeof bundle?.bundleId !== 'string' || bundle.bundleId.length === 0) fail('invalid worker bundle ID')
  if (typeof bundle?.main !== 'string' || bundle.main.length === 0) fail('invalid worker main entry')
  if (!Array.isArray(bundle?.addonTargets) || bundle.addonTargets.length === 0) fail('worker addon target list is empty')
  if (new Set(bundle.addonTargets).size !== bundle.addonTargets.length) fail('duplicate worker addon targets')
  for (const target of bundle.addonTargets) if (!targetPattern.test(target)) fail(`unsafe worker addon target: ${target}`)

  if (!Array.isArray(manifest.artifacts) || manifest.artifacts.length === 0) fail('artifact inventory is empty')
  const targets = new Set()
  const assets = new Set()
  let expectedBase
  for (const artifact of manifest.artifacts) {
    if (!targetPattern.test(artifact?.target ?? '')) fail(`unsafe target: ${artifact?.target}`)
    if (targets.has(artifact.target)) fail(`duplicate target: ${artifact.target}`)
    targets.add(artifact.target)
    const expectedAsset = `${artifact.target}.xcframework.zip`
    if (artifact.assetName !== expectedAsset) fail(`target ${artifact.target} has mismatched asset ${artifact.assetName}`)
    if (assets.has(artifact.assetName)) fail(`duplicate asset: ${artifact.assetName}`)
    assets.add(artifact.assetName)
    if (!Number.isSafeInteger(artifact.size) || artifact.size <= 0) fail(`invalid size for ${artifact.assetName}`)
    if (!hashPattern.test(artifact.sha256 ?? '') || artifact.swiftChecksum !== artifact.sha256) {
      fail(`invalid or inconsistent checksum for ${artifact.assetName}`)
    }
    let url
    try { url = new URL(artifact.url) } catch { fail(`invalid URL for ${artifact.assetName}`) }
    if (url.protocol !== 'https:' || url.hostname !== 'github.com') fail(`artifact URL must use https://github.com: ${artifact.url}`)
    const suffix = `/releases/download/${manifest.artifactTag}/${artifact.assetName}`
    if (!url.pathname.endsWith(suffix)) fail(`artifact URL does not match immutable tag/name: ${artifact.url}`)
    const base = artifact.url.slice(0, -artifact.assetName.length)
    if (expectedBase === undefined) expectedBase = base
    if (base !== expectedBase) fail('all artifacts must share one immutable release URL base')
  }
  if (!targets.has('BareKit')) fail('release is missing BareKit')
  for (const addon of bundle.addonTargets) if (!targets.has(addon)) fail(`release is missing bundle addon ${addon}`)

  const expectedBundleURL = `${expectedBase}worker.mobile.bundle`
  if (bundle.url !== expectedBundleURL) fail(`worker URL must be ${expectedBundleURL}`)

  const notices = manifest.notices
  if (notices?.assetName !== 'THIRD_PARTY_NOTICES.md') fail('unexpected third-party notices asset name')
  if (!Number.isSafeInteger(notices?.size) || notices.size <= 0) fail('invalid third-party notices size')
  if (!hashPattern.test(notices?.sha256 ?? '')) fail('invalid third-party notices SHA-256')
  const expectedNoticesURL = `${expectedBase}THIRD_PARTY_NOTICES.md`
  if (notices.url !== expectedNoticesURL) fail(`third-party notices URL must be ${expectedNoticesURL}`)
  return manifest
}

export function loadReleaseManifest(path) {
  let manifest
  try { manifest = JSON.parse(readFileSync(path, 'utf8')) } catch (error) { fail(`cannot read ${path}: ${error.message}`) }
  return validateReleaseManifest(manifest)
}

// Bind an externally published artifact manifest to the exact Swift source
// commit being released. This check is intentionally separate from structural
// validation so candidate builds can be rendered before the final source commit
// exists, while publication and source tagging must require exact equality.
export function assertReleaseSourceCommit(manifest, expectedCommit) {
  if (!commitPattern.test(expectedCommit ?? '')) fail(`invalid expected source commit: ${expectedCommit}`)
  if (manifest?.sourceCommit !== expectedCommit) {
    fail(`artifact sourceCommit ${manifest?.sourceCommit ?? '<missing>'} does not match release commit ${expectedCommit}`)
  }
  return manifest
}

export function validateDevelopmentManifest(manifest) {
  if (manifest?.schemaVersion !== 2 || manifest?.mode !== 'development' || manifest?.releaseEligible !== false) {
    fail('expected schemaVersion 2 non-release development manifest')
  }
  if (manifest.sdk?.version !== '0.17.0' || manifest.sdk?.sourceCommit !== authoritativeCommit) {
    fail('development manifest must use the authoritative SDK 0.17.0 source')
  }
  if (manifest.frameworkRoot !== 'tools/runtime/.build/artifacts') {
    fail('development framework root must be the tool-owned exact-runtime output')
  }
  const bundle = manifest.bundle
  if (bundle?.path !== 'Sources/QVACClient/Resources/worker.mobile.bundle'
      || bundle?.embeddedSDKVersion !== '0.17.0'
      || !hashPattern.test(bundle?.sha256 ?? '')
      || !Number.isSafeInteger(bundle?.size) || bundle.size <= 0
      || typeof bundle?.bundleId !== 'string' || bundle.bundleId.length === 0
      || !Array.isArray(bundle?.addonTargets) || bundle.addonTargets.length === 0) {
    fail('development manifest has invalid exact-0.17 bundle provenance')
  }
  if (!Array.isArray(manifest.targets) || manifest.targets.length === 0
      || new Set(manifest.targets).size !== manifest.targets.length) {
    fail('development manifest target inventory must be non-empty and unique')
  }
  for (const target of manifest.targets) if (!targetPattern.test(target)) fail(`unsafe development target: ${target}`)
  if (!manifest.targets.includes('BareKit')) fail('development manifest is missing BareKit')
  for (const addon of bundle.addonTargets) {
    if (!manifest.targets.includes(addon)) fail(`development manifest is missing bundle addon ${addon}`)
  }
  const closure = manifest.nativeClosure
  if (!Number.isSafeInteger(closure?.stagedTargetCount)
      || closure?.linkedTargetCount !== manifest.targets.length
      || !Array.isArray(closure?.excludedUnreferencedTargets)
      || new Set(closure.excludedUnreferencedTargets).size !== closure.excludedUnreferencedTargets.length
      || closure.stagedTargetCount !== closure.linkedTargetCount + closure.excludedUnreferencedTargets.length
      || closure.excludedUnreferencedTargets.some(target => manifest.targets.includes(target)
        || !targetPattern.test(target))) {
    fail('development manifest has inconsistent staged/excluded native-closure evidence')
  }
  return manifest
}

function swiftString(value) {
  return JSON.stringify(value)
}

export function renderPackageManifest(manifest) {
  validateReleaseManifest(manifest)
  const artifactTargets = manifest.artifacts.map(artifact => `        .binaryTarget(
            name: ${swiftString(artifact.target)},
            url: ${swiftString(artifact.url)},
            checksum: ${swiftString(artifact.swiftChecksum)}
        ),`).join('\n')
  const dependencies = manifest.artifacts.map(artifact =>
    `                .target(name: ${swiftString(artifact.target)}, condition: .when(platforms: [.iOS])),`
  ).join('\n')

  return `// swift-tools-version:5.10
// QVAC Swift Client — URL-installable release manifest.
// Generated from an immutable artifact-manifest.json by the exact 0.17.0
// artifact pipeline. Do not edit URLs or checksums by hand.

import PackageDescription

let package = Package(
    name: "QVACClient",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "QVACClient", targets: ["QVACClient"]),
    ],
    targets: [
${artifactTargets}
        .target(
            name: "QVACClient",
            dependencies: [
${dependencies}
            ],
            path: "Sources/QVACClient",
            resources: [
                .copy("Resources/worker.mobile.bundle"),
            ]
        ),
        .testTarget(
            name: "QVACClientUnitTests",
            dependencies: ["QVACClient"],
            path: "Tests/QVACClientUnitTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "QVACClientIntegrationTests",
            dependencies: ["QVACClient"],
            path: "Tests/QVACClientIntegrationTests"
        ),
    ]
)
`
}

export function renderDevelopmentPackageManifest(manifest) {
  validateDevelopmentManifest(manifest)
  const artifactTargets = manifest.targets.map(target => `        .binaryTarget(
            name: ${swiftString(target)},
            path: ${swiftString(`${manifest.frameworkRoot}/${target}.xcframework`)}
        ),`).join('\n')
  const dependencies = manifest.targets.map(target =>
    `                .target(name: ${swiftString(target)}, condition: .when(platforms: [.iOS])),`
  ).join('\n')

  return `// swift-tools-version:5.10
// QVAC Swift Client — exact SDK 0.17.0 development manifest.
// Generated from tools/release/artifacts.development.json. Run
// tools/runtime/link-ios-artifacts.sh before local iOS builds. Release tags must
// use the URL manifest generated only after immutable artifacts are published.

import PackageDescription

let package = Package(
    name: "QVACClient",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "QVACClient", targets: ["QVACClient"]),
    ],
    targets: [
${artifactTargets}
        .target(
            name: "QVACClient",
            dependencies: [
${dependencies}
            ],
            path: "Sources/QVACClient",
            resources: [
                .copy("Resources/worker.mobile.bundle"),
            ]
        ),
        .testTarget(
            name: "QVACClientUnitTests",
            dependencies: ["QVACClient"],
            path: "Tests/QVACClientUnitTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "QVACClientIntegrationTests",
            dependencies: ["QVACClient"],
            path: "Tests/QVACClientIntegrationTests"
        ),
    ]
)
`
}
