// generate-types.mjs — emit Sources/QVACClient/Generated/QVACTypes.generated.swift
//
// Pipeline: read QVAC SDK's Zod v4 schemas → z.toJSONSchema(…) with the options validated in
// docs/spike-validations.md (Spike-A) → emit Swift `Codable` types for every leaf branch of
// `requestSchema` and `responseSchema`, plus the discriminated-union wrappers `QVACRequest`
// and `QVACResponse`.
//
// Idempotent: re-running produces no diff against the checked-in output for an unchanged input.

import { z } from 'zod'
import { writeFileSync, mkdirSync, readFileSync } from 'node:fs'
import { dirname, resolve, relative } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const REPO_ROOT = resolve(__dirname, '..', '..')
const COMMON_JS = process.env.QVAC_COMMON_JS
  ?? resolve(REPO_ROOT, 'spike-js/node_modules/@qvac/sdk/dist/schemas/common.js')
const OUTPUT = resolve(REPO_ROOT, 'Sources/QVACClient/Generated/QVACTypes.generated.swift')
const OVERRIDES_PATH = resolve(__dirname, 'overrides.json')

const overrides = JSON.parse(readFileSync(OVERRIDES_PATH, 'utf8'))

// ------------------------------------------------------------------------------------
// Load schemas
// ------------------------------------------------------------------------------------

const common = await import(pathToFileURL(COMMON_JS).href)

// Options validated in Spike-A (docs/spike-validations.md):
//   io: 'input'              → produce the WIRE shape (pre-transform) since the Swift client
//                              SENDS this — the server applies transforms after parse.
//   unrepresentable: 'any'   → fields backed by runtime-only Zod types (z.date, transforms,
//                              instanceof Function, etc.) become {} which we map to JSONValue.
//   override (date)          → map Date → ISO-8601 string.
const toJsonSchemaOpts = {
  io: 'input',
  unrepresentable: 'any',
  override: (ctx) => {
    const type = ctx.zodSchema._zod?.def?.type
    if (type === 'date') {
      ctx.jsonSchema.type = 'string'
      ctx.jsonSchema.format = 'date-time'
    }
  },
}

const requestSchema  = z.toJSONSchema(common.requestSchema,  toJsonSchemaOpts)
const responseSchema = z.toJSONSchema(common.responseSchema, toJsonSchemaOpts)

// ------------------------------------------------------------------------------------
// §27 auto-callback detection
//
// JS-only callback fields like `onProgress`/`logger` show up as `z.function(...)` in the
// Zod schemas. They live entirely in the client process and never travel on the wire,
// so the generated Swift struct must NOT contain them.
//
// The JSON Schema output renders them as `{}` (because of `unrepresentable: 'any'`),
// which is indistinguishable from a legitimate `JSONValue` payload field at that
// level. So instead of guessing from JSON Schema, we introspect the Zod schema tree
// directly here and build a `{side/discriminator -> [fieldNames]}` map that augments
// the manual `overrides.omitFields`.
// ------------------------------------------------------------------------------------

/// Unwrap an optional / nullable / default Zod wrapper to find the innermost type def.
function innermostZodDef(node) {
  let cur = node?._zod?.def
  // Wrappers expose their inner type at .innerType (.def.innerType holds another Zod node).
  while (cur && ['optional', 'nullable', 'default', 'readonly', 'pipe', 'lazy'].includes(cur.type)) {
    const inner = cur.innerType ?? cur.in ?? cur.out
    if (!inner) break
    cur = inner?._zod?.def ?? null
  }
  return cur
}

/// Heuristic for "this looks like a non-wire callback / control field": name follows
/// the JS SDK convention for callbacks (`onProgress`, `onError`, …) or signal/abort/
/// logger handles. Combined with the type check below, this gives us a reliable filter.
const CALLBACK_NAME_PATTERNS = [
  /^on[A-Z]/,        // onProgress, onError, onChunk, …
  /^logger$/,
  /^signal$/,
  /^abortSignal$/,
  /^abortController$/,
  /^controller$/,
]

/// Walk a Zod object and return the list of property keys that look like JS-only
/// callback / control handles and therefore must NOT appear in the wire-level Swift
/// struct. Two ways to qualify:
///   1. Innermost Zod type is `function` / `custom` — definitive.
///   2. Innermost Zod type is `unknown` AND the field name matches a callback naming
///      convention. `z.unknown()` is the de-facto convention in @qvac/sdk for typing
///      JS-side function handles that don't have a wire representation.
function callbackFieldsOfObject(objZod) {
  const def = objZod?._zod?.def
  if (!def || def.type !== 'object') return []
  const shape = (typeof def.shape === 'function') ? def.shape() : def.shape
  if (!shape) return []
  const out = []
  for (const [key, child] of Object.entries(shape)) {
    const inner = innermostZodDef(child)
    const t = inner?.type
    if (t === 'function' || t === 'custom') {
      out.push(key)
      continue
    }
    if (t === 'unknown' && CALLBACK_NAME_PATTERNS.some(re => re.test(key))) {
      out.push(key)
    }
  }
  return out
}

/// Walk a Zod union (discriminatedUnion or union) and return
/// `{ [discriminator]: [callbackFieldNames] }`.
function discoverCallbackFields(unionZod) {
  const def = unionZod?._zod?.def
  if (!def) return {}
  const options = def.options ?? []
  const result = {}
  for (const opt of options) {
    // opt may itself be wrapped (intersection of base + variant).
    const queue = [opt]
    while (queue.length) {
      const cur = queue.shift()
      const curDef = cur?._zod?.def
      if (!curDef) continue
      if (curDef.type === 'object') {
        const shape = (typeof curDef.shape === 'function') ? curDef.shape() : curDef.shape
        const typeNode = shape?.type
        const discriminator = typeNode?._zod?.def?.values?.[0]
                          ?? typeNode?._zod?.def?.value
        if (discriminator) {
          const fields = callbackFieldsOfObject(cur)
          if (fields.length) {
            result[discriminator] = [...(result[discriminator] ?? []), ...fields]
          }
        }
      }
      if (curDef.type === 'intersection') {
        if (curDef.left)  queue.push(curDef.left)
        if (curDef.right) queue.push(curDef.right)
      }
      if (curDef.type === 'union' || curDef.type === 'discriminatedUnion') {
        for (const o of (curDef.options ?? [])) queue.push(o)
      }
    }
  }
  return result
}

const autoOmit = {
  request:  discoverCallbackFields(common.requestSchema),
  response: discoverCallbackFields(common.responseSchema),
}

// ------------------------------------------------------------------------------------
// Walk the schema tree and collect ALL leaf object branches.
//
// "Leaf branch" = a JSON Schema node of `type: "object"` with a `type: { const: X }`
// discriminator. The walker recurses into anyOf / oneOf / allOf to find them.
// ------------------------------------------------------------------------------------

function isObjectLeaf(node) {
  return node?.type === 'object' && node?.properties?.type?.const !== undefined
}

/// Collect every leaf (object-with-`type`-discriminator) reachable from `schema`.
/// Handles the QVAC-specific `allOf: [{type-discriminator}, {oneOf: [shape1, shape2]}]`
/// pattern by lifting the parent discriminator into each shape and merging properties.
function collectLeaves(schema, side /* 'request' | 'response' */) {
  const out = []
  function walk(node, ancestors = [], inheritedDiscriminator = null) {
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
      for (const branch of node.allOf) {
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
            for (const variant of sibling[arr]) {
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
        properties[k] = v
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
  props.sort(([a], [b]) => (a === 'type' ? -1 : b === 'type' ? 1 : a.localeCompare(b)))

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
    lines.push(`${doc}\n    public var ${swiftName}: ${swift}`)
    let defaultValue
    if (propName === 'type' && prop?.const !== undefined) {
      if (typeof prop.const === 'string') defaultValue = JSON.stringify(prop.const)
    }
    if (optional && defaultValue === undefined) defaultValue = 'nil'
    fields.push({ swiftName, propName, swift, optional, defaultValue })
  }

  // Initializer parameter order: `type` first (always has a default), then REQUIRED
  // fields (no default), then optional fields (default = nil). This way callers can
  // skip optional args without worrying about positional ordering.
  const initFields = [
    ...fields.filter(f => f.propName === 'type'),
    ...fields.filter(f => f.propName !== 'type' && f.defaultValue === undefined),
    ...fields.filter(f => f.propName !== 'type' && f.defaultValue !== undefined),
  ]
  const initParams = initFields.map(f =>
    `${f.swiftName}: ${f.swift}${f.defaultValue !== undefined ? ' = ' + f.defaultValue : ''}`
  ).join(', ')
  const initBody = initFields.map(f => `        self.${f.swiftName} = ${f.swiftName}`).join('\n')
  lines.push(`\n    public init(${initParams}) {`)
  lines.push(initBody)
  lines.push('    }')

  // CodingKeys, only when any swiftName differs from propName (i.e. needed escaping or rename).
  const hasRename = fields.some(f => f.swiftName.replace(/^`|`$/g, '') !== f.propName)
  if (hasRename) {
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
  }

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
  // Unknown branch lets us forward-decode unknown types gracefully.
  lines.push(`    case unknown(type: String, payload: JSONValue)`)

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
  lines.push('            self = .unknown(type: t, payload: try JSONValue(from: decoder))')
  lines.push('        }')
  lines.push('    }')
  lines.push('\n    public func encode(to encoder: Encoder) throws {')
  lines.push('        switch self {')
  for (const { discriminator } of leaves) {
    const caseName = safeIdentifier(discriminator)
    lines.push(`        case .${caseName}(let v): try v.encode(to: encoder)`)
  }
  lines.push('        case .unknown(_, let payload): try payload.encode(to: encoder)')
  lines.push('        }')
  lines.push('    }')
  lines.push('\n    public var discriminator: String {')
  lines.push('        switch self {')
  for (const { discriminator } of leaves) {
    const caseName = safeIdentifier(discriminator)
    lines.push(`        case .${caseName}: return "${discriminator}"`)
  }
  lines.push('        case .unknown(let t, _): return t')
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
//   ${relative(REPO_ROOT, COMMON_JS)}
// DO NOT EDIT BY HAND.
//
// Coverage: ${requests.length} request types, ${responses.length} response types
// (deduplicated from ${requestLeaves.length} + ${responseLeaves.length} JSON-Schema leaves).

import Foundation

`

const parts = [header]
for (const { discriminator, node } of [...requests].sort((a,b)=>a.discriminator.localeCompare(b.discriminator))) {
  parts.push(emitStruct(discriminator, node, 'request'))
}
for (const { discriminator, node } of [...responses].sort((a,b)=>a.discriminator.localeCompare(b.discriminator))) {
  parts.push(emitStruct(discriminator, node, 'response'))
}
parts.push(emitUnion('QVACRequest',  requests,  'request'))
parts.push(emitUnion('QVACResponse', responses, 'response'))

mkdirSync(dirname(OUTPUT), { recursive: true })
writeFileSync(OUTPUT, parts.join('\n\n') + '\n')
console.log(`Wrote ${requests.length} request + ${responses.length} response types → ${relative(REPO_ROOT, OUTPUT)}`)
