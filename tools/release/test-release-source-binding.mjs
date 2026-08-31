#!/usr/bin/env node

import assert from 'node:assert/strict'
import {
  assertReleaseSourceCommit,
  validateReleaseManifest,
} from './release-manifest.mjs'

const releaseCommit = '0123456789abcdef0123456789abcdef01234567'
const otherCommit = '89abcdef0123456789abcdef0123456789abcdef'

assert.doesNotThrow(() => assertReleaseSourceCommit({ sourceCommit: releaseCommit }, releaseCommit))
assert.throws(
  () => assertReleaseSourceCommit({ sourceCommit: otherCommit }, releaseCommit),
  /does not match release commit/,
)
assert.throws(
  () => assertReleaseSourceCommit({ sourceCommit: releaseCommit }, 'main'),
  /invalid expected source commit/,
)

const hash = 'a'.repeat(64)
const artifactTag = 'artifacts-sdk-0.17.0-r1'
const releaseBase = `https://github.com/Jainakin/qvac-swift/releases/download/${artifactTag}/`
const artifact = target => ({
  target,
  assetName: `${target}.xcframework.zip`,
  url: `${releaseBase}${target}.xcframework.zip`,
  size: 1,
  sha256: hash,
  swiftChecksum: hash,
})
const manifest = {
  schemaVersion: 2,
  mode: 'release',
  artifactTag,
  sourceCommit: releaseCommit,
  sdk: {
    version: '0.17.0',
    sourceCommit: 'e8b440665a053a9efe852f04c3601da44f0d55d8',
    npmIntegrity: 'sha512-YQ==',
    runtimeInventorySHA256: hash,
  },
  bundle: {
    assetName: 'worker.mobile.bundle',
    url: `${releaseBase}worker.mobile.bundle`,
    size: 1,
    sha256: hash,
    bundleId: 'test-bundle',
    main: 'index.js',
    embeddedSDKVersion: '0.17.0',
    addonTargets: ['Addon'],
  },
  notices: {
    assetName: 'THIRD_PARTY_NOTICES.md',
    url: `${releaseBase}THIRD_PARTY_NOTICES.md`,
    size: 1,
    sha256: hash,
  },
  artifacts: [artifact('BareKit'), artifact('Addon')],
}

assert.doesNotThrow(() => validateReleaseManifest(manifest))
const missingNotices = structuredClone(manifest)
delete missingNotices.notices
assert.throws(() => validateReleaseManifest(missingNotices), /third-party notices/)
const foreignNotices = structuredClone(manifest)
foreignNotices.notices.url = 'https://example.com/THIRD_PARTY_NOTICES.md'
assert.throws(() => validateReleaseManifest(foreignNotices), /third-party notices URL/)

console.log('[release-binding] exact source/notices binding accepted; mismatched or missing bindings rejected')
