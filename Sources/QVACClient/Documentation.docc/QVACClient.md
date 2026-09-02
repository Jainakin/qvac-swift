# ``QVACClient``

A native Swift concurrency client for QVAC SDK 0.17.0.

## Overview

`QVACClient` is an actor that owns one worker connection, performs the required
`__init_config` handshake, multiplexes concurrent RPCs, and closes the underlying
worker deterministically. macOS uses a spawned Bare process over a private
Unix-domain socket; iOS runs the verified mobile worker in a BareKit worklet.

The generated API contains 39 request/reply, server-stream, and duplex methods.
Generated requests and responses validate their type discriminators, and unknown
response types are reported as compatibility errors.

Rich operation APIs provide:

- request IDs and targeted cancellation;
- typed progress, event, token, and terminal-result views;
- `Data` to base64 conversion for audio, image, video, and VLA inputs;
- bounded fan-out streams and byte-bounded raw transport queues;
- per-request deadlines and profiling metadata capture; and
- typed `QVACError` values for worker, transport, timeout, encoding, and protocol
  failures.

Generated `wire…` methods remain available for applications that need every
optional contract field.

## Operation groups

| Group | Swift surfaces |
|---|---|
| Lifecycle | `heartbeat`, `close`, `cancel`, `suspend`, `resume`, `state` |
| Models and cache | `loadModel`, `loadModelStreaming`, `unloadModel`, `downloadAsset`, `deleteCache`, model information and registry APIs |
| Language | `completion`, `batchCompletion`, `completionOrchestrate`, `embed`, `translate` |
| Audio | `transcribe`, `transcribeStream`, `bciTranscribe`, `bciTranscribeStream`, `textToSpeech`, `textToSpeechStream`, `audioGen` |
| Vision and media | `ocr`, `classify`, `diffusion`, `video`, `upscale`, VLA preprocessing and inference |
| Data and extensions | RAG operations, plugins, finetuning, logging, and provider lifecycle |

## Contract identity

`QVACSDKContract` publishes the SDK version, upstream commit, method inventory,
call shapes, and conditional-progress metadata used by the generated API. The
same pinned contract produces the concrete Swift types and 136 error codes.

The worker bundle and generated API are pinned to QVAC SDK 0.17.0. CI reproduces
the worker from its locked runtime dependency graph.

## Resource limits

The default maximum wire message is 256 MiB to support 0.17 media operations that
return one complete base64 output per JSON record. Configure
`maximumWireMessageBytes` and `maximumBufferedStreamBytes` on initialization for
the application's model set and memory budget.

Per-operation public streams are bounded. ``QVACBufferedStream`` retains up to 64
indivisible worker batches within `maximumBufferedStreamBytes` and lazily flattens
frames containing many logical values. Falling behind on a lossless view fails it
explicitly with ``QVACStreamBufferOverflow``. Observational progress streams instead
coalesce older snapshots and retain the newest bounded window.

## Topics

### Guides

- <doc:GettingStarted>
- <doc:Architecture>
- <doc:Security>

### Core public types

- ``QVACError``
- ``QVACErrorCode``
- ``QVACErrorCategory``
- ``QVACRPCOptions``
- ``QVACBufferedStream``
- ``QVACResponseStream``
- ``QVACStreamBufferOverflow``
- ``QVACSDKContract``
