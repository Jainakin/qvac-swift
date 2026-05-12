#!/usr/bin/env node
// compute-manifest.mjs — emit the exact xcframework link set for a release.
//
// bare-link produces N xcframeworks under <artifacts-dir>. That set includes
// duplicates (multiple versions of the same package, because spike-js's
// `npm install --legacy-peer-deps` pulls duplicate peers) and packages the
// bundle never references at runtime. Linking everything into the host app
// would bloat the binary by hundreds of MB and risks symbol collisions
// between coexisting versions.
//
// The actual MINIMAL link set for a consumer-mode build is:
//   1. The exact framework name+version pairs the bundle's `addons` table
//      references — these are what `process.addon(N)` resolves to at runtime.
//   2. The transitive @rpath closure of (1) — one framework can dlopen
//      another (e.g. qvac__transcription-whispercpp dlopens bare-channel).
//   3. BareKit — the libuv/V8 host runtime that everything else lives in.
//
// This script computes (1) + (2) and emits a JSON manifest. The release
// pipeline uploads the manifest as a release asset so consumer-mode
// Package.swift generators can pin the exact set without recomputing.
//
// Usage:
//   node tools/release/compute-manifest.mjs <artifacts-dir> <bundle-path> <out-manifest>

import { readFileSync, writeFileSync, readdirSync, existsSync, statSync } from 'node:fs'
import { execSync } from 'node:child_process'
import { join, basename } from 'node:path'
import { argv, exit, stderr, cwd } from 'node:process'

const [, , artifactsDir, bundlePath, outPath] = argv
if (!artifactsDir || !bundlePath || !outPath) {
  stderr.write('usage: compute-manifest.mjs <artifacts-dir> <bundle-path> <out-manifest.json>\n')
  exit(2)
}

// ---------- 1. parse bundle addons ----------

async function loadBundle(path) {
  // Use bare-bundle from spike-js/node_modules — it does the same header
  // parsing as bare-module's `.bundle` extension handler, which is the
  // ground truth for what bytes the bundle actually exposes at runtime.
  // Hand-rolled offset arithmetic on the UTF-8-encoded bundle would need
  // careful char-vs-byte handling around the header/asset boundary.
  const { createRequire } = await import('node:module')
  const require = createRequire(import.meta.url)
  // Resolve bare-bundle relative to spike-js, the only place it's installed.
  const bareBundle = require(require.resolve('bare-bundle', {
    paths: [join(cwd(), 'spike-js'), join(cwd(), '..', 'spike-js')],
  }))
  const buf = readFileSync(path)
  const b = bareBundle.from(buf)
  return {
    id: b.id,
    main: b.main,
    addons: b.addons || {},
  }
}

const header = await loadBundle(bundlePath)
const required = new Set()
for (const v of Object.values(header.addons || {})) {
  // Format: "linked:NAME.VERSION.framework/NAME.VERSION"
  const m = v.match(/^linked:(.+)\.framework\//)
  if (m) required.add(m[1])
}
stderr.write(`[manifest] bundle references ${required.size} addons directly\n`)

// ---------- 2. inventory artifacts ----------

const available = new Map() // framework-name -> absolute xcframework path
for (const entry of readdirSync(artifactsDir)) {
  const full = join(artifactsDir, entry)
  if (entry.endsWith('.xcframework') && statSync(full).isDirectory()) {
    available.set(entry.replace(/\.xcframework$/, ''), full)
  }
}
stderr.write(`[manifest] artifacts dir has ${available.size} xcframeworks\n`)

// ---------- 3. transitive @rpath closure ----------

function rpathDeps(name) {
  const xcf = available.get(name)
  if (!xcf) return new Set()
  const deps = new Set()
  // Try ios-arm64 first (release slice), fall back to simulator if dev artefact.
  for (const slice of ['ios-arm64', 'ios-arm64-simulator', 'ios-x64-simulator', 'ios-arm64_x86_64-simulator']) {
    const fwk = join(xcf, slice, `${name}.framework`, name)
    if (existsSync(fwk)) {
      try {
        const out = execSync(`otool -L "${fwk}"`, { encoding: 'utf8' })
        for (const line of out.split('\n')) {
          const m = line.match(/@rpath\/([^/]+)\.framework\//)
          if (m && m[1] !== name) deps.add(m[1])
        }
      } catch {}
      break
    }
  }
  return deps
}

const needed = new Set(required)
const queue = [...required]
const missing = new Set()
while (queue.length > 0) {
  const name = queue.shift()
  if (!available.has(name)) {
    missing.add(name)
    continue
  }
  for (const d of rpathDeps(name)) {
    if (!needed.has(d)) {
      needed.add(d)
      queue.push(d)
    }
  }
}

if (missing.size > 0) {
  stderr.write(`[manifest] WARNING: ${missing.size} addons referenced by bundle/closure are missing from artifacts:\n`)
  for (const m of missing) stderr.write(`  - ${m}\n`)
}

// ---------- 4. emit manifest ----------

// Required: BareKit is the host runtime, always included.
const linkSet = [...needed].sort()

const manifest = {
  schemaVersion: 1,
  bundleId: header.id,
  bundleMain: header.main,
  // The host runtime — uploaded separately by release.yml's "Copy BareKit"
  // step. Not produced by bare-link.
  hostRuntime: 'BareKit',
  // Sorted addon names (matches the xcframework zip filenames before the
  // `.xcframework.zip` suffix). Order is deterministic so consumer-mode
  // Package.swift diffs are stable across regenerations.
  addons: linkSet,
  missingFromArtifacts: [...missing].sort(),
}
writeFileSync(outPath, JSON.stringify(manifest, null, 2))
stderr.write(`[manifest] wrote ${outPath}: ${linkSet.length} addons + BareKit\n`)
if (missing.size > 0) {
  stderr.write(`[manifest] exiting non-zero because of missing addons\n`)
  exit(3)
}
