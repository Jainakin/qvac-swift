// Identify the 6 request branches that collapse to empty {} under z.toJSONSchema(io: 'input', unrepresentable: 'any')
// For each one, find which Zod schema is the source.

import { z } from 'zod'
import { writeFileSync } from 'node:fs'
import { pathToFileURL } from 'node:url'
import { resolve } from 'node:path'

const commonUrl = pathToFileURL('/Users/hardik/Projects/qvac-swift/spike-js/node_modules/@qvac/sdk/dist/schemas/common.js').href
const common = await import(commonUrl)

const opts = {
  io: 'input',
  unrepresentable: 'any',
  override: (ctx) => {
    if (ctx.zodSchema._zod?.def?.type === 'date') {
      ctx.jsonSchema.type = 'string'
      ctx.jsonSchema.format = 'date-time'
    }
  },
}

// requestSchema is a z.union — its options array tells us each branch's identity.
const requestZ = common.requestSchema
console.log('requestSchema type:', requestZ._zod?.def?.type)
const options = requestZ._zod?.def?.options || []
console.log(`Found ${options.length} options in requestSchema union`)

console.log('\n=== walking each branch ===')
const empties = []
for (let i = 0; i < options.length; i++) {
  const branch = options[i]
  const branchType = branch._zod?.def?.type
  let typeLiteral = null
  let hasTransformAtTop = false

  // try to find the "type: z.literal(X)" discriminator
  // Most branches are z.object({ type: z.literal("..."), ... }), possibly wrapped in a transform.
  let inner = branch
  while (inner) {
    const d = inner._zod?.def
    if (!d) break
    if (d.type === 'pipe') {
      // pipe wraps a transform — keep walking
      hasTransformAtTop = true
      inner = d.in  // the source side
    } else if (d.type === 'object') {
      // look for properties.type.def.value
      const shape = d.shape || (typeof d.shape === 'function' ? d.shape() : null)
      if (shape && shape.type && shape.type._zod?.def?.type === 'literal') {
        typeLiteral = shape.type._zod.def.values?.[0] ?? shape.type._zod.def.value
      }
      break
    } else if (d.type === 'union' || d.type === 'discriminatedUnion') {
      typeLiteral = `<${d.type}>`
      break
    } else {
      break
    }
  }

  let jsonSchema
  try {
    jsonSchema = z.toJSONSchema(branch, opts)
  } catch (e) {
    jsonSchema = { ERROR: String(e.message) }
  }

  const topKeys = Object.keys(jsonSchema.properties || {})
  const isEmpty = topKeys.length === 0
  console.log(`#${i}: branchType=${branchType} typeLiteral=${typeLiteral} hasTransformAtTop=${hasTransformAtTop} jsonKeys=[${topKeys.join(',')}] ${isEmpty ? '⚠ EMPTY' : ''}`)
  if (isEmpty) {
    empties.push({ index: i, branchType, typeLiteral, hasTransformAtTop, jsonSchema })
  }
}

console.log(`\n=== ${empties.length} empty branches ===`)
console.log(JSON.stringify(empties, null, 2).slice(0, 2000))

// Save for later
writeFileSync('./empty-branches.json', JSON.stringify(empties, null, 2))
