#!/usr/bin/env node

import { readFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const scriptDir = dirname(fileURLToPath(import.meta.url))
const repoRoot = resolve(scriptDir, '..', '..')
const upstreamDir = resolve(process.env.QVAC_UPSTREAM_DIR ?? resolve(scriptDir, '.build/qvac-sdk'))
const generatedDir = resolve(process.env.QVAC_GENERATED_DIR
  ?? resolve(repoRoot, 'Sources/QVACClient/Generated'))
const manifest = JSON.parse(readFileSync(resolve(upstreamDir, 'packages/sdk/contract/manifest.json'), 'utf8'))
const schema = JSON.parse(readFileSync(resolve(upstreamDir, 'packages/sdk/contract/schema.json'), 'utf8'))
const api = readFileSync(resolve(generatedDir, 'QVACSDKContract.generated.swift'), 'utf8')
const types = readFileSync(resolve(generatedDir, 'QVACTypes.generated.swift'), 'utf8')
const errors = readFileSync(resolve(generatedDir, 'QVACErrorCodes.generated.swift'), 'utf8')
const modelTypeContract = readFileSync(resolve(generatedDir, 'QVACModelTypeContract.generated.swift'), 'utf8')
const modelTypeMaps = JSON.parse(readFileSync(
  resolve(upstreamDir, 'packages/sdk/contract/model-type-maps.json'),
  'utf8',
))
const generatedTestDir = resolve(process.env.QVAC_GENERATED_TEST_DIR
  ?? resolve(repoRoot, 'Tests/QVACClientUnitTests'))
const roundTrips = readFileSync(resolve(generatedTestDir, 'QVACGeneratedRoundTripTests.generated.swift'), 'utf8')
const modelTypeTests = readFileSync(resolve(generatedTestDir, 'QVACModelTypeContractTests.generated.swift'), 'utf8')

for (const [group, entries] of Object.entries(modelTypeMaps)) {
  if (!modelTypeContract.includes(`static let ${group}: [String: String]`)) {
    throw new Error(`[generated] missing model-type map ${group}`)
  }
  for (const [key, value] of Object.entries(entries)) {
    const entry = `${JSON.stringify(key)}: ${JSON.stringify(value)}`
    if (!modelTypeContract.includes(entry) || !modelTypeTests.includes(entry)) {
      throw new Error(`[generated] missing model-type map entry ${group}.${key}`)
    }
  }
}
if (!modelTypeContract.includes('aliasToCanonical[input] ?? input')) {
  throw new Error('[generated] model-type normalizer must preserve canonical and custom identifiers')
}

for (const method of manifest.methods) {
  const callShape = {
    'request-reply': 'requestReply',
    'server-stream': 'serverStream',
    duplex: 'duplex',
  }[method.callShape]
  const descriptor = `.init(name: "${method.name}", callShape: .${callShape},`
  if (!api.includes(descriptor)) throw new Error(`[generated] missing descriptor: ${descriptor}`)
  const requestCase = `case ${method.name}(${method.name[0].toUpperCase() + method.name.slice(1)}Request)`
  if (!types.includes(requestCase)) throw new Error(`[generated] missing request route: ${requestCase}`)
  if (method.progress && !api.includes(`condition: "${method.progress.condition}"`)) {
    throw new Error(`[generated] missing progress condition for ${method.name}`)
  }
  const requestTitle = schema.$defs[`${method.name}.request`]?.title
  const exactSignature = `func wire${requestTitle.slice(0, -'Request'.length)}(`
  if (!api.includes(exactSignature)) throw new Error(`[generated] missing exact method signature: ${exactSignature}`)
  const exactMethod = api.slice(api.indexOf(exactSignature), api.indexOf(exactSignature) + 500)
  if (method.callShape === 'server-stream') {
    const responseTitle = schema.$defs[`${method.name}.response`]?.title
    if (!exactMethod.includes(`-> QVACResponseStream<${responseTitle}>`)) {
      throw new Error(`[generated] ${method.name} must expose a cancellation-aware response stream`)
    }
  }
  if (method.progress && !api.includes(`${exactSignature.slice(0, -1)}Progress(`)) {
    throw new Error(`[generated] missing exact progress signature for ${method.name}`)
  }
  if (method.progress) {
    const progressSignature = `${exactSignature.slice(0, -1)}Progress(`
    const progressMethod = api.slice(api.indexOf(progressSignature), api.indexOf(progressSignature) + 300)
    if (!progressMethod.includes('-> QVACResponseStream<QVACResponse>')) {
      throw new Error(`[generated] ${method.name} progress must expose a cancellation-aware response stream`)
    }
  }
}

for (const required of [
  'func wireRequestReply(',
  'func wireProgressStream(',
  'func wireServerStream(',
  'func wireDuplex(',
  ') async throws -> QVACResponseStream<QVACResponse>',
  'guard method.callShape == expected else',
  'usesConditionalProgressTransport',
  'return Self.pullMap(source) { response in',
]) {
  if (!api.includes(required)) throw new Error(`[generated] generic routing guard missing: ${required}`)
}

if (/AsyncThrowingStream/.test(api)) {
  throw new Error('[generated] public wire streams must use cancellation-aware QVACResponseStream')
}
if (/Self\.makeStream\(|Task<Void, Never>/.test(api)) {
  throw new Error('[generated] exact adapters must be pull-driven and add no eager task/buffer')
}
if (/public var type: String/.test(types) || /public init\(type: String/.test(types)) {
  throw new Error('[generated] wire discriminators must not be caller-mutable or initializer-controlled')
}
if (/case unknown\(type: String, payload: JSONValue\)/.test(types)) {
  throw new Error('[generated] pinned request/response unions must reject unknown discriminators')
}

function structBlocks(source) {
  const blocks = []
  const pattern = /^public struct ([A-Za-z0-9_]+): Codable, Sendable, Equatable \{/gm
  for (const match of source.matchAll(pattern)) {
    let depth = 0
    let end = match.index
    for (; end < source.length; end++) {
      if (source[end] === '{') depth++
      if (source[end] === '}' && --depth === 0) { end++; break }
    }
    blocks.push([match[1], source.slice(match.index, end)])
  }
  return blocks
}

const concreteStructs = structBlocks(types)
if (concreteStructs.length !== 82) {
  throw new Error(`[generated] expected 82 concrete request/response structs, found ${concreteStructs.length}`)
}
for (const [name, block] of concreteStructs) {
  const properties = [...block.matchAll(/^    public (?:let|var) (`?[A-Za-z_][A-Za-z0-9_]*`?):/gm)]
    .map(match => match[1])
  const initializer = block.match(/\n    public init\(([^)]*)\) \{([\s\S]*?)\n    \}/)
  if (!initializer) throw new Error(`[generated] ${name} has no public memberwise initializer`)
  const [params, body] = initializer.slice(1)
  for (const property of properties) {
    if (!body.includes(`self.${property} = `)) {
      throw new Error(`[generated] ${name} initializer does not assign ${property}`)
    }
    if (property !== 'type' && !params.includes(`${property}:`)) {
      throw new Error(`[generated] ${name} initializer omits ${property}`)
    }
  }
  if (!roundTrips.includes(`= ${name}(`)) {
    throw new Error(`[generated] ${name} is missing from generated round-trip construction tests`)
  }
}
if (!roundTrips.includes(`test_all_${manifest.methods.length}_request_leaves_construct_encode_and_decode`)
    || !roundTrips.includes('test_all_43_response_leaves_construct_encode_and_decode')) {
  throw new Error('[generated] strict union round-trip suite has unexpected request/response coverage')
}
for (const required of [
  'public static let discriminator =',
  'guard decodedType == Self.discriminator else',
  'Unknown QVAC request discriminator',
  'Unknown QVAC response discriminator',
]) {
  if (!types.includes(required)) throw new Error(`[generated] discriminator invariant missing: ${required}`)
}

for (const [name, content] of [['api', api], ['types', types], ['errors', errors], ['model-types', modelTypeContract]]) {
  const header = content.split('\n').slice(0, 12).join('\n')
  if (/\/(Users|private\/tmp|var\/folders|tmp)\//.test(header)) {
    throw new Error(`[generated] ${name} header contains a machine-local path`)
  }
}

console.log(`[generated] verified ${manifest.methods.length} callable routes, progress guards, and portable headers`)
