#!/usr/bin/env node
// Generate the complete Swift error enum from the pinned, exported SDK contract.
// The contract is a release artifact at the authoritative source commit; codegen
// never scrapes a moving branch or reparses TypeScript source.

import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const scriptDir = dirname(fileURLToPath(import.meta.url))
const repoRoot = resolve(scriptDir, '..', '..')
const provenance = JSON.parse(readFileSync(resolve(repoRoot, 'tools/provenance/qvac-sdk.lock.json'), 'utf8'))
const upstreamDir = resolve(process.env.QVAC_UPSTREAM_DIR ?? resolve(scriptDir, '.build/qvac-sdk'))
const contractPath = resolve(upstreamDir, 'packages/sdk/contract/error-codes.json')
const generatedDir = resolve(process.env.QVAC_GENERATED_DIR
  ?? resolve(repoRoot, 'Sources/QVACClient/Generated'))
const output = resolve(generatedDir, 'QVACErrorCodes.generated.swift')

const contract = JSON.parse(readFileSync(contractPath, 'utf8'))
const expectedGroups = ['registry', 'client', 'server']
if (JSON.stringify(Object.keys(contract).sort()) !== JSON.stringify([...expectedGroups].sort())) {
  throw new Error(`Unexpected error-code groups in ${contractPath}: ${Object.keys(contract).join(', ')}`)
}

function lowerCamel(name) {
  const [head, ...tail] = name.toLowerCase().split('_')
  return head + tail.map(part => part[0].toUpperCase() + part.slice(1)).join('')
}

function upperFirst(value) {
  return value[0].toUpperCase() + value.slice(1)
}

const namesByGroup = Object.fromEntries(expectedGroups.map(group => [group, new Set(Object.keys(contract[group]))]))
const entries = []
for (const group of expectedGroups) {
  for (const [name, code] of Object.entries(contract[group])) {
    let swiftName = lowerCamel(name)
    if (group === 'registry') swiftName = `registry${upperFirst(swiftName)}`
    if (group === 'server' && namesByGroup.client.has(name)) swiftName += 'Server'
    entries.push({ group, name, code, swiftName })
  }
}
entries.sort((a, b) => a.code - b.code)

const seenCodes = new Map()
const seenSwiftNames = new Map()
for (const entry of entries) {
  if (!Number.isSafeInteger(entry.code)) throw new Error(`Invalid code for ${entry.group}.${entry.name}`)
  if (seenCodes.has(entry.code)) {
    throw new Error(`Duplicate error code ${entry.code}: ${seenCodes.get(entry.code)} and ${entry.group}.${entry.name}`)
  }
  if (seenSwiftNames.has(entry.swiftName)) {
    throw new Error(`Swift identifier collision ${entry.swiftName}: ${seenSwiftNames.get(entry.swiftName)} and ${entry.group}.${entry.name}`)
  }
  seenCodes.set(entry.code, `${entry.group}.${entry.name}`)
  seenSwiftNames.set(entry.swiftName, `${entry.group}.${entry.name}`)
}

const counts = Object.fromEntries(expectedGroups.map(group => [group, Object.keys(contract[group]).length]))
const ranges = [
  [19001, 19003, 'registry'],
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
  [53950, 54000, 'modelRegistry'],
]

const swift = `// QVACErrorCodes.generated.swift
//
// AUTO-GENERATED from @qvac/sdk@${provenance.sdkVersion} contract/error-codes.json
// gitHead: ${provenance.source.commit}
// DO NOT EDIT BY HAND. Re-run \`node tools/codegen/generate-errors.mjs\` to update.
//
// ${entries.length} total codes: ${counts.registry} registry + ${counts.client} client + ${counts.server} server.

import Foundation

/// Every numeric error code defined by the QVAC SDK.
/// See \`Public/QVACError.swift\` for the throwing surface.
public enum QVACErrorCode: Int, Sendable, Equatable, CaseIterable {
${entries.map(entry => `    case ${entry.swiftName} = ${entry.code}`).join('\n')}

    /// SCREAMING_SNAKE_CASE name as defined in the QVAC SDK source.
    public var name: String {
        switch self {
${entries.map(entry => `        case .${entry.swiftName}: return "${entry.name}"`).join('\n')}
        }
    }

    /// Coarse category used by \`QVACErrorCategory\`. Drives \`switch\`-friendly
    /// error-handling code without enumerating every individual case.
    public var category: QVACErrorCategory {
        switch rawValue {
${ranges.map(([low, high, category]) => `        case ${low}...${high}: return .${category}`).join('\n')}
        default: return .other
        }
    }
}
`

mkdirSync(dirname(output), { recursive: true })
writeFileSync(output, swift)
console.log(`Wrote ${entries.length} error codes from pinned contract -> ${output}`)
