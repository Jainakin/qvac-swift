#!/usr/bin/env node
// unwrap-bundle.mjs
//
// @qvac/cli emits a JavaScript file that exports the bare-bundle binary as a
// string literal (`module.exports = "<JSON-escaped-bytes>";`). That format is
// what react-native-bare-kit expects on Expo — RN's native bridge `require()`s
// the file and feeds the resulting string to BareKit's worklet loader.
//
// We don't ride RN. We feed the bundle bytes directly to BareKit on iOS via
// `BareWorklet.start(_:source:arguments:)`, which goes through `bare-module`'s
// `.bundle` extension handler -> `Bundle.from(buffer)` -> `fromBuffer()`. That
// path expects the raw binary format: optional shebang, decimal-encoded JSON
// header length, '\n', JSON header, then concatenated asset payloads.
//
// This script strips the `module.exports = "..."` wrapper and writes the raw
// bytes. Run it whenever `worker.mobile.bundle.js` is regenerated upstream.
//
// Usage:
//   node tools/bundle/unwrap-bundle.mjs <input.js> <output.bundle>
//
// Example (release pipeline):
//   node tools/bundle/unwrap-bundle.mjs spike-js/qvac/worker.bundle.js \
//     Sources/QVACClient/Resources/worker.mobile.bundle

import { readFileSync, writeFileSync } from 'node:fs'
import { argv, exit, stderr } from 'node:process'

const [, , inputPath, outputPath] = argv
if (!inputPath || !outputPath) {
  stderr.write('usage: unwrap-bundle.mjs <input.js> <output.bundle>\n')
  exit(2)
}

const src = readFileSync(inputPath, 'utf8')
const prefix = 'module.exports = '
if (!src.startsWith(prefix)) {
  stderr.write(`expected ${inputPath} to start with "${prefix}" — is this a bare-pack JS wrapper?\n`)
  exit(1)
}

// Trim semicolon / whitespace so JSON.parse sees just a JSON-string literal.
let payload = src.slice(prefix.length).trim()
if (payload.endsWith(';')) payload = payload.slice(0, -1).trim()

let raw
try {
  raw = JSON.parse(payload)
} catch (err) {
  stderr.write(`failed to parse string literal: ${err.message}\n`)
  exit(1)
}

if (typeof raw !== 'string') {
  stderr.write(`expected string literal, got ${typeof raw}\n`)
  exit(1)
}

// Header sanity check — raw format starts with decimal digits then '\n'.
// Skip optional shebang first (mirrors bare-bundle.fromBuffer).
let off = 0
if (raw.charCodeAt(0) === 0x23 && raw.charCodeAt(1) === 0x21) {
  while (off < raw.length && raw.charCodeAt(off) !== 0x0a) off++
  off++
}
let end = off
while (end < raw.length && raw.charCodeAt(end) >= 0x30 && raw.charCodeAt(end) <= 0x39) end++
if (end === off || raw.charCodeAt(end) !== 0x0a) {
  stderr.write(`unwrapped payload does not look like a bare-bundle (missing length\\n prefix)\n`)
  exit(1)
}

// `bare-pack` serializes the bundle as a JS string with Unicode chars left as
// literal codepoints — multi-byte UTF-8 sequences in the source (e.g. `é`,
// emoji) become a single JS char whose codepoint encodes the WHOLE original
// codepoint, not the UTF-8 byte sequence. To recover the original bytes we
// must re-encode the string as UTF-8 (the default). Using 'binary'/'latin1'
// instead would take the low byte of each codepoint, truncating multi-byte
// sequences and shifting every downstream offset in the bundle (which makes
// `bundle.read('/qvac/worker.entry.mjs')` return an empty buffer and the
// worker silently boot into a no-op state).
const out = Buffer.from(raw, 'utf8')
writeFileSync(outputPath, out)
stderr.write(`wrote ${outputPath} (${out.length} bytes, from ${raw.length} JS chars)\n`)
