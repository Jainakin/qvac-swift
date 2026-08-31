// swift-tools-version:5.10

import PackageDescription

let package = Package(
    name: "QVACiOSSmokeHarness",
    platforms: [.iOS(.v17)],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .testTarget(
            name: "QVACiOSSmokeTests",
            dependencies: [
                .product(name: "QVACClient", package: "qvac-swift"),
            ]
        ),
    ]
)
