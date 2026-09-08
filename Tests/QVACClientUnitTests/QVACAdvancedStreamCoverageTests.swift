import Foundation
import XCTest
@testable import QVACClient

/// Adversarial contract tests for the public plugin and advanced duplex adapters.
///
/// These tests use the production bare-rpc framing stack. Only the byte transport is
/// replaced, so request encoding, stream state, terminal draining, and teardown all
/// remain exercised end to end.
final class QVACAdvancedStreamCoverageTests: XCTestCase {
    private struct PluginParameters: Codable, Sendable, Equatable {
        let prompt: String
        let limit: Int
    }

    private struct PluginResult: Codable, Sendable, Equatable {
        let text: String
        let count: Int
    }

    private struct RejectingParameters: Encodable, Sendable {
        enum ExpectedFailure: Error { case encode }

        func encode(to encoder: Encoder) throws {
            throw ExpectedFailure.encode
        }
    }

    /// A canary result type used to prove that resource admission runs before
    /// the plugin's caller-owned `Decodable` initializer.
    private struct DecodeMustNotRun: Decodable, Sendable {
        enum UnexpectedDecode: Error { case reachedDecoder }

        init(from _: Decoder) throws {
            throw UnexpectedDecode.reachedDecoder
        }
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

    /// A bounded peer that acknowledges duplex opens and retains outbound frames for
    /// exact wire assertions. No sleeps occur outside bounded polling helpers below.
    private actor MockTransport: BareTransport {
        nonisolated private let inbound = InboundPipe()
        private var outboundBytes = Data()
        private var closed = false
        private var acknowledgedDuplexIDs: Set<UInt64> = []

        nonisolated func inboundStream() -> AsyncThrowingStream<Data, Error> {
            inbound.stream
        }

        func write(_ data: Data) async throws {
            outboundBytes.append(data)

            let reader = BareRPCFrameReader()
            try reader.append(data)
            while let frame = reader.next() {
                guard case .request(let id, _, let flags, _) = frame,
                      flags.contains(.open),
                      acknowledgedDuplexIDs.insert(id).inserted else { continue }

                var acknowledgements = BareRPCCodec.__testEncodeStreamFrame(
                    id: id,
                    flags: [.request, .open]
                )
                acknowledgements.append(BareRPCCodec.__testEncodeStreamFrame(
                    id: id,
                    flags: [.response, .open]
                ))
                inbound.continuation.yield(acknowledgements)
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
    }

    private static func frames(in data: Data) -> [BareRPCFrame] {
        let reader = BareRPCFrameReader()
        try? reader.append(data)
        var result: [BareRPCFrame] = []
        while let frame = reader.next() { result.append(frame) }
        return result
    }

    private static func waitForFrames(
        _ count: Int,
        on transport: MockTransport,
        timeout: Duration = .seconds(1)
    ) async throws -> [BareRPCFrame] {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            let decoded = frames(in: await transport.outbound())
            if decoded.count >= count { return decoded }
            try await Task.sleep(for: .milliseconds(5))
        }
        let decoded = frames(in: await transport.outbound())
        XCTFail("timed out waiting for \(count) outbound frames; got \(decoded.count)")
        return decoded
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
        let counts = await rpc.__testInFlightCounts()
        XCTFail("advanced stream fixture leaked bare-rpc state: \(counts)")
    }

    private static func request(
        in frames: [BareRPCFrame]
    ) throws -> (id: UInt64, object: [String: Any]) {
        for frame in frames {
            if case .request(let id, _, _, .some(let data)) = frame {
                let object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: data) as? [String: Any]
                )
                return (id, object)
            }
        }
        throw QVACError.protocolViolation("test peer did not observe an inline request")
    }

    private static func duplexRequest(
        in frames: [BareRPCFrame]
    ) throws -> (id: UInt64, object: [String: Any]) {
        for frame in frames {
            if case .stream(let id, let flags, .data(let data)) = frame,
               flags.contains(.request) {
                let object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: data) as? [String: Any]
                )
                return (id, object)
            }
        }
        throw QVACError.protocolViolation("test peer did not observe a duplex request")
    }

    private static func requestData(
        for id: UInt64,
        in frames: [BareRPCFrame]
    ) -> [Data] {
        frames.compactMap { frame in
            guard case .stream(let frameID, let flags, .data(let data)) = frame,
                  frameID == id,
                  flags.contains(.request) else { return nil }
            return data
        }
    }

    private static func feedReply(
        id: UInt64,
        response: QVACResponse,
        to transport: MockTransport
    ) async throws {
        let payload = try JSONEncoder.qvac.encode(response)
        await transport.feed(BareRPCCodec.__testEncodeResponseFrame(
            id: id,
            stream: [],
            payload: .success(payload)
        ))
    }

    private static func feedServerStream(
        id: UInt64,
        records: [String],
        to transport: MockTransport
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
        await transport.feed(inbound)
    }

    private static func feedDuplex(
        id: UInt64,
        records: [String],
        to transport: MockTransport,
        end: Bool = true
    ) async {
        var inbound = Data()
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

    private func assertProtocolViolation(
        _ error: Error,
        containing fragment: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .protocolViolation(let message) = error as? QVACError else {
            return XCTFail("expected protocol violation, got \(error)", file: file, line: line)
        }
        if let fragment {
            XCTAssertTrue(message.contains(fragment), "\(message)", file: file, line: line)
        }
    }

    // MARK: Plugin invocation

    func test_outbound_payload_budget_rejects_exact_and_plugin_requests_before_io() async {
        let transport = MockTransport()
        let client = QVACClient(
            testing: transport,
            maximumWireMessageBytes: 4_096,
            maximumOutboundPayloadBytes: 128
        )

        do {
            _ = try await client.wireUpscaleStream(
                UpscaleStreamRequest(
                    image: String(repeating: "A", count: 256),
                    modelId: "upscaler"
                )
            )
            XCTFail("an oversized exact request must reject before opening a stream")
        } catch let QVACError.invalidArgument(message) {
            XCTAssertTrue(message.contains("maximumOutboundPayloadBytes"), message)
        } catch {
            XCTFail("unexpected exact-request error: \(error)")
        }

        do {
            let _: PluginResult = try await client.invokePlugin(
                modelId: "plugin-model",
                handler: "generate",
                params: PluginParameters(
                    prompt: String(repeating: "x", count: 256),
                    limit: 1
                )
            )
            XCTFail("oversized plugin parameters must reject before JSONValue materialization")
        } catch let QVACError.invalidArgument(message) {
            XCTAssertTrue(message.contains("maximumOutboundPayloadBytes"), message)
        } catch {
            XCTFail("unexpected plugin-parameter error: \(error)")
        }

        let outbound = await transport.outbound()
        XCTAssertTrue(outbound.isEmpty)
        await client.close()
    }

    func test_typed_plugin_invocation_encodes_parameters_and_decodes_result() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let task = Task {
            try await client.invokePlugin(
                modelId: "plugin-model",
                handler: "summarize",
                params: PluginParameters(prompt: "hello", limit: 3),
                as: PluginResult.self
            )
        }

        let (id, request) = try Self.request(
            in: try await Self.waitForFrames(1, on: transport)
        )
        XCTAssertEqual(request["type"] as? String, "pluginInvoke")
        XCTAssertEqual(request["modelId"] as? String, "plugin-model")
        XCTAssertEqual(request["handler"] as? String, "summarize")
        let parameters = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(parameters["prompt"] as? String, "hello")
        XCTAssertEqual(parameters["limit"] as? Int, 3)

        try await Self.feedReply(
            id: id,
            response: .pluginInvoke(.init(result: .object([
                "text": .string("summary"),
                "count": .number(2),
            ]))),
            to: transport
        )
        let result = try await task.value
        XCTAssertEqual(result, PluginResult(text: "summary", count: 2))
        await client.close()
    }

    func test_untyped_plugin_invocation_returns_raw_result() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let expected: JSONValue = .object([
            "items": .array([.string("first"), .number(2)]),
            "metadata": .object(["cached": .bool(true)]),
        ])
        let task = Task { () throws -> JSONValue in
            try await client.invokePlugin(
                modelId: "plugin-model",
                handler: "raw-result",
                params: PluginParameters(prompt: "hello", limit: 2)
            )
        }

        let (id, request) = try Self.request(
            in: try await Self.waitForFrames(1, on: transport)
        )
        XCTAssertEqual(request["type"] as? String, "pluginInvoke")
        XCTAssertEqual(request["handler"] as? String, "raw-result")
        try await Self.feedReply(
            id: id,
            response: .pluginInvoke(.init(result: expected)),
            to: transport
        )

        let result = try await task.value
        XCTAssertEqual(result, expected)
        await client.close()
    }

    func test_plugin_unary_result_budget_accepts_exact_and_rejects_one_byte_over_before_decode_or_publication() async throws {
        let result: JSONValue = .object([
            "text": .string(String(repeating: "x", count: 64)),
            "count": .number(2),
        ])
        let retainedBytes = QVACClient.conservativeBufferedJSONBytes(
            result,
            elementCount: 1,
            fallback: 1
        )
        XCTAssertGreaterThan(retainedBytes, 1)

        do {
            let transport = MockTransport()
            let client = QVACClient(
                testing: transport,
                maximumWireMessageBytes: 4_096,
                maximumAccumulatedResultBytes: retainedBytes
            )
            let task = Task {
                try await client.invokePlugin(
                    modelId: "plugin-model",
                    handler: "exact-result",
                    params: PluginParameters(prompt: "hello", limit: 1),
                    as: PluginResult.self
                )
            }
            let (id, _) = try Self.request(
                in: try await Self.waitForFrames(1, on: transport)
            )
            try await Self.feedReply(
                id: id,
                response: .pluginInvoke(.init(result: result)),
                to: transport
            )
            let decoded = try await task.value
            XCTAssertEqual(
                decoded,
                PluginResult(text: String(repeating: "x", count: 64), count: 2)
            )
            await client.close()
        }

        do {
            let maximumBytes = retainedBytes - 1
            let transport = MockTransport()
            let client = QVACClient(
                testing: transport,
                maximumWireMessageBytes: 4_096,
                maximumAccumulatedResultBytes: maximumBytes
            )
            let task = Task {
                try await client.invokePlugin(
                    modelId: "plugin-model",
                    handler: "oversized-typed-result",
                    params: PluginParameters(prompt: "hello", limit: 1),
                    as: DecodeMustNotRun.self
                )
            }
            let (id, _) = try Self.request(
                in: try await Self.waitForFrames(1, on: transport)
            )
            try await Self.feedReply(
                id: id,
                response: .pluginInvoke(.init(result: result)),
                to: transport
            )
            do {
                _ = try await task.value
                XCTFail("a plugin result one byte over the retained-result budget must fail")
            } catch let QVACError.resourceLimitExceeded(
                operation,
                resource,
                observedMaximum,
                attemptedBytes
            ) {
                XCTAssertEqual(operation, "pluginInvoke")
                XCTAssertEqual(resource, "accumulated result bytes")
                XCTAssertEqual(observedMaximum, maximumBytes)
                XCTAssertEqual(attemptedBytes, retainedBytes)
            } catch {
                XCTFail("plugin result reached caller decoding before admission: \(error)")
            }
            await client.close()
        }

        do {
            let maximumBytes = retainedBytes - 1
            let transport = MockTransport()
            let client = QVACClient(
                testing: transport,
                maximumWireMessageBytes: 4_096,
                maximumAccumulatedResultBytes: maximumBytes
            )
            let task = Task { () throws -> JSONValue in
                try await client.invokePlugin(
                    modelId: "plugin-model",
                    handler: "oversized-untyped-result",
                    params: PluginParameters(prompt: "hello", limit: 1)
                )
            }
            let (id, _) = try Self.request(
                in: try await Self.waitForFrames(1, on: transport)
            )
            try await Self.feedReply(
                id: id,
                response: .pluginInvoke(.init(result: result)),
                to: transport
            )
            do {
                _ = try await task.value
                XCTFail("an oversized raw plugin result must not be published")
            } catch let QVACError.resourceLimitExceeded(
                operation,
                resource,
                observedMaximum,
                attemptedBytes
            ) {
                XCTAssertEqual(operation, "pluginInvoke")
                XCTAssertEqual(resource, "accumulated result bytes")
                XCTAssertEqual(observedMaximum, maximumBytes)
                XCTAssertEqual(attemptedBytes, retainedBytes)
            } catch {
                XCTFail("unexpected raw plugin result error: \(error)")
            }
            await client.close()
        }
    }

    func test_plugin_stream_result_budget_is_per_record_and_oversize_tears_down_before_decode() async throws {
        let result: JSONValue = .object([
            "text": .string(String(repeating: "y", count: 64)),
            "count": .number(3),
        ])
        let retainedBytes = QVACClient.conservativeBufferedJSONBytes(
            result,
            elementCount: 1,
            fallback: 1
        )
        let response = QVACResponse.pluginInvokeStream(.init(result: result))
        let record = String(decoding: try JSONEncoder.qvac.encode(response), as: UTF8.self)

        do {
            let transport = MockTransport()
            let client = QVACClient(
                testing: transport,
                maximumWireMessageBytes: 4_096,
                maximumAccumulatedResultBytes: retainedBytes
            )
            let stream: QVACResponseStream<PluginResult> = try await client.invokePluginStream(
                modelId: "plugin-model",
                handler: "exact-stream-result",
                params: PluginParameters(prompt: "hello", limit: 1)
            )
            let (id, _) = try Self.request(
                in: try await Self.waitForFrames(2, on: transport)
            )
            await Self.feedServerStream(
                id: id,
                records: [record, record],
                to: transport
            )
            var chunks: [PluginResult] = []
            for try await chunk in stream { chunks.append(chunk) }
            XCTAssertEqual(
                chunks,
                Array(
                    repeating: PluginResult(
                        text: String(repeating: "y", count: 64),
                        count: 3
                    ),
                    count: 2
                ),
                "the result ceiling applies independently to each backpressured record"
            )
            await client.close()
        }

        do {
            let maximumBytes = retainedBytes - 1
            let transport = MockTransport()
            let client = QVACClient(
                testing: transport,
                maximumWireMessageBytes: 4_096,
                maximumAccumulatedResultBytes: maximumBytes
            )
            let stream: QVACResponseStream<DecodeMustNotRun> = try await client.invokePluginStream(
                modelId: "plugin-model",
                handler: "oversized-stream-result",
                params: PluginParameters(prompt: "hello", limit: 1),
                rpcOptions: .init(timeout: nil)
            )
            let initialFrames = try await Self.waitForFrames(2, on: transport)
            let (id, _) = try Self.request(in: initialFrames)

            var inbound = BareRPCCodec.__testEncodeResponseFrame(
                id: id,
                stream: [.open],
                payload: .success(nil)
            )
            inbound.append(BareRPCCodec.__testEncodeStreamFrame(
                id: id,
                flags: [.response, .data],
                payload: .data(Data((record + "\n").utf8))
            ))
            await transport.feed(inbound)

            do {
                for try await _ in stream {}
                XCTFail("a streaming plugin result one byte over budget must fail")
            } catch let QVACError.resourceLimitExceeded(
                operation,
                resource,
                observedMaximum,
                attemptedBytes
            ) {
                XCTAssertEqual(operation, "pluginInvokeStream")
                XCTAssertEqual(resource, "accumulated result bytes")
                XCTAssertEqual(observedMaximum, maximumBytes)
                XCTAssertEqual(attemptedBytes, retainedBytes)
            } catch {
                XCTFail("plugin chunk reached caller decoding before admission: \(error)")
            }

            try await Self.waitForNoInFlight(await client.rpc)
            let teardownFrames = try await Self.waitForFrames(3, on: transport)
            let destroys = teardownFrames.filter { frame in
                guard case .stream(let frameID, let flags, .control) = frame else {
                    return false
                }
                return frameID == id && flags.contains(.response) && flags.contains(.destroy)
            }
            XCTAssertEqual(destroys.count, 1)
            await client.close()
        }
    }

    func test_plugin_invocation_propagates_parameter_and_result_codable_failures() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)

        do {
            let _: PluginResult = try await client.invokePlugin(
                modelId: "plugin-model",
                handler: "reject",
                params: RejectingParameters()
            )
            XCTFail("a parameter encoding failure must reject before transport I/O")
        } catch is RejectingParameters.ExpectedFailure {
            // Exact Codable failure is preserved for callers.
        }
        let bytesAfterEncodingFailure = await transport.outbound()
        XCTAssertTrue(bytesAfterEncodingFailure.isEmpty)

        let task = Task {
            try await client.invokePlugin(
                modelId: "plugin-model",
                handler: "bad-result",
                params: PluginParameters(prompt: "hello", limit: 1),
                as: PluginResult.self
            )
        }
        let (id, _) = try Self.request(in: try await Self.waitForFrames(1, on: transport))
        try await Self.feedReply(
            id: id,
            response: .pluginInvoke(.init(result: .object([
                "text": .string("summary"),
                "count": .string("not-an-integer"),
            ]))),
            to: transport
        )
        do {
            _ = try await task.value
            XCTFail("a result that violates the caller's schema must reject")
        } catch is DecodingError {
            // The plugin's caller-owned result schema failed exactly where expected.
        }
        await client.close()
    }

    func test_typed_and_untyped_plugin_invocation_reject_wrong_response_discriminator() async throws {
        do {
            let transport = MockTransport()
            let client = QVACClient(testing: transport)
            let task = Task {
                try await client.invokePlugin(
                    modelId: "plugin-model",
                    handler: "typed",
                    params: PluginParameters(prompt: "hello", limit: 1),
                    as: PluginResult.self
                )
            }
            let (id, _) = try Self.request(in: try await Self.waitForFrames(1, on: transport))
            try await Self.feedReply(
                id: id,
                response: .heartbeat(.init(number: 1)),
                to: transport
            )
            do {
                _ = try await task.value
                XCTFail("typed plugin invocation accepted a heartbeat response")
            } catch {
                assertProtocolViolation(error, containing: "expected pluginInvoke")
            }
            await client.close()
        }

        do {
            let transport = MockTransport()
            let client = QVACClient(testing: transport)
            let task = Task { () throws -> JSONValue in
                try await client.invokePlugin(
                    modelId: "plugin-model",
                    handler: "untyped",
                    params: PluginParameters(prompt: "hello", limit: 1)
                )
            }
            let (id, _) = try Self.request(in: try await Self.waitForFrames(1, on: transport))
            try await Self.feedReply(
                id: id,
                response: .heartbeat(.init(number: 2)),
                to: transport
            )
            do {
                _ = try await task.value
                XCTFail("untyped plugin invocation accepted a heartbeat response")
            } catch {
                assertProtocolViolation(error, containing: "expected pluginInvoke")
            }
            await client.close()
        }
    }

    func test_plugin_stream_drains_profile_then_surfaces_typed_worker_error() async throws {
        let transport = MockTransport()
        let profiling = ProfilingCounter()
        let client = QVACClient(
            testing: transport,
            profilingMetadataHandler: { _ in profiling.increment() }
        )
        let stream: QVACResponseStream<PluginResult> = try await client.invokePluginStream(
            modelId: "missing",
            handler: "stream",
            params: PluginParameters(prompt: "hello", limit: 1),
            rpcOptions: .init(timeout: nil, profiling: .init(enabled: true))
        )
        let (id, _) = try Self.request(in: try await Self.waitForFrames(2, on: transport))
        await Self.feedServerStream(
            id: id,
            records: [
                #"{"type":"error","code":52002,"message":"missing plugin model"}"#,
                #"{"__profilingTrailer":true,"__profiling":{"id":"plugin-error"}}"#,
            ],
            to: transport
        )

        do {
            for try await _ in stream {}
            XCTFail("a plugin worker error must terminate the public stream")
        } catch let QVACError.server(code, message) {
            XCTAssertEqual(code, .modelNotFound)
            XCTAssertEqual(message, "missing plugin model")
        }
        XCTAssertEqual(profiling.value(), 1)
        await client.close()

    }

    func test_plugin_stream_rejects_wrong_discriminator_and_chunk_schema_drift() async throws {
        do {
            let transport = MockTransport()
            let client = QVACClient(testing: transport)
            let stream: QVACResponseStream<PluginResult> = try await client.invokePluginStream(
                modelId: "plugin-model",
                handler: "wrong-type",
                params: PluginParameters(prompt: "hello", limit: 1)
            )
            let (id, _) = try Self.request(in: try await Self.waitForFrames(2, on: transport))
            await Self.feedServerStream(
                id: id,
                records: [#"{"type":"heartbeat","number":7}"#],
                to: transport
            )
            do {
                for try await _ in stream {}
                XCTFail("plugin stream accepted a different operation's frame")
            } catch {
                assertProtocolViolation(error, containing: "pluginInvokeStream")
            }
            await client.close()
        }

        do {
            let transport = MockTransport()
            let client = QVACClient(testing: transport)
            let stream: QVACResponseStream<PluginResult> = try await client.invokePluginStream(
                modelId: "plugin-model",
                handler: "bad-chunk",
                params: PluginParameters(prompt: "hello", limit: 1)
            )
            let (id, _) = try Self.request(in: try await Self.waitForFrames(2, on: transport))
            await Self.feedServerStream(
                id: id,
                records: [
                    #"{"type":"pluginInvokeStream","result":{"text":"ok","count":"bad"}}"#,
                ],
                to: transport
            )
            do {
                for try await _ in stream {}
                XCTFail("plugin stream accepted a chunk outside the requested schema")
            } catch let QVACError.encoding(message) {
                XCTAssertTrue(message.contains("count"), "\(message)")
            }
            await client.close()
        }
    }

    // MARK: Bidirectional transcription

    func test_transcribe_stream_validates_timing_options_before_transport_io() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)

        do {
            _ = try await client.transcribeStream(
                modelId: "speech",
                endOfTurnSilenceMs: -1
            )
            XCTFail("negative end-of-turn silence must reject")
        } catch let QVACError.invalidArgument(message) {
            XCTAssertTrue(message.contains("endOfTurnSilenceMs"))
        }
        do {
            _ = try await client.transcribeStream(
                modelId: "speech",
                vadRunIntervalMs: 0
            )
            XCTFail("a zero VAD interval must reject")
        } catch let QVACError.invalidArgument(message) {
            XCTAssertTrue(message.contains("vadRunIntervalMs"))
        }

        let outbound = await transport.outbound()
        XCTAssertTrue(outbound.isEmpty)
        await client.close()
    }

    func test_transcribe_stream_accepts_whisper_end_of_turn_and_rejects_invalid_duration() async throws {
        do {
            let transport = MockTransport()
            let client = QVACClient(testing: transport)
            let session = try await client.transcribeStream(
                modelId: "whisper",
                rpcOptions: .init(timeout: nil)
            )
            let (id, _) = try Self.duplexRequest(
                in: try await Self.waitForFrames(3, on: transport)
            )
            await Self.feedDuplex(
                id: id,
                records: [
                    #"{"type":"transcribeStream","done":true,"endOfTurn":{"source":"whisper","silenceDurationMs":375.5}}"#,
                ],
                to: transport
            )

            var events: [QVACClient.TranscribeStreamEvent] = []
            for try await event in session.events { events.append(event) }
            XCTAssertEqual(events, [
                .endOfTurn(.object([
                    "source": .string("whisper"),
                    "silenceDurationMs": .number(375.5),
                ])),
                .done,
            ])
            await client.close()
        }

        let malformedRecords = [
            #"{"type":"transcribeStream","done":true,"endOfTurn":{"source":"whisper"}}"#,
            #"{"type":"transcribeStream","done":true,"endOfTurn":{"source":"whisper","silenceDurationMs":"375"}}"#,
        ]
        for record in malformedRecords {
            let transport = MockTransport()
            let client = QVACClient(testing: transport)
            let session = try await client.transcribeStream(
                modelId: "whisper",
                rpcOptions: .init(timeout: nil)
            )
            let (id, _) = try Self.duplexRequest(
                in: try await Self.waitForFrames(3, on: transport)
            )
            await Self.feedDuplex(id: id, records: [record], to: transport)

            do {
                for try await _ in session.events {}
                XCTFail("invalid Whisper silenceDurationMs must reject")
            } catch {
                assertProtocolViolation(error, containing: "silenceDurationMs")
            }
            await client.close()
        }
    }

    func test_transcribe_stream_writes_audio_and_fans_out_complete_terminal_payload() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let session = try await client.transcribeStream(
            modelId: "speech",
            prompt: "domain words",
            rpcOptions: .init(timeout: nil)
        )
        var frames = try await Self.waitForFrames(3, on: transport)
        let (id, request) = try Self.duplexRequest(in: frames)
        XCTAssertEqual(request["requestId"] as? String, session.requestId)
        XCTAssertEqual(request["prompt"] as? String, "domain words")
        XCTAssertNil(request["metadata"])
        XCTAssertNil(request["emitVadEvents"])

        let audio = Data([0x00, 0x7F, 0x80, 0xFF])
        try await session.write(audio)
        try await session.end()
        frames = try await Self.waitForFrames(5, on: transport)
        XCTAssertEqual(Self.requestData(for: id, in: frames).last, audio)
        XCTAssertTrue(frames.contains { frame in
            guard case .stream(let frameID, let flags, .control) = frame else { return false }
            return frameID == id && flags.contains(.request) && flags.contains(.end)
        })

        await Self.feedDuplex(
            id: id,
            records: [
                #"{"type":"transcribeStream","segment":{"id":7,"text":"first","startMs":0,"endMs":120,"append":true}}"#,
                #"{"type":"transcribeStream","text":""}"#,
                #"{"type":"transcribeStream","done":true,"segment":{"id":8,"text":"tail segment","startMs":120,"endMs":240,"append":false},"text":"tail text","vad":{"speaking":false,"probability":0.1},"endOfTurn":{"source":"parakeet"}}"#,
            ],
            to: transport
        )
        var events: [QVACClient.TranscribeStreamEvent] = []
        for try await event in session.events { events.append(event) }
        XCTAssertEqual(events.count, 6)

        guard case .segment(let first) = events[0] else {
            return XCTFail("expected the nonterminal segment first")
        }
        XCTAssertEqual(first.id, 7)
        XCTAssertEqual(first.text, "first")
        XCTAssertEqual(first.startMs, 0)
        XCTAssertEqual(first.endMs, 120)
        XCTAssertTrue(first.append)

        guard case .segment(let terminalSegment) = events[1] else {
            return XCTFail("expected the terminal segment second")
        }
        XCTAssertEqual(terminalSegment.id, 8)
        XCTAssertEqual(terminalSegment.text, "tail segment")
        XCTAssertFalse(terminalSegment.append)
        XCTAssertEqual(events[2], .text("tail text"))
        XCTAssertEqual(events[3], .vad(.object([
            "speaking": .bool(false),
            "probability": .number(0.1),
        ])))
        XCTAssertEqual(events[4], .endOfTurn(.object(["source": .string("parakeet")])))
        XCTAssertEqual(events[5], .done)
        await client.close()
    }

    func test_transcribe_stream_drains_profile_then_surfaces_worker_error() async throws {
        let transport = MockTransport()
        let profiling = ProfilingCounter()
        let client = QVACClient(
            testing: transport,
            profilingMetadataHandler: { _ in profiling.increment() }
        )
        let session = try await client.transcribeStream(
            modelId: "speech",
            rpcOptions: .init(timeout: nil, profiling: .init(enabled: true))
        )
        let (id, _) = try Self.duplexRequest(
            in: try await Self.waitForFrames(3, on: transport)
        )
        await Self.feedDuplex(
            id: id,
            records: [
                #"{"type":"transcribeStream","error":"decoder failed"}"#,
                #"{"__profilingTrailer":true,"__profiling":{"id":"transcribe-error"}}"#,
            ],
            to: transport
        )

        do {
            for try await _ in session.events {}
            XCTFail("transcription failure must terminate the event stream")
        } catch let QVACError.server(code, message) {
            XCTAssertEqual(code, .transcriptionFailed)
            XCTAssertEqual(message, "decoder failed")
        }
        XCTAssertEqual(profiling.value(), 1)
        await client.close()

        for (record, expectedField) in [
            (#"{"type":"transcribeStream","done":true,"vad":{"speaking":true}}"#, "probability"),
            (#"{"type":"transcribeStream","done":true,"endOfTurn":{"source":"silence"}}"#, "source"),
        ] {
            let invalidTransport = MockTransport()
            let invalidClient = QVACClient(testing: invalidTransport)
            let invalidSession = try await invalidClient.transcribeStream(
                modelId: "speech",
                rpcOptions: .init(timeout: nil)
            )
            let (invalidID, _) = try Self.duplexRequest(
                in: try await Self.waitForFrames(3, on: invalidTransport)
            )
            await Self.feedDuplex(
                id: invalidID,
                records: [record],
                to: invalidTransport
            )
            do {
                for try await _ in invalidSession.events {}
                XCTFail("a malformed transcribe event must reject")
            } catch {
                assertProtocolViolation(error, containing: expectedField)
            }
            await invalidClient.close()
        }
    }

    func test_transcribe_stream_malformed_terminal_segment_rejects_after_profile_drain() async throws {
        let transport = MockTransport()
        let profiling = ProfilingCounter()
        let client = QVACClient(
            testing: transport,
            profilingMetadataHandler: { _ in profiling.increment() }
        )
        let session = try await client.transcribeStream(
            modelId: "speech",
            metadata: true,
            rpcOptions: .init(timeout: nil, profiling: .init(enabled: true))
        )
        let (id, _) = try Self.duplexRequest(
            in: try await Self.waitForFrames(3, on: transport)
        )
        await Self.feedDuplex(
            id: id,
            records: [
                #"{"type":"transcribeStream","done":true,"segment":{"id":9,"text":"missing append","startMs":0,"endMs":1}}"#,
                #"{"__profilingTrailer":true,"__profiling":{"id":"transcribe-malformed"}}"#,
            ],
            to: transport
        )

        do {
            for try await _ in session.events {}
            XCTFail("a malformed terminal segment must reject")
        } catch {
            assertProtocolViolation(error, containing: "segment")
        }
        XCTAssertEqual(profiling.value(), 1)
        await client.close()
    }

    func test_transcribe_stream_rejects_eof_without_done_and_second_event_sequence() async throws {
        do {
            let transport = MockTransport()
            let client = QVACClient(testing: transport)
            let session = try await client.transcribeStream(
                modelId: "speech",
                rpcOptions: .init(timeout: nil)
            )
            let (id, _) = try Self.duplexRequest(
                in: try await Self.waitForFrames(3, on: transport)
            )
            await Self.feedDuplex(
                id: id,
                records: [#"{"type":"transcribeStream","text":"partial"}"#],
                to: transport
            )
            do {
                for try await _ in session.events {}
                XCTFail("duplex EOF without done must reject")
            } catch let QVACError.client(code, message) {
                XCTAssertEqual(code, .streamEndedWithoutResponse)
                XCTAssertTrue(message?.contains("transcribeStream") == true)
            }
            await client.close()
        }

        do {
            let transport = MockTransport()
            let client = QVACClient(testing: transport)
            let session = try await client.transcribeStream(
                modelId: "speech",
                rpcOptions: .init(timeout: nil)
            )
            _ = try await Self.waitForFrames(3, on: transport)
            let first = session.events
            let second = session.events
            var iterator = second.makeAsyncIterator()
            do {
                _ = try await iterator.next()
                XCTFail("a second transcribe event sequence must reject")
            } catch {
                assertProtocolViolation(error, containing: "only be iterated once")
            }
            first.cancel()
            await client.close()
        }
    }

    func test_transcribe_stream_destroy_closes_both_duplex_directions_without_leak() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let session = try await client.transcribeStream(
            modelId: "speech",
            rpcOptions: .init(timeout: nil)
        )
        let (id, _) = try Self.duplexRequest(
            in: try await Self.waitForFrames(3, on: transport)
        )
        session.destroy()

        try await Self.waitForNoInFlight(await client.rpc)
        let frames = try await Self.waitForFrames(5, on: transport)
        XCTAssertTrue(frames.contains { frame in
            guard case .stream(let frameID, let flags, .control) = frame else { return false }
            return frameID == id && flags.contains(.request) && flags.contains(.close)
        })
        XCTAssertTrue(frames.contains { frame in
            guard case .stream(let frameID, let flags, .control) = frame else { return false }
            return frameID == id && flags.contains(.response) && flags.contains(.destroy)
        })
        await client.close()
    }

    // MARK: Completion orchestration

    func test_completion_orchestration_validates_tool_turn_bounds_before_transport_io() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)

        for invalid in [0, 33] {
            do {
                _ = try await client.completionOrchestrate(
                    CompletionOrchestrateRequest(
                        history: [],
                        modelId: "llm",
                        stream: true,
                        maxToolTurns: invalid,
                        tools: []
                    )
                )
                XCTFail("maxToolTurns=\(invalid) must reject")
            } catch let QVACError.invalidArgument(message) {
                XCTAssertTrue(message.contains("1...32"))
            }
        }
        let outbound = await transport.outbound()
        XCTAssertTrue(outbound.isEmpty)
        await client.close()
    }

    func test_completion_orchestration_preserves_id_and_fans_out_terminal_payload() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let session = try await client.completionOrchestrate(
            CompletionOrchestrateRequest(
                history: [.object(["role": .string("user"), "content": .string("weather")])],
                modelId: "llm",
                stream: true,
                maxToolTurns: 32,
                requestId: "caller-owned-id",
                tools: [.object(["name": .string("forecast")])]
            ),
            rpcOptions: .init(timeout: nil)
        )
        let (id, request) = try Self.duplexRequest(
            in: try await Self.waitForFrames(3, on: transport)
        )
        XCTAssertEqual(session.requestId, "caller-owned-id")
        XCTAssertEqual(request["requestId"] as? String, "caller-owned-id")
        XCTAssertEqual(request["maxToolTurns"] as? Int, 32)

        try await session.end()
        await Self.feedDuplex(
            id: id,
            records: [
                #"{"type":"completionOrchestrate","done":true,"events":[{"type":"contentDelta","text":"sunny"}],"toolCallback":{"callId":"call-terminal","name":"forecast","arguments":{"city":"Delhi"}},"stopReason":"maxToolTurns"}"#,
            ],
            to: transport
        )
        var events: [QVACClient.CompletionOrchestrationEvent] = []
        for try await event in session.events { events.append(event) }
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events[0], .turnEvents(
            turn: 0,
            events: [.object(["type": .string("contentDelta"), "text": .string("sunny")])]
        ))
        guard case .toolCallback(let callback) = events[1] else {
            return XCTFail("expected terminal tool callback")
        }
        XCTAssertEqual(callback.callId, "call-terminal")
        XCTAssertEqual(callback.name, "forecast")
        XCTAssertEqual(callback.arguments, ["city": .string("Delhi")])
        XCTAssertEqual(events[2], .done(stopReason: "maxToolTurns"))
        await client.close()
    }

    func test_completion_tool_results_validate_and_encode_null_and_error_ndjson() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let session = try await client.completionOrchestrate(
            modelId: "llm",
            history: [.user("weather")],
            tools: [],
            rpcOptions: .init(timeout: nil)
        )
        let initialFrames = try await Self.waitForFrames(3, on: transport)
        let (id, _) = try Self.duplexRequest(in: initialFrames)

        do {
            try await session.sendToolResult(callId: "")
            XCTFail("empty callback ids must reject")
        } catch let QVACError.invalidArgument(message) {
            XCTAssertTrue(message.contains("callId"))
        }
        do {
            try await session.sendToolResult(
                callId: "ambiguous",
                result: .string("value"),
                error: "failure"
            )
            XCTFail("simultaneous result and error must reject")
        } catch let QVACError.invalidArgument(message) {
            XCTAssertTrue(message.contains("mutually exclusive"))
        }
        let framesAfterValidation = Self.frames(in: await transport.outbound())
        XCTAssertEqual(framesAfterValidation.count, initialFrames.count)

        try await session.sendToolResult(callId: "null-result")
        try await session.sendToolResult(callId: "error-result", error: "tool failed")
        let writtenFrames = try await Self.waitForFrames(5, on: transport)
        let lines = Self.requestData(for: id, in: writtenFrames).dropFirst()
        XCTAssertEqual(lines.count, 2)

        let nullObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: lines[lines.startIndex]) as? [String: Any]
        )
        XCTAssertEqual(nullObject["callId"] as? String, "null-result")
        XCTAssertTrue(nullObject["result"] is NSNull)
        XCTAssertNil(nullObject["error"])

        let errorObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: lines[lines.index(after: lines.startIndex)])
                as? [String: Any]
        )
        XCTAssertEqual(errorObject["callId"] as? String, "error-result")
        XCTAssertEqual(errorObject["error"] as? String, "tool failed")
        XCTAssertNil(errorObject["result"])

        session.destroy()
        try await Self.waitForNoInFlight(await client.rpc)
        let teardownFrames = try await Self.waitForFrames(7, on: transport)
        XCTAssertTrue(teardownFrames.contains { frame in
            guard case .stream(let frameID, let flags, .control) = frame else { return false }
            return frameID == id && flags.contains(.request) && flags.contains(.close)
        })
        XCTAssertTrue(teardownFrames.contains { frame in
            guard case .stream(let frameID, let flags, .control) = frame else { return false }
            return frameID == id && flags.contains(.response) && flags.contains(.destroy)
        })
        await client.close()
    }

    func test_completion_tool_result_obeys_outbound_budget_without_poisoning_session() async throws {
        let transport = MockTransport()
        let client = QVACClient(
            testing: transport,
            maximumWireMessageBytes: 4_096,
            maximumOutboundPayloadBytes: 512
        )
        let session = try await client.completionOrchestrate(
            modelId: "llm",
            history: [],
            tools: [],
            rpcOptions: .init(timeout: nil)
        )
        let initialFrames = try await Self.waitForFrames(3, on: transport)

        do {
            try await session.sendToolResult(
                callId: "oversized",
                result: .string(String(repeating: "x", count: 600))
            )
            XCTFail("an oversized tool result must reject locally")
        } catch let QVACError.invalidArgument(message) {
            XCTAssertTrue(message.contains("maximumOutboundPayloadBytes"), message)
        }
        let framesAfterRejection = Self.frames(in: await transport.outbound())
        XCTAssertEqual(framesAfterRejection.count, initialFrames.count)

        try await session.sendToolResult(callId: "small", result: .string("ok"))
        let framesAfterValidResult = try await Self.waitForFrames(4, on: transport)
        XCTAssertEqual(framesAfterValidResult.count, 4)

        session.destroy()
        try await Self.waitForNoInFlight(await client.rpc)
        await client.close()
    }

    func test_completion_orchestration_rejects_malformed_callbacks_in_live_and_terminal_frames() async throws {
        do {
            let transport = MockTransport()
            let client = QVACClient(testing: transport)
            let session = try await client.completionOrchestrate(
                modelId: "llm",
                history: [],
                tools: [],
                rpcOptions: .init(timeout: nil)
            )
            let (id, _) = try Self.duplexRequest(
                in: try await Self.waitForFrames(3, on: transport)
            )
            await Self.feedDuplex(
                id: id,
                records: [
                    #"{"type":"completionOrchestrate","toolCallback":{"callId":"call","name":"tool"}}"#,
                ],
                to: transport
            )
            do {
                for try await _ in session.events {}
                XCTFail("a malformed live callback must reject")
            } catch {
                assertProtocolViolation(error, containing: "malformed toolCallback")
            }
            await client.close()
        }

        do {
            let transport = MockTransport()
            let profiling = ProfilingCounter()
            let client = QVACClient(
                testing: transport,
                profilingMetadataHandler: { _ in profiling.increment() }
            )
            let session = try await client.completionOrchestrate(
                modelId: "llm",
                history: [],
                tools: [],
                rpcOptions: .init(timeout: nil, profiling: .init(enabled: true))
            )
            let (id, _) = try Self.duplexRequest(
                in: try await Self.waitForFrames(3, on: transport)
            )
            await Self.feedDuplex(
                id: id,
                records: [
                    #"{"type":"completionOrchestrate","done":true,"toolCallback":"not-an-object"}"#,
                    #"{"__profilingTrailer":true,"__profiling":{"id":"orchestration-malformed"}}"#,
                ],
                to: transport
            )
            do {
                for try await _ in session.events {}
                XCTFail("a malformed terminal callback must reject")
            } catch {
                assertProtocolViolation(error, containing: "malformed toolCallback")
            }
            XCTAssertEqual(profiling.value(), 1)
            await client.close()
        }
    }

    func test_completion_orchestration_drains_profile_then_surfaces_worker_error() async throws {
        let transport = MockTransport()
        let profiling = ProfilingCounter()
        let client = QVACClient(
            testing: transport,
            profilingMetadataHandler: { _ in profiling.increment() }
        )
        let session = try await client.completionOrchestrate(
            modelId: "missing",
            history: [],
            tools: [],
            rpcOptions: .init(timeout: nil, profiling: .init(enabled: true))
        )
        let (id, _) = try Self.duplexRequest(
            in: try await Self.waitForFrames(3, on: transport)
        )
        await Self.feedDuplex(
            id: id,
            records: [
                #"{"type":"error","code":52002,"message":"missing orchestrator model"}"#,
                #"{"__profilingTrailer":true,"__profiling":{"id":"orchestration-error"}}"#,
            ],
            to: transport
        )

        do {
            for try await _ in session.events {}
            XCTFail("an orchestration worker error must terminate the stream")
        } catch let QVACError.server(code, message) {
            XCTAssertEqual(code, .modelNotFound)
            XCTAssertEqual(message, "missing orchestrator model")
        }
        XCTAssertEqual(profiling.value(), 1)
        await client.close()
    }
}
