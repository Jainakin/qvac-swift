// Walk the FULL requestSchema JSON Schema and find any properties that have NO type info
// (i.e. collapsed to `{}` by unrepresentable: 'any'). These are the real transform victims.
import { readFileSync, writeFileSync } from 'node:fs'

const schema = JSON.parse(readFileSync('/Users/hardik/Projects/qvac-swift/spike-js/requestSchema.json', 'utf8'))

const collapsed = []

function walk(node, path = []) {
  if (!node || typeof node !== 'object') return
  // A `{}` is an object with no own type-defining keys
  const isEmptyObject =
    typeof node === 'object' &&
    !Array.isArray(node) &&
    Object.keys(node).length === 0
  if (isEmptyObject) {
    collapsed.push(path.join('.'))
    return
  }
  if (node.properties) {
    for (const [k, v] of Object.entries(node.properties)) walk(v, [...path, k])
  }
  if (Array.isArray(node.anyOf)) node.anyOf.forEach((c, i) => walk(c, [...path, `anyOf[${i}]`]))
  if (Array.isArray(node.oneOf)) node.oneOf.forEach((c, i) => walk(c, [...path, `oneOf[${i}]`]))
  if (Array.isArray(node.allOf)) node.allOf.forEach((c, i) => walk(c, [...path, `allOf[${i}]`]))
  if (node.items) walk(node.items, [...path, 'items'])
  if (node.additionalProperties && typeof node.additionalProperties === 'object') {
    walk(node.additionalProperties, [...path, 'additionalProperties'])
  }
}
walk(schema)

console.log(`Found ${collapsed.length} collapsed-to-{} fields in requestSchema`)
collapsed.slice(0, 30).forEach((p, i) => console.log(`  #${i}: ${p}`))
writeFileSync('/Users/hardik/Projects/qvac-swift/spike-js/collapsed-fields.json', JSON.stringify(collapsed, null, 2))
