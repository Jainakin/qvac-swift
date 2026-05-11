import { z } from 'zod'
import { writeFileSync } from 'node:fs'
import { pathToFileURL } from 'node:url'
import { resolve } from 'node:path'

const commonUrl = pathToFileURL(resolve('./node_modules/@qvac/sdk/dist/schemas/common.js')).href
const common = await import(commonUrl)

const targets = [
  ['requestSchema',  common.requestSchema],
  ['responseSchema', common.responseSchema],
]

const opts = {
  // Inputs are what the Swift client sends over the wire — pre-transform.
  io: 'input',
  // Anything that can't be represented (transforms, instanceof, fns) becomes {}.
  unrepresentable: 'any',
  // Map Date → ISO 8601 string (the JSON-on-wire form).
  override: (ctx) => {
    const type = ctx.zodSchema._zod?.def?.type
    if (type === 'date') {
      ctx.jsonSchema.type = 'string'
      ctx.jsonSchema.format = 'date-time'
    }
  },
}

const summary = {}
for (const [name, schema] of targets) {
  try {
    const t0 = Date.now()
    const json = z.toJSONSchema(schema, opts)
    const ms = Date.now() - t0
    const text = JSON.stringify(json, null, 2)
    writeFileSync(`./${name}.json`, text)
    const branches = json.anyOf || json.oneOf || []
    const defs = json.$defs || json.definitions || {}

    // Walk every branch and see if there's a string-literal "type" discriminator.
    const discriminators = []
    for (const b of branches) {
      // resolve $ref if present
      let target = b
      if (b.$ref) {
        const key = b.$ref.replace(/^#\/\$defs\//, '').replace(/^#\/definitions\//, '')
        target = defs[key] || {}
      }
      const t = target.properties?.type
      if (t?.const) discriminators.push(t.const)
      else if (t?.enum?.length === 1) discriminators.push(t.enum[0])
      else discriminators.push(null)
    }

    summary[name] = {
      ok: true,
      ms,
      byteLen: text.length,
      branchCount: branches.length,
      defCount: Object.keys(defs).length,
      discriminatorsPresent: discriminators.filter(Boolean).length,
      discriminatorsMissing: discriminators.filter(d => d === null).length,
      discriminatorSamples: discriminators.filter(Boolean).slice(0, 12),
    }
  } catch (e) {
    summary[name] = { ok: false, error: String(e.message || e) }
  }
}

console.log(JSON.stringify(summary, null, 2))
writeFileSync('./spike2-summary.json', JSON.stringify(summary, null, 2))
