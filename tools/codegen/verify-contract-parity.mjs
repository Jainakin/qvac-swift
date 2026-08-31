#!/usr/bin/env node

// Independently compare the published npm wire schemas with the authoritative
// release-source contract. Production generators consume only the source-side,
// hash-locked contract JSON. This verifier intentionally does not import npm's
// contract builder/exporter or trust npm's dist/contract output.

import { readFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { pathToFileURL, fileURLToPath } from 'node:url'
import { z } from 'zod'

const scriptDir = dirname(fileURLToPath(import.meta.url))
const sourceDir = resolve(process.env.QVAC_UPSTREAM_DIR ?? join(scriptDir, '.build/qvac-sdk'))
const sourceContract = join(sourceDir, 'packages/sdk/contract')
const publishedSdk = join(scriptDir, 'node_modules/@qvac/sdk')
const packageLock = JSON.parse(readFileSync(join(scriptDir, 'package-lock.json'), 'utf8'))
const installedZod = JSON.parse(readFileSync(join(scriptDir, 'node_modules/zod/package.json'), 'utf8'))

function fail(message) {
  throw new Error(`[contract] ${message}`)
}

function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical)
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical(value[key])]))
  }
  return value
}

function load(path) {
  return JSON.parse(readFileSync(path, 'utf8'))
}

function withoutGeneratorMetadata(value) {
  if (Array.isArray(value)) return value.map(withoutGeneratorMetadata)
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.entries(value)
      .filter(([key]) => key !== 'title' && key !== 'x-enum-varnames')
      .map(([key, child]) => [key, withoutGeneratorMetadata(child)]))
  }
  return value
}

function isObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

function mergeObjectSchemaParts(parts, context) {
  const properties = {}
  const required = []
  for (const part of parts) {
    if (part.type !== undefined && part.type !== 'object') {
      fail(`cannot flatten non-object allOf member for ${context}`)
    }
    for (const [key, value] of Object.entries(part.properties ?? {})) {
      if (key in properties && JSON.stringify(canonical(properties[key])) !== JSON.stringify(canonical(value))) {
        fail(`conflicting property ${key} while flattening ${context}`)
      }
      properties[key] = value
    }
    for (const key of part.required ?? []) if (!required.includes(key)) required.push(key)
  }
  return { type: 'object', properties, required }
}

function flattenAllOfWithUnion(json, context) {
  if (!Array.isArray(json.allOf)) return json
  const isUnion = member => isObject(member)
    && (Array.isArray(member.oneOf) || Array.isArray(member.anyOf))
  const unionMembers = json.allOf.filter(isUnion)
  const plainMembers = json.allOf.filter(member => !isUnion(member))
  if (unionMembers.length !== 1) fail(`unsupported allOf shape for ${context}`)
  const union = unionMembers[0]
  const key = Array.isArray(union.oneOf) ? 'oneOf' : 'anyOf'
  const output = { ...json }
  delete output.allOf
  output[key] = union[key].map(arm => mergeObjectSchemaParts([...plainMembers, arm], context))
  return output
}

function collapseSingleMemberUnions(node) {
  if (!isObject(node)) return node
  if (isObject(node.properties)) {
    for (const key of Object.keys(node.properties)) {
      node.properties[key] = collapseSingleMemberUnions(node.properties[key])
    }
  }
  if (node.items !== undefined) node.items = collapseSingleMemberUnions(node.items)
  if (isObject(node.additionalProperties)) {
    node.additionalProperties = collapseSingleMemberUnions(node.additionalProperties)
  }
  const unionKey = Array.isArray(node.oneOf) ? 'oneOf' : Array.isArray(node.anyOf) ? 'anyOf' : undefined
  if (!unionKey) return node
  const arms = node[unionKey].map(collapseSingleMemberUnions)
  if (arms.length !== 1) {
    node[unionKey] = arms
    return node
  }
  const wrapper = { ...node }
  delete wrapper[unionKey]
  return isObject(arms[0]) ? { ...wrapper, ...arms[0] } : Object.keys(wrapper).length > 0 ? wrapper : arms[0]
}

function toWireJSONSchema(schema, io, context) {
  const json = z.toJSONSchema(schema, {
    target: 'draft-2020-12',
    io,
    unrepresentable: 'any',
  })
  delete json.$schema
  return collapseSingleMemberUnions(flattenAllOfWithUnion(json, context))
}

function wireTypesOf(schema) {
  if (schema instanceof z.ZodObject) {
    const typeField = schema.shape.type
    if (typeField instanceof z.ZodLiteral) {
      return [...typeField.values].filter(value => typeof value === 'string')
    }
    return []
  }
  if (schema instanceof z.ZodUnion) return [...new Set(schema.options.flatMap(wireTypesOf))]
  if (schema instanceof z.ZodPipe) return wireTypesOf(schema.in)
  if (schema instanceof z.ZodIntersection) {
    return [...new Set([...wireTypesOf(schema.def.left), ...wireTypesOf(schema.def.right)])]
  }
  return []
}

function collectByWireType(options, side) {
  const result = new Map()
  for (const [index, schema] of options.entries()) {
    const types = wireTypesOf(schema)
    if (types.length !== 1) fail(`${side} union member ${index} has ${types.length} wire discriminators`)
    if (result.has(types[0])) fail(`duplicate ${side} schema for ${types[0]}`)
    result.set(types[0], schema)
  }
  return result
}

const lockedZod = packageLock.packages?.['node_modules/zod']?.version
if (installedZod.version !== lockedZod || installedZod.version !== '4.4.3') {
  fail(`schema parity requires exact Zod 4.4.3; lock=${lockedZod}, installed=${installedZod.version}`)
}

const common = await import(pathToFileURL(join(publishedSdk, 'dist/schemas/common.js')))
const publishedShapes = (await import(
  pathToFileURL(join(publishedSdk, 'dist/server/rpc/method-shapes.js'))
)).methodShapes
const publishedErrors = {
  server: (await import(pathToFileURL(join(publishedSdk, 'dist/schemas/sdk-errors-server.js')))).SDK_SERVER_ERROR_CODES,
  client: (await import(pathToFileURL(join(publishedSdk, 'dist/schemas/sdk-errors-client.js')))).SDK_CLIENT_ERROR_CODES,
  registry: (await import(pathToFileURL(join(publishedSdk, 'dist/schemas/sdk-errors-registry.js')))).REGISTRY_ERROR_CODES,
}

if (!Array.isArray(common.requestSchema?.options) || !Array.isArray(common.responseSchema?.options)) {
  fail('published common.js does not export inspectable request/response unions')
}

const sourceSchema = load(join(sourceContract, 'schema.json'))
const sourceManifest = load(join(sourceContract, 'manifest.json'))
const sourceErrors = load(join(sourceContract, 'error-codes.json'))
const sourceModelTypeMaps = load(join(sourceContract, 'model-type-maps.json'))
const publishedModelTypes = await import(pathToFileURL(join(publishedSdk, 'dist/schemas/model-types.js')))
const requestByType = collectByWireType(common.requestSchema.options, 'request')
const responseByType = collectByWireType(common.responseSchema.options, 'response')
const methods = new Map(sourceManifest.methods.map(method => [method.name, method]))
const callShape = { reply: 'request-reply', stream: 'server-stream', duplex: 'duplex' }

const requestTypes = [...requestByType.keys()].sort()
const methodTypes = [...methods.keys()].sort()
if (JSON.stringify(requestTypes) !== JSON.stringify(methodTypes)) {
  fail(`npm request method set differs: npm=${requestTypes.join(',')} source=${methodTypes.join(',')}`)
}
if (JSON.stringify(Object.keys(publishedShapes).sort()) !== JSON.stringify(methodTypes)) {
  fail('published method-shapes set differs from the pinned manifest')
}

for (const name of methodTypes) {
  const expectedShape = callShape[publishedShapes[name]]
  if (!expectedShape || methods.get(name).callShape !== expectedShape) {
    fail(`${name} call shape differs: npm=${expectedShape ?? publishedShapes[name]} source=${methods.get(name).callShape}`)
  }
}

const progressResponseTypes = new Set(sourceManifest.methods.flatMap(method => {
  const match = method.progress?.responseSchema?.match(/\/\$defs\/([^/]+)\.response$/)
  return match ? [match[1]] : []
}))
const allowedResponseTypes = new Set([...methodTypes, ...progressResponseTypes, 'error'])
const npmResponseTypes = [...responseByType.keys()].sort()
if (npmResponseTypes.some(type => !allowedResponseTypes.has(type))
    || [...allowedResponseTypes].some(type => !responseByType.has(type))) {
  fail(`npm response method set differs: npm=${npmResponseTypes.join(',')} source=${[...allowedResponseTypes].sort().join(',')}`)
}

for (const [type, schema] of requestByType) {
  const npmJSON = canonical(withoutGeneratorMetadata(toWireJSONSchema(schema, 'input', `${type}.request`)))
  const sourceJSON = canonical(withoutGeneratorMetadata(sourceSchema.$defs[`${type}.request`]))
  if (JSON.stringify(npmJSON) !== JSON.stringify(sourceJSON)) {
    fail(`normalized npm request schema differs for ${type}`)
  }
}
for (const [type, schema] of responseByType) {
  const npmJSON = canonical(withoutGeneratorMetadata(toWireJSONSchema(schema, 'output', `${type}.response`)))
  const sourceJSON = canonical(withoutGeneratorMetadata(sourceSchema.$defs[`${type}.response`]))
  if (JSON.stringify(npmJSON) !== JSON.stringify(sourceJSON)) {
    fail(`normalized npm response schema differs for ${type}`)
  }
}

if (JSON.stringify(canonical(publishedErrors)) !== JSON.stringify(canonical(sourceErrors))) {
  fail('published SDK error maps differ from pinned contract/error-codes.json')
}
if (JSON.stringify(canonical(publishedModelTypes.ModelTypeAliases))
    !== JSON.stringify(canonical(sourceModelTypeMaps.aliasToCanonical))) {
  fail('published SDK alias normalization differs from pinned contract/model-type-maps.json')
}

const errorCount = Object.values(sourceErrors)
  .reduce((count, group) => count + Object.keys(group).length, 0)
console.log(`[contract] npm/source parity verified independently: ${methodTypes.length} methods, ${npmResponseTypes.length} response types, ${errorCount} error codes, ${Object.keys(sourceModelTypeMaps.aliasToCanonical).length} model aliases`)
console.log(`[contract] exact parity toolchain: Zod ${installedZod.version}`)
console.log('[contract] source-only metadata (progress conditions, constants, engine/legacy model maps, models) is SHA-256 locked; it is not claimed to be reconstructable from npm common.js')
