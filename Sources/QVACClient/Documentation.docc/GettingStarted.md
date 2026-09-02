# Getting started

Add QVACClient to an iOS or macOS application, load a model, and stream a
completion.

## Add the package

The 0.2 release line contains the current SDK 0.17.0 API. Add the package through
Xcode or Swift Package Manager:

```swift
dependencies: [
    .package(
        url: "https://github.com/Jainakin/qvac-swift.git",
        .upToNextMinor(from: "0.2.0")
    )
],
targets: [
    .target(
        name: "MyApp",
        dependencies: [
            .product(name: "QVACClient", package: "qvac-swift")
        ]
    )
]
```

The minimum platforms are iOS 17 and macOS 14. The macOS runtime requires Apple
silicon.

> Important: If `0.2.0` is not yet available during review, evaluators can
> temporarily replace the version requirement with `branch: "main"`. Do not ship
> a branch-based dependency. The existing `v0.1.0` tag predates the current stream
> types and buffering behavior.

## Create a client

On iOS, start the worker bundled with the package:

```swift
let client = try await QVACClient(
    configuration: try .iOSWithBundledResource()
)
```

On macOS, install `bare-runtime@1.31.0` and `@qvac/sdk@0.17.0` in a locked npm
environment, then provide its `node_modules` directory:

```swift
let client = try await QVACClient(
    configuration: try .macOS(
        nodeModulesDir: URL(
            fileURLWithPath: "/absolute/path/to/qvac-runtime/node_modules"
        )
    )
)
```

The macOS configuration prefers that directory's
`bare-runtime/bin/bare` executable, keeping the worker and runtime in the same
dependency graph.

## Load and infer

`modelConfig` is optional. When omitted, the client sends the empty object required
by the QVAC 0.17.0 worker.

```swift
let load = try await client.loadModelStreaming(
    modelSrc: modelURL,
    modelType: "llamacpp-completion",
    rpcOptions: .init(timeout: .seconds(600))
)

async let loadedId = load.result.value
for try await progress in load.progress {
    updateProgress(progress.percentage)
}
let modelId = try await loadedId

let run = try await client.completion(
    modelId: modelId,
    history: [.user("Say hello in five words.")],
    rpcOptions: .init(timeout: .seconds(60))
)

for try await token in run.tokenStream {
    append(token)
}
let final = try await run.final.value
print(final.stats as Any)
```

Each run exposes its request ID immediately. Use it for targeted cancellation:

```swift
try await client.cancel(
    .request(requestId: run.requestId),
    rpcOptions: .init(timeout: .seconds(2))
)
```

## Deadlines

Every operation accepts `QVACRPCOptions`. Unary calls use a total response
deadline, server streams use an inactivity deadline between frames, and duplex
operations apply the deadline while opening the session. Values below 100
milliseconds are rejected.

Calls default to a 60-second deadline. Override it for operations that legitimately
take longer; use `timeout: nil` only when another watchdog bounds the operation.

## Streams and errors

High-level worker and transport failures are reported as `QVACError`. Swift task
cancellation remains `CancellationError`.

Progress streams coalesce older snapshots when a consumer falls behind. Lossless
result streams report ``QVACStreamBufferOverflow`` rather than drop accepted data.
See <doc:Architecture> for buffer and lifecycle details.

```swift
do {
    _ = try await run.final.value
} catch let error as QVACError {
    switch error {
    case .connectionReset:
        reloadModelsAndRetry()
    case .requestTimedOut(let operation, _):
        print("Timed out: \(operation)")
    case .server(let code, let message):
        print("QVAC \(code.name): \(message ?? "no message")")
    case .protocolViolation(let detail):
        reportWorkerCompatibilityFailure(detail)
    default:
        report(error)
    }
}
```

Profiling trailers are removed before typed response decoding. Malformed ordinary
records, unknown discriminators, and truncated NDJSON remain errors.

``QVACResponseStream`` is single-consumer. Use one `for try await` loop or one
iterator. Leaving the loop tears down the remote stream; call `cancel()` if the
operation must be stopped before iteration begins.

If an iOS request times out after a suspected worklet exit, close and recreate the
client. Do not automatically replay stateful work unless it is safe to do so.

## Shut down

Unload models that are no longer needed and await `close()`:

```swift
try await client.unloadModel(
    modelId: modelId,
    rpcOptions: .init(timeout: .seconds(10))
)
await client.close()
```

`close()` is idempotent. On iOS it completes the SDK shutdown handshake before
terminating the BareKit worklet.

## Next steps

- <doc:Architecture>
- <doc:Security>
- See `Examples/QVACChat` for a complete SwiftUI flow.
