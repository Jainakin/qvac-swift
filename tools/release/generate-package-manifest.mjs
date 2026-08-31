#!/usr/bin/env node

import { readFileSync, writeFileSync } from 'node:fs'
import { resolve } from 'node:path'
import {
  loadReleaseManifest,
  renderDevelopmentPackageManifest,
  renderPackageManifest,
  validateDevelopmentManifest,
} from './release-manifest.mjs'

const manifestPath = process.argv[2]
const outputPath = process.argv[3]
if (!manifestPath || !outputPath) {
  throw new Error('usage: generate-package-manifest.mjs <artifact-manifest.json> <Package.swift output>')
}

const raw = JSON.parse(readFileSync(resolve(manifestPath), 'utf8'))
if (raw.mode === 'development') {
  const manifest = validateDevelopmentManifest(raw)
  writeFileSync(resolve(outputPath), renderDevelopmentPackageManifest(manifest))
  console.log(`[package-manifest] generated ${manifest.targets.length} exact local binary targets -> ${resolve(outputPath)}`)
} else {
  const manifest = loadReleaseManifest(resolve(manifestPath))
  writeFileSync(resolve(outputPath), renderPackageManifest(manifest))
  console.log(`[package-manifest] generated ${manifest.artifacts.length} immutable binary targets -> ${resolve(outputPath)}`)
}
