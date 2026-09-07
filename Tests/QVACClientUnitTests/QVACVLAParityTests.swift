import Foundation
import XCTest
@testable import QVACClient

final class QVACVLAParityTests: XCTestCase {
    private let footprintTestCameraCount = 64
    private struct UnexpectedTransportIO: Error {}

    private actor NoIOTransport: BareTransport {
        nonisolated func inboundStream() -> AsyncThrowingStream<Data, Error> {
            AsyncThrowingStream { _ in }
        }

        func write(_ data: Data) async throws {
            XCTFail("VLA input validation unexpectedly reached the transport (\(data.count) bytes)")
            throw UnexpectedTransportIO()
        }

        func close() {}
    }

    func test_preprocess_hwc_bytes_matches_published_017_javascript_fixture() throws {
        let output = try vlaPreprocessImage(
            [255, 0, 127, 0, 255, 128] as [UInt8],
            width: 2,
            height: 1,
            options: .init(size: 3, layout: .hwc)
        )
        XCTAssertEqual(
            littleEndianBase64(output),
            "AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAPwAAAAAAAIC/"
                + "AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAAAAAAIA/"
                + "AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/gYCAuwAAAACBgIA7"
        )
    }

    func test_preprocess_chw_float_matches_published_017_javascript_fixture() throws {
        let output = try vlaPreprocessImage(
            [0, 1, 0.25, 0.75, 0.5, 0.125] as [Float],
            width: 2,
            height: 1,
            options: .init(size: 3, layout: .chw, scale: 1)
        )
        XCTAssertEqual(
            littleEndianBase64(output),
            "AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAAAAAAIA/"
                + "AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AAAAvwAAAAAAAAA/"
                + "AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AAAAAAAAwL4AAEC/"
        )
    }

    func test_preprocess_square_bilinear_upscale_matches_pinned_017_bit_patterns() throws {
        let hwc = [
            0, 0.25, 0.5,
            1, 0.75, 0.125,
            0.5, 1, 0.375,
            0.25, 0, 0.875,
        ] as [Double]
        let chw = [
            0, 1, 0.5, 0.25,
            0.25, 0.75, 1, 0,
            0.5, 0.125, 0.375, 0.875,
        ] as [Double]
        let expected: [UInt32] = [
            0xbf80_0000, 0x0000_0000, 0x3f80_0000,
            0xbf00_0000, 0xbe00_0000, 0x3e80_0000,
            0x0000_0000, 0xbe80_0000, 0xbf00_0000,
            0xbf00_0000, 0x0000_0000, 0x3f00_0000,
            0x3e80_0000, 0x0000_0000, 0xbe80_0000,
            0x3f80_0000, 0x0000_0000, 0xbf80_0000,
            0x0000_0000, 0xbec0_0000, 0xbf40_0000,
            0xbe00_0000, 0xbd80_0000, 0x0000_0000,
            0xbe80_0000, 0x3e80_0000, 0x3f40_0000,
        ]

        assertBitPatterns(
            try vlaPreprocessImage(
                hwc,
                width: 2,
                height: 2,
                options: .init(size: 3, layout: .hwc, scale: 1)
            ),
            expected
        )
        assertBitPatterns(
            try vlaPreprocessImage(
                chw,
                width: 2,
                height: 2,
                options: .init(size: 3, layout: .chw, scale: 1)
            ),
            expected
        )
    }

    func test_preprocess_portrait_and_landscape_downscale_match_pinned_017_bits() throws {
        let portrait = [
            0, 0.125, 0.25,
            0.375, 0.5, 0.625,
            0.75, 0.875, 1,
            1, 0.75, 0.5,
            0.25, 0, 0.5,
            0.625, 0.375, 0.125,
        ] as [Double]
        assertBitPatterns(
            try vlaPreprocessImage(
                portrait,
                width: 2,
                height: 3,
                options: .init(size: 2, layout: .hwc, scale: 1)
            ),
            [
                0xbf80_0000, 0xbe90_0000, 0xbf80_0000, 0x3dc0_0000,
                0xbf80_0000, 0xbe00_0000, 0xbf80_0000, 0xbea0_0000,
                0xbf80_0000, 0x3d00_0000, 0xbf80_0000, 0xbe20_0000,
            ]
        )

        let landscape = [
            0, 0.25, 0.5, 0.75, 1, 0.5,
            1, 0.75, 0.5, 0.25, 0, 0.5,
            0.125, 0.375, 0.625, 0.875, 0.625, 0.375,
        ] as [Double]
        assertBitPatterns(
            try vlaPreprocessImage(
                landscape,
                width: 3,
                height: 2,
                options: .init(size: 2, layout: .chw, scale: 1)
            ),
            [
                0xbf80_0000, 0xbf80_0000, 0xbe00_0000, 0x3d80_0000,
                0xbf80_0000, 0xbf80_0000, 0x3e00_0000, 0xbd80_0000,
                0xbf80_0000, 0xbf80_0000, 0x0000_0000, 0x0000_0000,
            ]
        )
    }

    func test_preprocess_degenerate_axes_match_pinned_017_bits() throws {
        assertBitPatterns(
            try vlaPreprocessImage(
                [0, 64, 255, 128, 192, 32, 255, 0, 127] as [UInt8],
                width: 3,
                height: 1,
                options: .init(size: 2)
            ),
            [
                0xbf80_0000, 0xbf80_0000, 0xbf3f_bfc0, 0x3f40_4040,
                0xbf80_0000, 0xbf80_0000, 0xbe7c_fcfd, 0xbf1f_9fa0,
                0xbf80_0000, 0xbf80_0000, 0x3f10_1010, 0xbe42_c2c3,
            ]
        )
        assertBitPatterns(
            try vlaPreprocessImage(
                [0, 0.5, 1, 1, 0.25, 0, 0.125, 0.875, 0.5] as [Double],
                width: 1,
                height: 3,
                options: .init(size: 2, layout: .chw)
            ),
            [
                0xbf80_0000, 0xbf40_0000, 0xbf80_0000, 0x3f40_0000,
                0xbf80_0000, 0x3f20_0000, 0xbf80_0000, 0xbf60_0000,
                0xbf80_0000, 0xbec0_0000, 0xbf80_0000, 0x3e40_0000,
            ]
        )
    }

    func test_preprocess_scale_detection_boundaries_match_pinned_017_bits() throws {
        assertBitPatterns(
            try vlaPreprocessImage(
                [1.001, 0.5, 0] as [Double],
                width: 1,
                height: 1,
                options: .init(size: 1)
            ),
            [0x3f80_4189, 0x0000_0000, 0xbf80_0000]
        )
        assertBitPatterns(
            try vlaPreprocessImage(
                [Double(1.001).nextUp, 0.5, 0],
                width: 1,
                height: 1,
                options: .init(size: 1)
            ),
            [0xbf7d_fd7a, 0xbf7e_feff, 0xbf80_0000]
        )
        assertBitPatterns(
            try vlaPreprocessImage(
                [Float(1.001), 0.5, 0],
                width: 1,
                height: 1,
                options: .init(size: 1)
            ),
            [0xbf7d_fd7a, 0xbf7e_feff, 0xbf80_0000]
        )
        assertBitPatterns(
            try vlaPreprocessImage(
                [1, 0, 1] as [UInt8],
                width: 1,
                height: 1,
                options: .init(size: 1)
            ),
            [0xbf7d_fdfe, 0xbf80_0000, 0xbf7d_fdfe]
        )
        assertBitPatterns(
            try vlaPreprocessImage(
                [1, 0, 1] as [Double],
                width: 1,
                height: 1,
                options: .init(size: 1)
            ),
            [0x3f80_0000, 0xbf80_0000, 0x3f80_0000]
        )
    }

    func test_preprocess_scale_detection_scans_only_first_256_values_like_017() throws {
        var values = [Double](repeating: 1, count: 258)
        values[256] = 255
        assertBitPatterns(
            try vlaPreprocessImage(values, width: 86, height: 1, options: .init(size: 1)),
            [0x3f80_0000, 0x3f80_0000, 0x3f80_0000]
        )
    }

    func test_pad_state_matches_published_017_javascript_fixture() throws {
        let padded = try vlaPadState([1.5, -2] as [Float], targetDimension: 4)
        XCTAssertEqual(padded, [1.5, -2, 0, 0])
        XCTAssertEqual(littleEndianBase64(padded), "AADAPwAAAMAAAAAAAAAAAA==")
    }

    func test_preprocessing_and_padding_validate_shape() throws {
        XCTAssertThrowsError(try vlaPreprocessImage([UInt8](repeating: 0, count: 5), width: 1, height: 2))
        XCTAssertThrowsError(try vlaPreprocessImage([UInt8](repeating: 0, count: 3), width: 1, height: 1, options: .init(size: 0)))
        XCTAssertThrowsError(try vlaPadState([1, 2] as [Float], targetDimension: 1))
    }

    func test_double_overloads_match_byte_autoscaling_and_float_padding() throws {
        let bytes = [255, 0, 127, 0, 255, 128] as [UInt8]
        let doubles = bytes.map(Double.init)
        XCTAssertEqual(
            try vlaPreprocessImage(bytes, width: 2, height: 1, options: .init(size: 3)),
            try vlaPreprocessImage(doubles, width: 2, height: 1, options: .init(size: 3))
        )
        XCTAssertEqual(
            try vlaPadState([1.5, -2] as [Double], targetDimension: 4),
            [1.5, -2, 0, 0]
        )

        let explicitByteScale = try vlaPreprocessImage(
            doubles,
            width: 2,
            height: 1,
            options: .init(size: 3, scale: 1 / 255)
        )
        XCTAssertEqual(explicitByteScale, try vlaPreprocessImage(bytes, width: 2, height: 1, options: .init(size: 3)))
        XCTAssertEqual(
            try vlaPreprocessImage(
                doubles,
                width: 2,
                height: 1,
                options: .init(size: 3, scale: .nan)
            ),
            explicitByteScale,
            "an unsupported explicit scale must fall back to data-driven scale detection"
        )

        let portrait = try vlaPreprocessImage(
            [255, 0, 0, 0, 255, 0] as [UInt8],
            width: 1,
            height: 2,
            options: .init(size: 2)
        )
        XCTAssertEqual(portrait.count, 12)
        XCTAssertEqual(Array(portrait[0..<4]), [-1, 1, -1, -1])
        XCTAssertEqual(Array(portrait[4..<8]), [-1, -1, -1, 1])
        XCTAssertEqual(Array(portrait[8..<12]), [-1, -1, -1, -1])
    }

    func test_preprocessing_rejects_invalid_dimensions_and_arithmetic_overflow() {
        XCTAssertThrowsError(
            try vlaPreprocessImage([] as [Double], width: 0, height: 1)
        )
        XCTAssertThrowsError(
            try vlaPreprocessImage([] as [Double], width: 1, height: 0)
        )
        XCTAssertThrowsError(
            try vlaPreprocessImage([] as [Double], width: Int.max, height: Int.max)
        )
        XCTAssertThrowsError(
            try vlaPreprocessImage(
                [0, 0, 0] as [Double],
                width: 1,
                height: 1,
                options: .init(size: Int.max)
            )
        )
        XCTAssertThrowsError(
            try vlaPreprocessImage(
                [0, 0, 0] as [Double],
                width: 1,
                height: 1,
                options: .init(size: 1_000_000_000)
            )
        )
        XCTAssertThrowsError(
            try vlaPreprocessImage(
                [0, 0, 0] as [Double],
                width: 1,
                height: 1,
                options: .init(size: 10_000)
            )
        )
        XCTAssertThrowsError(
            try vlaPadState([] as [Double], targetDimension: 0)
        )
        XCTAssertThrowsError(
            try vlaPadState([] as [Double], targetDimension: Int.max)
        )
        XCTAssertThrowsError(
            try vlaPadState([] as [Double], targetDimension: 20_000_000)
        )
    }

    func test_tensor_footprint_math_is_checked_at_both_safety_boundaries() throws {
        XCTAssertEqual(qvacBase64EncodedByteCount(0), 0)
        XCTAssertEqual(qvacBase64EncodedByteCount(1), 4)
        XCTAssertEqual(qvacBase64EncodedByteCount(2), 4)
        XCTAssertEqual(qvacBase64EncodedByteCount(3), 4)
        XCTAssertEqual(qvacBase64EncodedByteCount(4), 8)
        XCTAssertNil(qvacBase64EncodedByteCount(-1))
        XCTAssertNil(qvacBase64EncodedByteCount(Int.max))
        XCTAssertNil(vlaTensorFootprint([(elementCount: Int.max, elementStride: 4)]))
        XCTAssertNil(vlaTensorFootprint([(elementCount: 1, elementStride: 0)]))

        let exactElementCount = vlaMaximumClientRequestTensorBytes / MemoryLayout<Float>.stride
        let exact = try vlaValidateRequestTensorFootprint([
            (elementCount: exactElementCount, elementStride: MemoryLayout<Float>.stride),
        ])
        XCTAssertEqual(exact.rawByteCount, vlaMaximumClientRequestTensorBytes)
        XCTAssertEqual(
            exact.base64ByteCount,
            qvacBase64EncodedByteCount(vlaMaximumClientRequestTensorBytes)
        )
        XCTAssertThrowsError(try vlaValidateRequestTensorFootprint([
            (elementCount: exactElementCount + 1, elementStride: MemoryLayout<Float>.stride),
        ]))
        XCTAssertThrowsError(try vlaValidateRequestTensorFootprint(
            [
                (elementCount: exactElementCount / 2 + 1, elementStride: 4),
                (elementCount: exactElementCount / 2 + 1, elementStride: 4),
            ],
            rawByteLimit: vlaMaximumClientRequestTensorBytes,
            encodedByteLimit: vlaMaximumClientEncodedRequestBytes
        ))
        XCTAssertThrowsError(try vlaValidateRequestTensorFootprint(
            [
                (elementCount: 1, elementStride: 1),
                (elementCount: 1, elementStride: 1),
            ],
            rawByteLimit: 2,
            encodedByteLimit: 7
        ))
    }

    func test_preprocessing_and_padding_reject_nonfinite_float32_results() {
        for value in [Float.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(
                try vlaPreprocessImage([value, 0, 0], width: 1, height: 1)
            )
            XCTAssertThrowsError(try vlaPadState([value], targetDimension: 2))
        }
        for value in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude] {
            XCTAssertThrowsError(
                try vlaPreprocessImage([value, 0, 0], width: 1, height: 1)
            )
            XCTAssertThrowsError(try vlaPadState([value], targetDimension: 2))
        }
    }

    func test_vla_action_budget_defaults_clamp_and_preserve_explicit_limit() async {
        let defaulted = QVACClient(testing: NoIOTransport())
        let wireClamped = QVACClient(
            testing: NoIOTransport(),
            maximumWireMessageBytes: 4_096
        )
        let aggregateClamped = QVACClient(
            testing: NoIOTransport(),
            maximumWireMessageBytes: 4_096,
            maximumAccumulatedResultBytes: 2_048
        )
        let configured = QVACClient(
            testing: NoIOTransport(),
            maximumWireMessageBytes: 4_096,
            maximumAccumulatedResultBytes: 2_048,
            maximumVLAActionBytes: 1_024
        )

        let limits = await (
            defaulted.maximumVLAActionBytes,
            wireClamped.maximumVLAActionBytes,
            aggregateClamped.maximumVLAActionBytes,
            configured.maximumVLAActionBytes
        )
        XCTAssertEqual(limits.0, QVACClient.defaultMaximumVLAActionBytes)
        XCTAssertEqual(limits.1, 4_096)
        XCTAssertEqual(limits.2, 2_048)
        XCTAssertEqual(limits.3, 1_024)

        await defaulted.close()
        await wireClamped.close()
        await aggregateClamped.close()
        await configured.close()
    }

    func test_public_initializer_rejects_invalid_vla_action_limits_before_io() async {
        let cases: [(String, () async throws -> QVACClient)] = [
            ("zero", {
                try await QVACClient(
                    configuration: .testing(NoIOTransport()),
                    runtimeContext: nil,
                    maximumVLAActionBytes: 0,
                    logger: nil
                )
            }),
            ("wire", {
                try await QVACClient(
                    configuration: .testing(NoIOTransport()),
                    runtimeContext: nil,
                    maximumWireMessageBytes: 1_024,
                    maximumVLAActionBytes: 1_025,
                    logger: nil
                )
            }),
            ("aggregate", {
                try await QVACClient(
                    configuration: .testing(NoIOTransport()),
                    runtimeContext: nil,
                    maximumWireMessageBytes: 1_024,
                    maximumAccumulatedResultBytes: 512,
                    maximumVLAActionBytes: 513,
                    logger: nil
                )
            }),
        ]

        for (boundary, makeClient) in cases {
            do {
                let client = try await makeClient()
                await client.close()
                XCTFail("invalid maximumVLAActionBytes \(boundary) boundary was accepted")
            } catch let QVACError.invalidArgument(message) {
                XCTAssertTrue(message.contains("maximumVLAActionBytes"), message)
            } catch {
                XCTFail("expected invalidArgument for \(boundary) boundary, got \(error)")
            }
        }
    }

    func test_vla_rejects_every_locally_invalid_tensor_shape_before_io() async {
        let client = QVACClient(testing: NoIOTransport())
        let valid = QVACClient.VLAParameters(
            modelId: "vla-model",
            images: [[0, 0, 0]],
            imageWidth: 1,
            imageHeight: 1,
            state: [],
            tokens: [1],
            mask: [1]
        )
        let budgetCrossingImage = [Float](
            repeating: 0,
            count: vlaMaximumClientRequestTensorBytes
                / footprintTestCameraCount
                / MemoryLayout<Float>.stride + 1
        )
        let invalid: [(QVACClient.VLAParameters, String)] = [
            (
                .init(
                    modelId: valid.modelId,
                    images: valid.images,
                    imageWidth: 0,
                    imageHeight: valid.imageHeight,
                    state: valid.state,
                    tokens: valid.tokens,
                    mask: valid.mask
                ),
                "dimensions"
            ),
            (
                .init(
                    modelId: valid.modelId,
                    images: valid.images,
                    imageWidth: Int.max,
                    imageHeight: valid.imageHeight,
                    state: valid.state,
                    tokens: valid.tokens,
                    mask: valid.mask
                ),
                "dimensions"
            ),
            (
                .init(
                    modelId: valid.modelId,
                    images: valid.images,
                    imageWidth: valid.imageWidth,
                    imageHeight: 0,
                    state: valid.state,
                    tokens: valid.tokens,
                    mask: valid.mask
                ),
                "dimensions"
            ),
            (
                .init(
                    modelId: valid.modelId,
                    images: [],
                    imageWidth: valid.imageWidth,
                    imageHeight: valid.imageHeight,
                    state: valid.state,
                    tokens: valid.tokens,
                    mask: valid.mask
                ),
                "non-empty image"
            ),
            (
                .init(
                    modelId: valid.modelId,
                    images: Array(
                        repeating: valid.images[0],
                        count: QVACClient.defaultMaximumInlineBinaryItems - 2
                    ),
                    imageWidth: valid.imageWidth,
                    imageHeight: valid.imageHeight,
                    state: valid.state,
                    tokens: valid.tokens,
                    mask: valid.mask
                ),
                "maximumInlineBinaryItems"
            ),
            (
                .init(
                    modelId: valid.modelId,
                    images: [[]],
                    imageWidth: valid.imageWidth,
                    imageHeight: valid.imageHeight,
                    state: valid.state,
                    tokens: valid.tokens,
                    mask: valid.mask
                ),
                "non-empty image"
            ),
            (
                .init(
                    modelId: valid.modelId,
                    images: valid.images,
                    imageWidth: valid.imageWidth,
                    imageHeight: valid.imageHeight,
                    state: valid.state,
                    tokens: [],
                    mask: valid.mask
                ),
                "tokens"
            ),
            (
                .init(
                    modelId: valid.modelId,
                    images: valid.images,
                    imageWidth: valid.imageWidth,
                    imageHeight: valid.imageHeight,
                    state: valid.state,
                    tokens: valid.tokens,
                    mask: []
                ),
                "mask"
            ),
            (
                .init(
                    modelId: valid.modelId,
                    images: valid.images,
                    imageWidth: valid.imageWidth,
                    imageHeight: valid.imageHeight,
                    state: valid.state,
                    tokens: [1, 2],
                    mask: [1]
                ),
                "same length"
            ),
            (
                .init(
                    modelId: valid.modelId,
                    images: valid.images,
                    imageWidth: valid.imageWidth,
                    imageHeight: valid.imageHeight,
                    state: valid.state,
                    tokens: valid.tokens,
                    mask: valid.mask,
                    noise: []
                ),
                "noise"
            ),
            (
                .init(
                    modelId: valid.modelId,
                    images: [[.nan]],
                    imageWidth: valid.imageWidth,
                    imageHeight: valid.imageHeight,
                    state: valid.state,
                    tokens: valid.tokens,
                    mask: valid.mask
                ),
                "image tensors"
            ),
            (
                .init(
                    modelId: valid.modelId,
                    images: valid.images,
                    imageWidth: valid.imageWidth,
                    imageHeight: valid.imageHeight,
                    state: [.infinity],
                    tokens: valid.tokens,
                    mask: valid.mask
                ),
                "state"
            ),
            (
                .init(
                    modelId: valid.modelId,
                    images: valid.images,
                    imageWidth: valid.imageWidth,
                    imageHeight: valid.imageHeight,
                    state: valid.state,
                    tokens: valid.tokens,
                    mask: valid.mask,
                    noise: [.nan]
                ),
                "noise"
            ),
            (
                .init(
                    modelId: valid.modelId,
                    images: Array(
                        repeating: budgetCrossingImage,
                        count: footprintTestCameraCount
                    ),
                    imageWidth: valid.imageWidth,
                    imageHeight: valid.imageHeight,
                    state: valid.state,
                    tokens: valid.tokens,
                    mask: valid.mask
                ),
                "raw-data limit"
            ),
        ]

        for (parameters, diagnostic) in invalid {
            do {
                _ = try await client.vla(parameters)
                XCTFail("VLA accepted invalid \(diagnostic) input")
            } catch let QVACError.invalidArgument(message) {
                XCTAssertTrue(message.contains(diagnostic), "unexpected diagnostic: \(message)")
            } catch {
                XCTFail("expected invalid argument for \(diagnostic), got \(error)")
            }
        }
        await client.close()
    }

    private func littleEndianBase64(_ values: [Float]) -> String {
        var data = Data(capacity: values.count * 4)
        for value in values {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data.base64EncodedString()
    }

    private func assertBitPatterns(
        _ actual: [Float],
        _ expected: [UInt32],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.map(\.bitPattern), expected, file: file, line: line)
    }
}
