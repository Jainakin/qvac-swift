# QVACChat

QVACChat is a small SwiftUI application that demonstrates the complete client
lifecycle: create a client, download and load a model, stream a completion, unload
the model, and close the worker.

## Generate the project

Generate the Xcode project from the example directory:

```bash
cd Examples/QVACChat
xcodegen generate
open QVACChat.xcodeproj
```

The generated `.xcodeproj` is a local build product and is not committed. Xcode
resolves QVACClient and its binary dependencies from the repository's URL-backed
package manifest.

## iOS

Select the `QVACChat-iOS` scheme and an iOS 17 or later device or simulator. A
physical device requires a valid development team in the target's Signing &
Capabilities settings.

The first run downloads the model configured in `ContentView.swift`; allow time
and storage for that download. Subsequent runs can use the worker's local cache.

## macOS

Install the locked runtime from the repository root:

```bash
tools/runtime/bootstrap.sh
```

Set `QVAC_NODE_MODULES` to `tools/runtime/node_modules`, select the
`QVACChat-macOS` scheme, and run the application.

## Expected flow

1. Tap **Load model** and wait for progress to complete.
2. Enter a prompt and start generation.
3. Confirm that text arrives incrementally.
4. Unload the model before closing the application.

The status view reports user-facing failures. Detailed client and worker messages
are available in the Xcode console.
