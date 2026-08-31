// generate-types.mjs — emit Sources/QVACClient/Generated/QVACTypes.generated.swift
//
// Pipeline: read the immutable JSON Schema exported in the pinned QVAC SDK source
// contract → emit Swift `Codable` types for every leaf branch, plus the
// discriminated-union wrappers `QVACRequest` and `QVACResponse`.
//
// Idempotent: re-running produces no diff against the checked-in output for an unchanged input.

import { writeFileSync, mkdirSync, readFileSync } from 'node:fs'
import { dirname, relative, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const REPO_ROOT = resolve(__dirname, '..', '..')
const PROVENANCE = JSON.parse(readFileSync(resolve(REPO_ROOT, 'tools/provenance/qvac-sdk.lock.json'), 'utf8'))
const UPSTREAM_DIR = resolve(process.env.QVAC_UPSTREAM_DIR ?? resolve(__dirname, '.build/qvac-sdk'))
const CONTRACT_SCHEMA = resolve(UPSTREAM_DIR, 'packages/sdk/contract/schema.json')
const GENERATED_DIR = resolve(process.env.QVAC_GENERATED_DIR
  ?? resolve(REPO_ROOT, 'Sources/QVACClient/Generated'))
const OUTPUT = resolve(GENERATED_DIR, 'QVACTypes.generated.swift')
const GENERATED_TEST_DIR = resolve(process.env.QVAC_GENERATED_TEST_DIR
  ?? resolve(REPO_ROOT, 'Tests/QVACClientUnitTests'))
const ROUNDTRIP_TEST_OUTPUT = resolve(GENERATED_TEST_DIR, 'QVACGeneratedRoundTripTests.generated.swift')
const OVERRIDES_PATH = resolve(__dirname, 'overrides.json')

const codePointCompare = (a, b) => a < b ? -1 : a > b ? 1 : 0

const overrides = JSON.parse(readFileSync(OVERRIDES_PATH, 'utf8'))

const contract = JSON.parse(readFileSync(CONTRACT_SCHEMA, 'utf8'))
if (!contract.$defs?.request || !contract.$defs?.response) {
  throw new Error(`Pinned contract is missing request/response definitions: ${CONTRACT_SCHEMA}`)
}
const requestSchema = contract.$defs.request
const responseSchema = contract.$defs.response

// The exported contract is already the wire-only shape; runtime callbacks and
// transforms have been deliberately removed upstream.
const autoOmit = { request: {}, response: {} }

function resolveRef(node) {
  let current = node
  const seen = new Set()
  while (current?.$ref) {
    const prefix = '#/$defs/'
    if (!current.$ref.startsWith(prefix)) throw new Error(`Unsupported external $ref: ${current.$ref}`)
    const key = decodeURIComponent(current.$ref.slice(prefix.length))
    if (seen.has(key)) return current
    seen.add(key)
    current = contract.$defs[key]
    if (!current) throw new Error(`Unresolved contract $ref: ${node.$ref}`)
  }
  return current
}

// ------------------------------------------------------------------------------------
// Walk the schema tree and collect ALL leaf object branches.
//
// "Leaf branch" = a JSON Schema node of `type: "object"` with a `type: { const: X }`
// discriminator. The walker recurses into anyOf / oneOf / allOf to find them.
// ------------------------------------------------------------------------------------

function isObjectLeaf(node) {
  node = resolveRef(node)
  return node?.type === 'object' && node?.properties?.type?.const !== undefined
}

/// Collect every leaf (object-with-`type`-discriminator) reachable from `schema`.
/// Handles the QVAC-specific `allOf: [{type-discriminator}, {oneOf: [shape1, shape2]}]`
/// pattern by lifting the parent discriminator into each shape and merging properties.
function collectLeaves(schema, side /* 'request' | 'response' */) {
  const out = []
  function walk(node, ancestors = [], inheritedDiscriminator = null) {
    node = resolveRef(node)
    if (!node || typeof node !== 'object') return

    // Plain leaf: object with type:{const} discriminator.
    if (isObjectLeaf(node)) {
      out.push({
        side,
        node,
        discriminator: node.properties.type.const,
        ancestors,
      })
      return
    }

    // allOf: combine a base object (which may carry the type discriminator) with one or more
    // siblings (which may be oneOf of variant shapes).
    if (Array.isArray(node.allOf)) {
      // Find a base object that fixes the type discriminator.
      let baseDiscriminator = inheritedDiscriminator
      let baseProperties = {}
      let baseRequired = []
      const nonBaseBranches = []
      for (const rawBranch of node.allOf) {
        const branch = resolveRef(rawBranch)
        if (isObjectLeaf(branch)) {
          baseDiscriminator = branch.properties.type.const
          // Merge in the base's other props (usually just `type`).
          baseProperties = { ...baseProperties, ...(branch.properties ?? {}) }
          baseRequired = [...baseRequired, ...(branch.required ?? [])]
        } else if (branch.type === 'object' && branch.properties) {
          // Object branch without a type discriminator — fold its props into the base.
          baseProperties = { ...baseProperties, ...branch.properties }
          baseRequired = [...baseRequired, ...(branch.required ?? [])]
        } else {
          nonBaseBranches.push(branch)
        }
      }
      // For each non-base branch (typically a oneOf), emit one leaf per variant,
      // with the base props + variant props merged.
      for (const sibling of nonBaseBranches) {
        for (const arr of ['oneOf', 'anyOf']) {
          if (Array.isArray(sibling[arr])) {
            for (const rawVariant of sibling[arr]) {
              const variant = resolveRef(rawVariant)
              if (variant?.type === 'object' && variant?.properties) {
                const merged = {
                  type: 'object',
                  properties: { ...baseProperties, ...variant.properties },
                  required: [...new Set([...(baseRequired), ...(variant.required ?? [])])],
                }
                // Ensure the merged shape carries the type:{const} so downstream emitter recognizes it.
                if (baseDiscriminator !== null && !merged.properties.type?.const) {
                  merged.properties.type = { type: 'string', const: baseDiscriminator }
                }
                out.push({
                  side,
                  node: merged,
                  discriminator: baseDiscriminator ?? '<unknown>',
                  ancestors,
                })
              }
            }
          }
        }
      }
      // If allOf had only base shapes (no variant), emit a single merged leaf.
      if (nonBaseBranches.length === 0 && baseDiscriminator !== null) {
        out.push({
          side,
          node: {
            type: 'object',
            properties: baseProperties,
            required: [...new Set(baseRequired)],
          },
          discriminator: baseDiscriminator,
          ancestors,
        })
      }
      return
    }

    // Recurse into anyOf/oneOf.
    for (const arr of ['anyOf', 'oneOf']) {
      if (Array.isArray(node[arr])) {
        node[arr].forEach((c, i) => walk(c, [...ancestors, `${arr}[${i}]`], inheritedDiscriminator))
      }
    }
  }
  walk(schema)
  return out
}

const requestLeaves  = collectLeaves(requestSchema,  'request')
const responseLeaves = collectLeaves(responseSchema, 'response')

// ------------------------------------------------------------------------------------
// Merge leaves that share the same discriminator (cancel has `allOf: [base, oneOf]`
// which produces multiple leaves per discriminator value with merged shapes).
// ------------------------------------------------------------------------------------

/// Score a JSON-Schema property shape by how specifically it describes the wire
/// representation. Used by mergeLeavesByDiscriminator to pick the best shape
/// when discriminator variants disagree on a field's type.
///
/// Ranking (high → low):
///   array > primitive type with items     {type: "array", items: {...}}
///   3   > primitive type with constraints {type: "object", properties: {...}} | {type: "string", const: "x"}
///   2   > bare primitive type             {type: "boolean"}
///   1   > anyOf/oneOf union               {anyOf: [...]}
///   0   > unrepresentable / opaque        {} | {not: {}} | undefined
function shapeSpecificity(shape) {
  if (!shape || typeof shape !== 'object') return 0
  // {} and {not: ...} are the "absent / forbidden" cases — least specific.
  if (Object.keys(shape).length === 0) return 0
  if (shape.not !== undefined && shape.type === undefined && !shape.anyOf && !shape.oneOf) return 0
  // anyOf/oneOf without a `type` discriminator is a union — less specific than
  // a single concrete type since the Swift generator falls back to JSONValue.
  if ((shape.anyOf || shape.oneOf) && shape.type === undefined) return 1
  // Bare primitive type.
  if (shape.type !== undefined) {
    // Arrays with items, objects with properties, and constrained types score higher.
    if (shape.type === 'array' && shape.items) return 3
    if (shape.type === 'object' && shape.properties) return 3
    if (shape.const !== undefined || shape.enum !== undefined) return 3
    if (shape.additionalProperties) return 3
    return 2
  }
  // additionalProperties without explicit type (map shape).
  if (shape.additionalProperties) return 2
  return 0
}

function mergeLeavesByDiscriminator(leaves) {
  const grouped = new Map()
  for (const leaf of leaves) {
    const key = leaf.discriminator
    if (!grouped.has(key)) grouped.set(key, [])
    grouped.get(key).push(leaf)
  }
  // For each discriminator, deep-merge properties (UNION) and required (INTERSECTION).
  // Intersection on required preserves correctness across variants: a field is
  // "always required" only if every variant requires it.
  const merged = []
  for (const [discriminator, group] of grouped) {
    if (group.length === 1) {
      merged.push({ discriminator, node: group[0].node })
      continue
    }
    const properties = {}
    let requiredIntersect = null
    for (const g of group) {
      for (const [k, v] of Object.entries(g.node.properties ?? {})) {
        // §B7 — merge field shapes intelligently across discriminator variants.
        //
        // Why: a discriminated union like LoadModel has 10 branches; 9 declare
        // `seed: {type: "boolean"}` and 1 declares `seed: {not: {}}` (the
        // `z.never()` variant forbids the field on that branch). Naive last-
        // write-wins would pick `{not: {}}` for some variant orderings,
        // erasing the type information and forcing the Swift generator to fall
        // back to `JSONValue?`. We score each shape by specificity and keep
        // the most specific seen.
        const existing = properties[k]
        if (!existing || shapeSpecificity(v) > shapeSpecificity(existing)) {
          properties[k] = v
        }
      }
      const r = new Set(g.node.required ?? [])
      if (requiredIntersect === null) {
        requiredIntersect = r
      } else {
        requiredIntersect = new Set([...requiredIntersect].filter(x => r.has(x)))
      }
    }
    merged.push({
      discriminator,
      node: {
        type: 'object',
        properties,
        required: [...(requiredIntersect ?? new Set())],
      },
    })
  }
  return merged
}

const requests  = mergeLeavesByDiscriminator(requestLeaves)
const responses = mergeLeavesByDiscriminator(responseLeaves)
const emittedStructs = []

// ------------------------------------------------------------------------------------
// Swift identifier helpers
// ------------------------------------------------------------------------------------

const SWIFT_RESERVED = new Set([
  'class', 'struct', 'enum', 'protocol', 'extension', 'func', 'var', 'let', 'init',
  'deinit', 'self', 'Self', 'super', 'import', 'return', 'throws', 'rethrows',
  'where', 'if', 'else', 'for', 'while', 'do', 'switch', 'case', 'default',
  'break', 'continue', 'in', 'true', 'false', 'nil', 'is', 'as', 'try', 'catch',
  'guard', 'defer', 'repeat', 'fallthrough', 'public', 'private', 'fileprivate',
  'internal', 'open', 'final', 'static', 'lazy', 'weak', 'unowned', 'inout',
  'operator', 'precedencegroup', 'infix', 'prefix', 'postfix', 'left', 'right',
  'none', 'associativity', 'higherThan', 'lowerThan', 'assignment', 'subscript',
  'typealias', 'associatedtype', 'mutating', 'nonmutating', 'override', 'required',
  'convenience', 'dynamic', 'optional', 'indirect', 'lazy', 'some', 'any', 'Any',
  'Type', 'Protocol', 'description',
])

function toPascalCase(name) {
  // Split on any non-alphanumeric, capitalize each word, concat. Handles
  // colons (`rag:progress`), dashes, underscores, dots, slashes, etc.
  return name
    .split(/[^A-Za-z0-9]+/)
    .filter(Boolean)
    .map(w => w[0].toUpperCase() + w.slice(1))
    .join('')
}
function toCamelCase(name) {
  const p = toPascalCase(name)
  return p.charAt(0).toLowerCase() + p.slice(1)
}
function safeIdentifier(name) {
  const camel = toCamelCase(name)
  // Empty after sanitization → fallback to a deterministic name.
  if (!camel) return `_unknown_${Math.abs(simpleHash(name))}`
  return SWIFT_RESERVED.has(camel) ? '`' + camel + '`' : camel
}
function simpleHash(s) {
  let h = 0
  for (let i = 0; i < s.length; i++) h = ((h << 5) - h + s.charCodeAt(i)) | 0
  return h
}
function structName(discriminator, side) {
  return toPascalCase(discriminator) + (side === 'request' ? 'Request' : 'Response')
}

// ------------------------------------------------------------------------------------
// JSON Schema property → Swift type
// ------------------------------------------------------------------------------------

function swiftType(prop, context = {}) {
  prop = resolveRef(prop)
  if (!prop || typeof prop !== 'object') return 'JSONValue'

  // anyOf/oneOf at property level → JSONValue unless it's the optional-nullable pattern.
  if (Array.isArray(prop.anyOf) || Array.isArray(prop.oneOf)) {
    return 'JSONValue'
  }
  if (prop.const !== undefined) {
    // Literal constant. Always carried as a String on the wire for our `type` field.
    if (typeof prop.const === 'string') return 'String'
    if (typeof prop.const === 'number') return 'Double'
    if (typeof prop.const === 'boolean') return 'Bool'
    return 'JSONValue'
  }
  if (Array.isArray(prop.enum)) {
    // We could emit a real enum, but enums-in-Swift complicate Codable round-trip when
    // upstream adds new values. Carry as String for forward-compat.
    return 'String'
  }
  switch (prop.type) {
    case 'string':
      return 'String'
    case 'number':
      return 'Double'
    case 'integer':
      return 'Int'
    case 'boolean':
      return 'Bool'
    case 'null':
      return 'JSONValue?'
    case 'array': {
      const item = swiftType(prop.items, context)
      return `[${item}]`
    }
    case 'object': {
      if (prop.additionalProperties && !prop.properties) {
        // Map-shape: `{ [key: string]: T }`
        const v = swiftType(prop.additionalProperties, context)
        return `[String: ${v}]`
      }
      // Nested anonymous structs are inlined as JSONValue for now — we don't generate
      // a struct for every sub-shape. Future work: extract to named substruct.
      return 'JSONValue'
    }
    default:
      // No type info — typical for fields that the input schema couldn't resolve
      // (transforms, instanceof, etc.). Carry as opaque JSONValue.
      return 'JSONValue'
  }
}

function isOptional(propName, node) {
  const required = new Set(node.required ?? [])
  return !required.has(propName)
}

// ------------------------------------------------------------------------------------
// Emit a single struct for one (discriminator, node)
// ------------------------------------------------------------------------------------

function emitStruct(discriminator, node, side) {
  const name = structName(discriminator, side)
  const props = Object.entries(node.properties ?? {})
  // Move `type` first (visually) so generated code is readable.
  props.sort(([a], [b]) => (a === 'type' ? -1 : b === 'type' ? 1 : codePointCompare(a, b)))

  // Apply two sources of "omit this field" instructions:
  //   1. Per-side per-discriminator entries in overrides.json (manual escape hatch).
  //   2. Auto-detected `z.function`/`z.custom` callback fields from the Zod schema
  //      (§27 in AUDIT.md). These travel only inside the JS client process and never
  //      hit the wire, so they must not appear in the generated Codable struct.
  const omit = new Set([
    ...(overrides.omitFields?.[`${side}/${discriminator}`] ?? []),
    ...(overrides.omitFields?.['*'] ?? []),
    ...(autoOmit[side]?.[discriminator] ?? []),
  ])

  const lines = []
  lines.push(`/// Wire-level shape for the QVAC SDK "${discriminator}" ${side}.`)
  lines.push(`public struct ${name}: Codable, Sendable, Equatable {`)
  const fields = []
  for (const [propName, prop] of props) {
    if (omit.has(propName)) continue
    const swiftName = safeIdentifier(propName)
    let swift = swiftType(prop, { side, discriminator, propName })
    const optional = isOptional(propName, node)
    if (optional && !swift.endsWith('?')) swift = swift + '?'
    const doc = prop?.description ? `\n    /// ${prop.description.replace(/\*\//g, '*\\/')}` : ''
    if (propName === 'type') {
      if (prop?.const !== discriminator) throw new Error(`Missing exact discriminator for ${side}/${discriminator}`)
      lines.push(`\n    public static let discriminator = ${JSON.stringify(discriminator)}`)
      lines.push(`${doc}\n    public let ${swiftName}: ${swift}`)
    } else {
      lines.push(`${doc}\n    public var ${swiftName}: ${swift}`)
    }
    let defaultValue
    if (optional && defaultValue === undefined) defaultValue = 'nil'
    fields.push({ swiftName, propName, swift, optional, defaultValue, discriminator: propName === 'type' })
  }

  // The discriminator is deliberately absent from the public initializer. It is an
  // invariant of the generated concrete type, not caller-controlled payload data.
  const initFields = [
    ...fields.filter(f => !f.discriminator && f.defaultValue === undefined),
    ...fields.filter(f => !f.discriminator && f.defaultValue !== undefined),
  ]
  const initParams = initFields.map(f =>
    `${f.swiftName}: ${f.swift}${f.defaultValue !== undefined ? ' = ' + f.defaultValue : ''}`
  ).join(', ')
  const initBody = [
    '        self.type = Self.discriminator',
    ...initFields.map(f => `        self.${f.swiftName} = ${f.swiftName}`),
  ].join('\n')
  emittedStructs.push({ name, discriminator, side, fields, initFields })
  lines.push(`\n    public init(${initParams}) {`)
  lines.push(initBody)
  lines.push('    }')

  // Always emit explicit Codable so direct decoding of a concrete leaf validates
  // its literal. Synthesized Codable for a defaulted `let type` would ignore an
  // incorrect wire discriminator and silently manufacture a different request.
  lines.push('\n    enum CodingKeys: String, CodingKey {')
  for (const f of fields) {
    const cleanSwiftName = f.swiftName.replace(/^`|`$/g, '')
    if (cleanSwiftName === f.propName) {
      lines.push(`        case ${f.swiftName}`)
    } else {
      lines.push(`        case ${f.swiftName} = "${f.propName}"`)
    }
  }
  lines.push('    }')

  lines.push('\n    public init(from decoder: Decoder) throws {')
  lines.push('        let container = try decoder.container(keyedBy: CodingKeys.self)')
  lines.push('        let decodedType = try container.decode(String.self, forKey: .type)')
  lines.push('        guard decodedType == Self.discriminator else {')
  lines.push('            throw DecodingError.dataCorruptedError(')
  lines.push('                forKey: .type,')
  lines.push('                in: container,')
  lines.push(`                debugDescription: "Expected ${discriminator} discriminator, got \\(decodedType)"`)
  lines.push('            )')
  lines.push('        }')
  lines.push('        self.type = Self.discriminator')
  for (const f of fields.filter(field => !field.discriminator)) {
    const decodeType = f.optional && f.swift.endsWith('?') ? f.swift.slice(0, -1) : f.swift
    const operation = f.optional ? 'decodeIfPresent' : 'decode'
    lines.push(`        self.${f.swiftName} = try container.${operation}(${decodeType}.self, forKey: .${f.swiftName})`)
  }
  lines.push('    }')

  lines.push('\n    public func encode(to encoder: Encoder) throws {')
  lines.push('        var container = encoder.container(keyedBy: CodingKeys.self)')
  lines.push('        try container.encode(Self.discriminator, forKey: .type)')
  for (const f of fields.filter(field => !field.discriminator)) {
    const operation = f.optional ? 'encodeIfPresent' : 'encode'
    lines.push(`        try container.${operation}(${f.swiftName}, forKey: .${f.swiftName})`)
  }
  lines.push('    }')

  lines.push('}')
  return lines.join('\n')
}

// ------------------------------------------------------------------------------------
// Emit the discriminated-union envelope
// ------------------------------------------------------------------------------------

function emitUnion(name, leaves, side) {
  const lines = []
  lines.push(`/// Discriminated union over every wire-level ${side} the QVAC SDK exposes.`)
  lines.push(`/// Round-trips through ${side === 'request' ? '`encode`' : '`decode`'} via the "type" discriminator.`)
  lines.push(`public enum ${name}: Codable, Sendable, Equatable {`)
  for (const { discriminator } of leaves) {
    const caseName = safeIdentifier(discriminator)
    const structN = structName(discriminator, side)
    lines.push(`    case ${caseName}(${structN})`)
  }
  // Custom Codable: dispatch on the "type" discriminator.
  lines.push('\n    private enum Key: String, CodingKey { case type }')
  lines.push('\n    public init(from decoder: Decoder) throws {')
  lines.push('        let probe = try decoder.container(keyedBy: Key.self)')
  lines.push('        let t = try probe.decode(String.self, forKey: .type)')
  lines.push('        switch t {')
  for (const { discriminator } of leaves) {
    const caseName = safeIdentifier(discriminator)
    const structN = structName(discriminator, side)
    lines.push(`        case "${discriminator}":`)
    lines.push(`            self = .${caseName}(try ${structN}(from: decoder))`)
  }
  lines.push('        default:')
  lines.push('            throw DecodingError.dataCorruptedError(')
  lines.push('                forKey: .type,')
  lines.push('                in: probe,')
  lines.push(`                debugDescription: "Unknown QVAC ${side} discriminator '\\(t)' for pinned SDK ${PROVENANCE.sdkVersion}"`)
  lines.push('            )')
  lines.push('        }')
  lines.push('    }')
  lines.push('\n    public func encode(to encoder: Encoder) throws {')
  lines.push('        switch self {')
  for (const { discriminator } of leaves) {
    const caseName = safeIdentifier(discriminator)
    lines.push(`        case .${caseName}(let v): try v.encode(to: encoder)`)
  }
  lines.push('        }')
  lines.push('    }')
  lines.push('\n    public var discriminator: String {')
  lines.push('        switch self {')
  for (const { discriminator } of leaves) {
    const caseName = safeIdentifier(discriminator)
    lines.push(`        case .${caseName}: return "${discriminator}"`)
  }
  lines.push('        }')
  lines.push('    }')
  lines.push('}')
  return lines.join('\n')
}

// ------------------------------------------------------------------------------------
// Emit
// ------------------------------------------------------------------------------------

const header = `\
// QVACTypes.generated.swift
//
// AUTO-GENERATED by tools/codegen/generate-types.mjs from:
//   @qvac/sdk@${PROVENANCE.sdkVersion} contract/schema.json
//   gitHead: ${PROVENANCE.source.commit}
// Source and npm distribution parity are verified before generation.
// DO NOT EDIT BY HAND.
//
// Coverage: ${requests.length} request types, ${responses.length} response types
// (deduplicated from ${requestLeaves.length} + ${responseLeaves.length} JSON-Schema leaves).

import Foundation

`

const parts = [header]
for (const { discriminator, node } of [...requests].sort((a,b)=>codePointCompare(a.discriminator, b.discriminator))) {
  parts.push(emitStruct(discriminator, node, 'request'))
}
for (const { discriminator, node } of [...responses].sort((a,b)=>codePointCompare(a.discriminator, b.discriminator))) {
  parts.push(emitStruct(discriminator, node, 'response'))
}
parts.push(emitUnion('QVACRequest',  requests,  'request'))
parts.push(emitUnion('QVACResponse', responses, 'response'))

mkdirSync(dirname(OUTPUT), { recursive: true })
writeFileSync(OUTPUT, parts.join('\n\n') + '\n')
console.log(`Wrote ${requests.length} request + ${responses.length} response types → ${relative(REPO_ROOT, OUTPUT)}`)

function sampleValue(swiftTypeName) {
  let type = swiftTypeName
  while (type.endsWith('?')) type = type.slice(0, -1)
  if (type === 'String') return '"fixture"'
  if (type === 'Double') return '1.25'
  if (type === 'Int') return '1'
  if (type === 'Bool') return 'true'
  if (type === 'JSONValue') return '.string("fixture")'
  if (type.startsWith('[String:')) return '[:]'
  if (type.startsWith('[')) return '[]'
  throw new Error(`No generated round-trip sample for Swift type ${swiftTypeName}`)
}

function testConstruction(item, index) {
  const argumentsList = item.initFields
    .map(field => `${field.swiftName.replace(/^`|`$/g, '')}: ${sampleValue(field.swift)}`)
    .join(', ')
  const caseName = safeIdentifier(item.discriminator)
  const envelope = item.side === 'request' ? 'QVACRequest' : 'QVACResponse'
  return `        let value${index} = ${item.name}(${argumentsList})
        try assertRoundTrip(value${index})
        try assertRoundTrip(${envelope}.${caseName}(value${index}))`
}

const requestConstructions = emittedStructs.filter(item => item.side === 'request')
  .map(testConstruction).join('\n')
const responseConstructions = emittedStructs.filter(item => item.side === 'response')
  .map(testConstruction).join('\n')
const roundTripTest = `// QVACGeneratedRoundTripTests.generated.swift
//
// AUTO-GENERATED from the exact @qvac/sdk@${PROVENANCE.sdkVersion} contract/schema.json
// gitHead: ${PROVENANCE.source.commit}
// Exercises every concrete initializer plus both strict discriminated unions.
// DO NOT EDIT BY HAND.

import XCTest
@testable import QVACClient

final class QVACGeneratedRoundTripTests: XCTestCase {
    private func assertRoundTrip<T: Codable & Equatable>(
        _ value: T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let encoded = try JSONEncoder.qvac.encode(value)
        let decoded = try JSONDecoder().decode(T.self, from: encoded)
        XCTAssertEqual(decoded, value, file: file, line: line)
    }

    func test_all_${requests.length}_request_leaves_construct_encode_and_decode() throws {
${requestConstructions}
    }

    func test_all_${responses.length}_response_leaves_construct_encode_and_decode() throws {
${responseConstructions}
    }
}
`
mkdirSync(dirname(ROUNDTRIP_TEST_OUTPUT), { recursive: true })
writeFileSync(ROUNDTRIP_TEST_OUTPUT, roundTripTest)
console.log(`Wrote ${emittedStructs.length} concrete round-trip constructions → ${relative(REPO_ROOT, ROUNDTRIP_TEST_OUTPUT)}`)
