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

For release validation, select the `QVACChat-PhysicalDevice` scheme and run its
UI test on a provisioned, unlocked device. The test fails if it is launched on a
simulator. It records screenshots while it loads the immutable model revision,
finishes a completion with nonempty output, and unloads the model.

Final r2 evidence must use the dedicated runner rather than the generated project
directly. It builds an exact clean commit with all 38 local artifacts, replaces
BareKit with the selected candidate, checks that the device is unlocked before
building, and validates the one-test result and four screenshots:

```bash
tools/ci/run-ios-physical-lifecycle.sh --self-test
QVAC_XCODEGEN=/absolute/path/to/xcodegen-2.46.0 \
tools/ci/run-ios-physical-lifecycle.sh \
  --source-sha <full-commit-sha> \
  --destination 'platform=iOS,id=<device-udid>' \
  --candidate /absolute/path/to/BareKit.xcframework \
  --evidence-dir /absolute/new/path/outside/the/repository \
  --development-team <team-identifier> \
  --allow-provisioning-updates
```

Keep the device connected, trusted, paired, in Developer Mode, and unlocked for
the entire run. The test may use the worker's existing model cache; it does not
attest a cold model download or incremental token timing.

## Native IPC stress validation

The native stress runner exercises the staged BareKit candidate in this app's
process without downloading a model or using the network. It verifies 16 MiB of
ordered, backpressured echo traffic; concurrent close/read races; and bounded
post-warm-up physical-memory growth over 256 MiB of traffic. It writes an
`.xcresult`, build log, and validated JSON attachments to an evidence directory
outside the checkout. A separate record identifies the source revision and
selected binary and stores the validated results and build-log digest.

The runner requires a clean checkout, all 38 development XCFrameworks staged by
`tools/runtime/link-ios-artifacts.sh`, the patched r2 `BareKit.xcframework`, and
XcodeGen 2.46.0 selected with `QVAC_XCODEGEN`. It independently reproduces the
source archive and generated project, and verifies the canonical 37-framework
SDK lock before and after the build. Run its negative-gate self-tests with:

```bash
tools/ci/run-ios-native-stress.sh --self-test
```

For a simulator, boot an iOS 17 or later device and pass its UDID:

```bash
tools/ci/run-ios-native-stress.sh \
  --mode regular \
  --platform simulator \
  --destination 'platform=iOS Simulator,id=<simulator-udid>' \
  --candidate /absolute/path/to/BareKit.xcframework \
  --evidence-dir /absolute/path/outside/the/repository
```

A physical run additionally requires an iOS 17 or later arm64 iPhone that is
connected, unlocked, trusted, paired with Xcode, and has Developer Mode enabled.
The Mac must have an Apple development identity and a team able to provision the
example app and its test bundle. Supply that team without modifying the project:

```bash
tools/ci/run-ios-native-stress.sh \
  --mode regular \
  --platform device \
  --destination 'platform=iOS,id=<device-identifier>' \
  --candidate /absolute/path/to/BareKit.xcframework \
  --evidence-dir /absolute/path/outside/the/repository \
  --development-team <team-identifier> \
  --allow-provisioning-updates
```

Thread Sanitizer is intentionally a separate simulator-only run restricted to
the race test. The unsanitized regular run is the memory gate; sanitizer runtime
allocations are never accepted as memory-plateau evidence.

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
