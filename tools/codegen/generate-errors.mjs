// generate-errors.mjs — emit Sources/QVACClient/Generated/QVACErrorCodes.generated.swift
//
// Reads:
//   <qvac-sdk-root>/schemas/sdk-errors-client.ts
//   <qvac-sdk-root>/schemas/sdk-errors-server.ts
// Extracts every `NAME: <integer>,` from the `SDK_*_ERROR_CODES` object literals and emits
// a Swift `enum QVACErrorCode: Int` covering every code.
//
// Idempotent: re-running produces no diff against the checked-in output when the upstream
// hasn't changed (verified by tools/codegen-freshness.sh).

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const REPO_ROOT = resolve(__dirname, '..', '..')

// Default location — sparse-checkout of tetherto/qvac (see tools/codegen/README.md §1).
// Overridable via env to support running against a different checkout.
const SDK_SCHEMAS_DIR = process.env.QVAC_SCHEMAS_DIR
  ?? resolve(REPO_ROOT, 'qvac-sparse/packages/sdk/schemas')

const CLIENT_TS = resolve(SDK_SCHEMAS_DIR, 'sdk-errors-client.ts')
const SERVER_TS = resolve(SDK_SCHEMAS_DIR, 'sdk-errors-server.ts')
const OUTPUT = resolve(REPO_ROOT, 'Sources/QVACClient/Generated/QVACErrorCodes.generated.swift')

// ----------------------------------------------------------------------------------
// Parsing
// ----------------------------------------------------------------------------------

/**
 * Extract codes from an `SDK_*_ERROR_CODES = { ... } as const;` block.
 * We rely on the structure of these files (committed format, one entry per line) rather
 * than a full TS parser; the QVAC repo's lint/format rules keep this stable.
 */
function extractCodes(filePath, expectedSymbol) {
  const src = readFileSync(filePath, 'utf8')
  const startMarker = `export const ${expectedSymbol} = {`
  const startIdx = src.indexOf(startMarker)
  if (startIdx === -1) throw new Error(`Couldn't find ${startMarker} in ${filePath}`)
  let depth = 0, i = startIdx + startMarker.length
  while (i < src.length) {
    if (src[i] === '{') depth++
    else if (src[i] === '}') {
      if (depth === 0) break
      depth--
    }
    i++
  }
  const block = src.slice(startIdx + startMarker.length, i)

  // Match `NAME: 12345,` lines, allowing inline /* comments */.
  const out = []
  for (const line of block.split('\n')) {
    const trimmed = line.split('//')[0].trim()
    if (!trimmed) continue
    const m = trimmed.match(/^([A-Z][A-Z0-9_]*)\s*:\s*([0-9]+)\s*,?$/)
    if (!m) continue
    const [, name, code] = m
    out.push({ name, code: Number(code) })
  }
  return out
}

const clientCodes = extractCodes(CLIENT_TS, 'SDK_CLIENT_ERROR_CODES')
const serverCodes = extractCodes(SERVER_TS, 'SDK_SERVER_ERROR_CODES')

// Some names exist in BOTH files with different numeric codes (e.g. DELEGATE_NO_FINAL_RESPONSE
// is 50402 on the client and 53700 on the server — they're genuinely distinct concepts,
// just labelled identically). Disambiguate by tagging the server-side variant.
const clientNames = new Set(clientCodes.map(e => e.name))
const serverCodesDisambiguated = serverCodes.map(e =>
  clientNames.has(e.name) ? { ...e, name: e.name + '_SERVER' } : e
)
const all = [...clientCodes, ...serverCodesDisambiguated].sort((a, b) => a.code - b.code)

// Sanity: no duplicates on either code or name.
const seenCode = new Map(), seenName = new Map()
for (const e of all) {
  if (seenCode.has(e.code)) throw new Error(`Duplicate error code ${e.code}: ${seenCode.get(e.code)} vs ${e.name}`)
  if (seenName.has(e.name)) throw new Error(`Duplicate error name ${e.name}: codes ${seenName.get(e.name)} and ${e.code}`)
  seenCode.set(e.code, e.name)
  seenName.set(e.name, e.code)
}

// ----------------------------------------------------------------------------------
// Categorization (matches Public/QVACError.swift's QVACErrorCategory)
// ----------------------------------------------------------------------------------

function categorize(code) {
  // Mirrors the comment-section ranges in the upstream TS files.
  if (code >= 50001 && code <= 50199) return 'responseValidation'
  if (code >= 50200 && code <= 50399) return 'rpcCommunication'
  if (code >= 50400 && code <= 50599) return 'providerDelegation'
  if (code >= 50600 && code <= 50799) return 'buildBundle'
  if (code >= 50800 && code <= 50899) return 'profiler'
  if (code >= 52001 && code <= 52199) return 'modelRegistry'
  if (code >= 52200 && code <= 52399) return 'modelLoading'
  if (code >= 52400 && code <= 52799) return 'modelOperation'
  if (code >= 52800 && code <= 52999) return 'rag'
  if (code >= 53000 && code <= 53199) return 'download'
  if (code >= 53200 && code <= 53349) return 'cache'
  if (code >= 53350 && code <= 53499) return 'config'
  if (code >= 53500 && code <= 53599) return 'systemRuntime'
  if (code >= 53600 && code <= 53699) return 'lifecycle'
  if (code >= 53700 && code <= 53849) return 'serverRpcDelegation'
  if (code >= 53850 && code <= 53899) return 'plugin'
  if (code >= 53900 && code <= 53949) return 'security'
  return 'other'
}

// ----------------------------------------------------------------------------------
// Emit Swift
// ----------------------------------------------------------------------------------

function swiftIdentifier(name) {
  // Codes are already SCREAMING_SNAKE_CASE; Swift convention is camelCase for enum cases.
  // Lowercase first letter, the rest follows underscore→PascalCase folding.
  const parts = name.toLowerCase().split('_')
  const head = parts[0]
  const tail = parts.slice(1).map(p => p[0].toUpperCase() + p.slice(1)).join('')
  return head + tail
}

const header = `\
// QVACErrorCodes.generated.swift
//
// AUTO-GENERATED by tools/codegen/generate-errors.mjs from:
//   ${CLIENT_TS.replace(REPO_ROOT + '/', '')}
//   ${SERVER_TS.replace(REPO_ROOT + '/', '')}
// DO NOT EDIT BY HAND. Re-run \`node tools/codegen/generate-errors.mjs\` to update.
//
// ${all.length} total codes: ${clientCodes.length} client (50001-52000), ${serverCodes.length} server (52001+).

import Foundation

/// Every numeric error code defined by the QVAC SDK.
/// See \`Public/QVACError.swift\` for the throwing surface.
public enum QVACErrorCode: Int, Sendable, Equatable, CaseIterable {
${all.map(e => `    case ${swiftIdentifier(e.name)} = ${e.code}`).join('\n')}

    /// SCREAMING_SNAKE_CASE name as defined in the QVAC SDK source.
    public var name: String {
        switch self {
${all.map(e => `        case .${swiftIdentifier(e.name)}: return "${e.name}"`).join('\n')}
        }
    }

    /// Coarse category used by \`QVACErrorCategory\`. Drives \`switch\`-friendly
    /// error-handling code without enumerating every individual case.
    public var category: QVACErrorCategory {
        switch rawValue {
${(() => {
  // Emit one ranged case per category. Cleaner than per-code mapping for big lists.
  const ranges = [
    [50001, 50199, 'responseValidation'],
    [50200, 50399, 'rpcCommunication'],
    [50400, 50599, 'providerDelegation'],
    [50600, 50799, 'buildBundle'],
    [50800, 50899, 'profiler'],
    [52001, 52199, 'modelRegistry'],
    [52200, 52399, 'modelLoading'],
    [52400, 52799, 'modelOperation'],
    [52800, 52999, 'rag'],
    [53000, 53199, 'download'],
    [53200, 53349, 'cache'],
    [53350, 53499, 'config'],
    [53500, 53599, 'systemRuntime'],
    [53600, 53699, 'lifecycle'],
    [53700, 53849, 'serverRpcDelegation'],
    [53850, 53899, 'plugin'],
    [53900, 53949, 'security'],
  ]
  return ranges.map(([lo, hi, cat]) =>
    `        case ${lo}...${hi}: return .${cat}`).join('\n')
})()}
        default: return .other
        }
    }
}
`

mkdirSync(dirname(OUTPUT), { recursive: true })
writeFileSync(OUTPUT, header)
console.log(`Wrote ${all.length} codes (${clientCodes.length} client + ${serverCodes.length} server) → ${OUTPUT.replace(REPO_ROOT + '/', '')}`)
