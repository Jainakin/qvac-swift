// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "QVACSpike",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "CompactEncoding", targets: ["CompactEncoding"]),
        .library(name: "BareRPC", targets: ["BareRPC"]),
        .executable(name: "MacOSProbe", targets: ["MacOSProbe"]),
        .library(name: "BareKitProbeLib", targets: ["BareKitProbeLib"]),
    ],
    targets: [
        .target(name: "CompactEncoding", path: "Sources/CompactEncoding"),
        .target(
            name: "BareRPC",
            dependencies: ["CompactEncoding"],
            path: "Sources/BareRPC"
        ),
        .executableTarget(
            name: "MacOSProbe",
            dependencies: ["BareRPC", "CompactEncoding"],
            path: "Sources/MacOSProbe"
        ),
        .binaryTarget(name: "BareKit", path: "Vendor/BareKit.xcframework"),
        .target(
            name: "BareKitProbeLib",
            dependencies: ["BareKit", "BareRPC", "CompactEncoding"],
            path: "Sources/BareKitProbeLib"
        ),
        .testTarget(
            name: "CompactEncodingTests",
            dependencies: ["CompactEncoding"],
            path: "Tests/CompactEncodingTests",
            resources: [.copy("fixtures.json")]
        ),
        .testTarget(
            name: "BareRPCTests",
            dependencies: ["BareRPC", "CompactEncoding"],
            path: "Tests/BareRPCTests"
        ),
    ]
)
