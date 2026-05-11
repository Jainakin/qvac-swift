import c from 'compact-encoding'
import { writeFileSync } from 'node:fs'

function enc(codec, value) {
  const buf = c.encode(codec, value)
  return Buffer.from(buf).toString('hex')
}

// Boundary values for uint varint (1/3/5/9 byte boundaries)
const uintCases = [
  { name: 'uint_0',           value: 0 },
  { name: 'uint_1',           value: 1 },
  { name: 'uint_252',         value: 0xfc },
  { name: 'uint_253',         value: 0xfd },
  { name: 'uint_65535',       value: 0xffff },
  { name: 'uint_65536',       value: 0x10000 },
  { name: 'uint_4294967295',  value: 0xffffffff },
  { name: 'uint_4294967296',  value: 4_294_967_296 },
]

// zigzag int boundary values
const intCases = [
  { name: 'int_0',     value: 0 },
  { name: 'int_-1',    value: -1 },
  { name: 'int_1',     value: 1 },
  { name: 'int_-100',  value: -100 },
  { name: 'int_100',   value: 100 },
  { name: 'int_-65536', value: -65536 },
]

const fixtures = {
  // uint varint
  ...Object.fromEntries(uintCases.map(({name, value}) => [name, { codec: 'uint', value, hex: enc(c.uint, value) }])),
  // zigzag int varint
  ...Object.fromEntries(intCases.map(({name, value}) => [name, { codec: 'int', value, hex: enc(c.int, value) }])),
  // fixed uint32 LE (the bare-rpc frame length prefix)
  'uint32_0':           { codec: 'uint32', value: 0,           hex: enc(c.uint32, 0) },
  'uint32_1':           { codec: 'uint32', value: 1,           hex: enc(c.uint32, 1) },
  'uint32_0xdeadbeef':  { codec: 'uint32', value: 0xdeadbeef,  hex: enc(c.uint32, 0xdeadbeef) },
  'uint32_max':         { codec: 'uint32', value: 0xffffffff,  hex: enc(c.uint32, 0xffffffff) },
  // bool
  'bool_true':  { codec: 'bool', value: true,  hex: enc(c.bool, true) },
  'bool_false': { codec: 'bool', value: false, hex: enc(c.bool, false) },
  // utf8 string (uint-length-prefixed)
  'utf8_empty': { codec: 'utf8', value: '',           hex: enc(c.utf8, '') },
  'utf8_hello': { codec: 'utf8', value: 'hello',      hex: enc(c.utf8, 'hello') },
  'utf8_emoji': { codec: 'utf8', value: 'hi 🌊 qvac', hex: enc(c.utf8, 'hi 🌊 qvac') },
  // raw buffer (uint-length-prefixed)
  'buffer_empty':    { codec: 'buffer', value: '',         hex: enc(c.buffer, Buffer.alloc(0)) },
  'buffer_3bytes':   { codec: 'buffer', value: '010203',   hex: enc(c.buffer, Buffer.from([1,2,3])) },
  'buffer_300bytes': { codec: 'buffer', value: 'aa'.repeat(300), hex: enc(c.buffer, Buffer.alloc(300, 0xaa)) },
  // optionalBuffer (0-byte length means null)
  'optBuffer_null':    { codec: 'optionalBuffer', value: null,       hex: enc(c.optionalBuffer, null) },
  'optBuffer_empty':   { codec: 'optionalBuffer', value: '',         hex: enc(c.optionalBuffer, Buffer.alloc(0)) }, // note: zero-length buffer encodes same as null
  'optBuffer_3bytes':  { codec: 'optionalBuffer', value: '0a0b0c',   hex: enc(c.optionalBuffer, Buffer.from([10,11,12])) },
}

// --- Now build a full bare-rpc REQUEST frame so we test the actual wire we care about
// Frame: [uint32 frame_len][uint type=1][uint id=42][uint command=7][uint stream=0][optBuffer data]
// Mirrors bare-rpc/lib/messages.js header.encode for a REQUEST with stream==0
{
  const t = { REQUEST: 1, RESPONSE: 2, STREAM: 3 }
  const data = Buffer.from(JSON.stringify({ type: '__init_config', config: {}, runtimeContext: { runtime: 'bare', platform: 'darwin' } }))
  // hand-build the body without the frame_len, then prepend frame_len
  const bodyState = c.state()
  c.uint.preencode(bodyState, t.REQUEST)
  c.uint.preencode(bodyState, 1)        // id
  c.uint.preencode(bodyState, 1)        // command (for __init_config, command id = 1)
  c.uint.preencode(bodyState, 0)        // stream flags = 0 → carries data
  c.optionalBuffer.preencode(bodyState, data)
  bodyState.buffer = Buffer.alloc(bodyState.end)
  c.uint.encode(bodyState, t.REQUEST)
  c.uint.encode(bodyState, 1)
  c.uint.encode(bodyState, 1)
  c.uint.encode(bodyState, 0)
  c.optionalBuffer.encode(bodyState, data)
  const body = bodyState.buffer

  const full = Buffer.alloc(4 + body.length)
  full.writeUInt32LE(body.length, 0)
  body.copy(full, 4)

  fixtures['frame_init_config_request'] = {
    codec: 'frame',
    description: 'Full bare-rpc REQUEST frame carrying __init_config payload',
    bodyLength: body.length,
    hex: full.toString('hex'),
    json: data.toString('utf8'),
  }
}

writeFileSync(new URL('./fixtures.json', import.meta.url), JSON.stringify(fixtures, null, 2))
console.log(`Wrote ${Object.keys(fixtures).length} fixtures`)
