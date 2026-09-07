import Foundation
import XCTest
@testable import QVACClient

/// Adversarial specifications for public API boundaries that are easy to miss in
/// happy-path contract tests. The peer is fully in memory, but all requests still
/// traverse the production encoder, multiplexer, decoder, and terminal drain.
final class QVACPublicBoundaryTests: XCTestCase {
    private enum FactoryProbeError: Error {
        case failed
    }

    private final class InboundPipe: @unchecked Sendable {
        let stream: AsyncThrowingStream<Data, Error>
        let continuation: AsyncThrowingStream<Data, Error>.Continuation

        init() {
            var captured: AsyncThrowingStream<Data, Error>.Continuation!
            stream = AsyncThrowingStream { captured = $0 }
            continuation = captured
        }
    }

    /// A byte-level peer that also acknowledges the two duplex OPEN directions.
    private actor PeerTransport: BareTransport {
        nonisolated private let inbound = InboundPipe()
        private var outboundBytes = Data()
        private var closed = false
        private var acknowledgedDuplexIDs: Set<UInt64> = []

        nonisolated func inboundStream() -> AsyncThrowingStream<Data, Error> {
            inbound.stream
        }

        func write(_ data: Data) throws {
            outboundBytes.append(data)

            let reader = BareRPCFrameReader()
            try reader.append(data)
            while let frame = reader.next() {
                guard case .request(let id, _, let flags, _) = frame,
                      flags.contains(.open),
                      acknowledgedDuplexIDs.insert(id).inserted else { continue }
                var reply = BareRPCCodec.__testEncodeStreamFrame(
                    id: id,
                    flags: [.request, .open]
                )
                reply.append(BareRPCCodec.__testEncodeStreamFrame(
                    id: id,
                    flags: [.response, .open]
                ))
                inbound.continuation.yield(reply)
            }
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
        func isClosed() -> Bool { closed }
    }

    private static func frames(in data: Data) -> [BareRPCFrame] {
        let reader = BareRPCFrameReader()
        try? reader.append(data)
        var frames: [BareRPCFrame] = []
        while let frame = reader.next() { frames.append(frame) }
        return frames
    }

    private static func waitForFrames(
        _ count: Int,
        on transport: PeerTransport,
        timeout: Duration = .seconds(1)
    ) async throws -> [BareRPCFrame] {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            let observed = frames(in: await transport.outbound())
            if observed.count >= count { return observed }
            try await Task.sleep(for: .milliseconds(5))
        }
        let observed = frames(in: await transport.outbound())
        XCTFail("timed out waiting for \(count) bare-rpc frames; received \(observed.count)")
        throw QVACError.protocolViolation("test peer did not receive the expected request")
    }

    private static func request(
        in frames: [BareRPCFrame]
    ) throws -> (id: UInt64, body: [String: Any]) {
        for frame in frames {
            if case .request(let id, _, _, .some(let payload)) = frame {
                let body = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: payload) as? [String: Any]
                )
                return (id, body)
            }
        }
        throw QVACError.protocolViolation("test peer did not observe an inline request")
    }

    private static func duplexRequest(
        in frames: [BareRPCFrame]
    ) throws -> (id: UInt64, body: [String: Any]) {
        for frame in frames {
            if case .stream(let id, let flags, .data(let payload)) = frame,
               flags.contains(.request) {
                let body = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: payload) as? [String: Any]
                )
                return (id, body)
            }
        }
        throw QVACError.protocolViolation("test peer did not observe a duplex request")
    }

    private static func feedReply(
        id: UInt64,
        payload: Data?,
        to transport: PeerTransport
    ) async {
        await transport.feed(BareRPCCodec.__testEncodeResponseFrame(
            id: id,
            stream: [],
            payload: .success(payload)
        ))
    }

    private static func feedServerStream(
        id: UInt64,
        records: [String],
        to transport: PeerTransport,
        end: Bool = true
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
        if end {
            inbound.append(BareRPCCodec.__testEncodeStreamFrame(
                id: id,
                flags: [.response, .end]
            ))
        }
        await transport.feed(inbound)
    }

    private static func waitForNoInFlight(
        _ rpc: BareRPCClient,
        timeout: Duration = .seconds(1)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await rpc.__testInFlightCounts() == (0, 0, 0) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("bare-rpc state did not terminate: \(await rpc.__testInFlightCounts())")
    }

    private func assertProtocolViolation(
        _ error: Error,
        contains expected: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .protocolViolation(let message) = error as? QVACError else {
            return XCTFail("expected protocolViolation, got \(error)", file: file, line: line)
        }
        if let expected {
            XCTAssertTrue(
                message.contains(expected),
                "'\(message)' does not contain '\(expected)'",
                file: file,
                line: line
            )
        }
    }

    private func assertEndedWithoutTerminal(
        _ error: Error,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .client(let code, _) = error as? QVACError else {
            return XCTFail("expected typed client error, got \(error)", file: file, line: line)
        }
        XCTAssertEqual(code, .streamEndedWithoutResponse, file: file, line: line)
    }

    private func assertServerError<Value: Sendable>(
        _ task: Task<Value, Error>,
        code expectedCode: QVACErrorCode,
        message expectedMessage: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await task.value
            XCTFail("expected a typed server error", file: file, line: line)
        } catch let QVACError.server(code, message) {
            XCTAssertEqual(code, expectedCode, file: file, line: line)
            XCTAssertEqual(message, expectedMessage, file: file, line: line)
        } catch {
            XCTFail("expected a typed server error, got \(error)", file: file, line: line)
        }
    }

    func test_os_logger_accepts_every_public_log_level() {
        let logger = QVACOSLogger()
        for level in [
            BareRPCLogLevel.debug,
            .info,
            .warn,
            .error,
        ] {
            logger.log(level, "QVAC logger boundary smoke test")
        }
    }

    func test_public_initializer_bounds_silent_and_rejected_handshakes() async throws {
        do {
            let transport = PeerTransport()
            let clock = ContinuousClock()
            let started = clock.now
            do {
                let client = try await QVACClient(
                    configuration: .testing(transport),
                    runtimeContext: nil,
                    initHandshakeTimeout: .milliseconds(25),
                    logger: nil
                )
                await client.close()
                XCTFail("a silent worker must not leave initialization pending")
            } catch let QVACError.transport(reason, _) {
                XCTAssertTrue(reason.contains("did not reply to __init_config"))
                XCTAssertTrue(reason.contains("0.025 seconds"))
            } catch {
                XCTFail("expected normalized handshake timeout, got \(error)")
            }
            XCTAssertLessThan(started.duration(to: clock.now), .seconds(1))
            let transportClosed = await transport.isClosed()
            XCTAssertTrue(transportClosed)
        }

        do {
            let transport = PeerTransport()
            let initialization = Task {
                try await QVACClient(
                    configuration: .testing(transport),
                    runtimeContext: nil,
                    initHandshakeTimeout: .seconds(1),
                    logger: nil
                )
            }
            let outbound = try await Self.waitForFrames(1, on: transport)
            let request = try Self.request(in: outbound)
            XCTAssertEqual(request.body["type"] as? String, "__init_config")
            await Self.feedReply(
                id: request.id,
                payload: Data(#"{"success":false,"error":"policy rejected"}"#.utf8),
                to: transport
            )

            do {
                let client = try await initialization.value
                await client.close()
                XCTFail("a negative init acknowledgement must fail")
            } catch let QVACError.transport(reason, underlying) {
                XCTAssertTrue(reason.contains("policy rejected"))
                XCTAssertTrue(underlying is QVACInitConfigFailed)
            } catch {
                XCTFail("expected normalized init rejection, got \(error)")
            }
            let transportClosed = await transport.isClosed()
            XCTAssertTrue(transportClosed)
        }
    }

    func test_testing_factory_preserves_qvac_errors_and_wraps_foreign_errors() async {
        do {
            let client = try await QVACClient(
                configuration: .testing(factory: {
                    throw QVACError.invalidArgument("factory rejected configuration")
                }),
                runtimeContext: nil,
                logger: nil
            )
            await client.close()
            XCTFail("factory failure must escape initialization")
        } catch let QVACError.invalidArgument(message) {
            XCTAssertEqual(message, "factory rejected configuration")
        } catch {
            XCTFail("typed factory error changed identity: \(error)")
        }

        do {
            let client = try await QVACClient(
                configuration: .testing(factory: { throw FactoryProbeError.failed }),
                runtimeContext: nil,
                logger: nil
            )
            await client.close()
            XCTFail("foreign factory failure must escape initialization")
        } catch let QVACError.transport(reason, underlying) {
            XCTAssertEqual(reason, "could not create worker transport")
            XCTAssertTrue(underlying is FactoryProbeError)
        } catch {
            XCTFail("foreign factory error was not normalized: \(error)")
        }
    }

    func test_response_decoding_and_public_error_mapping_fail_closed() throws {
        XCTAssertThrowsError(try QVACClient.decodeOrThrowStatic(
            HeartbeatResponse.self,
            from: Data(#"{"type":"error","code":52002,"message":"missing"}"#.utf8)
        )) { error in
            guard case QVACError.server(.modelNotFound, let message) = error else {
                return XCTFail("expected typed worker error, got \(error)")
            }
            XCTAssertEqual(message, "missing")
        }

        XCTAssertThrowsError(try QVACClient.decodeStreamRecord(
            QVACResponse.self,
            from: Data(#"{"type":"error","code":52002}"#.utf8)
        )) { error in
            self.assertProtocolViolation(error, contains: "malformed error response")
        }

        guard case QVACError.streamBufferOverflow(
            let operation,
            let maximumBytes,
            let attemptedBytes
        ) = QVACClient.publicRPCError(
            BareRPCStreamBufferOverflow(maximumBufferedBytes: 64, attemptedBufferedBytes: 65),
            operation: "completionStream"
        ) else { return XCTFail("stream overflow must retain its byte accounting") }
        XCTAssertEqual(operation, "completionStream")
        XCTAssertEqual(maximumBytes, 64)
        XCTAssertEqual(attemptedBytes, 65)

        guard case QVACError.server(.modelNotFound, let remoteMessage) =
            QVACClient.publicRPCError(
                BareRPCError(message: "missing", code: "MODEL_NOT_FOUND", errno: 52_002),
                operation: "classify"
            )
        else { return XCTFail("remote bare-rpc error must retain its typed code") }
        XCTAssertEqual(remoteMessage, "missing")

        let foreign = QVACClient.publicRPCError(FactoryProbeError.failed, operation: "videoStream")
        guard case QVACError.transport(let reason, let underlying) = foreign else {
            return XCTFail("foreign errors must be normalized to transport failures")
        }
        XCTAssertEqual(reason, "videoStream RPC failed")
        XCTAssertTrue(underlying is FactoryProbeError)
    }

    func test_unary_empty_reply_is_a_protocol_violation() async throws {
        let transport = PeerTransport()
        let client = QVACClient(testing: transport)
        let heartbeat = Task { try await client.wireHeartbeat(.init()) }
        let request = try Self.request(in: try await Self.waitForFrames(1, on: transport))
        await Self.feedReply(id: request.id, payload: nil, to: transport)

        do {
            _ = try await heartbeat.value
            XCTFail("a successful bare-rpc envelope without JSON must fail")
        } catch {
            assertProtocolViolation(error, contains: "empty reply")
        }
        await client.close()
    }

    func test_concrete_stream_rejects_domain_data_after_terminal_error() async throws {
        let transport = PeerTransport()
        let client = QVACClient(testing: transport)
        let stream: QVACResponseStream<CompletionStreamResponse> = try await client.streamTyped(
            .completionStream(.init(history: [], modelId: "missing", stream: true)),
            decoding: CompletionStreamResponse.self
        )
        let request = try Self.request(in: try await Self.waitForFrames(2, on: transport))
        await Self.feedServerStream(
            id: request.id,
            records: [
                #"{"type":"error","code":52002,"message":"missing"}"#,
                #"{"type":"completionStream","events":[],"done":true}"#,
            ],
            to: transport
        )

        do {
            var iterator = stream.makeAsyncIterator()
            _ = try await iterator.next()
            XCTFail("a concrete stream must not accept domain data after an error")
        } catch {
            assertProtocolViolation(error, contains: "after its terminal error")
        }
        await client.close()
    }

    func test_duplex_write_and_end_normalize_closed_stream_errors() async throws {
        let transport = PeerTransport()
        let client = QVACClient(testing: transport)
        let session = try await client.wireBciTranscribeStream(.init(modelId: "bci"))
        let frames = try await Self.waitForFrames(3, on: transport)
        let request = try Self.duplexRequest(in: frames)

        var terminal = BareRPCCodec.__testEncodeStreamFrame(
            id: request.id,
            flags: [.request, .end]
        )
        terminal.append(BareRPCCodec.__testEncodeStreamFrame(
            id: request.id,
            flags: [.response, .end]
        ))
        await transport.feed(terminal)
        let rpc = await client.rpc
        try await Self.waitForNoInFlight(rpc)

        for operation in [
            { try await session.write(Data([1])) },
            { try await session.end() },
        ] {
            do {
                try await operation()
                XCTFail("a terminated duplex direction must reject further writes")
            } catch let QVACError.transport(reason, underlying) {
                XCTAssertEqual(reason, "bciTranscribeStream RPC failed")
                XCTAssertTrue(underlying is BareRPCStreamClosed)
            } catch {
                XCTFail("duplex error leaked an internal type: \(error)")
            }
        }
        await client.close()
    }

    func test_upscale_rejects_empty_and_malformed_images_and_missing_terminal() async throws {
        do {
            let transport = PeerTransport()
            let client = QVACClient(testing: transport)
            do {
                _ = try await client.upscale(modelId: "upscaler", image: Data())
                XCTFail("empty images must be rejected before base64 encoding")
            } catch let QVACError.invalidArgument(message) {
                XCTAssertTrue(message.contains("must not be empty"))
            } catch {
                XCTFail("expected invalidArgument, got \(error)")
            }
            let outbound = await transport.outbound()
            XCTAssertTrue(outbound.isEmpty)
            await client.close()
        }

        for record in [
            #"{"type":"upscaleStream","data":"%%%","done":false}"#,
            #"{"type":"upscaleStream","data":"%%%","done":true}"#,
        ] {
            let transport = PeerTransport()
            let client = QVACClient(testing: transport)
            let run = try await client.upscale(modelId: "upscaler", image: Data([1]))
            let request = try Self.request(in: try await Self.waitForFrames(2, on: transport))
            await Self.feedServerStream(id: request.id, records: [record], to: transport)
            do {
                _ = try await run.outputs.value
                XCTFail("invalid base64 image output must fail")
            } catch {
                assertProtocolViolation(error, contains: "invalid base64 image")
            }
            await client.close()
        }

        do {
            let transport = PeerTransport()
            let client = QVACClient(testing: transport)
            let run = try await client.upscale(modelId: "upscaler", image: Data([1]))
            let request = try Self.request(in: try await Self.waitForFrames(2, on: transport))
            await Self.feedServerStream(
                id: request.id,
                records: [#"{"type":"upscaleStream"}"#],
                to: transport
            )
            do {
                _ = try await run.outputs.value
                XCTFail("upscale must require a terminal done frame")
            } catch {
                assertEndedWithoutTerminal(error)
            }
            await client.close()
        }
    }

    func test_video_covers_terminal_progress_intermediate_output_and_terminal_failures() async throws {
        do {
            let transport = PeerTransport()
            let client = QVACClient(testing: transport)
            let run = try await client.video(
                VideoStreamRequest(mode: "txt2vid", modelId: "video", prompt: "move")
            )
            let request = try Self.request(in: try await Self.waitForFrames(2, on: transport))
            await Self.feedServerStream(
                id: request.id,
                records: [
                    #"{"type":"videoStream","data":"AQI="}"#,
                    #"{"type":"videoStream","step":3,"totalSteps":3,"elapsedMs":12,"done":true}"#,
                ],
                to: transport
            )
            let outputs = try await run.outputs.value
            XCTAssertEqual(outputs, [Data([1, 2])])
            var progress: [QVACClient.VideoProgressTick] = []
            for try await tick in run.progressStream { progress.append(tick) }
            XCTAssertEqual(progress, [.init(step: 3, totalSteps: 3, elapsedMs: 12)])
            let stats = try await run.stats.value
            XCTAssertNil(stats)
            await client.close()
        }

        for fixture in [
            (record: #"{"type":"heartbeat","number":1}"#, expected: "videoStream"),
            (record: #"{"type":"videoStream"}"#, expected: "terminal"),
            (
                record: #"{"type":"videoStream","stats":{"seed":"invalid"},"done":true}"#,
                expected: "malformed stats"
            ),
        ] {
            let transport = PeerTransport()
            let client = QVACClient(testing: transport)
            let run = try await client.video(
                VideoStreamRequest(mode: "txt2vid", modelId: "video", prompt: "move")
            )
            let request = try Self.request(in: try await Self.waitForFrames(2, on: transport))
            await Self.feedServerStream(id: request.id, records: [fixture.record], to: transport)
            do {
                _ = try await run.outputs.value
                XCTFail("video failure fixture unexpectedly succeeded")
            } catch let error as QVACError {
                if fixture.expected == "terminal" {
                    assertEndedWithoutTerminal(error)
                } else {
                    assertProtocolViolation(error, contains: fixture.expected)
                }
            } catch {
                XCTFail("video leaked a non-QVAC error: \(error)")
            }
            await client.close()
        }
    }

    func test_video_binary_overload_rejects_empty_inputs_before_io() async {
        let transport = PeerTransport()
        let client = QVACClient(testing: transport)

        let operations: [() async throws -> Void] = [
            {
                _ = try await client.video(
                    modelId: "video",
                    mode: "img2vid",
                    prompt: "move",
                    initImage: Data()
                )
            },
            {
                _ = try await client.video(
                    modelId: "video",
                    mode: "txt2vid",
                    prompt: "move",
                    controlFrames: []
                )
            },
            {
                _ = try await client.video(
                    modelId: "video",
                    mode: "txt2vid",
                    prompt: "move",
                    controlFrames: [Data([1]), Data()]
                )
            },
        ]
        for operation in operations {
            do {
                try await operation()
                XCTFail("empty binary video input must fail")
            } catch let QVACError.invalidArgument(message) {
                XCTAssertTrue(message.contains("must not"))
            } catch {
                XCTFail("expected invalidArgument, got \(error)")
            }
        }
        let outbound = await transport.outbound()
        XCTAssertTrue(outbound.isEmpty)
        await client.close()
    }

    func test_classification_accepts_exact_results_and_rejects_schema_drift() async throws {
        do {
            let transport = PeerTransport()
            let client = QVACClient(testing: transport)
            let result = Task {
                try await client.classify(modelId: "classifier", image: Data([1]))
            }
            let request = try Self.request(in: try await Self.waitForFrames(2, on: transport))
            await Self.feedServerStream(
                id: request.id,
                records: [
                    #"{"type":"classify","results":[{"label":"cat","confidence":0.9},{"label":"dog","confidence":0.1}],"done":true}"#,
                ],
                to: transport
            )
            let values = try await result.value
            XCTAssertEqual(values.map(\.label), ["cat", "dog"])
            XCTAssertEqual(values.map(\.confidence), [0.9, 0.1])
            await client.close()
        }

        for record in [
            #"{"type":"classify","results":[{"label":"cat"}],"done":true}"#,
            #"{"type":"heartbeat","number":1}"#,
        ] {
            let transport = PeerTransport()
            let client = QVACClient(testing: transport)
            let result = Task {
                try await client.classify(modelId: "classifier", image: Data([1]))
            }
            let request = try Self.request(in: try await Self.waitForFrames(2, on: transport))
            await Self.feedServerStream(id: request.id, records: [record], to: transport)
            do {
                _ = try await result.value
                XCTFail("classification schema drift must fail")
            } catch {
                assertProtocolViolation(error)
            }
            await client.close()
        }
    }

    func test_empty_classify_and_ocr_data_match_the_017_base64_contract() async throws {
        do {
            let transport = PeerTransport()
            let client = QVACClient(testing: transport)
            let result = Task {
                try await client.classify(
                    modelId: "classifier",
                    image: Data(),
                    rpcOptions: .init(timeout: nil)
                )
            }
            let request = try Self.request(in: try await Self.waitForFrames(2, on: transport))
            XCTAssertEqual(request.body["type"] as? String, "classify")
            XCTAssertEqual(request.body["image"] as? String, "")
            await Self.feedServerStream(
                id: request.id,
                records: [#"{"type":"classify","results":[],"done":true}"#],
                to: transport
            )
            let values = try await result.value
            XCTAssertEqual(values, [])
            await client.close()
        }

        do {
            let transport = PeerTransport()
            let client = QVACClient(testing: transport)
            let run = try await client.ocr(
                modelId: "ocr",
                imageBytes: Data(),
                rpcOptions: .init(timeout: nil)
            )
            let request = try Self.request(in: try await Self.waitForFrames(2, on: transport))
            XCTAssertEqual(request.body["type"] as? String, "ocrStream")
            let image = try XCTUnwrap(request.body["image"] as? [String: Any])
            XCTAssertEqual(image["type"] as? String, "base64")
            XCTAssertEqual(image["value"] as? String, "")
            await Self.feedServerStream(
                id: request.id,
                records: [#"{"type":"ocrStream","blocks":[],"done":true}"#],
                to: transport
            )
            let blocks = try await run.blocks.value
            XCTAssertEqual(blocks, [])
            await client.close()
        }
    }

    func test_audio_generation_preserves_terminal_progress_and_all_stats() async throws {
        let transport = PeerTransport()
        let client = QVACClient(testing: transport)
        let run = try await client.audioGen(modelId: "audio", caption: "rain")
        let request = try Self.request(in: try await Self.waitForFrames(2, on: transport))
        await Self.feedServerStream(
            id: request.id,
            records: [
                #"{"type":"audioGenStream","data":"AQI=","sampleRate":48000,"channels":2,"bitsPerSample":16,"progress":{"stage":"complete","step":2,"total":2},"stats":{"audioDurationMs":1000,"totalTimeMs":1100,"realTimeFactor":1.1,"backendDevice":1,"backendId":7},"done":true,"stopReason":"completed"}"#,
            ],
            to: transport
        )

        let audio = try await run.audio.value
        XCTAssertEqual(audio.pcm, Data([1, 2]))
        var progress: [QVACClient.AudioGenProgress] = []
        for try await value in run.progressStream { progress.append(value) }
        XCTAssertEqual(progress.map(\.stage), ["complete"])
        XCTAssertEqual(progress.map(\.step), [2])
        XCTAssertEqual(progress.map(\.total), [2])
        let terminalStats = try await run.stats.value
        let stats = try XCTUnwrap(terminalStats)
        XCTAssertEqual(stats.audioDurationMs, 1_000)
        XCTAssertEqual(stats.totalTimeMs, 1_100)
        XCTAssertEqual(stats.realTimeFactor, 1.1)
        XCTAssertEqual(stats.backendDevice, 1)
        XCTAssertEqual(stats.backendId, 7)
        await client.close()
    }

    func test_audio_generation_rejects_wrong_type_cancellation_eof_and_malformed_metadata() async throws {
        enum ExpectedFailure {
            case protocolMessage(String)
            case cancelled
            case missingTerminal
        }
        let fixtures: [(String, ExpectedFailure)] = [
            (#"{"type":"heartbeat","number":1}"#, .protocolMessage("audioGenStream")),
            (
                #"{"type":"audioGenStream","done":true,"stopReason":"cancelled"}"#,
                .cancelled
            ),
            (#"{"type":"audioGenStream","done":false}"#, .missingTerminal),
            (
                #"{"type":"audioGenStream","progress":"invalid","done":false}"#,
                .protocolMessage("progress")
            ),
            (
                #"{"type":"audioGenStream","data":"AQI=","sampleRate":48000,"channels":1,"bitsPerSample":16,"stats":[],"done":true}"#,
                .protocolMessage("stats must be an object")
            ),
            (
                #"{"type":"audioGenStream","data":"AQI=","sampleRate":48000,"channels":1,"bitsPerSample":16,"stats":{"audioDurationMs":"slow"},"done":true}"#,
                .protocolMessage("finite number")
            ),
        ]

        for (record, expected) in fixtures {
            let transport = PeerTransport()
            let client = QVACClient(testing: transport)
            let run = try await client.audioGen(modelId: "audio", caption: "rain")
            let request = try Self.request(in: try await Self.waitForFrames(2, on: transport))
            await Self.feedServerStream(id: request.id, records: [record], to: transport)
            do {
                _ = try await run.audio.value
                XCTFail("invalid audio generation fixture unexpectedly succeeded")
            } catch {
                switch expected {
                case .protocolMessage(let message):
                    assertProtocolViolation(error, contains: message)
                case .cancelled:
                    guard case QVACError.server(.inferenceCancelled, let message) = error else {
                        XCTFail("expected inferenceCancelled, got \(error)")
                        break
                    }
                    XCTAssertTrue(message?.contains(run.requestId) == true)
                case .missingTerminal:
                    assertEndedWithoutTerminal(error)
                }
            }
            await client.close()
        }
    }

    func test_batch_completion_local_and_wire_validation_fail_closed() async throws {
        do {
            let transport = PeerTransport()
            let client = QVACClient(testing: transport)
            for prompts in [
                [QVACClient.BatchPrompt](),
                [.init(id: "", history: [.user("hello")])],
            ] {
                do {
                    _ = try await client.batchCompletion(modelId: "llm", prompts: prompts)
                    XCTFail("invalid prompt collection must fail")
                } catch let QVACError.invalidArgument(message) {
                    XCTAssertTrue(message.contains("prompt"))
                } catch {
                    XCTFail("expected invalidArgument, got \(error)")
                }
            }
            let outbound = await transport.outbound()
            XCTAssertTrue(outbound.isEmpty)
            await client.close()
        }

        let invalidTerminalRecords = [
            #"{"type":"batchCompletionStream","ids":["same","same"],"events":[],"done":true}"#,
            #"{"type":"batchCompletionStream","events":[{"event":{"type":"contentDelta","seq":0,"text":"missing id"}}],"done":true}"#,
            #"{"type":"batchCompletionStream","events":[],"stats":"invalid","done":true}"#,
        ]
        for record in invalidTerminalRecords {
            let transport = PeerTransport()
            let client = QVACClient(testing: transport)
            let run = try await client.batchCompletion(
                modelId: "llm",
                prompts: [
                    .init(history: [.user("one")]),
                    .init(history: [.user("two")]),
                ]
            )
            let request = try Self.request(in: try await Self.waitForFrames(2, on: transport))
            await Self.feedServerStream(id: request.id, records: [record], to: transport)
            do {
                _ = try await run.results.value
                XCTFail("invalid batch terminal frame must fail")
            } catch {
                assertProtocolViolation(error)
            }
            await client.close()
        }

        do {
            let transport = PeerTransport()
            let client = QVACClient(testing: transport)
            let run = try await client.batchCompletion(
                modelId: "llm",
                prompts: [.init(history: [.user("one")])]
            )
            let request = try Self.request(in: try await Self.waitForFrames(2, on: transport))
            await Self.feedServerStream(
                id: request.id,
                records: [
                    #"{"type":"batchCompletionStream","events":[{"id":"one","event":{"type":"contentDelta","seq":0,"text":"a"}},{"id":"two","event":{"type":"contentDelta","seq":0,"text":"b"}}]}"#,
                ],
                to: transport
            )
            do {
                _ = try await run.results.value
                XCTFail("the worker must not introduce more ids than prompts")
            } catch {
                assertProtocolViolation(error, contains: "more ids")
            }
            await client.close()
        }
    }

    func test_batch_completion_propagates_worker_error_and_eof_to_existing_views() async throws {
        do {
            let transport = PeerTransport()
            let client = QVACClient(testing: transport)
            let run = try await client.batchCompletion(
                modelId: "missing",
                prompts: [.init(id: "prompt", history: [.user("hello")])]
            )
            let perID = run.byId("prompt")
            let request = try Self.request(in: try await Self.waitForFrames(2, on: transport))
            await Self.feedServerStream(
                id: request.id,
                records: [#"{"type":"error","code":52002,"message":"missing model"}"#],
                to: transport
            )

            await assertServerError(
                run.ids,
                code: .modelNotFound,
                message: "missing model"
            )
            await assertServerError(
                run.results,
                code: .modelNotFound,
                message: "missing model"
            )
            await assertServerError(
                perID.final,
                code: .modelNotFound,
                message: "missing model"
            )
            var iterator = perID.events.makeAsyncIterator()
            do {
                _ = try await iterator.next()
                XCTFail("per-id event view must receive the worker error")
            } catch let QVACError.server(code, _) {
                XCTAssertEqual(code, .modelNotFound)
            } catch {
                XCTFail("per-id event view received the wrong error: \(error)")
            }
            await client.close()
        }

        do {
            let transport = PeerTransport()
            let client = QVACClient(testing: transport)
            let run = try await client.batchCompletion(
                modelId: "llm",
                prompts: [.init(history: [.user("hello")])]
            )
            let request = try Self.request(in: try await Self.waitForFrames(2, on: transport))
            await Self.feedServerStream(
                id: request.id,
                records: [#"{"type":"batchCompletionStream","events":[]}"#],
                to: transport
            )
            do {
                _ = try await run.results.value
                XCTFail("batch completion must require a terminal done frame")
            } catch {
                assertEndedWithoutTerminal(error)
            }
            await client.close()
        }
    }

    func test_batch_completion_accumulates_all_event_families_before_failure() async throws {
        let transport = PeerTransport()
        let client = QVACClient(testing: transport)
        let run = try await client.batchCompletion(
            modelId: "llm",
            prompts: [.init(id: "prompt", history: [.user("hello")])]
        )
        let perID = run.byId("prompt")
        let request = try Self.request(in: try await Self.waitForFrames(2, on: transport))
        await Self.feedServerStream(
            id: request.id,
            records: [
                #"{"type":"batchCompletionStream","ids":["prompt"],"events":[{"id":"prompt","event":{"type":"thinkingDelta","seq":0,"text":"reason"}},{"id":"prompt","event":{"type":"toolCall","seq":1,"call":{"id":"call","name":"lookup","arguments":{}}}},{"id":"prompt","event":{"type":"rawDelta","seq":2,"text":"raw"}},{"id":"prompt","event":{"type":"toolError","seq":3,"error":{"code":"UNKNOWN_TOOL","message":"missing"}}},{"id":"prompt","event":{"type":"completionDone","seq":4,"stopReason":"error","error":{"message":"backend failed"},"raw":{"fullText":"partial"}}}],"done":true}"#,
            ],
            to: transport
        )

        await assertServerError(
            run.results,
            code: .completionFailed,
            message: "backend failed"
        )
        await assertServerError(
            perID.final,
            code: .completionFailed,
            message: "backend failed"
        )
        var events: [QVACClient.CompletionEvent] = []
        for try await event in perID.events { events.append(event) }
        XCTAssertEqual(events.count, 5)
        await client.close()
    }
}
