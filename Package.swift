// swift-tools-version:5.10
// QVAC Swift Client — URL-installable release manifest.
// Generated from an immutable artifact-manifest.json by the exact 0.17.0
// artifact pipeline. Do not edit URLs or checksums by hand.

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
            url: "https://github.com/Jainakin/qvac-swift/releases/download/artifacts-sdk-0.17.0-r1/BareKit.xcframework.zip",
            checksum: "21d0107fdcd8e5286cff44fb28cc1646df09b63f6ad663791871cb1086817225"
        ),
        .binaryTarget(
            name: "bare-buffer.3.7.0",
            url: "https://github.com/Jainakin/qvac-swift/releases/download/artifacts-sdk-0.17.0-r1/bare-buffer.3.7.0.xcframework.zip",
            checksum: "1b3391899681cb420f41ed21d82a7cc3f2de8c107c99eaa9e55029a3bdb9f565"
        ),
        .binaryTarget(
            name: "bare-cpu-info.0.1.1",
            url: "https://github.com/Jainakin/qvac-swift/releases/download/artifacts-sdk-0.17.0-r1/bare-cpu-info.0.1.1.xcframework.zip",
            checksum: "fdf1c9612182d15367013070d3e482e7f74f65954776911328f57f2684f72326"
        ),
        .binaryTarget(
            name: "bare-crypto.1.15.3",
            url: "https://github.com/Jainakin/qvac-swift/releases/download/artifacts-sdk-0.17.0-r1/bare-crypto.1.15.3.xcframework.zip",
            checksum: "b82e622d49f0bbb73b4df478a4e549de05dff9fbc8d71b01873b456d9bf24d05"
        ),
        .binaryTarget(
            name: "bare-dns.2.2.0",
            url: "https://github.com/Jainakin/qvac-swift/releases/download/artifacts-sdk-0.17.0-r1/bare-dns.2.2.0.xcframework.zip",
            checksum: "9e1196dcf9c00abf973a2558f09b6c10a34acd875218701702715382dc8f59fb"
        ),
        .binaryTarget(
            name: "bare-ffmpeg.1.5.0",
            url: "https://github.com/Jainakin/qvac-swift/releases/download/artifacts-sdk-0.17.0-r1/bare-ffmpeg.1.5.0.xcframework.zip",
            checksum: "1ca03888c6441b5c0d014b15d4383e5c3a22dcddbbc5cbce044e12957f5b847e"
        ),
        .binaryTarget(
            name: "bare-fs.4.8.1",
            url: "https://github.com/Jainakin/qvac-swift/releases/download/artifacts-sdk-0.17.0-r1/bare-fs.4.8.1.xcframework.zip",
            checksum: "3f4d10a0a3dc4f4fd7376a7e53a97b359304e27b2e49fea422cbea8f20e72e45"
        ),
        .binaryTarget(
            name: "bare-gpu-info.0.1.1",
            url: "https://github.com/Jainakin/qvac-swift/releases/download/artifacts-sdk-0.17.0-r1/bare-gpu-info.0.1.1.xcframework.zip",
            checksum: "8bd7b0825677c19c0b4e243200ea91e64e55e0d09b7ece85b86de04a74fc8334"
        ),
        .binaryTarget(
            name: "bare-inspect.3.1.5",
            url: "https://github.com/Jainakin/qvac-swift/releases/download/artifacts-sdk-0.17.0-r1/bare-inspect.3.1.5.xcframework.zip",
            checksum: "a14dd3eb94b2536bff3cc4fa9141dd6c21220b8b583e65cc4dadc3d2581c9614"
        ),
        .binaryTarget(
            name: "bare-os.3.9.3",
            url: "https://github.com/Jainakin/qvac-swift/releases/download/artifacts-sdk-0.17.0-r1/bare-os.3.9.3.xcframework.zip",
            checksum: "4f24517c43b306941e8053b0c8bb3c7ba0b6599849fac422b7732950ddae9311"
        ),
        .binaryTarget(
            name: "bare-path.3.1.1",
            url: "https://github.com/Jainakin/qvac-swift/releases/download/artifacts-sdk-0.17.0-r1/bare-path.3.1.1.xcframework.zip",
            checksum: "376b4bafcd56bf9c586350f6d09c2c3ed06e93103375b02f7678d2ef744b5f90"
        ),
        .binaryTarget(
            name: "bare-performance.2.1.1",
            url: "https://github.com/Jainakin/qvac-swift/releases/download/artifacts-sdk-0.17.0-r1/bare-performance.2.1.1.xcframework.zip",
            checksum: "3d0fc6711b85461ebc4d1b416149f1e8195ceb2319adc0bb040fdf38a7cb66ff"
        ),
        .binaryTarget(
            name: "bare-pipe.4.3.1",
            url: "https://github.com/Jainakin/qvac-swift/releases/download/artifacts-sdk-0.17.0-r1/bare-pipe.4.3.1.xcframework.zip",
            checksum: "15b07c312d0f7ced86d0e78b5851ee0aef778ca070535854da078144dbb48214"
        ),
        .binaryTarget(
            name: "bare-signals.4.2.0",
            url: "https://github.com/Jainakin/qvac-swift/releases/download/artifacts-sdk-0.17.0-r1/bare-signals.4.2.0.xcframework.zip",
            checksum: "b4cba67d77e21235ce08aea1a8e1303ceae86df341deb8804ae6680b4f4b4e86"
        ),
        .binaryTarget(
            name: "bare-tcp.2.6.1",
            url: "https://github.com/Jainakin/qvac-swift/releases/download/artifacts-sdk-0.17.0-r1/bare-tcp.2.6.1.xcframework.zip",
            checksum: "7537bab343a61565eeb9aba2da444bf953e313c906ac52746ce825cfb58fc84e"
        ),
        .binaryTarget(
            name: "bare-tls.3.1.10",
            url: "https://github.com/Jainakin/qvac-swift/releases/download/artifacts-sdk-0.17.0-r1/bare-tls.3.1.10.xcframework.zip",
            checksum: "0fd48388fd7c6ac3a7579c428ccdf9a0908481dfb3241793a6f0f323a9e45cd4"
        ),
        .binaryTarget(
            name: "bare-type.1.1.0",
            url: "https://github.com/Jainakin/qvac-swift/releases/download/artifacts-sdk-0.17.0-r1/bare-type.1.1.0.xcframework.zip",
            checksum: "576a475a0eebf1b3d878354f7adbbb38f889fa93e4c309d8737b43e407132db5"
        ),
        .binaryTarget(
            name: "bare-url.2.5.2",
            url: "https://github.com/Jainakin/qvac-swift/releases/download/artifacts-sdk-0.17.0-r1/bare-url.2.5.2.xcframework.zip",
            checksum: "4514afac7687be88403273a5b15e63f6f25ee09a98104db51087370333d4560b"
        ),
        .binaryTarget(
            name: "bare-zlib.1.4.1",
            url: "https://github.com/Jainakin/qvac-swift/releases/download/artifacts-sdk-0.17.0-r1/bare-zlib.1.4.1.xcframework.zip",
            checksum: "558b73d4161cd3c57d73763cea2f382a772c35a12890547f9504b78050b079bf"
        ),
        .binaryTarget(
            name: "fs-native-extensions.1.5.0",
            url: "https://github.com/Jainakin/qvac-swift/releases/download/artifacts-sdk-0.17.0-r1/fs-native-extensions.1.5.0.xcframework.zip",
            checksum: "66e1694f955517f90156a26dcda5339dbb5aaa1a7a076b1660cbb367eaae4683"
        ),
        .binaryTarget(
            name: "quickbit-native.2.4.8",
            url: "https://github.com/Jainakin/qvac-swift/releases/download/artifacts-sdk-0.17.0-r1/quickbit-native.2.4.8.xcframework.zip",
            checksum: "531b942590149d4c5c88488420addaaeb51db40d69bb3ae74d8fa7886b984817"
        ),
        .binaryTarget(
            name: "qvac__asr-ggml.0.1.1",
            url: "https://github.com/Jainakin/qvac-swift/releases/download/artifacts-sdk-0.17.0-r1/qvac__asr-ggml.0.1.1.xcframework.zip",
            checksum: "48c6de9ea3ec3aa04cbeea5788a88a06698511c376b9a803f4d1a88e0a87c9dc"
        ),
        .binaryTarget(
            name: "qvac__audiogen-ggml.0.1.1",
            url: "https://github.com/Jainakin/qvac-swift/releases/download/artifacts-sdk-0.17.0-r1/qvac__audiogen-ggml.0.1.1.xcframework.zip",
            checksum: "221db672c8fdbbc575eb8c9d8eb54c056192683d2356fa7becccfbe176fdabb7"
        ),
        .binaryTarget(
            name: "qvac__bci-whispercpp.0.6.0",
            url: "https://github.com/Jainakin/qvac-swift/releases/download/artifacts-sdk-0.17.0-r1/qvac__bci-whispercpp.0.6.0.xcframework.zip",
            checksum: "d2e5fd2c049d4e7e63e2a4325d62dd0675e9cfacd091bf9d1f23b81ff1846d44"
        ),
        .binaryTarget(
            name: "qvac__classification-ggml.0.15.1",
            url: "https://github.com/Jainakin/qvac-swift/releases/download/artifacts-sdk-0.17.0-r1/qvac__classification-ggml.0.15.1.xcframework.zip",
            checksum: "a48d71b834b363c781aeb73e7238305d3a1e932c5fb3b780d56fe63fb79de15e"
        ),
        .binaryTarget(
            name: "qvac__diffusion-cpp.0.17.0",
            url: "https://github.com/Jainakin/qvac-swift/releases/download/artifacts-sdk-0.17.0-r1/qvac__diffusion-cpp.0.17.0.xcframework.zip",
            checksum: "b0a36fcd378a54d3060d36fdf5516145801a5a43f4c305f693bd97f318ee1cf8"
        ),
        .binaryTarget(
            name: "qvac__embed-llamacpp.0.30.1",
            url: "https://github.com/Jainakin/qvac-swift/releases/download/artifacts-sdk-0.17.0-r1/qvac__embed-llamacpp.0.30.1.xcframework.zip",
            checksum: "7d1daab6982125dc0e6fdd848d003b5af8d999726747ab744d4545ecaeb0da7c"
        ),
        .binaryTarget(
            name: "qvac__fabric.0.3.1",
            url: "https://github.com/Jainakin/qvac-swift/releases/download/artifacts-sdk-0.17.0-r1/qvac__fabric.0.3.1.xcframework.zip",
            checksum: "c63cf774b729d6434710159b1ff2e5287661d6df722e58b9117c743b2a74ee14"
        ),
        .binaryTarget(
            name: "qvac__llm-llamacpp.0.39.4",
            url: "https://github.com/Jainakin/qvac-swift/releases/download/artifacts-sdk-0.17.0-r1/qvac__llm-llamacpp.0.39.4.xcframework.zip",
            checksum: "f1ca5b4c375f98ee66b1fb6ccb177bb46b48c44541cd08eb8480e09e3549538d"
        ),
        .binaryTarget(
            name: "qvac__ocr-ggml.0.13.1",
            url: "https://github.com/Jainakin/qvac-swift/releases/download/artifacts-sdk-0.17.0-r1/qvac__ocr-ggml.0.13.1.xcframework.zip",
            checksum: "93b8f35b2c1233d561364a9cbe318b55bb4641f9356a6dfb933882b76e6aedd2"
        ),
        .binaryTarget(
            name: "qvac__translation-nmtcpp.8.3.1",
            url: "https://github.com/Jainakin/qvac-swift/releases/download/artifacts-sdk-0.17.0-r1/qvac__translation-nmtcpp.8.3.1.xcframework.zip",
            checksum: "b017cfa60b550074b7ccf1f5b1234988245212fc706e1c9e1acbf0cd578df983"
        ),
        .binaryTarget(
            name: "qvac__tts-ggml.0.6.3",
            url: "https://github.com/Jainakin/qvac-swift/releases/download/artifacts-sdk-0.17.0-r1/qvac__tts-ggml.0.6.3.xcframework.zip",
            checksum: "6a58bc182978b6c81bff02cf825b413d78e69afa13178ba59b33ea9f9662a17d"
        ),
        .binaryTarget(
            name: "qvac__vla-ggml.0.16.2",
            url: "https://github.com/Jainakin/qvac-swift/releases/download/artifacts-sdk-0.17.0-r1/qvac__vla-ggml.0.16.2.xcframework.zip",
            checksum: "a1aca1dd4208f24f978030df5bd86d80d95622f6c72f56dd1802aa0b741be610"
        ),
        .binaryTarget(
            name: "rabin-native.2.0.0",
            url: "https://github.com/Jainakin/qvac-swift/releases/download/artifacts-sdk-0.17.0-r1/rabin-native.2.0.0.xcframework.zip",
            checksum: "be6f969fad5a259a58d6fd69166e5b6cd47c17cb1f3f8ad3f29f6bd19e150680"
        ),
        .binaryTarget(
            name: "rocksdb-native.3.17.4",
            url: "https://github.com/Jainakin/qvac-swift/releases/download/artifacts-sdk-0.17.0-r1/rocksdb-native.3.17.4.xcframework.zip",
            checksum: "87478026bccabbbf708d949d9a94048458a0b07cc6d79f13db1f531f10663a42"
        ),
        .binaryTarget(
            name: "simdle-native.1.3.9",
            url: "https://github.com/Jainakin/qvac-swift/releases/download/artifacts-sdk-0.17.0-r1/simdle-native.1.3.9.xcframework.zip",
            checksum: "6e1e316820d2e9696fa6937759480dbddc85471677c809909fd2bfd8514fdee0"
        ),
        .binaryTarget(
            name: "sodium-native.5.1.0",
            url: "https://github.com/Jainakin/qvac-swift/releases/download/artifacts-sdk-0.17.0-r1/sodium-native.5.1.0.xcframework.zip",
            checksum: "6fa255ff712980b4b74b361b9a54ec50e78ac1438f95bda520ac7bfdb69b9f9f"
        ),
        .binaryTarget(
            name: "udx-native.1.21.1",
            url: "https://github.com/Jainakin/qvac-swift/releases/download/artifacts-sdk-0.17.0-r1/udx-native.1.21.1.xcframework.zip",
            checksum: "0aed8e2b0196409f27588803fb8957250930ad228ee3c5ffcc7b6f2375a0e190"
        ),
        .target(
            name: "QVACClient",
            dependencies: [
                .target(name: "BareKit", condition: .when(platforms: [.iOS])),
                .target(name: "bare-buffer.3.7.0", condition: .when(platforms: [.iOS])),
                .target(name: "bare-cpu-info.0.1.1", condition: .when(platforms: [.iOS])),
                .target(name: "bare-crypto.1.15.3", condition: .when(platforms: [.iOS])),
                .target(name: "bare-dns.2.2.0", condition: .when(platforms: [.iOS])),
                .target(name: "bare-ffmpeg.1.5.0", condition: .when(platforms: [.iOS])),
                .target(name: "bare-fs.4.8.1", condition: .when(platforms: [.iOS])),
                .target(name: "bare-gpu-info.0.1.1", condition: .when(platforms: [.iOS])),
                .target(name: "bare-inspect.3.1.5", condition: .when(platforms: [.iOS])),
                .target(name: "bare-os.3.9.3", condition: .when(platforms: [.iOS])),
                .target(name: "bare-path.3.1.1", condition: .when(platforms: [.iOS])),
                .target(name: "bare-performance.2.1.1", condition: .when(platforms: [.iOS])),
                .target(name: "bare-pipe.4.3.1", condition: .when(platforms: [.iOS])),
                .target(name: "bare-signals.4.2.0", condition: .when(platforms: [.iOS])),
                .target(name: "bare-tcp.2.6.1", condition: .when(platforms: [.iOS])),
                .target(name: "bare-tls.3.1.10", condition: .when(platforms: [.iOS])),
                .target(name: "bare-type.1.1.0", condition: .when(platforms: [.iOS])),
                .target(name: "bare-url.2.5.2", condition: .when(platforms: [.iOS])),
                .target(name: "bare-zlib.1.4.1", condition: .when(platforms: [.iOS])),
                .target(name: "fs-native-extensions.1.5.0", condition: .when(platforms: [.iOS])),
                .target(name: "quickbit-native.2.4.8", condition: .when(platforms: [.iOS])),
                .target(name: "qvac__asr-ggml.0.1.1", condition: .when(platforms: [.iOS])),
                .target(name: "qvac__audiogen-ggml.0.1.1", condition: .when(platforms: [.iOS])),
                .target(name: "qvac__bci-whispercpp.0.6.0", condition: .when(platforms: [.iOS])),
                .target(name: "qvac__classification-ggml.0.15.1", condition: .when(platforms: [.iOS])),
                .target(name: "qvac__diffusion-cpp.0.17.0", condition: .when(platforms: [.iOS])),
                .target(name: "qvac__embed-llamacpp.0.30.1", condition: .when(platforms: [.iOS])),
                .target(name: "qvac__fabric.0.3.1", condition: .when(platforms: [.iOS])),
                .target(name: "qvac__llm-llamacpp.0.39.4", condition: .when(platforms: [.iOS])),
                .target(name: "qvac__ocr-ggml.0.13.1", condition: .when(platforms: [.iOS])),
                .target(name: "qvac__translation-nmtcpp.8.3.1", condition: .when(platforms: [.iOS])),
                .target(name: "qvac__tts-ggml.0.6.3", condition: .when(platforms: [.iOS])),
                .target(name: "qvac__vla-ggml.0.16.2", condition: .when(platforms: [.iOS])),
                .target(name: "rabin-native.2.0.0", condition: .when(platforms: [.iOS])),
                .target(name: "rocksdb-native.3.17.4", condition: .when(platforms: [.iOS])),
                .target(name: "simdle-native.1.3.9", condition: .when(platforms: [.iOS])),
                .target(name: "sodium-native.5.1.0", condition: .when(platforms: [.iOS])),
                .target(name: "udx-native.1.21.1", condition: .when(platforms: [.iOS])),
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
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "QVACClientIntegrationTests",
            dependencies: ["QVACClient"],
            path: "Tests/QVACClientIntegrationTests"
        ),
    ]
)
