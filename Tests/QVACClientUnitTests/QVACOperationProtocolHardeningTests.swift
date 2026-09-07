import Foundation
import XCTest
@testable import QVACClient

/// Fail-closed protocol specifications for public operation adapters.
///
/// The peer below replaces only the byte transport. Requests still pass through the
/// production encoder, bare-rpc multiplexer, NDJSON decoder, profiling-trailer drain,
/// and public operation adapter. This makes malformed-worker behavior deterministic
/// without weakening the exercised stack with a model or network dependency.
final class QVACOperationProtocolHardeningTests: XCTestCase {
    private final class InboundPipe: @unchecked Sendable {
        let stream: AsyncThrowingStream<Data, Error>
        let continuation: AsyncThrowingStream<Data, Error>.Continuation

        init() {
            let pair = AsyncThrowingStream<Data, Error>.makeStream(
                bufferingPolicy: .bufferingNewest(64)
            )
            stream = pair.stream
            continuation = pair.continuation
        }
    }

    private actor ScriptedPeer: BareTransport {
        nonisolated private let inbound = InboundPipe()
        private var outboundBytes = Data()
        private var closed = false

        nonisolated func inboundStream() -> AsyncThrowingStream<Data, Error> {
            inbound.stream
        }

        func write(_ data: Data) {
            outboundBytes.append(data)
        }

        func close() {
            guard !closed else { return }
            closed = true
            inbound.continuation.finish()
        }

        func feed(_ data: Data) {
            inbound.continuation.yield(data)
        }

        func outbound() -> Data { outboundBytes }
    }

    private final class ProfilingCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }

        func value() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    private static func request(
        in data: Data
    ) -> (id: UInt64, body: [String: Any])? {
        let reader = BareRPCFrameReader()
        try? reader.append(data)
        while let frame = reader.next() {
            guard case .request(let id, _, _, .some(let payload)) = frame,
                  let body = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
            else { continue }
            return (id, body)
        }
        return nil
    }

    private static func waitForRequest(
        on peer: ScriptedPeer,
        timeout: Duration = .seconds(1)
    ) async throws -> (id: UInt64, body: [String: Any]) {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let request = request(in: await peer.outbound()) { return request }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("timed out waiting for an outbound request")
        throw QVACError.protocolViolation("scripted peer did not receive a request")
    }

    private static func feedReply(
        id: UInt64,
        response: QVACResponse,
        to peer: ScriptedPeer
    ) async throws {
        let payload = try JSONEncoder.qvac.encode(response)
        await peer.feed(BareRPCCodec.__testEncodeResponseFrame(
            id: id,
            stream: [],
            payload: .success(payload)
        ))
    }

    private static func feedServerStream(
        id: UInt64,
        records: [String],
        to peer: ScriptedPeer
    ) async {
        var inbound = BareRPCCodec.__testEncodeResponseFrame(
            id: id,
            stream: [.open],
            payload: .success(nil)
        )
        for record in records {
            inbound.append(BareRPCCodec.__testEncodeStreamFrame(
                id: id,
                flags: [.response, .data],
                payload: .data(Data((record + "\n").utf8))
            ))
        }
        inbound.append(BareRPCCodec.__testEncodeStreamFrame(
            id: id,
            flags: [.response, .end]
        ))
        await peer.feed(inbound)
    }

    private func assertProtocolViolation<Value>(
        containing expected: String,
        operation: () async throws -> Value,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("expected protocol violation", file: file, line: line)
        } catch let QVACError.protocolViolation(message) {
            XCTAssertTrue(
                message.contains(expected),
                "expected '\(expected)' in '\(message)'",
                file: file,
                line: line
            )
        } catch {
            XCTFail("expected protocol violation, got \(error)", file: file, line: line)
        }
    }

    private func assertInvalidArgument<Value>(
        containing expected: String,
        operation: () async throws -> Value,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("expected invalid argument", file: file, line: line)
        } catch let QVACError.invalidArgument(message) {
            XCTAssertTrue(
                message.contains(expected),
                "expected '\(expected)' in '\(message)'",
                file: file,
                line: line
            )
        } catch {
            XCTFail("expected invalid argument, got \(error)", file: file, line: line)
        }
    }

    private func assertStreamEndedWithoutTerminal<Value>(
        operation: () async throws -> Value,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("expected missing-terminal error", file: file, line: line)
        } catch let QVACError.client(code, _) {
            XCTAssertEqual(code, .streamEndedWithoutResponse, file: file, line: line)
        } catch {
            XCTFail("expected missing-terminal error, got \(error)", file: file, line: line)
        }
    }

    // MARK: Model lifecycle

    func test_model_progress_metadata_rejects_invalid_containers_and_scalars() throws {
        let validShard: [String: JSONValue] = [
            "currentShard": .number(1),
            "totalShards": .number(2),
            "shardName": .string("model-00001-of-00002.gguf"),
            "overallDownloaded": .number(64),
            "overallTotal": .number(128),
            "overallPercentage": .number(50),
        ]
        let validFileSet: [String: JSONValue] = [
            "setKey": .string("model-files"),
            "currentFile": .string("tokenizer.json"),
            "fileIndex": .number(1),
            "totalFiles": .number(2),
            "overallDownloaded": .number(64),
            "overallTotal": .number(128),
            "overallPercentage": .number(50),
        ]

        XCTAssertThrowsError(try QVACClient.ModelShardProgress(wire: .array([]))) { error in
            guard case .protocolViolation(let message) = error as? QVACError else {
                return XCTFail("expected protocol violation, got \(error)")
            }
            XCTAssertEqual(message, "modelProgress.shardInfo must be an object")
        }

        for (field, badValue) in [
            ("currentShard", JSONValue.string("1")),
            ("totalShards", .number(.infinity)),
            ("overallDownloaded", .number(.nan)),
        ] {
            var object = validShard
            object[field] = badValue
            XCTAssertThrowsError(try QVACClient.ModelShardProgress(wire: .object(object))) {
                error in
                guard case .protocolViolation(let message) = error as? QVACError else {
                    return XCTFail("expected protocol violation, got \(error)")
                }
                XCTAssertEqual(
                    message,
                    "modelProgress.shardInfo.\(field) must be a finite number"
                )
            }
        }

        var shardWithInvalidName = validShard
        shardWithInvalidName["shardName"] = .number(1)
        XCTAssertThrowsError(
            try QVACClient.ModelShardProgress(wire: .object(shardWithInvalidName))
        ) { error in
            guard case .protocolViolation(let message) = error as? QVACError else {
                return XCTFail("expected protocol violation, got \(error)")
            }
            XCTAssertEqual(message, "modelProgress.shardInfo.shardName must be a string")
        }

        XCTAssertThrowsError(try QVACClient.ModelFileSetProgress(wire: .array([]))) { error in
            guard case .protocolViolation(let message) = error as? QVACError else {
                return XCTFail("expected protocol violation, got \(error)")
            }
            XCTAssertEqual(message, "modelProgress.fileSetInfo must be an object")
        }

        for (field, badValue, expectedKind) in [
            ("setKey", JSONValue.number(1), "string"),
            ("currentFile", .bool(false), "string"),
            ("fileIndex", .number(.infinity), "finite number"),
            ("totalFiles", .string("2"), "finite number"),
        ] {
            var object = validFileSet
            object[field] = badValue
            XCTAssertThrowsError(try QVACClient.ModelFileSetProgress(wire: .object(object))) {
                error in
                guard case .protocolViolation(let message) = error as? QVACError else {
                    return XCTFail("expected protocol violation, got \(error)")
                }
                XCTAssertEqual(
                    message,
                    "modelProgress.fileSetInfo.\(field) must be a \(expectedKind)"
                )
            }
        }
    }

    func test_descriptor_model_load_maps_legacy_tts_engine_and_drains_profiled_progress() async throws {
        let peer = ScriptedPeer()
        let profiling = ProfilingCounter()
        let client = QVACClient(
            testing: peer,
            profilingMetadataHandler: { _ in profiling.increment() }
        )
        let run = try await client.loadModelStreaming(
            modelSrc: .init(
                src: "https://models.example.invalid/speech.bin",
                name: "speech",
                engine: "onnx-tts"
            ),
            rpcOptions: .init(timeout: nil, profiling: .init(enabled: true))
        )
        let request = try await Self.waitForRequest(on: peer)
        XCTAssertEqual(request.body["type"] as? String, "loadModel")
        XCTAssertEqual(request.body["modelType"] as? String, "tts-ggml")
        XCTAssertEqual(request.body["modelName"] as? String, "speech")
        XCTAssertEqual(request.body["withProgress"] as? Bool, true)
        XCTAssertEqual(request.body["modelConfig"] as? [String: String], [:])

        await Self.feedServerStream(
            id: request.id,
            records: [
                #"{"type":"modelProgress","downloaded":64,"downloadKey":"weights","percentage":50,"total":128,"shardInfo":{"currentShard":1,"totalShards":2,"shardName":"model-00001-of-00002.gguf","overallDownloaded":64,"overallTotal":128,"overallPercentage":50},"fileSetInfo":{"setKey":"speech","currentFile":"tokens.txt","fileIndex":1,"totalFiles":2,"overallDownloaded":64,"overallTotal":128,"overallPercentage":50}}"#,
                #"{"type":"loadModel","success":true,"modelId":"speech-model"}"#,
                #"{"__profilingTrailer":true,"__profiling":{"id":"model-load-profile"}}"#,
            ],
            to: peer
        )

        let modelId = try await run.result.value
        XCTAssertEqual(modelId, "speech-model")
        XCTAssertEqual(profiling.value(), 1)
        var updates: [QVACClient.ModelLoadProgress] = []
        for try await update in run.progress { updates.append(update) }
        XCTAssertEqual(updates.count, 1)
        let update = try XCTUnwrap(updates.first)
        XCTAssertEqual(update.shardInfo?.shardName, "model-00001-of-00002.gguf")
        XCTAssertEqual(update.fileSetInfo?.currentFile, "tokens.txt")
        await client.close()
    }

    func test_model_lifecycle_rejects_invalid_reload_and_unary_response_contracts() async throws {
        do {
            let peer = ScriptedPeer()
            let client = QVACClient(testing: peer)
            await assertInvalidArgument(containing: "modelConfig must be an object") {
                try await client.reloadModelConfig(
                    modelId: "0123456789abcdef",
                    modelConfig: .array([])
                )
            }
            let outbound = await peer.outbound()
            XCTAssertTrue(outbound.isEmpty)
            await client.close()
        }

        do {
            let peer = ScriptedPeer()
            let client = QVACClient(testing: peer)
            let run = try await client.loadModel(
                modelSrc: "/models/model.gguf",
                modelType: "llamacpp-completion"
            )
            let request = try await Self.waitForRequest(on: peer)
            try await Self.feedReply(
                id: request.id,
                response: .heartbeat(.init(number: 1)),
                to: peer
            )
            await assertProtocolViolation(containing: "expected loadModel response") {
                try await run.result.value
            }
            await client.close()
        }

        do {
            let peer = ScriptedPeer()
            let client = QVACClient(testing: peer)
            let task = Task { try await client.unloadModel(modelId: "model") }
            let request = try await Self.waitForRequest(on: peer)
            try await Self.feedReply(
                id: request.id,
                response: .heartbeat(.init(number: 1)),
                to: peer
            )
            await assertProtocolViolation(containing: "expected unloadModel response") {
                try await task.value
            }
            await client.close()
        }

        do {
            let peer = ScriptedPeer()
            let client = QVACClient(testing: peer)
            let task = Task { try await client.unloadModel(modelId: "model") }
            let request = try await Self.waitForRequest(on: peer)
            try await Self.feedReply(
                id: request.id,
                response: .unloadModel(.init(success: false, error: "model is busy")),
                to: peer
            )
            do {
                _ = try await task.value
                XCTFail("a failed unload must reject")
            } catch let QVACError.server(code, message) {
                XCTAssertEqual(code, .modelUnloadFailed)
                XCTAssertEqual(message, "model is busy")
            }
            await client.close()
        }
    }

    // MARK: Diffusion

    func test_diffusion_rejects_ambiguous_or_empty_high_level_image_inputs_before_io() async {
        let peer = ScriptedPeer()
        let client = QVACClient(testing: peer)

        await assertInvalidArgument(containing: "mutually exclusive") {
            try await client.diffusion(
                modelId: "diffusion",
                prompt: "prompt",
                initImage: Data([1]),
                initImages: [Data([2])]
            )
        }
        await assertInvalidArgument(containing: "initImages must not be empty") {
            try await client.diffusion(
                modelId: "diffusion",
                prompt: "prompt",
                initImages: []
            )
        }
        await assertInvalidArgument(containing: "initImage must not be empty") {
            try await client.diffusion(
                modelId: "diffusion",
                prompt: "prompt",
                initImage: Data()
            )
        }
        await assertInvalidArgument(containing: "must not contain empty data") {
            try await client.diffusion(
                modelId: "diffusion",
                prompt: "prompt",
                initImages: [Data([1]), Data()]
            )
        }
        await assertInvalidArgument(containing: "mutually exclusive") {
            try await client.diffusion(
                modelId: "diffusion",
                prompt: "prompt",
                initImage: Data([1]),
                configure: { request in request.initImages = ["Ag=="] }
            )
        }

        let outbound = await peer.outbound()
        XCTAssertTrue(outbound.isEmpty)
        await client.close()
    }

    func test_diffusion_preserves_nonterminal_and_terminal_outputs_progress_stats_and_profile() async throws {
        let peer = ScriptedPeer()
        let profiling = ProfilingCounter()
        let client = QVACClient(
            testing: peer,
            profilingMetadataHandler: { _ in profiling.increment() }
        )
        let first = Data([0x89, 0x50, 0x4e, 0x47, 1])
        let second = Data([0x89, 0x50, 0x4e, 0x47, 2])
        let run = try await client.diffusion(
            modelId: "diffusion",
            prompt: "two frames",
            rpcOptions: .init(timeout: nil, profiling: .init(enabled: true))
        )
        let request = try await Self.waitForRequest(on: peer)
        await Self.feedServerStream(
            id: request.id,
            records: [
                #"{"type":"diffusionStream","data":"\#(first.base64EncodedString())","step":1,"totalSteps":2,"elapsedMs":10,"stats":{"seed":7}}"#,
                #"{"type":"diffusionStream","data":"\#(second.base64EncodedString())","step":2,"totalSteps":2,"elapsedMs":20,"done":true,"stats":{"generationMs":18,"seed":8}}"#,
                #"{"__profilingTrailer":true,"__profiling":{"id":"diffusion-profile"}}"#,
            ],
            to: peer
        )

        let outputs = try await run.outputs.value
        let stats = try await run.stats.value
        XCTAssertEqual(outputs, [first, second])
        XCTAssertEqual(stats?.seed, 8)
        XCTAssertEqual(stats?.generationMs, 18)
        XCTAssertEqual(profiling.value(), 1)
        var progress: [QVACClient.DiffusionProgressTick] = []
        for try await tick in run.progressStream { progress.append(tick) }
        XCTAssertEqual(progress.map(\.step), [1, 2])
        XCTAssertEqual(progress.map(\.totalSteps), [2, 2])
        XCTAssertEqual(progress.map(\.elapsedMs), [10, 20])
        await client.close()
    }

    func test_diffusion_fails_closed_for_wrong_type_invalid_base64_malformed_stats_and_eof() async throws {
        enum Fixture: CaseIterable {
            case wrongType
            case invalidBase64
            case malformedStats
            case missingTerminal

            var records: [String] {
                switch self {
                case .wrongType:
                    return [#"{"type":"heartbeat","number":1}"#]
                case .invalidBase64:
                    return [#"{"type":"diffusionStream","data":"not-base64"}"#]
                case .malformedStats:
                    return [#"{"type":"diffusionStream","stats":"not-an-object"}"#]
                case .missingTerminal:
                    return [#"{"type":"diffusionStream","step":1,"totalSteps":2,"elapsedMs":1}"#]
                }
            }
        }

        for fixture in Fixture.allCases {
            let peer = ScriptedPeer()
            let client = QVACClient(testing: peer)
            let run = try await client.diffusion(modelId: "diffusion", prompt: "prompt")
            let request = try await Self.waitForRequest(on: peer)
            await Self.feedServerStream(id: request.id, records: fixture.records, to: peer)

            switch fixture {
            case .wrongType:
                await assertProtocolViolation(containing: "expected diffusionStream") {
                    try await run.outputs.value
                }
            case .invalidBase64:
                await assertProtocolViolation(containing: "invalid base64") {
                    try await run.outputs.value
                }
            case .malformedStats:
                await assertProtocolViolation(containing: "malformed stats") {
                    try await run.outputs.value
                }
            case .missingTerminal:
                await assertStreamEndedWithoutTerminal {
                    try await run.outputs.value
                }
            }
            await client.close()
        }
    }

    // MARK: OCR

    func test_ocr_block_decoder_rejects_invalid_required_optional_and_finite_fields() {
        let fixtures: [(wire: JSONValue, expected: String)] = [
            (.string("text"), "requires text"),
            (.object([:]), "requires text"),
            (.object(["text": .string("text"), "bbox": .array([.number(1)])]),
             "bbox must contain four numbers"),
            (.object([
                "text": .string("text"),
                "bbox": .array([.number(1), .number(2), .string("3"), .number(4)]),
            ]), "bbox must contain finite numbers"),
            (.object([
                "text": .string("text"),
                "bbox": .array([.number(1), .number(2), .number(.infinity), .number(4)]),
            ]), "bbox must contain finite numbers"),
            (.object(["text": .string("text"), "confidence": .string("high")]),
             "confidence must be a finite number"),
            (.object(["text": .string("text"), "confidence": .number(.nan)]),
             "confidence must be a finite number"),
        ]

        for fixture in fixtures {
            XCTAssertThrowsError(try QVACClient.OCRTextBlock(wire: fixture.wire)) { error in
                guard case .protocolViolation(let message) = error as? QVACError else {
                    return XCTFail("expected protocol violation, got \(error)")
                }
                XCTAssertTrue(message.contains(fixture.expected), "\(message)")
            }
        }
    }

    func test_ocr_stream_preserves_terminal_blocks_latest_stats_and_profile() async throws {
        let peer = ScriptedPeer()
        let profiling = ProfilingCounter()
        let client = QVACClient(
            testing: peer,
            profilingMetadataHandler: { _ in profiling.increment() }
        )
        let run = try await client.ocr(
            modelId: "ocr",
            imageBytes: Data([1, 2, 3]),
            stream: true,
            rpcOptions: .init(timeout: nil, profiling: .init(enabled: true))
        )
        let request = try await Self.waitForRequest(on: peer)
        await Self.feedServerStream(
            id: request.id,
            records: [
                #"{"type":"ocrStream","blocks":[{"text":"first"}],"stats":{"detectionTime":3}}"#,
                #"{"type":"ocrStream","blocks":[{"text":"second","bbox":[1,2,3,4],"confidence":0.75}],"done":true,"stats":{"recognitionTime":4,"totalTime":7}}"#,
                #"{"__profilingTrailer":true,"__profiling":{"id":"ocr-profile"}}"#,
            ],
            to: peer
        )

        let blocks = try await run.blocks.value
        let stats = try await run.stats.value
        XCTAssertEqual(blocks, [])
        XCTAssertEqual(stats?.totalTime, 7)
        XCTAssertEqual(profiling.value(), 1)
        var batches: [[QVACClient.OCRTextBlock]] = []
        for try await batch in run.blockStream { batches.append(batch) }
        XCTAssertEqual(batches.map { $0.map(\.text) }, [["first"], ["second"]])
        XCTAssertEqual(batches.last?.first?.boundingBox, [1, 2, 3, 4])
        XCTAssertEqual(batches.last?.first?.confidence, 0.75)
        await client.close()

        let terminalAuthorityPeer = ScriptedPeer()
        let terminalAuthorityClient = QVACClient(testing: terminalAuthorityPeer)
        let terminalAuthorityRun = try await terminalAuthorityClient.ocr(
            modelId: "ocr",
            imagePath: "/image.png"
        )
        let terminalAuthorityRequest = try await Self.waitForRequest(
            on: terminalAuthorityPeer
        )
        await Self.feedServerStream(
            id: terminalAuthorityRequest.id,
            records: [
                #"{"type":"ocrStream","stats":{"totalTime":99}}"#,
                #"{"type":"ocrStream","done":true}"#,
            ],
            to: terminalAuthorityPeer
        )
        _ = try await terminalAuthorityRun.blocks.value
        let terminalStats = try await terminalAuthorityRun.stats.value
        XCTAssertNil(
            terminalStats,
            "an omitted done-frame stats value must clear provisional nonterminal stats"
        )
        await terminalAuthorityClient.close()
    }

    func test_ocr_fails_closed_for_worker_error_wrong_type_malformed_stats_and_eof() async throws {
        enum Fixture: CaseIterable {
            case workerError
            case wrongType
            case malformedStats
            case missingTerminal

            var records: [String] {
                switch self {
                case .workerError:
                    return [
                        #"{"type":"ocrStream","error":"recognizer crashed"}"#,
                        #"{"__profilingTrailer":true,"__profiling":{"id":"ocr-error-profile"}}"#,
                    ]
                case .wrongType:
                    return [#"{"type":"heartbeat","number":1}"#]
                case .malformedStats:
                    return [#"{"type":"ocrStream","stats":"not-an-object"}"#]
                case .missingTerminal:
                    return [#"{"type":"ocrStream","blocks":[{"text":"partial"}]}"#]
                }
            }
        }

        for fixture in Fixture.allCases {
            let peer = ScriptedPeer()
            let profiling = ProfilingCounter()
            let client = QVACClient(
                testing: peer,
                profilingMetadataHandler: { _ in profiling.increment() }
            )
            let run = try await client.ocr(modelId: "ocr", imagePath: "/image.png")
            let request = try await Self.waitForRequest(on: peer)
            await Self.feedServerStream(id: request.id, records: fixture.records, to: peer)

            switch fixture {
            case .workerError:
                do {
                    _ = try await run.blocks.value
                    XCTFail("declared OCR failure must reject")
                } catch let QVACError.server(code, message) {
                    XCTAssertEqual(code, .ocrFailed)
                    XCTAssertEqual(message, "recognizer crashed")
                }
                XCTAssertEqual(profiling.value(), 1)
            case .wrongType:
                await assertProtocolViolation(containing: "expected ocrStream") {
                    try await run.blocks.value
                }
            case .malformedStats:
                await assertProtocolViolation(containing: "malformed stats") {
                    try await run.blocks.value
                }
            case .missingTerminal:
                await assertStreamEndedWithoutTerminal {
                    try await run.blocks.value
                }
            }
            await client.close()
        }
    }

    // MARK: BCI

    func test_bci_one_shot_preserves_segments_terminal_fields_and_profile() async throws {
        let peer = ScriptedPeer()
        let profiling = ProfilingCounter()
        let client = QVACClient(
            testing: peer,
            profilingMetadataHandler: { _ in profiling.increment() }
        )
        let run = try await client.bciTranscribe(
            modelId: "bci",
            neuralData: .filePath("/recording.bin"),
            metadata: true,
            rpcOptions: .init(timeout: nil, profiling: .init(enabled: true))
        )
        let request = try await Self.waitForRequest(on: peer)
        await Self.feedServerStream(
            id: request.id,
            records: [
                #"{"type":"bciTranscribe","text":"hello ","segment":{"id":1,"text":"hello","startMs":0,"endMs":100,"append":true},"stats":{"windows":1}}"#,
                #"{"type":"bciTranscribe","text":"world","segment":{"id":2,"text":"world","startMs":100,"endMs":200,"append":false},"done":true,"stats":{"windows":2}}"#,
                #"{"__profilingTrailer":true,"__profiling":{"id":"bci-profile"}}"#,
            ],
            to: peer
        )

        let result = try await run.result.value
        XCTAssertEqual(result.text, "hello world")
        XCTAssertEqual(result.segments.map(\.id), [1, 2])
        XCTAssertEqual(result.segments.map(\.text), ["hello", "world"])
        XCTAssertEqual(result.segments.map(\.append), [true, false])
        XCTAssertEqual(result.stats, .object(["windows": .number(2)]))
        XCTAssertEqual(profiling.value(), 1)
        await client.close()

        let firstStats: JSONValue = .object(["windows": .number(1)])
        let secondStats: JSONValue = .object(["windows": .number(2)])
        let oneStatsCharge = QVACClient.conservativeBufferedJSONBytes(
            firstStats,
            elementCount: 1,
            fallback: Int.max
        )
        let replacementPeer = ScriptedPeer()
        let replacementClient = QVACClient(
            testing: replacementPeer,
            maximumAccumulatedResultBytes: oneStatsCharge
        )
        let replacementRun = try await replacementClient.bciTranscribe(
            modelId: "bci",
            neuralData: .filePath("/recording.bin"),
            rpcOptions: .init(timeout: nil)
        )
        let replacementRequest = try await Self.waitForRequest(on: replacementPeer)
        await Self.feedServerStream(
            id: replacementRequest.id,
            records: [
                #"{"type":"bciTranscribe","stats":{"windows":1}}"#,
                #"{"type":"bciTranscribe","stats":{"windows":2}}"#,
                #"{"type":"bciTranscribe","done":true}"#,
            ],
            to: replacementPeer
        )
        let replacementResult = try await replacementRun.result.value
        XCTAssertEqual(replacementResult.stats, secondStats)
        await replacementClient.close()
    }

    func test_bci_one_shot_fails_closed_for_worker_error_wrong_type_and_eof() async throws {
        enum Fixture: CaseIterable {
            case workerError
            case wrongType
            case missingTerminal

            var records: [String] {
                switch self {
                case .workerError:
                    return [
                        #"{"type":"bciTranscribe","error":"decoder failed","text":"must not be retained","segment":{"malformed":true},"stats":{"oversized":"must not be charged"}}"#,
                        #"{"__profilingTrailer":true,"__profiling":{"id":"bci-error-profile"}}"#,
                    ]
                case .wrongType:
                    return [#"{"type":"heartbeat","number":1}"#]
                case .missingTerminal:
                    return [#"{"type":"bciTranscribe","text":"partial"}"#]
                }
            }
        }

        for fixture in Fixture.allCases {
            let peer = ScriptedPeer()
            let profiling = ProfilingCounter()
            let maximumResultBytes: Int
            switch fixture {
            case .workerError: maximumResultBytes = 1
            case .wrongType, .missingTerminal: maximumResultBytes = 1_024
            }
            let client = QVACClient(
                testing: peer,
                maximumAccumulatedResultBytes: maximumResultBytes,
                profilingMetadataHandler: { _ in profiling.increment() }
            )
            let run = try await client.bciTranscribe(
                modelId: "bci",
                neuralData: .filePath("/recording.bin"),
                rpcOptions: .init(timeout: nil, profiling: .init(enabled: true))
            )
            let request = try await Self.waitForRequest(on: peer)
            await Self.feedServerStream(id: request.id, records: fixture.records, to: peer)

            switch fixture {
            case .workerError:
                do {
                    _ = try await run.result.value
                    XCTFail("declared BCI failure must reject")
                } catch let QVACError.server(code, message) {
                    XCTAssertEqual(code, .transcriptionFailed)
                    XCTAssertEqual(message, "decoder failed")
                }
                XCTAssertEqual(profiling.value(), 1)
            case .wrongType:
                await assertProtocolViolation(containing: "expected bciTranscribe") {
                    try await run.result.value
                }
            case .missingTerminal:
                await assertStreamEndedWithoutTerminal {
                    try await run.result.value
                }
            }
            await client.close()
        }
    }

    // MARK: Completion, translation, transcription, and speech

    func test_completion_drains_profile_before_declared_failure_and_rejects_wrong_type() async throws {
        do {
            let peer = ScriptedPeer()
            let profiling = ProfilingCounter()
            let client = QVACClient(
                testing: peer,
                profilingMetadataHandler: { _ in profiling.increment() }
            )
            let run = try await client.completion(
                modelId: "llm",
                history: [.user("hello")],
                rpcOptions: .init(timeout: nil, profiling: .init(enabled: true))
            )
            let request = try await Self.waitForRequest(on: peer)
            await Self.feedServerStream(
                id: request.id,
                records: [
                    #"{"type":"completionStream","events":[{"type":"contentDelta","seq":0,"text":"partial"}]}"#,
                    #"{"type":"completionStream","events":[{"type":"completionDone","seq":1,"stopReason":"error","error":{"message":"backend failed"},"raw":{"fullText":"partial raw"}}],"done":true}"#,
                    #"{"__profilingTrailer":true,"__profiling":{"id":"completion-error-profile"}}"#,
                ],
                to: peer
            )

            do {
                _ = try await run.final.value
                XCTFail("declared completion failure must reject")
            } catch let QVACError.server(code, message) {
                XCTAssertEqual(code, .completionFailed)
                XCTAssertEqual(message, "backend failed")
            }
            XCTAssertEqual(profiling.value(), 1)

            var events: [QVACClient.CompletionEvent] = []
            for try await event in run.events { events.append(event) }
            guard events.count == 2 else {
                return XCTFail("expected two completion events, got \(events)")
            }
            guard case .contentDelta(seq: 0, text: "partial") = events[0] else {
                return XCTFail("missing pre-failure content event: \(events)")
            }
            guard case .failure(seq: 1, message: "backend failed", rawFullText: "partial raw") =
                events[1]
            else { return XCTFail("missing semantic failure event: \(events)") }
            await client.close()
        }

        do {
            let peer = ScriptedPeer()
            let client = QVACClient(testing: peer)
            let run = try await client.completion(modelId: "llm", history: [.user("hello")])
            let request = try await Self.waitForRequest(on: peer)
            await Self.feedServerStream(
                id: request.id,
                records: [#"{"type":"heartbeat","number":1}"#],
                to: peer
            )
            await assertProtocolViolation(containing: "completionStream returned heartbeat") {
                try await run.final.value
            }
            await client.close()
        }
    }

    func test_completion_drains_consecutive_profiling_trailers_split_across_rpc_frames() async throws {
        let peer = ScriptedPeer()
        let profiling = ProfilingCounter()
        let client = QVACClient(
            testing: peer,
            profilingMetadataHandler: { _ in profiling.increment() }
        )
        let run = try await client.completion(
            modelId: "llm",
            history: [.user("hello")],
            rpcOptions: .init(timeout: nil, profiling: .init(enabled: true))
        )
        let request = try await Self.waitForRequest(on: peer)

        let terminal = Data(
            (#"{"type":"completionStream","events":[{"type":"completionDone","seq":0,"stopReason":"eos"}],"done":true}"# + "\n").utf8
        )
        let firstTrailer = Data(
            (#"{"__profilingTrailer":true,"__profiling":{"id":"split"}}"# + "\n").utf8
        )
        let splitIndex = firstTrailer.index(firstTrailer.startIndex, offsetBy: 23)
        let secondTrailer = Data(
            (#"{"__profilingTrailer":true,"__profiling":{"id":"consecutive"}}"# + "\n").utf8
        )

        var inbound = BareRPCCodec.__testEncodeResponseFrame(
            id: request.id,
            stream: [.open],
            payload: .success(nil)
        )
        for fragment in [
            terminal,
            Data(firstTrailer[..<splitIndex]),
            Data(firstTrailer[splitIndex...]),
            secondTrailer,
        ] {
            inbound.append(BareRPCCodec.__testEncodeStreamFrame(
                id: request.id,
                flags: [.response, .data],
                payload: .data(fragment)
            ))
        }
        inbound.append(BareRPCCodec.__testEncodeStreamFrame(
            id: request.id,
            flags: [.response, .end]
        ))
        await peer.feed(inbound)

        let result = try await run.final.value
        XCTAssertEqual(result.stopReason, .eos)
        XCTAssertEqual(profiling.value(), 2)
        await client.close()
    }

    func test_translation_fails_closed_for_worker_error_wrong_type_malformed_stats_and_eof() async throws {
        enum Fixture: CaseIterable {
            case workerError
            case wrongType
            case malformedStats
            case missingTerminal

            var records: [String] {
                switch self {
                case .workerError:
                    return [
                        #"{"type":"translate","token":"","error":"translator failed"}"#,
                        #"{"__profilingTrailer":true,"__profiling":{"id":"translate-error-profile"}}"#,
                    ]
                case .wrongType:
                    return [#"{"type":"heartbeat","number":1}"#]
                case .malformedStats:
                    return [
                        #"{"type":"translate","token":"","done":true,"stats":"not-an-object"}"#,
                        #"{"__profilingTrailer":true,"__profiling":{"id":"translate-stats-profile"}}"#,
                    ]
                case .missingTerminal:
                    return [#"{"type":"translate","token":"partial"}"#]
                }
            }
        }

        for fixture in Fixture.allCases {
            let peer = ScriptedPeer()
            let profiling = ProfilingCounter()
            let client = QVACClient(
                testing: peer,
                profilingMetadataHandler: { _ in profiling.increment() }
            )
            let run = try await client.translate(
                modelId: "translator",
                modelType: "llamacpp-completion",
                text: "hello",
                to: "fr",
                stream: false,
                rpcOptions: .init(timeout: nil, profiling: .init(enabled: true))
            )
            let request = try await Self.waitForRequest(on: peer)
            await Self.feedServerStream(id: request.id, records: fixture.records, to: peer)

            switch fixture {
            case .workerError:
                do {
                    _ = try await run.text.value
                    XCTFail("declared translation failure must reject")
                } catch let QVACError.server(code, message) {
                    XCTAssertEqual(code, .translationFailed)
                    XCTAssertEqual(message, "translator failed")
                }
                XCTAssertEqual(profiling.value(), 1)
            case .wrongType:
                await assertProtocolViolation(containing: "expected translate") {
                    try await run.text.value
                }
            case .malformedStats:
                await assertProtocolViolation(containing: "malformed stats") {
                    try await run.text.value
                }
                XCTAssertEqual(profiling.value(), 1)
            case .missingTerminal:
                await assertStreamEndedWithoutTerminal {
                    try await run.text.value
                }
            }
            await client.close()
        }
    }

    func test_translation_cancel_terminates_the_authoritative_processing_task() async throws {
        let peer = ScriptedPeer()
        let client = QVACClient(testing: peer)
        let run = try await client.translate(
            modelId: "translator",
            modelType: "llamacpp-completion",
            text: "hello",
            to: "fr"
        )
        _ = try await Self.waitForRequest(on: peer)
        run.cancel()

        do {
            _ = try await run.stats.value
            XCTFail("cancelled translation must not resolve successfully")
        } catch is CancellationError {
            // Cancellation is a public semantic, not a worker failure mapping.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        await client.close()
    }

    func test_transcribe_preserves_nonterminal_segments_and_rejects_worker_or_type_errors() async throws {
        do {
            let peer = ScriptedPeer()
            let client = QVACClient(testing: peer)
            let run = try await client.transcribeWithMetadata(
                modelId: "transcriber",
                audioPath: "/audio.wav"
            )
            let request = try await Self.waitForRequest(on: peer)
            await Self.feedServerStream(
                id: request.id,
                records: [
                    #"{"type":"transcribe","text":"first ","segment":{"id":1,"text":"first","startMs":0,"endMs":100,"append":true}}"#,
                    #"{"type":"transcribe","text":"second","done":true,"stats":{"segments":1}}"#,
                ],
                to: peer
            )
            let result = try await run.result.value
            XCTAssertEqual(result.text, "first second")
            XCTAssertEqual(result.segments.map(\.id), [1])
            XCTAssertEqual(result.segments.map(\.text), ["first"])
            XCTAssertEqual(result.stats, .object(["segments": .number(1)]))
            await client.close()
        }

        do {
            let firstStats: JSONValue = .object(["segments": .number(1)])
            let secondStats: JSONValue = .object(["segments": .number(2)])
            let oneStatsCharge = QVACClient.conservativeBufferedJSONBytes(
                firstStats,
                elementCount: 1,
                fallback: Int.max
            )
            let peer = ScriptedPeer()
            let client = QVACClient(
                testing: peer,
                maximumAccumulatedResultBytes: oneStatsCharge
            )
            let run = try await client.transcribe(
                modelId: "transcriber",
                audioPath: "/audio.wav",
                rpcOptions: .init(timeout: nil)
            )
            let request = try await Self.waitForRequest(on: peer)
            await Self.feedServerStream(
                id: request.id,
                records: [
                    #"{"type":"transcribe","stats":{"segments":1}}"#,
                    #"{"type":"transcribe","stats":{"segments":2}}"#,
                    #"{"type":"transcribe","done":true}"#,
                ],
                to: peer
            )
            let result = try await run.result.value
            XCTAssertEqual(result.stats, secondStats)
            await client.close()
        }

        enum Fixture: CaseIterable {
            case workerError
            case wrongType

            var records: [String] {
                switch self {
                case .workerError:
                    return [
                        #"{"type":"transcribe","error":"decoder failed"}"#,
                        #"{"__profilingTrailer":true,"__profiling":{"id":"transcribe-error-profile"}}"#,
                    ]
                case .wrongType:
                    return [#"{"type":"heartbeat","number":1}"#]
                }
            }
        }

        for fixture in Fixture.allCases {
            let peer = ScriptedPeer()
            let profiling = ProfilingCounter()
            let client = QVACClient(
                testing: peer,
                profilingMetadataHandler: { _ in profiling.increment() }
            )
            let run = try await client.transcribe(
                modelId: "transcriber",
                audioPath: "/audio.wav",
                rpcOptions: .init(timeout: nil, profiling: .init(enabled: true))
            )
            let request = try await Self.waitForRequest(on: peer)
            await Self.feedServerStream(id: request.id, records: fixture.records, to: peer)

            switch fixture {
            case .workerError:
                do {
                    _ = try await run.result.value
                    XCTFail("declared transcription failure must reject")
                } catch let QVACError.server(code, message) {
                    XCTAssertEqual(code, .transcriptionFailed)
                    XCTAssertEqual(message, "decoder failed")
                }
                XCTAssertEqual(profiling.value(), 1)
            case .wrongType:
                await assertProtocolViolation(containing: "expected transcribe") {
                    try await run.result.value
                }
            }
            await client.close()
        }
    }

    func test_text_to_speech_rejects_wrong_response_type_and_eof_without_done() async throws {
        enum Fixture: CaseIterable {
            case wrongType
            case missingTerminal

            var records: [String] {
                switch self {
                case .wrongType:
                    return [#"{"type":"heartbeat","number":1}"#]
                case .missingTerminal:
                    return [#"{"type":"textToSpeech","buffer":[0.25],"done":false}"#]
                }
            }
        }

        for fixture in Fixture.allCases {
            let peer = ScriptedPeer()
            let client = QVACClient(testing: peer)
            let run = try await client.textToSpeech(modelId: "tts", text: "hello")
            let request = try await Self.waitForRequest(on: peer)
            await Self.feedServerStream(id: request.id, records: fixture.records, to: peer)

            switch fixture {
            case .wrongType:
                await assertProtocolViolation(containing: "expected textToSpeech") {
                    try await run.done.value
                }
            case .missingTerminal:
                await assertStreamEndedWithoutTerminal {
                    try await run.done.value
                }
            }
            await client.close()
        }
    }
}
