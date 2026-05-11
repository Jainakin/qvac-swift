import { readFileSync, writeFileSync } from 'node:fs'

const empties = JSON.parse(readFileSync('/Users/hardik/Projects/qvac-swift/spike-js/empty-branches.json', 'utf8'))

const report = []
for (const e of empties) {
  // Recursively extract every `type: { const: X }` discriminator out of the (possibly nested) anyOf/oneOf tree
  const found = []
  function walk(node) {
    if (!node || typeof node !== 'object') return
    const t = node?.properties?.type
    if (t?.const) found.push(t.const)
    for (const arr of [node.anyOf, node.oneOf, node.allOf]) {
      if (Array.isArray(arr)) arr.forEach(walk)
    }
  }
  walk(e.jsonSchema)
  report.push({
    index: e.index,
    branchType: e.branchType,
    discriminatorsInside: found,
    totalLeaves: found.length,
    sample: JSON.stringify(e.jsonSchema).slice(0, 400) + '...',
  })
}

console.log(JSON.stringify(report, null, 2))
writeFileSync('/Users/hardik/Projects/qvac-swift/spike-js/empty-branches-decoded.json', JSON.stringify(report, null, 2))
