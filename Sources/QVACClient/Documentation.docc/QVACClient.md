#  ``QVACClient``

A native Swift client for the [QVAC SDK](https://docs.qvac.tether.io/) —
Tether's local-first on-device AI runtime.

## Overview

`QVACClient` is an actor that owns a connection to a Bare worker process and exposes
QVAC's full inference + RAG + plugin API as idiomatic Swift `async`/`await` methods,
with streaming responses delivered via `AsyncSequence`.

It supports two transport models, picked by ``Configuration``:

- **macOS / Linux**: Spawn `bare worker.js` as a subprocess; communicate over Unix
  Domain Socket.
- **iOS**: Run the worker in-process as a libuv thread via Holepunch's BareKit, with
  IPC over a socketpair the host app never has to manage.

The wire format is bare-rpc binary framing with NDJSON inside — the same protocol the
QVAC JavaScript client uses, validated byte-for-byte against the JS reference.

## Topics

### Getting started

- ``QVACClient/init(configuration:runtimeContext:config:)``
- ``QVACClient/Configuration``
- ``QVACClient/heartbeat()``
- ``QVACClient/close()``

### Loading models

- ``QVACClient/loadModel(modelSrc:modelType:modelConfig:modelName:)``
- ``QVACClient/loadModelStreaming(modelSrc:modelType:modelConfig:modelName:)``
- ``QVACClient/unloadModel(modelId:clearStorage:)``
- ``QVACClient/downloadAsset(assetSrc:seed:)``
- ``QVACClient/downloadAssetStreaming(assetSrc:seed:)``

### Inference

- ``QVACClient/completion(modelId:history:generationParams:captureThinking:)``
- ``QVACClient/embed(modelId:text:)-9z2nb``
- ``QVACClient/translate(modelId:modelType:text:from:to:context:)``

### Audio

- ``QVACClient/transcribe(modelId:audioPath:prompt:)-7gv3n``
- ``QVACClient/transcribeStream(modelId:prompt:metadata:)``
- ``QVACClient/textToSpeech(modelId:text:sentenceStream:sentenceStreamLocale:sentenceStreamMaxChunkScalars:inputType:)``
- ``QVACClient/textToSpeechStream(modelId:accumulateSentences:sentenceDelimiterPreset:maxBufferScalars:flushAfterMs:inputType:)``

### Vision

- ``QVACClient/ocr(modelId:imagePath:options:)-9d2nb``
- ``QVACClient/diffusion(modelId:prompt:negativePrompt:width:height:steps:cfgScale:guidance:samplingMethod:scheduler:seed:batchCount:initImage:strength:)``

### Retrieval-Augmented Generation (RAG)

- ``QVACClient/ragIngest(modelId:documents:workspace:chunkOpts:)``
- ``QVACClient/ragSearch(modelId:query:topK:workspace:)``
- ``QVACClient/ragChunk(documents:chunkOpts:)``
- ``QVACClient/ragSaveEmbeddings(documents:modelId:workspace:)``
- ``QVACClient/ragDeleteEmbeddings(ids:workspace:)``
- ``QVACClient/ragListWorkspaces()``
- ``QVACClient/ragCloseWorkspace(workspace:deleteOnClose:)``
- ``QVACClient/ragDeleteWorkspace(workspace:)``
- ``QVACClient/ragReindex(workspace:n:)``

### Plugin invocation

- ``QVACClient/invokePlugin(modelId:handler:params:as:)``
- ``QVACClient/invokePluginStream(modelId:handler:params:as:)``

### Cancellation

- ``QVACClient/cancel(_:)``
- ``QVACClient/CancelOperation``

### Errors

- ``QVACError``
- ``QVACErrorCode``
- ``QVACErrorCategory``
