#  Getting started

Install QVACClient via Swift Package Manager and run streaming completion in under
ten minutes.

## Add the package

In your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/tetherto/qvac-swift", from: "0.1.0"),
],
targets: [
    .target(
        name: "MyApp",
        dependencies: [
            .product(name: "QVACClient", package: "qvac-swift"),
        ]
    ),
]
```

Minimum platforms: iOS 17, macOS 14, both arm64.

## Run the first inference

### iOS

```swift
import QVACClient

let client = try await QVACClient(
    configuration: try .iOSWithBundledResource()
)
let modelId = try await client.loadModel(
    modelSrc: "https://huggingface.co/.../model.gguf",
    modelType: "llamacpp-completion"
)
let run = try await client.completion(
    modelId: modelId,
    history: [.user("Say hi in one word.")]
)
for try await tok in run.tokenStream {
    print(tok, terminator: "")
}
try await client.unloadModel(modelId: modelId)
```

The iOS `Configuration.iOSWithBundledResource()` factory loads the pre-built
`worker.mobile.bundle.js` shipped inside the SPM package — no additional setup needed.

### macOS

macOS spawns the Bare runtime as a subprocess. You'll need:

1. `bare` runtime installed (`brew install holepunchto/tap/bare` or `npm i -g bare-runtime`).
2. An npm install of `@qvac/sdk` somewhere on disk — the client points at its
   `node_modules` directory.

```swift
let client = try await QVACClient(configuration:
    try .macOS(nodeModulesDir: URL(fileURLWithPath: "/path/to/my-app/node_modules"))
)
```

## Streaming completion

`completion(...)` returns a ``QVACClient/CompletionRun`` with three views into the
same stream:

```swift
let run = try await client.completion(modelId: id, history: [.user("Hello")])

// Most ergonomic — just text tokens as they arrive:
for try await tok in run.tokenStream {
    UI.append(tok)
}

// Or for tool calls / thinking deltas / stats events:
for try await event in run.events {
    switch event {
    case .contentDelta(let text):  UI.append(text)
    case .thinkingDelta(let text): UI.appendThinking(text)
    case .toolCall(let raw):       handleToolCall(raw)
    case .done(let payload):       print("done: \(payload)")
    default: break
    }
}

// And/or block for the final stats payload:
let final = try await run.final.value
```

## Cancellation

```swift
let run = try await client.completion(modelId: id, history: ...)
let cancelLater = Task {
    try await Task.sleep(for: .seconds(5))
    try await client.cancel(.inference(modelId: id))
}
for try await tok in run.tokenStream { ... }  // terminates within ~500ms of cancel
await cancelLater.value
```

## Error handling

```swift
do {
    try await client.loadModel(modelSrc: bad, modelType: "llamacpp-completion")
} catch let e as QVACError {
    switch e {
    case .server(let code, let msg) where code.category == .download:
        retry()
    case .client(.rpcInitTimeout, _):
        // worker didn't start
    case .transport:
        // can't reach the worker at all
    default:
        throw e
    }
}
```

## Where to go next

- ``QVACClient`` — the full API surface
- <doc:Architecture> — wire protocol + transport details
- The `Examples/QVACChat` SwiftUI app — a complete working demo
