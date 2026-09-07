import Foundation
import XCTest
@testable import QVACClient

/// Deterministic boundary tests for the client-wide finite resource policy.
final class QVACResourceLimitContractTests: XCTestCase {
    private final class InboundPipe: @unchecked Sendable {
        let stream: AsyncThrowingStream<Data, Error>
        let continuation: AsyncThrowingStream<Data, Error>.Continuation

        init() {
            var captured: AsyncThrowingStream<Data, Error>.Continuation!
            stream = AsyncThrowingStream { captured = $0 }
            continuation = captured
        }
    }

    private actor RecordingTransport: BareTransport {
        nonisolated private let inbound = InboundPipe()
        private var outboundBytes = Data()
        private var closeCount = 0
        private var closed = false

        nonisolated func inboundStream() -> AsyncThrowingStream<Data, Error> {
            inbound.stream
        }

        func write(_ data: Data) async throws {
            outboundBytes.append(data)
        }

        func close() {
            guard !closed else { return }
            closed = true
            closeCount += 1
            inbound.continuation.finish()
        }

        func feed(_ data: Data) {
            inbound.continuation.yield(data)
        }

        func snapshot() -> (outbound: Data, closes: Int) {
            (outboundBytes, closeCount)
        }
    }

    private enum MetadataEndpoint: CaseIterable, Sendable {
        case loadedModelInfo
        case modelInfo
        case systemResources
        case registryList
        case registrySearch
        case registryModel

        var operation: String {
            switch self {
            case .loadedModelInfo: "getLoadedModelInfo"
            case .modelInfo: "getModelInfo"
            case .systemResources: "getSystemResources"
            case .registryList: "modelRegistryList"
            case .registrySearch: "modelRegistrySearch"
            case .registryModel: "modelRegistryGetModel"
            }
        }

        func payload(padding: String) throws -> Data {
            let value: JSONValue = .object(["padding": .string(padding)])
            let response: QVACResponse = switch self {
            case .loadedModelInfo:
                .getLoadedModelInfo(.init(info: value))
            case .modelInfo:
                .getModelInfo(.init(modelInfo: value))
            case .systemResources:
                .getSystemResources(.init(capabilities: value))
            case .registryList:
                .modelRegistryList(.init(success: true, models: [value]))
            case .registrySearch:
                .modelRegistrySearch(.init(success: true, models: [value]))
            case .registryModel:
                .modelRegistryGetModel(.init(success: true, model: value))
            }
            return try JSONEncoder.qvac.encode(response)
        }

        func invoke(on client: QVACClient) async throws {
            switch self {
            case .loadedModelInfo:
                _ = try await client.getLoadedModelInfo(modelId: "model")
            case .modelInfo:
                _ = try await client.getModelInfo(name: "model")
            case .systemResources:
                _ = try await client.getSystemResources(sample: true)
            case .registryList:
                _ = try await client.modelRegistryList()
            case .registrySearch:
                _ = try await client.modelRegistrySearch(filter: "model")
            case .registryModel:
                _ = try await client.modelRegistryGetModel(
                    registryPath: "owner/model",
                    registrySource: "huggingface"
                )
            }
        }
    }

    private static func frames(in data: Data) throws -> [BareRPCFrame] {
        let reader = BareRPCFrameReader()
        try reader.append(data)
        var frames: [BareRPCFrame] = []
        while let frame = reader.next() { frames.append(frame) }
        return frames
    }

    private static func waitForRequest(
        on transport: RecordingTransport,
        minimumCount: Int = 1,
        timeout: Duration = .seconds(1)
    ) async throws -> (id: UInt64, payload: Data) {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            let snapshot = await transport.snapshot()
            let requests: [(id: UInt64, payload: Data)] = try frames(
                in: snapshot.outbound
            ).compactMap { frame -> (id: UInt64, payload: Data)? in
                guard case .request(let id, _, _, let payload?) = frame else { return nil }
                return (id, payload)
            }
            if requests.count >= minimumCount { return requests[minimumCount - 1] }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw QVACError.protocolViolation(
            "test peer did not observe request \(minimumCount)"
        )
    }

    private static func feedInitSuccess(
        id: UInt64,
        to transport: RecordingTransport
    ) async throws {
        let payload = try JSONSerialization.data(
            withJSONObject: ["success": true],
            options: [.sortedKeys]
        )
        await transport.feed(BareRPCCodec.__testEncodeResponseFrame(
            id: id,
            stream: [],
            payload: .success(payload)
        ))
    }

    private static func feedPluginResult(
        id: UInt64,
        result: JSONValue,
        to transport: RecordingTransport
    ) async throws {
        let payload = try JSONEncoder.qvac.encode(
            QVACResponse.pluginInvoke(.init(result: result))
        )
        await transport.feed(BareRPCCodec.__testEncodeResponseFrame(
            id: id,
            stream: [],
            payload: .success(payload)
        ))
    }

    private static func feedTerminalStream(
        id: UInt64,
        response: QVACResponse,
        to transport: RecordingTransport
    ) async throws {
        var record = try JSONEncoder.qvac.encode(response)
        record.append(0x0A)
        var frames = BareRPCCodec.__testEncodeResponseFrame(
            id: id,
            stream: [.open],
            payload: .success(nil)
        )
        frames.append(BareRPCCodec.__testEncodeStreamFrame(
            id: id,
            flags: [.response, .data],
            payload: .data(record)
        ))
        frames.append(BareRPCCodec.__testEncodeStreamFrame(
            id: id,
            flags: [.response, .end]
        ))
        await transport.feed(frames)
    }

    private static func float32Base64(_ values: [Float]) -> String {
        var data = Data(capacity: values.count * MemoryLayout<Float>.stride)
        for value in values {
            var littleEndian = value.bitPattern.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        return data.base64EncodedString()
    }

    func test_result_budget_accepts_exact_boundary_and_reports_one_byte_overrun() throws {
        var budget = QVACResultByteBudget(operation: "completion", maximumBytes: 10)
        try budget.consume(4)
        try budget.consume(6)
        XCTAssertEqual(budget.consumedBytes, 10)

        do {
            try budget.consume(1)
            XCTFail("one byte over the cumulative limit must fail")
        } catch let QVACError.resourceLimitExceeded(
            operation,
            resource,
            maximumBytes,
            attemptedBytes
        ) {
            XCTAssertEqual(operation, "completion")
            XCTAssertEqual(resource, "accumulated result bytes")
            XCTAssertEqual(maximumBytes, 10)
            XCTAssertEqual(attemptedBytes, 11)
        } catch {
            XCTFail("expected resourceLimitExceeded, got \(error)")
        }
        XCTAssertEqual(budget.consumedBytes, 10, "a rejected charge must not mutate state")

        XCTAssertEqual(QVACClient.retainedStringAggregateAppendBytes("é"), 4)
        var stringBudget = QVACResultByteBudget(operation: "translate", maximumBytes: 4)
        try stringBudget.consumeRetainedString("é")
        XCTAssertEqual(stringBudget.consumedBytes, 4)
    }

    func test_result_budget_rejects_negative_and_saturates_addition_overflow_atomically() throws {
        var negative = QVACResultByteBudget(operation: "ocrStream", maximumBytes: 8)
        do {
            try negative.consume(-1)
            XCTFail("negative accounting input must be rejected")
        } catch let QVACError.invalidArgument(message) {
            XCTAssertEqual(message, "ocrStream result byte count must not be negative")
        } catch {
            XCTFail("expected invalidArgument, got \(error)")
        }
        XCTAssertEqual(negative.consumedBytes, 0)

        var overflow = QVACResultByteBudget(
            operation: "batchCompletionStream",
            maximumBytes: Int.max
        )
        try overflow.consume(Int.max)
        do {
            try overflow.consume(1)
            XCTFail("overflowing cumulative accounting must fail closed")
        } catch let QVACError.resourceLimitExceeded(
            operation,
            resource,
            maximumBytes,
            attemptedBytes
        ) {
            XCTAssertEqual(operation, "batchCompletionStream")
            XCTAssertEqual(resource, "accumulated result bytes")
            XCTAssertEqual(maximumBytes, Int.max)
            XCTAssertEqual(attemptedBytes, Int.max)
        } catch {
            XCTFail("expected resourceLimitExceeded, got \(error)")
        }
        XCTAssertEqual(
            overflow.consumedBytes,
            Int.max,
            "an overflowing rejected charge must not mutate accounting state"
        )
    }

    func test_result_budget_replace_rejects_invalid_accounting_atomically() throws {
        var budget = QVACResultByteBudget(
            operation: "transcribe",
            maximumBytes: 10
        )
        try budget.consume(5)

        let invalidReplacements: [(previous: Int, new: Int, reason: String)] = [
            (-1, 0, "negative previous charge"),
            (0, -1, "negative replacement charge"),
            (6, 0, "previous charge larger than retained bytes"),
        ]
        for replacement in invalidReplacements {
            do {
                try budget.replace(replacement.previous, with: replacement.new)
                XCTFail("\(replacement.reason) must be rejected")
            } catch let QVACError.invalidArgument(message) {
                XCTAssertEqual(
                    message,
                    "transcribe replacement byte counts must describe retained result bytes"
                )
            } catch {
                XCTFail("expected invalidArgument for \(replacement.reason), got \(error)")
            }
            XCTAssertEqual(
                budget.consumedBytes,
                5,
                "an invalid replacement must leave the prior charge intact"
            )
        }
    }

    func test_result_budget_replace_enforces_boundary_and_saturates_overflow_atomically() throws {
        var boundary = QVACResultByteBudget(
            operation: "bci",
            resource: "retained BCI result bytes",
            maximumBytes: 10
        )
        try boundary.consume(6)
        try boundary.replace(2, with: 6)
        XCTAssertEqual(boundary.consumedBytes, 10, "an exact-boundary replacement must succeed")

        do {
            try boundary.replace(6, with: 7)
            XCTFail("a replacement one byte over the cumulative limit must fail")
        } catch let QVACError.resourceLimitExceeded(
            operation,
            resource,
            maximumBytes,
            attemptedBytes
        ) {
            XCTAssertEqual(operation, "bci")
            XCTAssertEqual(resource, "retained BCI result bytes")
            XCTAssertEqual(maximumBytes, 10)
            XCTAssertEqual(attemptedBytes, 11)
        } catch {
            XCTFail("expected resourceLimitExceeded, got \(error)")
        }
        XCTAssertEqual(
            boundary.consumedBytes,
            10,
            "an over-limit replacement must leave the prior charge intact"
        )

        try boundary.replace(6, with: 1)
        XCTAssertEqual(boundary.consumedBytes, 5, "a shrinking replacement must release its charge")

        var overflow = QVACResultByteBudget(
            operation: "transcribe",
            maximumBytes: Int.max
        )
        try overflow.consume(2)
        do {
            try overflow.replace(0, with: Int.max)
            XCTFail("overflowing replacement accounting must fail closed")
        } catch let QVACError.resourceLimitExceeded(
            operation,
            resource,
            maximumBytes,
            attemptedBytes
        ) {
            XCTAssertEqual(operation, "transcribe")
            XCTAssertEqual(resource, "accumulated result bytes")
            XCTAssertEqual(maximumBytes, Int.max)
            XCTAssertEqual(attemptedBytes, Int.max)
        } catch {
            XCTFail("expected resourceLimitExceeded, got \(error)")
        }
        XCTAssertEqual(
            overflow.consumedBytes,
            2,
            "an overflowing replacement must leave the prior charge intact"
        )
    }

    func test_strict_base64_preflight_is_exact_and_charges_before_decode() throws {
        let validSizes: [(String, Int)] = [
            ("AA==", 1),
            ("AAA=", 2),
            ("AAAA", 3),
            ("AAAAAA==", 4),
            ("AAAAAAA=", 5),
            ("AAAAAAAA", 6),
        ]
        for (encoded, expectedByteCount) in validSizes {
            XCTAssertEqual(
                qvacStrictBase64DecodedByteCount(encoded),
                expectedByteCount,
                encoded
            )
        }

        let invalidValues = [
            "",
            "A",
            "AAA",
            "AA?=",
            "AA-=",
            "AA_=",
            "AA==\n",
            "=AAA",
            "A=AA",
            "AA=A",
            "A===",
            "====",
        ]
        for encoded in invalidValues {
            XCTAssertNil(qvacStrictBase64DecodedByteCount(encoded), encoded)
        }

        let payload = Data([1, 2, 3])
        let retainedBytes = QVACClient.retainedBinaryArrayElementBytes(payload.count)
        var exact = QVACResultByteBudget(
            operation: "diffusionStream",
            maximumBytes: retainedBytes
        )
        XCTAssertEqual(
            try QVACClient.decodeRetainedBase64Output(
                payload.base64EncodedString(),
                invalidMessage: "invalid test base64",
                retention: .binaryArrayElement,
                resultBudget: &exact
            ),
            payload
        )
        XCTAssertEqual(exact.consumedBytes, retainedBytes)

        var oneByteBelow = QVACResultByteBudget(
            operation: "diffusionStream",
            maximumBytes: retainedBytes - 1
        )
        XCTAssertThrowsError(try QVACClient.decodeRetainedBase64Output(
            payload.base64EncodedString(),
            invalidMessage: "invalid test base64",
            retention: .binaryArrayElement,
            resultBudget: &oneByteBelow
        )) { error in
            guard case .resourceLimitExceeded(
                operation: "diffusionStream",
                resource: "accumulated result bytes",
                maximumBytes: retainedBytes - 1,
                attemptedBytes: retainedBytes
            ) = error as? QVACError else {
                return XCTFail("unexpected one-byte-over error: \(error)")
            }
        }
        XCTAssertEqual(oneByteBelow.consumedBytes, 0)

        var invalid = QVACResultByteBudget(
            operation: "diffusionStream",
            maximumBytes: retainedBytes
        )
        XCTAssertThrowsError(try QVACClient.decodeRetainedBase64Output(
            "AA=A",
            invalidMessage: "invalid test base64",
            retention: .binaryArrayElement,
            resultBudget: &invalid
        )) { error in
            guard case .protocolViolation("invalid test base64") = error as? QVACError else {
                return XCTFail("unexpected invalid-base64 error: \(error)")
            }
        }
        XCTAssertEqual(
            invalid.consumedBytes,
            0,
            "invalid syntax must fail before charging or decoding"
        )
    }

    func test_client_result_budget_defaults_to_wire_limit_and_preserves_explicit_limits() async {
        let defaulted = QVACClient(
            testing: RecordingTransport(),
            maximumWireMessageBytes: 4_096
        )
        let configured = QVACClient(
            testing: RecordingTransport(),
            maximumWireMessageBytes: 4_096,
            maximumInlineBinaryItems: 17,
            maximumBatchPrompts: 23,
            maximumAccumulatedResultBytes: 2_048,
            maximumVLAActionBytes: 768,
            maximumMetadataResponseBytes: 1_024,
            maximumRegistryResponseBytes: 1_536
        )

        let defaultedLimit = await defaulted.maximumAccumulatedResultBytes
        let configuredLimits = await (
            configured.maximumInlineBinaryItems,
            configured.maximumBatchPrompts,
            configured.maximumAccumulatedResultBytes,
            configured.maximumVLAActionBytes,
            configured.maximumMetadataResponseBytes,
            configured.maximumRegistryResponseBytes
        )
        XCTAssertEqual(defaultedLimit, 4_096)
        let defaultedBatchLimit = await defaulted.maximumBatchPrompts
        XCTAssertEqual(defaultedBatchLimit, QVACClient.defaultMaximumBatchPrompts)
        let defaultedMetadataLimit = await defaulted.maximumMetadataResponseBytes
        XCTAssertEqual(defaultedMetadataLimit, 4_096)
        let defaultedVLAActionLimit = await defaulted.maximumVLAActionBytes
        XCTAssertEqual(defaultedVLAActionLimit, 4_096)
        let defaultedRegistryLimit = await defaulted.maximumRegistryResponseBytes
        XCTAssertEqual(defaultedRegistryLimit, 4_096)
        XCTAssertEqual(configuredLimits.0, 17)
        XCTAssertEqual(configuredLimits.1, 23)
        XCTAssertEqual(configuredLimits.2, 2_048)
        XCTAssertEqual(configuredLimits.3, 768)
        XCTAssertEqual(configuredLimits.4, 1_024)
        XCTAssertEqual(configuredLimits.5, 1_536)
        await defaulted.close()
        await configured.close()
    }

    func test_inline_binary_preflight_enforces_item_boundary_and_json_structure_without_io() async throws {
        let transport = RecordingTransport()
        let client = QVACClient(
            testing: transport,
            maximumWireMessageBytes: 1_024,
            maximumOutboundPayloadBytes: 100,
            maximumInlineBinaryBytes: 32,
            maximumInlineBinaryItems: 2
        )

        try await client.validateBase64InputSizes(
            [1, 1].lazy,
            operation: "boundary"
        )
        do {
            try await client.validateBase64InputSizes(
                [1, 1, 1].lazy,
                operation: "boundary"
            )
            XCTFail("one item over the configured ceiling must fail")
        } catch let QVACError.invalidArgument(message) {
            XCTAssertTrue(message.contains("maximumInlineBinaryItems 2"), message)
        }

        do {
            _ = try await client.diffusion(
                modelId: "model",
                prompt: "prompt",
                initImages: [Data([1]), Data([2]), Data([3])]
            )
            XCTFail("rich wrappers must run item-count preflight before base64 allocation")
        } catch let QVACError.invalidArgument(message) {
            XCTAssertTrue(message.contains("maximumInlineBinaryItems 2"), message)
        }

        do {
            _ = try await client.diffusion(.init(
                modelId: "model",
                prompt: "prompt",
                initImages: ["AA==", "AA==", "AA=="]
            ))
            XCTFail("full diffusion requests must enforce the same item-count ceiling")
        } catch let QVACError.invalidArgument(message) {
            XCTAssertTrue(message.contains("maximumInlineBinaryItems 2"), message)
        }

        do {
            _ = try await client.video(.init(
                mode: "txt2vid",
                modelId: "model",
                prompt: "prompt",
                controlFrames: ["AA==", "AA==", "AA=="]
            ))
            XCTFail("full video requests must enforce the same item-count ceiling")
        } catch let QVACError.invalidArgument(message) {
            XCTAssertTrue(message.contains("maximumInlineBinaryItems 2"), message)
        }
        let snapshot = await transport.snapshot()
        XCTAssertTrue(snapshot.outbound.isEmpty)
        await client.close()

        let structureTransport = RecordingTransport()
        let structureClient = QVACClient(
            testing: structureTransport,
            maximumWireMessageBytes: 1_024,
            maximumOutboundPayloadBytes: 14,
            maximumInlineBinaryBytes: 32,
            maximumInlineBinaryItems: 2
        )
        do {
            // Two one-byte values need eight base64 bytes and at least six bytes
            // of JSON string/separator structure. Equality leaves no room for the
            // operation-specific envelope and is therefore rejected.
            try await structureClient.validateBase64InputSizes(
                [1, 1].lazy,
                operation: "structure"
            )
            XCTFail("per-element JSON structure must count toward outbound preflight")
        } catch let QVACError.invalidArgument(message) {
            XCTAssertTrue(message.contains("at least 14"), message)
        }
        let structureSnapshot = await structureTransport.snapshot()
        XCTAssertTrue(structureSnapshot.outbound.isEmpty)
        await structureClient.close()
    }

    func test_full_media_requests_enforce_exact_aggregate_decoded_byte_limit() async throws {
        let oneByte = Data([1]).base64EncodedString()

        do {
            let transport = RecordingTransport()
            let client = QVACClient(
                testing: transport,
                maximumWireMessageBytes: 4_096,
                maximumOutboundPayloadBytes: 4_096,
                maximumInlineBinaryBytes: 2,
                maximumInlineBinaryItems: 4
            )
            let call = Task {
                try await client.diffusion(.init(
                    modelId: "model",
                    prompt: "prompt",
                    initImages: [oneByte, oneByte]
                ))
            }
            let request = try await Self.waitForRequest(on: transport)
            try await Self.feedTerminalStream(
                id: request.id,
                response: .diffusionStream(.init(done: true)),
                to: transport
            )
            let run = try await call.value
            let outputs = try await run.outputs.value
            XCTAssertEqual(outputs, [])
            await client.close()
        }

        do {
            let transport = RecordingTransport()
            let client = QVACClient(
                testing: transport,
                maximumWireMessageBytes: 4_096,
                maximumOutboundPayloadBytes: 4_096,
                maximumInlineBinaryBytes: 2,
                maximumInlineBinaryItems: 4
            )
            let call = Task {
                try await client.video(.init(
                    mode: "img2vid",
                    modelId: "model",
                    prompt: "prompt",
                    controlFrames: [oneByte],
                    initImage: oneByte
                ))
            }
            let request = try await Self.waitForRequest(on: transport)
            try await Self.feedTerminalStream(
                id: request.id,
                response: .videoStream(.init(done: true)),
                to: transport
            )
            let run = try await call.value
            let outputs = try await run.outputs.value
            XCTAssertEqual(outputs, [])
            await client.close()
        }

        for operation in ["diffusion", "video"] {
            let transport = RecordingTransport()
            let client = QVACClient(
                testing: transport,
                maximumWireMessageBytes: 4_096,
                maximumOutboundPayloadBytes: 4_096,
                maximumInlineBinaryBytes: 2,
                maximumInlineBinaryItems: 4
            )
            do {
                if operation == "diffusion" {
                    _ = try await client.diffusion(.init(
                        modelId: "model",
                        prompt: "prompt",
                        initImages: [oneByte, oneByte, oneByte]
                    ))
                } else {
                    _ = try await client.video(.init(
                        mode: "img2vid",
                        modelId: "model",
                        prompt: "prompt",
                        controlFrames: [oneByte, oneByte],
                        initImage: oneByte
                    ))
                }
                XCTFail("\(operation) accepted one decoded byte over its aggregate quota")
            } catch let QVACError.invalidArgument(message) {
                XCTAssertTrue(message.contains("total 3 raw bytes"), message)
                XCTAssertTrue(message.contains("maximumInlineBinaryBytes 2"), message)
            } catch {
                XCTFail("\(operation) returned unexpected error: \(error)")
            }
            let snapshot = await transport.snapshot()
            XCTAssertTrue(snapshot.outbound.isEmpty)
            await client.close()
        }
    }

    func test_media_configure_hooks_cannot_replace_inputs_above_decoded_byte_limit() async {
        let oversized = Data([1, 2]).base64EncodedString()

        for operation in ["diffusion", "video"] {
            let transport = RecordingTransport()
            let client = QVACClient(
                testing: transport,
                maximumWireMessageBytes: 4_096,
                maximumOutboundPayloadBytes: 4_096,
                maximumInlineBinaryBytes: 1,
                maximumInlineBinaryItems: 4
            )
            do {
                if operation == "diffusion" {
                    _ = try await client.diffusion(
                        modelId: "model",
                        prompt: "prompt",
                        initImage: Data([1]),
                        configure: { request in request.initImage = oversized }
                    )
                } else {
                    _ = try await client.video(
                        modelId: "model",
                        mode: "img2vid",
                        prompt: "prompt",
                        initImage: Data([1]),
                        configure: { request in request.initImage = oversized }
                    )
                }
                XCTFail("\(operation) configure hook bypassed maximumInlineBinaryBytes")
            } catch let QVACError.invalidArgument(message) {
                XCTAssertTrue(message.contains("total 2 raw bytes"), message)
                XCTAssertTrue(message.contains("maximumInlineBinaryBytes 1"), message)
            } catch {
                XCTFail("\(operation) returned unexpected error: \(error)")
            }
            let snapshot = await transport.snapshot()
            XCTAssertTrue(snapshot.outbound.isEmpty)
            await client.close()
        }
    }

    func test_public_initializer_rejects_new_invalid_limits_before_io() async {
        let maximumUInt32 = Int(UInt32.max)
        let cases: [(String, () async throws -> QVACClient)] = [
            ("maximumInlineBinaryItems", {
                try await QVACClient(
                    configuration: .testing(RecordingTransport()),
                    runtimeContext: nil,
                    maximumInlineBinaryItems: 0,
                    logger: nil
                )
            }),
            ("maximumInlineBinaryItems", {
                try await QVACClient(
                    configuration: .testing(RecordingTransport()),
                    runtimeContext: nil,
                    maximumInlineBinaryItems: maximumUInt32 + 1,
                    logger: nil
                )
            }),
            ("maximumAccumulatedResultBytes", {
                try await QVACClient(
                    configuration: .testing(RecordingTransport()),
                    runtimeContext: nil,
                    maximumAccumulatedResultBytes: 0,
                    logger: nil
                )
            }),
            ("maximumAccumulatedResultBytes", {
                try await QVACClient(
                    configuration: .testing(RecordingTransport()),
                    runtimeContext: nil,
                    maximumAccumulatedResultBytes: maximumUInt32 + 1,
                    logger: nil
                )
            }),
            ("maximumBatchPrompts", {
                try await QVACClient(
                    configuration: .testing(RecordingTransport()),
                    runtimeContext: nil,
                    maximumBatchPrompts: 0,
                    logger: nil
                )
            }),
            ("maximumBatchPrompts", {
                try await QVACClient(
                    configuration: .testing(RecordingTransport()),
                    runtimeContext: nil,
                    maximumBatchPrompts: maximumUInt32 + 1,
                    logger: nil
                )
            }),
            ("maximumMetadataResponseBytes", {
                try await QVACClient(
                    configuration: .testing(RecordingTransport()),
                    runtimeContext: nil,
                    maximumMetadataResponseBytes: 0,
                    logger: nil
                )
            }),
            ("maximumMetadataResponseBytes", {
                try await QVACClient(
                    configuration: .testing(RecordingTransport()),
                    runtimeContext: nil,
                    maximumWireMessageBytes: 1_024,
                    maximumMetadataResponseBytes: 1_025,
                    logger: nil
                )
            }),
            ("maximumMetadataResponseBytes", {
                try await QVACClient(
                    configuration: .testing(RecordingTransport()),
                    runtimeContext: nil,
                    maximumWireMessageBytes: 1_024,
                    maximumAccumulatedResultBytes: 512,
                    maximumMetadataResponseBytes: 513,
                    logger: nil
                )
            }),
            ("maximumRegistryResponseBytes", {
                try await QVACClient(
                    configuration: .testing(RecordingTransport()),
                    runtimeContext: nil,
                    maximumRegistryResponseBytes: 0,
                    logger: nil
                )
            }),
            ("maximumRegistryResponseBytes", {
                try await QVACClient(
                    configuration: .testing(RecordingTransport()),
                    runtimeContext: nil,
                    maximumWireMessageBytes: 1_024,
                    maximumRegistryResponseBytes: 1_025,
                    logger: nil
                )
            }),
            ("maximumRegistryResponseBytes", {
                try await QVACClient(
                    configuration: .testing(RecordingTransport()),
                    runtimeContext: nil,
                    maximumWireMessageBytes: 1_024,
                    maximumAccumulatedResultBytes: 512,
                    maximumRegistryResponseBytes: 513,
                    logger: nil
                )
            }),
        ]

        for (expected, makeClient) in cases {
            do {
                let client = try await makeClient()
                await client.close()
                XCTFail("invalid \(expected) was accepted")
            } catch let QVACError.invalidArgument(message) {
                XCTAssertTrue(message.contains(expected), message)
            } catch {
                XCTFail("expected invalidArgument, got \(error)")
            }
        }
    }

    func test_init_config_limit_accepts_exact_payload_and_rejects_one_byte_over_without_write() async throws {
        let config: JSONValue = .object(["padding": .string(String(repeating: "x", count: 64))])
        let envelope = InitConfigEnvelope(config: config, runtimeContext: nil)
        let payloadBytes = try JSONEncoder.qvac.encode(envelope).count

        let exactTransport = RecordingTransport()
        let exactRPC = BareRPCClient(
            validatedTransport: exactTransport,
            maximumWireMessageBytes: payloadBytes + 128,
            maximumBufferedStreamBytes: payloadBytes + 128,
            logger: nil
        )
        let exact = Task {
            try await QVACHandshake.sendInitConfig(
                on: exactRPC,
                config: config,
                runtimeContext: nil,
                timeout: .seconds(1),
                maximumOutboundPayloadBytes: payloadBytes
            )
        }
        let request = try await Self.waitForRequest(on: exactTransport)
        XCTAssertEqual(request.payload.count, payloadBytes)
        try await Self.feedInitSuccess(id: request.id, to: exactTransport)
        try await exact.value
        await exactRPC.close()

        let overTransport = RecordingTransport()
        let overRPC = BareRPCClient(
            validatedTransport: overTransport,
            maximumWireMessageBytes: payloadBytes + 128,
            maximumBufferedStreamBytes: payloadBytes + 128,
            logger: nil
        )
        do {
            try await QVACHandshake.sendInitConfig(
                on: overRPC,
                config: config,
                runtimeContext: nil,
                timeout: .seconds(1),
                maximumOutboundPayloadBytes: payloadBytes - 1
            )
            XCTFail("one byte over the handshake ceiling must fail")
        } catch let QVACError.invalidArgument(message) {
            XCTAssertTrue(message.contains("__init_config outbound payload"), message)
            XCTAssertTrue(message.contains("\(payloadBytes) bytes"), message)
        }
        let overSnapshot = await overTransport.snapshot()
        XCTAssertTrue(overSnapshot.outbound.isEmpty)
        await overRPC.close()
    }

    func test_public_initial_handshake_preflights_outbound_limit_without_write() async throws {
        let transport = RecordingTransport()
        let config: JSONValue = .object(["padding": .string(String(repeating: "x", count: 64))])
        let payloadBytes = try JSONEncoder.qvac.encode(
            InitConfigEnvelope(config: config, runtimeContext: nil)
        ).count
        do {
            _ = try await QVACClient(
                configuration: .testing(transport),
                runtimeContext: nil,
                config: config,
                initHandshakeTimeout: .seconds(1),
                maximumWireMessageBytes: payloadBytes + 128,
                maximumOutboundPayloadBytes: payloadBytes - 1,
                logger: nil
            )
            XCTFail("initial handshake must enforce the configured outbound ceiling")
        } catch let QVACError.invalidArgument(message) {
            XCTAssertTrue(message.contains("__init_config outbound payload"), message)
        }
        let snapshot = await transport.snapshot()
        XCTAssertTrue(snapshot.outbound.isEmpty)
        XCTAssertEqual(snapshot.closes, 1)
    }

    func test_reconnect_handshake_preflights_outbound_limit_without_write() async throws {
        let replacement = RecordingTransport()
        let config: JSONValue = .object(["padding": .string(String(repeating: "x", count: 64))])
        let payloadBytes = try JSONEncoder.qvac.encode(
            InitConfigEnvelope(config: config, runtimeContext: nil)
        ).count
        do {
            try await QVACClient.__testMakeReplacementConnection(
                transport: replacement,
                config: config,
                maximumWireMessageBytes: payloadBytes + 128,
                maximumOutboundPayloadBytes: payloadBytes - 1,
                maximumBufferedStreamBytes: payloadBytes + 128
            )
            XCTFail("replacement handshake must enforce the configured outbound ceiling")
        } catch let QVACError.invalidArgument(message) {
            XCTAssertTrue(message.contains("__init_config outbound payload"), message)
        }
        let snapshot = await replacement.snapshot()
        XCTAssertTrue(snapshot.outbound.isEmpty)
        XCTAssertEqual(snapshot.closes, 1)
    }

    func test_vla_standalone_output_limits_accept_exact_boundary_and_are_configurable() throws {
        let pixels: [UInt8] = [0, 0, 0]
        let exact = try vlaPreprocessImage(
            pixels,
            width: 1,
            height: 1,
            options: .init(size: 2, maximumOutputBytes: 48)
        )
        XCTAssertEqual(exact.count * MemoryLayout<Float>.stride, 48)
        do {
            _ = try vlaPreprocessImage(
                pixels,
                width: 1,
                height: 1,
                options: .init(size: 2, maximumOutputBytes: 47)
            )
            XCTFail("one byte below the required tensor size must fail")
        } catch let QVACError.resourceLimitExceeded(
            operation,
            resource,
            maximumBytes,
            attemptedBytes
        ) {
            XCTAssertEqual(operation, "vlaPreprocessImage")
            XCTAssertEqual(resource, "output tensor bytes")
            XCTAssertEqual(maximumBytes, 47)
            XCTAssertEqual(attemptedBytes, 48)
        }

        XCTAssertEqual(
            try vlaPadState([1] as [Float], targetDimension: 2, maximumOutputBytes: 8),
            [1, 0]
        )
        XCTAssertThrowsError(
            try vlaPadState([1] as [Float], targetDimension: 2, maximumOutputBytes: 7)
        ) { error in
            guard case .resourceLimitExceeded(
                operation: "vlaPadState",
                resource: "output tensor bytes",
                maximumBytes: 7,
                attemptedBytes: 8
            ) = error as? QVACError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func test_vla_hparams_metadata_cap_accepts_exact_response_and_rejects_one_byte_over_predecode() async throws {
        func payload(backendName: String) throws -> Data {
            try JSONEncoder.qvac.encode(QVACResponse.pluginInvoke(.init(result: .object([
                "hparams": .object([
                    "chunkSize": .number(1),
                    "actionDim": .number(2),
                    "maxActionDim": .number(3),
                    "maxStateDim": .number(4),
                    "tokenizerMaxLength": .number(5),
                    "visionImageSize": .number(6),
                ]),
                "backendName": .string(backendName),
            ]))))
        }

        let base = try payload(backendName: "")
        let exactPayload = try payload(backendName: String(repeating: "x", count: 64))
        XCTAssertEqual(exactPayload.count, base.count + 64)
        let limit = exactPayload.count
        let transport = RecordingTransport()
        let client = QVACClient(
            testing: transport,
            maximumWireMessageBytes: limit + 128,
            maximumOutboundPayloadBytes: limit + 128,
            maximumAccumulatedResultBytes: limit + 128,
            maximumMetadataResponseBytes: limit
        )

        let exact = Task { try await client.vlaHparams(modelId: "vla") }
        let exactRequest = try await Self.waitForRequest(on: transport)
        await transport.feed(BareRPCCodec.__testEncodeResponseFrame(
            id: exactRequest.id,
            stream: [],
            payload: .success(exactPayload)
        ))
        let result = try await exact.value
        XCTAssertEqual(result.backendName, String(repeating: "x", count: 64))
        XCTAssertEqual(result.hyperparameters.actionDimension, 2)

        let over = Task { try await client.vlaHparams(modelId: "vla") }
        let overRequest = try await Self.waitForRequest(on: transport, minimumCount: 2)
        await transport.feed(BareRPCCodec.__testEncodeResponseFrame(
            id: overRequest.id,
            stream: [],
            payload: .success(Data(repeating: 0, count: limit + 1))
        ))
        do {
            _ = try await over.value
            XCTFail("metadata response one byte over the cap must fail before JSON decoding")
        } catch let QVACError.resourceLimitExceeded(
            operation,
            resource,
            maximumBytes,
            attemptedBytes
        ) {
            XCTAssertEqual(operation, "pluginInvoke")
            XCTAssertEqual(resource, "response bytes")
            XCTAssertEqual(maximumBytes, limit)
            XCTAssertEqual(attemptedBytes, limit + 1)
        }

        let heartbeat = Task { try await client.heartbeat() }
        let heartbeatRequest = try await Self.waitForRequest(
            on: transport,
            minimumCount: 3
        )
        let heartbeatPayload = try JSONEncoder.qvac.encode(
            QVACResponse.heartbeat(.init(number: 17))
        )
        await transport.feed(BareRPCCodec.__testEncodeResponseFrame(
            id: heartbeatRequest.id,
            stream: [],
            payload: .success(heartbeatPayload)
        ))
        let heartbeatResult = try await heartbeat.value
        XCTAssertEqual(heartbeatResult.number, 17)
        let snapshot = await transport.snapshot()
        XCTAssertEqual(snapshot.closes, 0)
        await client.close()
    }

    func test_all_open_ended_metadata_apis_enforce_exact_predecode_response_limit() async throws {
        for endpoint in MetadataEndpoint.allCases {
            let exactPayload = try endpoint.payload(
                padding: String(repeating: "x", count: 64)
            )
            let limit = exactPayload.count
            let transport = RecordingTransport()
            let client = QVACClient(
                testing: transport,
                maximumWireMessageBytes: limit + 256,
                maximumOutboundPayloadBytes: limit + 256,
                maximumAccumulatedResultBytes: limit + 256,
                maximumMetadataResponseBytes: limit,
                maximumRegistryResponseBytes: limit
            )

            let exact = Task { try await endpoint.invoke(on: client) }
            let exactRequest = try await Self.waitForRequest(on: transport)
            let decodedRequest = try JSONDecoder().decode(
                QVACRequest.self,
                from: exactRequest.payload
            )
            XCTAssertEqual(decodedRequest.discriminator, endpoint.operation)
            await transport.feed(BareRPCCodec.__testEncodeResponseFrame(
                id: exactRequest.id,
                stream: [],
                payload: .success(exactPayload)
            ))
            try await exact.value

            let over = Task { try await endpoint.invoke(on: client) }
            let overRequest = try await Self.waitForRequest(
                on: transport,
                minimumCount: 2
            )
            await transport.feed(BareRPCCodec.__testEncodeResponseFrame(
                id: overRequest.id,
                stream: [],
                payload: .success(Data(repeating: 0, count: limit + 1))
            ))
            do {
                try await over.value
                XCTFail("\(endpoint.operation) accepted a response one byte over its cap")
            } catch let QVACError.resourceLimitExceeded(
                operation,
                resource,
                maximumBytes,
                attemptedBytes
            ) {
                XCTAssertEqual(operation, endpoint.operation)
                XCTAssertEqual(resource, "response bytes")
                XCTAssertEqual(maximumBytes, limit)
                XCTAssertEqual(attemptedBytes, limit + 1)
            } catch {
                XCTFail("\(endpoint.operation) returned unexpected error: \(error)")
            }
            await client.close()
        }
    }

    func test_registry_list_and_search_accept_current_scale_responses_above_small_metadata_limit() async throws {
        let recordCount = 700
        let records: [JSONValue] = (0..<recordCount).map { index in
            .object([
                "name": .string("model-\(index)"),
                "registryPath": .string("models/\(index)/model-q4.gguf"),
                "registrySource": .string("s3"),
                "metadata": .string(String(repeating: "x", count: 400)),
            ])
        }

        for endpoint in [MetadataEndpoint.registryList, .registrySearch] {
            let response: QVACResponse = switch endpoint {
            case .registryList:
                .modelRegistryList(.init(success: true, models: records))
            case .registrySearch:
                .modelRegistrySearch(.init(success: true, models: records))
            default:
                preconditionFailure("registry-only test received \(endpoint)")
            }
            let payload = try JSONEncoder.qvac.encode(response)
            XCTAssertGreaterThan(
                payload.count,
                QVACClient.defaultMaximumMetadataResponseBytes,
                "the fixture must exercise the independent registry ceiling"
            )
            XCTAssertLessThan(
                payload.count,
                QVACClient.defaultMaximumRegistryResponseBytes
            )

            let transport = RecordingTransport()
            let client = QVACClient(
                testing: transport,
                maximumMetadataResponseBytes: 1_024
            )
            let operation = Task { try await endpoint.invoke(on: client) }
            let request = try await Self.waitForRequest(on: transport)
            await transport.feed(BareRPCCodec.__testEncodeResponseFrame(
                id: request.id,
                stream: [],
                payload: .success(payload)
            ))
            try await operation.value
            let snapshot = await transport.snapshot()
            XCTAssertEqual(snapshot.closes, 0)
            await client.close()
        }
    }

    func test_vla_uses_client_item_and_accumulated_result_limits_at_exact_boundaries() async throws {
        let rejectedTransport = RecordingTransport()
        let rejectedClient = QVACClient(
            testing: rejectedTransport,
            maximumWireMessageBytes: 1_024,
            maximumOutboundPayloadBytes: 512,
            maximumInlineBinaryBytes: 128,
            maximumInlineBinaryItems: 3,
            maximumAccumulatedResultBytes: 8
        )
        let parameters = QVACClient.VLAParameters(
            modelId: "vla",
            images: [[0, 0, 0]],
            imageWidth: 1,
            imageHeight: 1,
            state: [],
            tokens: [1],
            mask: [1]
        )
        do {
            _ = try await rejectedClient.vla(parameters)
            XCTFail("one image plus three fixed tensors must exceed an item limit of three")
        } catch let QVACError.invalidArgument(message) {
            XCTAssertTrue(message.contains("maximumInlineBinaryItems 3"), message)
        }
        let rejectedSnapshot = await rejectedTransport.snapshot()
        XCTAssertTrue(rejectedSnapshot.outbound.isEmpty)
        await rejectedClient.close()

        let transport = RecordingTransport()
        let client = QVACClient(
            testing: transport,
            maximumWireMessageBytes: 1_024,
            maximumOutboundPayloadBytes: 512,
            maximumInlineBinaryBytes: 128,
            maximumInlineBinaryItems: 4,
            maximumAccumulatedResultBytes: 8
        )
        let exactTask = Task { try await client.vla(parameters) }
        let exactRequest = try await Self.waitForRequest(on: transport)
        try await Self.feedPluginResult(
            id: exactRequest.id,
            result: .object([
                "actions": .string(Self.float32Base64([1, 2])),
                "actionDim": .number(2),
                "chunkSize": .number(1),
            ]),
            to: transport
        )
        let exactResult = try await exactTask.value
        XCTAssertEqual(exactResult.actions, [1, 2])

        let overTask = Task { try await client.vla(parameters) }
        let overRequest = try await Self.waitForRequest(on: transport, minimumCount: 2)
        try await Self.feedPluginResult(
            id: overRequest.id,
            result: .object([
                "actions": .string(Self.float32Base64([1, 2, 3])),
                "actionDim": .number(3),
                "chunkSize": .number(1),
            ]),
            to: transport
        )
        do {
            _ = try await overTask.value
            XCTFail("one Float32 beyond the decoded-action budget must fail")
        } catch let QVACError.resourceLimitExceeded(
            operation,
            resource,
            maximumBytes,
            attemptedBytes
        ) {
            XCTAssertEqual(operation, "vla")
            XCTAssertEqual(resource, "decoded action bytes")
            XCTAssertEqual(maximumBytes, 8)
            XCTAssertEqual(attemptedBytes, 12)
        }
        await client.close()
    }
}
