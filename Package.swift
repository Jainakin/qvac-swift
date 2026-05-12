// swift-tools-version:5.10
// QVAC Swift Client — Swift Package Manager manifest
//
// Tether grant: https://tether.dev/grants/bounties/2885283454/
// Plan: PLAN.md, Issues: ISSUES.md
//
// Platforms: macOS 14+ arm64 (subprocess Bare worker over Unix Domain Socket),
//            iOS 17+ arm64 (in-process Bare worker via BareKit + BareIPC).
//
// The iOS path needs BareKit (the libuv host runtime) plus an xcframework for each
// addon the committed worker bundle references via its `addons` table, AND the
// transitive @rpath closure (one framework can link to others). All vendored
// under `spike-swift/Vendor/` by `tools/dev/vendor-from-release.sh`.
// QVACClient depends on every one so SPM actually copies them into App.app/Frameworks/.
//
// For consumer-mode distribution (URL-based binaryTargets + GitHub Releases) see
// `tools/release/prepare-release.sh` and `docs/distribution.md`.

import PackageDescription

let package = Package(
    name: "QVACClient",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "QVACClient", targets: ["QVACClient"]),
    ],
    targets: [
        .binaryTarget(
            name: "BareKit",
            path: "spike-swift/Vendor/BareKit.xcframework"
        ),
        .binaryTarget(
            name: "bare-abort.2.0.13",
            path: "spike-swift/Vendor/bare-abort.2.0.13.xcframework"
        ),
        .binaryTarget(
            name: "bare-buffer.3.6.0",
            path: "spike-swift/Vendor/bare-buffer.3.6.0.xcframework"
        ),
        .binaryTarget(
            name: "bare-channel.5.2.3",
            path: "spike-swift/Vendor/bare-channel.5.2.3.xcframework"
        ),
        .binaryTarget(
            name: "bare-crypto.1.13.6",
            path: "spike-swift/Vendor/bare-crypto.1.13.6.xcframework"
        ),
        .binaryTarget(
            name: "bare-dns.2.1.4",
            path: "spike-swift/Vendor/bare-dns.2.1.4.xcframework"
        ),
        .binaryTarget(
            name: "bare-ffmpeg.1.2.2",
            path: "spike-swift/Vendor/bare-ffmpeg.1.2.2.xcframework"
        ),
        .binaryTarget(
            name: "bare-fs.4.7.1",
            path: "spike-swift/Vendor/bare-fs.4.7.1.xcframework"
        ),
        .binaryTarget(
            name: "bare-hrtime.2.1.1",
            path: "spike-swift/Vendor/bare-hrtime.2.1.1.xcframework"
        ),
        .binaryTarget(
            name: "bare-inspect.3.1.4",
            path: "spike-swift/Vendor/bare-inspect.3.1.4.xcframework"
        ),
        .binaryTarget(
            name: "bare-os.3.9.1",
            path: "spike-swift/Vendor/bare-os.3.9.1.xcframework"
        ),
        .binaryTarget(
            name: "bare-pipe.4.1.5",
            path: "spike-swift/Vendor/bare-pipe.4.1.5.xcframework"
        ),
        .binaryTarget(
            name: "bare-signals.4.2.0",
            path: "spike-swift/Vendor/bare-signals.4.2.0.xcframework"
        ),
        .binaryTarget(
            name: "bare-stdio.1.0.2",
            path: "spike-swift/Vendor/bare-stdio.1.0.2.xcframework"
        ),
        .binaryTarget(
            name: "bare-structured-clone.1.5.4",
            path: "spike-swift/Vendor/bare-structured-clone.1.5.4.xcframework"
        ),
        .binaryTarget(
            name: "bare-tcp.2.2.13",
            path: "spike-swift/Vendor/bare-tcp.2.2.13.xcframework"
        ),
        .binaryTarget(
            name: "bare-tls.3.1.3",
            path: "spike-swift/Vendor/bare-tls.3.1.3.xcframework"
        ),
        .binaryTarget(
            name: "bare-tty.5.1.0",
            path: "spike-swift/Vendor/bare-tty.5.1.0.xcframework"
        ),
        .binaryTarget(
            name: "bare-type.1.1.0",
            path: "spike-swift/Vendor/bare-type.1.1.0.xcframework"
        ),
        .binaryTarget(
            name: "bare-url.2.4.3",
            path: "spike-swift/Vendor/bare-url.2.4.3.xcframework"
        ),
        .binaryTarget(
            name: "bare-zlib.1.3.3",
            path: "spike-swift/Vendor/bare-zlib.1.3.3.xcframework"
        ),
        .binaryTarget(
            name: "fs-native-extensions.1.5.0",
            path: "spike-swift/Vendor/fs-native-extensions.1.5.0.xcframework"
        ),
        .binaryTarget(
            name: "quickbit-native.2.4.8",
            path: "spike-swift/Vendor/quickbit-native.2.4.8.xcframework"
        ),
        .binaryTarget(
            name: "qvac__diffusion-cpp.0.3.0",
            path: "spike-swift/Vendor/qvac__diffusion-cpp.0.3.0.xcframework"
        ),
        .binaryTarget(
            name: "qvac__embed-llamacpp.0.14.0",
            path: "spike-swift/Vendor/qvac__embed-llamacpp.0.14.0.xcframework"
        ),
        .binaryTarget(
            name: "qvac__llm-llamacpp.0.17.4",
            path: "spike-swift/Vendor/qvac__llm-llamacpp.0.17.4.xcframework"
        ),
        .binaryTarget(
            name: "qvac__ocr-onnx.0.4.5",
            path: "spike-swift/Vendor/qvac__ocr-onnx.0.4.5.xcframework"
        ),
        .binaryTarget(
            name: "qvac__onnx.0.14.0",
            path: "spike-swift/Vendor/qvac__onnx.0.14.0.xcframework"
        ),
        .binaryTarget(
            name: "qvac__transcription-parakeet.0.3.3",
            path: "spike-swift/Vendor/qvac__transcription-parakeet.0.3.3.xcframework"
        ),
        .binaryTarget(
            name: "qvac__transcription-whispercpp.0.6.8",
            path: "spike-swift/Vendor/qvac__transcription-whispercpp.0.6.8.xcframework"
        ),
        .binaryTarget(
            name: "qvac__translation-nmtcpp.2.1.1",
            path: "spike-swift/Vendor/qvac__translation-nmtcpp.2.1.1.xcframework"
        ),
        .binaryTarget(
            name: "qvac__tts-onnx.0.8.7",
            path: "spike-swift/Vendor/qvac__tts-onnx.0.8.7.xcframework"
        ),
        .binaryTarget(
            name: "rabin-native.2.0.0",
            path: "spike-swift/Vendor/rabin-native.2.0.0.xcframework"
        ),
        .binaryTarget(
            name: "rocksdb-native.3.15.1",
            path: "spike-swift/Vendor/rocksdb-native.3.15.1.xcframework"
        ),
        .binaryTarget(
            name: "simdle-native.1.3.9",
            path: "spike-swift/Vendor/simdle-native.1.3.9.xcframework"
        ),
        .binaryTarget(
            name: "sodium-native.5.1.0",
            path: "spike-swift/Vendor/sodium-native.5.1.0.xcframework"
        ),
        .binaryTarget(
            name: "udx-native.1.19.2",
            path: "spike-swift/Vendor/udx-native.1.19.2.xcframework"
        ),
        .target(
            name: "QVACClient",
            dependencies: [
                .target(name: "BareKit", condition: .when(platforms: [.iOS])),
                .target(name: "bare-abort.2.0.13", condition: .when(platforms: [.iOS])),
                .target(name: "bare-buffer.3.6.0", condition: .when(platforms: [.iOS])),
                .target(name: "bare-channel.5.2.3", condition: .when(platforms: [.iOS])),
                .target(name: "bare-crypto.1.13.6", condition: .when(platforms: [.iOS])),
                .target(name: "bare-dns.2.1.4", condition: .when(platforms: [.iOS])),
                .target(name: "bare-ffmpeg.1.2.2", condition: .when(platforms: [.iOS])),
                .target(name: "bare-fs.4.7.1", condition: .when(platforms: [.iOS])),
                .target(name: "bare-hrtime.2.1.1", condition: .when(platforms: [.iOS])),
                .target(name: "bare-inspect.3.1.4", condition: .when(platforms: [.iOS])),
                .target(name: "bare-os.3.9.1", condition: .when(platforms: [.iOS])),
                .target(name: "bare-pipe.4.1.5", condition: .when(platforms: [.iOS])),
                .target(name: "bare-signals.4.2.0", condition: .when(platforms: [.iOS])),
                .target(name: "bare-stdio.1.0.2", condition: .when(platforms: [.iOS])),
                .target(name: "bare-structured-clone.1.5.4", condition: .when(platforms: [.iOS])),
                .target(name: "bare-tcp.2.2.13", condition: .when(platforms: [.iOS])),
                .target(name: "bare-tls.3.1.3", condition: .when(platforms: [.iOS])),
                .target(name: "bare-tty.5.1.0", condition: .when(platforms: [.iOS])),
                .target(name: "bare-type.1.1.0", condition: .when(platforms: [.iOS])),
                .target(name: "bare-url.2.4.3", condition: .when(platforms: [.iOS])),
                .target(name: "bare-zlib.1.3.3", condition: .when(platforms: [.iOS])),
                .target(name: "fs-native-extensions.1.5.0", condition: .when(platforms: [.iOS])),
                .target(name: "quickbit-native.2.4.8", condition: .when(platforms: [.iOS])),
                .target(name: "qvac__diffusion-cpp.0.3.0", condition: .when(platforms: [.iOS])),
                .target(name: "qvac__embed-llamacpp.0.14.0", condition: .when(platforms: [.iOS])),
                .target(name: "qvac__llm-llamacpp.0.17.4", condition: .when(platforms: [.iOS])),
                .target(name: "qvac__ocr-onnx.0.4.5", condition: .when(platforms: [.iOS])),
                .target(name: "qvac__onnx.0.14.0", condition: .when(platforms: [.iOS])),
                .target(name: "qvac__transcription-parakeet.0.3.3", condition: .when(platforms: [.iOS])),
                .target(name: "qvac__transcription-whispercpp.0.6.8", condition: .when(platforms: [.iOS])),
                .target(name: "qvac__translation-nmtcpp.2.1.1", condition: .when(platforms: [.iOS])),
                .target(name: "qvac__tts-onnx.0.8.7", condition: .when(platforms: [.iOS])),
                .target(name: "rabin-native.2.0.0", condition: .when(platforms: [.iOS])),
                .target(name: "rocksdb-native.3.15.1", condition: .when(platforms: [.iOS])),
                .target(name: "simdle-native.1.3.9", condition: .when(platforms: [.iOS])),
                .target(name: "sodium-native.5.1.0", condition: .when(platforms: [.iOS])),
                .target(name: "udx-native.1.19.2", condition: .when(platforms: [.iOS])),
            ],
            path: "Sources/QVACClient",
            resources: [
                .copy("Resources/worker.mobile.bundle"),
            ]
        ),
        .testTarget(
            name: "QVACClientUnitTests",
            dependencies: ["QVACClient"],
            path: "Tests/QVACClientUnitTests",
            resources: [
                .copy("Fixtures"),
            ]
        ),
        .testTarget(
            name: "QVACClientIntegrationTests",
            dependencies: ["QVACClient"],
            path: "Tests/QVACClientIntegrationTests"
        ),
    ]
)
