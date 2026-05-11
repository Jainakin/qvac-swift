// swift-tools-version:5.10
// QVAC Swift Client — Swift Package Manager manifest
//
// Tether grant: https://tether.dev/grants/bounties/2885283454/
// Plan: PLAN.md, Issues: ISSUES.md
//
// Platforms: macOS 14+ arm64 (subprocess Bare worker over Unix Domain Socket),
//            iOS 17+ arm64 (in-process Bare worker via BareKit + BareIPC).
//
// Phase-1 (M1) scope: bare-rpc codec + IPC transport + codegen tooling.
// API surface (M2/M3) is generated under Sources/QVACClient/Generated/.

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
        // The xcframework is vendored locally for development; in v0.1 release it is
        // distributed as a binaryTarget(url:checksum:) referenced from GitHub Releases
        // (see docs/bundle-and-addons.md §5).
        .binaryTarget(
            name: "BareKit",
            path: "spike-swift/Vendor/BareKit.xcframework"
        ),
        .target(
            name: "QVACClient",
            dependencies: [
                .target(name: "BareKit", condition: .when(platforms: [.iOS])),
            ],
            path: "Sources/QVACClient",
            exclude: [],
            resources: [
                // Pre-built QVAC mobile bundle (all plugins compiled in via `qvac bundle sdk`).
                // Loaded at runtime on iOS via `Configuration.iOSWorkletFromBundledResource()`.
                // Regenerate with: `node spike-js/node_modules/@qvac/cli/dist/index.js bundle sdk --host ios-arm64 ...`
                .copy("Resources/worker.mobile.bundle.js"),
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
