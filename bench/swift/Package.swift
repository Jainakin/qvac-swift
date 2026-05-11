// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "QVACBench",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "QVACBench",
            dependencies: [
                .product(name: "QVACClient", package: "qvac-swift"),
            ],
            path: "Sources"
        ),
    ]
)
