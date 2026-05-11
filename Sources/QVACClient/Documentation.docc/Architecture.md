#  Architecture

How QVACClient connects Swift code to QVAC's Bare worker.

## Two transport models

```
┌──────────────────────────────────────────────────────────┐
│ Consumer iOS / macOS app                                 │
│  import QVACClient                                       │
│  let client = try await QVACClient(...)                  │
│  for try await tok in client.completion(...).tokenStream │
└──────────────────────────────────────────────────────────┘
                          │
        ┌─────────────────┴────────────────┐
        ▼                                  ▼
   macOS path                          iOS path
   subprocess                          in-process
   ──────────                          ──────────
   bare worker.js (child proc)         BareKit worklet (pthread)
   UnixDomainSocketTransport            BareIPCTransport
   `Process` API + AF_UNIX socket       BareKit.xcframework + BareIPC
```

Both transports expose the same byte-stream contract (``BareTransport``), so the
RPC client doesn't care which platform it's on.

## Wire protocol

Two stacked layers:

### Outer — bare-rpc

Length-prefixed binary framing. Each frame:

```
[uint32 LE frame_len]
[varuint type]                     1=REQUEST, 2=RESPONSE, 3=STREAM
[varuint id]                       message id (auto-allocated)
[per-type fields]
[varuint dataLen?][raw data bytes?]
```

Stream flags are a bitmask: `OPEN=0x1, CLOSE=0x2, PAUSE=0x4, RESUME=0x8, DATA=0x10,
END=0x20, DESTROY=0x40, ERROR=0x80, REQUEST=0x100, RESPONSE=0x200`. Backpressure via
`PAUSE`/`RESUME`. The Swift codec is wire-compatible with Holepunch's reference
implementation, validated byte-for-byte against fixtures.

### Inner — JSON / NDJSON

Each frame's data payload carries one JSON object (for single-shot) or one JSON object
per newline (for streaming responses). The `"type"` field discriminates between message
shapes: `loadModel`, `completionStream`, `transcribe`, etc.

## Init handshake

The first message on a new connection is `__init_config`. The Swift client sends it
automatically as part of `init(configuration:...)`:

```
{
  "type": "__init_config",
  "config": <opaque user config or null>,
  "runtimeContext": { "runtime": "bare"|"node", "platform": "ios"|"darwin"|... }
}
```

The worker stores the config in memory; subsequent attempts to override it return
``QVACErrorCode/configAlreadySet``.

## Three RPC primitives

QVACClient exposes three transport primitives that compose into every public method:

| Primitive | Pattern | Used by |
|---|---|---|
| `send`   | 1 request → 1 response (JSON) | heartbeat, embed, cancel, unloadModel, downloadAsset (blocking) |
| `stream` | 1 request → N responses (NDJSON) | completion, transcribe, translate, ocr, diffusion, textToSpeech, loadModelStreaming |
| `duplex` | bidirectional (client writes audio, server streams transcripts) | transcribeStream, textToSpeechStream |

## Error model

Every wire-level error is decoded into ``QVACError``. The numeric code is preserved
as ``QVACErrorCode`` (e.g. `52200` = `modelLoadFailed`), and the error is categorized
by ``QVACErrorCategory`` (e.g. `.modelLoading`, `.rag`, `.download`).

Server-side errors travel through the response stream as ordinary NDJSON frames with
`"type": "error"` — not bare-rpc-level ERROR frames. The Swift client handles both.

## Multiplexing

A single QVACClient instance can have many concurrent in-flight operations. Each gets
a unique bare-rpc message id; responses route back via an `id`-keyed in-flight table
inside the codec. There's no head-of-line blocking — a slow `completion` doesn't
prevent a quick `heartbeat` from going through.

## See also

- <doc:GettingStarted>
- ``QVACClient``
- ``BareRPCClient``
