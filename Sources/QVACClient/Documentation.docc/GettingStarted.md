# Getting started

Connect to the exact QVAC SDK 0.17.0 worker, load a model, stream a completion,
and close every resource deterministically.

## Add the package

After an artifact-backed source tag has been published:

```swift
dependencies: [
    .package(
        url: "https://github.com/Jainakin/qvac-swift.git",
        exact: "0.1.0"
    ),
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

Do not select `0.1.0` until that tag exists. An unpublished development checkout
uses local generated xcframeworks and is not a valid URL dependency. The release
preflight creates a checksum-pinned URL manifest only after every immutable binary
archive is visible and verified.

The minimum platforms are iOS 17 and macOS 14 on arm64.

## Create a client

On iOS, use the worker bundled in an artifact-backed release:

```swift
let client = try await QVACClient(
    configuration: try .iOSWithBundledResource(),
    maximumWireMessageBytes: 256 * 1024 * 1024
)
```

On macOS, install exact `bare-runtime@1.31.0` and `@qvac/sdk@0.17.0` dependencies,
retain the npm lockfile, and provide its `node_modules` directory. The configuration
prefers that directory's `.bin/bare`, so the worker and executable come from the
same locked graph:

```swift
let client = try await QVACClient(
    configuration: try .macOS(
        nodeModulesDir: URL(fileURLWithPath: "/absolute/qvac-runtime/node_modules")
    )
)
```

## Load and infer

`modelConfig` is optional. The client sends an empty object when it is omitted,
which is required by the 0.17 worker and fixes the npm-installed macOS path.

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

Each run exposes a request ID before its terminal result resolves. Use it for
targeted cancellation:

```swift
try await client.cancel(
    .request(requestId: run.requestId),
    rpcOptions: .init(timeout: .seconds(2))
)
```

## Deadlines

Every public operation accepts `QVACRPCOptions`. Request/reply calls use a total
response deadline, server streams use a next-frame inactivity deadline, and duplex
operations apply the deadline while opening the session. Values below 100 ms are
rejected.

The exact 0.17 behavior leaves the timeout unset by default. Set an explicit value
for production calls based on the expected model and output size.

## Errors

RPC and worker failures are surfaced as `QVACError`. Cooperative Swift task
cancellation remains `CancellationError`, while a bounded high-level observer that
falls behind reports `QVACStreamBufferOverflow`:

```swift
do {
    _ = try await run.final.value
} catch let error as QVACError {
    switch error {
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

Profiling-only trailer records are removed before response decoding. Malformed
non-trailers, unknown discriminators, and truncated NDJSON still fail explicitly.

Live RPC responses are exposed as `QVACResponseStream`. They are single-consumer
sequences: use one `for try await` loop or iterator. Breaking the loop tears down
the remote operation even if your code retains the stream; call `cancel()` to stop
it before iteration begins.

## Shut down

Unload models that are no longer needed and always await `close()`:

```swift
try await client.unloadModel(
    modelId: modelId,
    rpcOptions: .init(timeout: .seconds(10))
)
await client.close()
```

`close()` is idempotent and joinable. On iOS it performs the SDK's bounded
`__shutdown__` handshake before ending the BareKit worklet.

## Next steps

- <doc:Architecture>
- <doc:Security>
- See the `Examples/QVACChat` target for a complete SwiftUI flow.
