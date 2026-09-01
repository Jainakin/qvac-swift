import XCTest
@testable import QVACClient

/// Protocol-level tests for the public operations added with the published 0.17.0
/// contract. These run through the real typed client and bare-rpc multiplexer; only
/// the byte transport is replaced with an in-memory peer.
final class QVACSDK017OperationSemanticsTests: XCTestCase {
    private final class BufferedPayloadProbe: @unchecked Sendable {}

    private final class BufferedIteratorHolder<Element: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var iterator: QVACBufferedStream<Element>.AsyncIterator?

        init(_ stream: QVACBufferedStream<Element>) {
            iterator = stream.makeAsyncIterator()
        }

        func next() async throws -> Element? {
            let claimed: QVACBufferedStream<Element>.AsyncIterator? = lock.withLock {
                defer { iterator = nil }
                return iterator
            }
            guard var current = claimed else {
                throw QVACError.protocolViolation("buffered iterator holder is empty")
            }
            do {
                let value = try await current.next()
                lock.withLock { iterator = current }
                return value
            } catch {
                lock.withLock { iterator = current }
                throw error
            }
        }

        func drop() {
            lock.withLock { iterator = nil }
        }
    }

    private actor AsyncGate {
        private var isOpen = false
        private var waiter: CheckedContinuation<Void, Never>?

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiter = $0 }
        }

        func open() {
            guard !isOpen else { return }
            isOpen = true
            let pending = waiter
            waiter = nil
            pending?.resume()
        }
    }

    private struct RejectingEncodableProbe: Encodable {
        private enum ExpectedFailure: Error { case encode }

        func encode(to encoder: Encoder) throws {
            throw ExpectedFailure.encode
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
            var captured: AsyncThrowingStream<Data, Error>.Continuation!
            stream = AsyncThrowingStream { captured = $0 }
            continuation = captured
        }
    }

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
        func isClosed() -> Bool { closed }
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
        XCTFail("timed out waiting for \(count) outbound bare-rpc frames; got \(decoded.count)")
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
        XCTFail("wrapper cancellation leaked bare-rpc state: \(counts)")
    }

    private static func request(in frames: [BareRPCFrame]) throws -> (UInt64, [String: Any]) {
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
    ) throws -> (UInt64, [String: Any]) {
        for frame in frames {
            if case .stream(let id, let flags, .data(let data)) = frame,
               flags.contains(.request) {
                let object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: data) as? [String: Any]
                )
                return (id, object)
            }
        }
        throw QVACError.protocolViolation("test peer did not observe a duplex request payload")
    }

    private static func feedServerStream(
        id: UInt64,
        records: [String],
        to transport: MockTransport,
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
            inbound.append(BareRPCCodec.__testEncodeStreamFrame(id: id, flags: [.response, .end]))
        }
        await transport.feed(inbound)
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

    private static func feedDuplex(
        id: UInt64,
        records: [String],
        to transport: MockTransport,
        open: Bool,
        end: Bool
    ) async {
        var inbound = Data()
        if open {
            inbound.append(BareRPCCodec.__testEncodeStreamFrame(id: id, flags: [.request, .open]))
            inbound.append(BareRPCCodec.__testEncodeStreamFrame(id: id, flags: [.response, .open]))
        }
        for record in records {
            inbound.append(BareRPCCodec.__testEncodeStreamFrame(
                id: id,
                flags: [.response, .data],
                payload: .data(Data((record + "\n").utf8))
            ))
        }
        if end {
            inbound.append(BareRPCCodec.__testEncodeStreamFrame(id: id, flags: [.response, .end]))
        }
        await transport.feed(inbound)
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

    private func assertProtocolViolation(
        _ error: Error,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .protocolViolation = error as? QVACError else {
            return XCTFail("expected protocol violation, got \(error)", file: file, line: line)
        }
    }

    private func assertRejectsTinyTimeout(
        _ operation: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("\(operation) unexpectedly accepted an invalid timeout", file: file, line: line)
        } catch let QVACError.invalidArgument(message) {
            XCTAssertTrue(message.contains("at least 100 milliseconds"), file: file, line: line)
        } catch {
            XCTFail("\(operation) reached the transport instead of local validation: \(error)", file: file, line: line)
        }
    }

    func test_cancel_uses_exact_native_request_and_broad_shapes() throws {
        let targeted = QVACClient.makeCancelRequest(
            .request(requestId: "request-17", clearCache: true)
        )
        XCTAssertEqual(targeted.operation, "request")
        XCTAssertEqual(targeted.requestId, "request-17")
        XCTAssertEqual(targeted.clearCache, true)
        XCTAssertNil(targeted.modelId)
        XCTAssertNil(targeted.kind)

        let broad = QVACClient.makeCancelRequest(.broad(modelId: "model-17", kind: "video"))
        XCTAssertEqual(broad.operation, "broad")
        XCTAssertEqual(broad.modelId, "model-17")
        XCTAssertEqual(broad.kind, "video")
        XCTAssertNil(broad.requestId)
        XCTAssertNil(broad.clearCache)

        let targetedWire = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder.qvac.encode(QVACRequest.cancel(targeted))
        ) as? [String: Any])
        XCTAssertEqual(Set(targetedWire.keys), ["type", "operation", "requestId", "clearCache"])

        let broadWire = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder.qvac.encode(QVACRequest.cancel(broad))
        ) as? [String: Any])
        XCTAssertEqual(Set(broadWire.keys), ["type", "operation", "modelId", "kind"])
    }

    func test_completion_request_id_terminal_frame_and_token_fanout() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let run = try await client.completion(
            modelId: "llm",
            history: [.user(
                "hello",
                attachments: [.init(path: "/models/image.png")]
            )],
            tools: [.object(["name": .string("forecast")])],
            captureThinking: true,
            emitRawDeltas: true,
            toolDialect: .dsml
        )
        let frames = try await Self.waitForFrames(2, on: transport)
        let (id, request) = try Self.request(in: frames)
        XCTAssertFalse(run.requestId.isEmpty)
        XCTAssertEqual(request["requestId"] as? String, run.requestId)
        XCTAssertEqual(request["captureThinking"] as? Bool, true)
        XCTAssertEqual(request["emitRawDeltas"] as? Bool, true)
        XCTAssertEqual(request["toolDialect"] as? String, "dsml")
        let history = try XCTUnwrap(request["history"] as? [[String: Any]])
        let attachments = try XCTUnwrap(history.first?["attachments"] as? [[String: Any]])
        XCTAssertEqual(attachments.first?["path"] as? String, "/models/image.png")

        await Self.feedServerStream(
            id: id,
            records: [
                #"{"type":"completionStream","events":[{"type":"contentDelta","seq":0,"text":"hi"},{"type":"thinkingDelta","seq":1,"text":"reason"},{"type":"rawDelta","seq":2,"text":"<think>reason</think>hi"},{"type":"toolCall","seq":3,"call":{"id":"call-1","name":"forecast","arguments":{"city":"Delhi"},"raw":"<｜DSML｜invoke>"}},{"type":"completionStats","seq":4,"stats":{"generatedTokens":7,"emittedTokens":5,"backendDevice":"gpu"}}]}"#,
                #"{"type":"completionStream","events":[{"type":"completionDone","seq":5,"stopReason":"eos","raw":{"fullText":"<think>reason</think> hi"}}],"done":true}"#,
            ],
            to: transport
        )
        let final = try await run.final.value
        var tokens: [String] = []
        for try await token in run.tokenStream { tokens.append(token) }
        XCTAssertEqual(tokens, ["hi"])
        var calls: [QVACClient.CompletionToolCall] = []
        for try await call in run.toolCallStream { calls.append(call) }
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "forecast")
        XCTAssertEqual(calls.first?.arguments["city"], .string("Delhi"))
        XCTAssertEqual(final.contentText, "hi")
        XCTAssertEqual(final.thinkingText, "reason")
        XCTAssertEqual(final.toolCalls, calls)
        XCTAssertEqual(final.stats?.generatedTokens, 7)
        XCTAssertEqual(final.stats?.emittedTokens, 5)
        XCTAssertEqual(final.stats?.backendDevice, .gpu)
        XCTAssertEqual(final.stopReason, .eos)
        XCTAssertEqual(final.raw.fullText, "<think>reason</think> hi")
        XCTAssertNil(final.cacheableAssistantContent)
        let text = try await run.text.value
        let finalToolCalls = try await run.toolCalls.value
        let finalStats = try await run.stats.value
        XCTAssertEqual(text, "hi")
        XCTAssertEqual(finalToolCalls, calls)
        XCTAssertEqual(finalStats?.emittedTokens, 5)
        await client.close()
    }

    func test_completion_single_terminal_frame_preserves_more_than_64_events() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let run = try await client.completion(
            modelId: "llm",
            history: [.user("return a long response")],
            stream: false
        )
        let frames = try await Self.waitForFrames(2, on: transport)
        let (id, _) = try Self.request(in: frames)

        let fragments = (0..<192).map { "\($0)|" }
        var wireEvents = fragments.enumerated().map { index, text in
            JSONValue.object([
                "type": .string("contentDelta"),
                "seq": .number(Double(index)),
                "text": .string(text),
            ])
        }
        let expectedText = fragments.joined()
        wireEvents.append(.object([
            "type": .string("completionDone"),
            "seq": .number(192),
            "stopReason": .string("eos"),
            "raw": .object(["fullText": .string(expectedText)]),
        ]))
        let encoded = try JSONEncoder.qvac.encode(QVACResponse.completionStream(.init(
            events: wireEvents,
            done: true
        )))
        await Self.feedServerStream(
            id: id,
            records: [String(decoding: encoded, as: UTF8.self)],
            to: transport
        )

        let final = try await run.final.value
        XCTAssertEqual(final.contentText, expectedText)
        XCTAssertEqual(final.stopReason, .eos)

        var events: [QVACClient.CompletionEvent] = []
        for try await event in run.events { events.append(event) }
        XCTAssertEqual(events.count, 193)
        for (index, event) in events.dropLast().enumerated() {
            guard case .contentDelta(let sequence, let text) = event else {
                return XCTFail("event \(index) is not a content delta")
            }
            XCTAssertEqual(sequence, index)
            XCTAssertEqual(text, fragments[index])
        }
        guard let lastEvent = events.last,
              case .done(let sequence, let reason, _) = lastEvent else {
            return XCTFail("the terminal completion event is missing")
        }
        XCTAssertEqual(sequence, 192)
        XCTAssertEqual(reason, .eos)

        var tokens: [String] = []
        for try await token in run.tokenStream { tokens.append(token) }
        XCTAssertTrue(tokens.isEmpty, "stream:false must keep the token fan-out empty")
        var toolCalls: [QVACClient.CompletionToolCall] = []
        for try await call in run.toolCallStream { toolCalls.append(call) }
        XCTAssertTrue(toolCalls.isEmpty, "stream:false must keep the tool fan-out empty")
        await client.close()
    }

    func test_completion_single_frame_preserves_large_token_and_tool_fanouts() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let run = try await client.completion(
            modelId: "llm",
            history: [.user("stream tokens and tools")],
            stream: true
        )
        let frames = try await Self.waitForFrames(2, on: transport)
        let (id, _) = try Self.request(in: frames)

        let fragments = (0..<96).map { "t\($0)" }
        var sequence = 0
        var wireEvents: [JSONValue] = fragments.map { text in
            defer { sequence += 1 }
            return .object([
                "type": .string("contentDelta"),
                "seq": .number(Double(sequence)),
                "text": .string(text),
            ])
        }
        let expectedCallIDs = (0..<80).map { "call-\($0)" }
        wireEvents.append(contentsOf: expectedCallIDs.map { callID in
            defer { sequence += 1 }
            return .object([
                "type": .string("toolCall"),
                "seq": .number(Double(sequence)),
                "call": .object([
                    "id": .string(callID),
                    "name": .string("record"),
                    "arguments": .object(["id": .string(callID)]),
                ]),
            ])
        })
        wireEvents.append(.object([
            "type": .string("completionDone"),
            "seq": .number(Double(sequence)),
            "stopReason": .string("eos"),
            "raw": .object(["fullText": .string(fragments.joined())]),
        ]))
        let encoded = try JSONEncoder.qvac.encode(QVACResponse.completionStream(.init(
            events: wireEvents,
            done: true
        )))
        await Self.feedServerStream(
            id: id,
            records: [String(decoding: encoded, as: UTF8.self)],
            to: transport
        )

        let final = try await run.final.value
        XCTAssertEqual(final.contentText, fragments.joined())
        XCTAssertEqual(final.toolCalls.map(\.id), expectedCallIDs)

        var events: [QVACClient.CompletionEvent] = []
        for try await event in run.events { events.append(event) }
        XCTAssertEqual(events.count, fragments.count + expectedCallIDs.count + 1)
        var tokens: [String] = []
        for try await token in run.tokenStream { tokens.append(token) }
        XCTAssertEqual(tokens, fragments)
        var calls: [QVACClient.CompletionToolCall] = []
        for try await call in run.toolCallStream { calls.append(call) }
        XCTAssertEqual(calls.map(\.id), expectedCallIDs)
        await client.close()
    }

    func test_completion_cancellation_preserves_request_id_and_partial_aggregate() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let run = try await client.completion(
            modelId: "llm",
            history: [.user("continue until cancelled")]
        )
        let frames = try await Self.waitForFrames(2, on: transport)
        let (id, _) = try Self.request(in: frames)

        await Self.feedServerStream(
            id: id,
            records: [
                #"{"type":"completionStream","events":[{"type":"contentDelta","seq":0,"text":"partial"},{"type":"toolCall","seq":1,"call":{"id":"call-1","name":"save","arguments":{"value":"draft"}}},{"type":"completionStats","seq":2,"stats":{"generatedTokens":2}}]}"#,
                #"{"type":"completionStream","events":[{"type":"completionDone","seq":3,"stopReason":"cancelled","raw":{"fullText":"partial"}}],"done":true}"#,
            ],
            to: transport
        )

        do {
            _ = try await run.final.value
            XCTFail("a cancelled completion aggregate must reject")
        } catch let QVACError.inferenceCancelled(requestId, partial) {
            XCTAssertEqual(requestId, run.requestId)
            XCTAssertEqual(partial.text, "partial")
            XCTAssertEqual(partial.toolCalls?.count, 1)
            XCTAssertEqual(partial.toolCalls?.first?.name, "save")
            XCTAssertEqual(partial.stats?.generatedTokens, 2)
        } catch {
            XCTFail("expected rich inference cancellation, got \(error)")
        }

        do {
            _ = try await run.text.value
            XCTFail("completion convenience aggregates must share the cancellation error")
        } catch let QVACError.inferenceCancelled(requestId, partial) {
            XCTAssertEqual(requestId, run.requestId)
            XCTAssertEqual(partial.text, "partial")
        } catch {
            XCTFail("expected rich inference cancellation, got \(error)")
        }

        var events: [QVACClient.CompletionEvent] = []
        for try await event in run.events { events.append(event) }
        XCTAssertTrue(events.contains { event in
            guard case .done(_, let reason, _) = event else { return false }
            return reason == .cancelled
        })
        await client.close()
    }

    func test_completion_text_response_format_allows_tools_but_structured_format_does_not() async throws {
        let allowedTransport = MockTransport()
        let allowedClient = QVACClient(testing: allowedTransport)
        let run = try await allowedClient.completion(
            modelId: "llm",
            history: [.user("call a tool")],
            tools: [.object(["type": .string("function"), "name": .string("save")])],
            responseFormat: .object(["type": .string("text")])
        )
        let frames = try await Self.waitForFrames(2, on: allowedTransport)
        let (_, request) = try Self.request(in: frames)
        XCTAssertEqual(
            request["responseFormat"] as? [String: String],
            ["type": "text"]
        )
        XCTAssertEqual((request["tools"] as? [[String: Any]])?.count, 1)
        run.final.cancel()
        _ = try? await run.final.value
        await allowedClient.close()

        let rejectedTransport = MockTransport()
        let rejectedClient = QVACClient(testing: rejectedTransport)
        do {
            _ = try await rejectedClient.completion(
                modelId: "llm",
                history: [.user("return json")],
                tools: [.object(["type": .string("function"), "name": .string("save")])],
                responseFormat: .object(["type": .string("json_object")])
            )
            XCTFail("structured response formats must reject tool-constrained output")
        } catch let QVACError.invalidArgument(message) {
            XCTAssertTrue(message.contains("structured responseFormat"))
        } catch {
            XCTFail("expected invalidArgument, got \(error)")
        }
        let rejectedFrames = Self.frames(in: await rejectedTransport.outbound())
        XCTAssertTrue(rejectedFrames.isEmpty)
        await rejectedClient.close()
    }

    func test_completion_rejects_end_without_done() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let run = try await client.completion(modelId: "llm", history: [.user("hello")])
        let frames = try await Self.waitForFrames(2, on: transport)
        let (id, _) = try Self.request(in: frames)
        await Self.feedServerStream(
            id: id,
            records: [#"{"type":"completionStream","events":[]}"#],
            to: transport
        )
        do {
            _ = try await run.final.value
            XCTFail("completion must reject a stream without done")
        } catch {
            assertEndedWithoutTerminal(error)
        }
        await client.close()
    }

    func test_transcribe_request_id_base64_aggregation_and_terminal_enforcement() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let audio = Data([0x01, 0x02, 0x03])
        let run = try await client.transcribe(modelId: "speech", audioBytes: audio)
        var frames = try await Self.waitForFrames(2, on: transport)
        var (id, request) = try Self.request(in: frames)
        XCTAssertEqual(request["requestId"] as? String, run.requestId)
        let audioChunk = try XCTUnwrap(request["audioChunk"] as? [String: Any])
        XCTAssertEqual(audioChunk["type"] as? String, "base64")
        XCTAssertEqual(audioChunk["value"] as? String, audio.base64EncodedString())
        await Self.feedServerStream(
            id: id,
            records: [
                #"{"type":"transcribe","text":"hello "}"#,
                #"{"type":"transcribe","text":"world","done":true,"stats":{"rtf":0.1}}"#,
            ],
            to: transport
        )
        let outcome = try await run.result.value
        XCTAssertEqual(outcome.text, "hello world")
        XCTAssertEqual(outcome.stats, .object(["rtf": .number(0.1)]))

        await client.close()

        let secondTransport = MockTransport()
        let secondClient = QVACClient(testing: secondTransport)
        let incomplete = try await secondClient.transcribe(
            modelId: "speech",
            audioPath: "/tmp/probe.wav"
        )
        frames = try await Self.waitForFrames(2, on: secondTransport)
        (id, request) = try Self.request(in: frames)
        XCTAssertEqual(request["requestId"] as? String, incomplete.requestId)
        await Self.feedServerStream(
            id: id,
            records: [#"{"type":"transcribe","text":"partial"}"#],
            to: secondTransport
        )
        do {
            _ = try await incomplete.result.value
            XCTFail("transcribe must reject a stream without done")
        } catch {
            assertEndedWithoutTerminal(error)
        }
        await secondClient.close()
    }

    func test_upscale_base64_roundtrip_and_terminal_aggregation() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let source = Data([0x00, 0x01, 0xFE, 0xFF])
        let outputA = Data([0x89, 0x50, 0x4E, 0x47])
        let outputB = Data([0x10, 0x20])

        let run = try await client.upscale(modelId: "upscaler", image: source, repeats: 2)
        let frames = try await Self.waitForFrames(2, on: transport)
        let (id, request) = try Self.request(in: frames)
        XCTAssertEqual(request["type"] as? String, "upscaleStream")
        XCTAssertEqual(request["image"] as? String, source.base64EncodedString())
        XCTAssertEqual(request["repeats"] as? Int, 2)

        await Self.feedServerStream(
            id: id,
            records: [
                #"{"type":"upscaleStream","data":"\#(outputA.base64EncodedString())","outputIndex":0}"#,
                #"{"type":"upscaleStream","data":"\#(outputB.base64EncodedString())","outputIndex":1,"done":true,"stats":{"repeats":2}}"#,
            ],
            to: transport
        )
        let outputs = try await run.outputs.value
        let stats = try await run.stats.value
        XCTAssertEqual(outputs, [outputA, outputB])
        XCTAssertEqual(stats?.repeats, 2)
        await client.close()
    }

    func test_classify_rejects_stream_end_without_done() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let task = Task {
            try await client.classify(modelId: "classifier", image: Data([1, 2, 3]))
        }
        let frames = try await Self.waitForFrames(2, on: transport)
        let (id, request) = try Self.request(in: frames)
        XCTAssertEqual(request["image"] as? String, Data([1, 2, 3]).base64EncodedString())
        await Self.feedServerStream(
            id: id,
            records: [#"{"type":"classify","results":[{"label":"cat","confidence":0.9}]}"#],
            to: transport
        )
        do {
            _ = try await task.value
            XCTFail("classify must reject a stream without its terminal done frame")
        } catch {
            assertEndedWithoutTerminal(error)
        }
        await client.close()
    }

    func test_diffusion_progress_coalesces_by_client_byte_budget_without_failing_outputs() async throws {
        let prototype = QVACClient.DiffusionProgressTick(
            step: 1,
            totalSteps: 9,
            elapsedMs: 1
        )
        let snapshotBytes = QVACClient.conservativeBufferedJSONBytes(
            prototype,
            elementCount: 1,
            fallback: Int.max
        )
        let maximumBufferedBytes = snapshotBytes * 2 - 1
        let transport = MockTransport()
        let client = QVACClient(
            testing: transport,
            maximumBufferedStreamBytes: maximumBufferedBytes
        )
        let output = Data([0x89, 0x50, 0x4E, 0x47])
        let run = try await client.diffusion(modelId: "diffusion-model", prompt: "a lake")
        let frames = try await Self.waitForFrames(2, on: transport)
        let (id, request) = try Self.request(in: frames)
        XCTAssertEqual(request["type"] as? String, "diffusionStream")
        XCTAssertEqual(request["modelId"] as? String, "diffusion-model")

        await Self.feedServerStream(
            id: id,
            records: [
                #"{"type":"diffusionStream","step":1,"totalSteps":9,"elapsedMs":1}"#,
                #"{"type":"diffusionStream","step":2,"totalSteps":9,"elapsedMs":1}"#,
                #"{"type":"diffusionStream","step":3,"totalSteps":9,"elapsedMs":1}"#,
                #"{"type":"diffusionStream","data":"\#(output.base64EncodedString())","done":true,"stats":{"seed":17}}"#,
            ],
            to: transport
        )

        let outputs = try await run.outputs.value
        XCTAssertEqual(outputs, [output])
        let stats = try await run.stats.value
        XCTAssertEqual(stats?.seed, 17)
        var progress: [QVACClient.DiffusionProgressTick] = []
        for try await tick in run.progressStream { progress.append(tick) }
        XCTAssertEqual(progress.map(\.step), [3])
        XCTAssertEqual(progress.first?.totalSteps, 9)
        XCTAssertEqual(progress.first?.elapsedMs, 1)
        await client.close()
    }

    func test_diffusion_exposes_every_current_017_binary_and_optional_input() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let references = [Data([1, 2]), Data([3, 4])]
        let run = try await client.diffusion(
            modelId: "flux2",
            prompt: "fuse references",
            imgCfgScale: 2.5,
            vaeTiling: true,
            cachePreset: "fast",
            initImages: references,
            increaseRefIndex: true,
            autoResizeRefImage: false,
            lora: "/models/style.safetensors",
            upscale: .object(["repeats": .number(2)])
        )
        let frames = try await Self.waitForFrames(2, on: transport)
        let (id, request) = try Self.request(in: frames)
        XCTAssertEqual(request["img_cfg_scale"] as? Double, 2.5)
        XCTAssertEqual(request["vae_tiling"] as? Bool, true)
        XCTAssertEqual(request["cache_preset"] as? String, "fast")
        XCTAssertEqual(
            request["init_images"] as? [String],
            references.map { $0.base64EncodedString() }
        )
        XCTAssertEqual(request["increase_ref_index"] as? Bool, true)
        XCTAssertEqual(request["auto_resize_ref_image"] as? Bool, false)
        XCTAssertEqual(request["lora"] as? String, "/models/style.safetensors")
        XCTAssertEqual(
            request["upscale"] as? [String: Int],
            ["repeats": 2]
        )
        await Self.feedServerStream(
            id: id,
            records: [#"{"type":"diffusionStream","done":true}"#],
            to: transport
        )
        let outputs = try await run.outputs.value
        XCTAssertEqual(outputs, [])
        await client.close()
    }

    func test_generation_operations_match_017_empty_terminal_output_semantics() async throws {
        do {
            let transport = MockTransport()
            let client = QVACClient(testing: transport)
            let run = try await client.upscale(modelId: "upscaler", image: Data([1]))
            let frames = try await Self.waitForFrames(2, on: transport)
            let (id, _) = try Self.request(in: frames)
            await Self.feedServerStream(
                id: id,
                records: [#"{"type":"upscaleStream","data":"","done":true}"#],
                to: transport
            )
            let outputs = try await run.outputs.value
            XCTAssertEqual(outputs, [])
            await client.close()
        }

        do {
            let transport = MockTransport()
            let client = QVACClient(testing: transport)
            let run = try await client.video(
                modelId: "video",
                mode: "txt2vid",
                prompt: "empty"
            )
            let frames = try await Self.waitForFrames(2, on: transport)
            let (id, _) = try Self.request(in: frames)
            await Self.feedServerStream(
                id: id,
                records: [#"{"type":"videoStream","done":true}"#],
                to: transport
            )
            let outputs = try await run.outputs.value
            XCTAssertEqual(outputs, [])
            await client.close()
        }
    }

    func test_diffusion_oversized_progress_view_does_not_fail_output_or_terminal_drain() async throws {
        let prototype = QVACClient.DiffusionProgressTick(
            step: 1,
            totalSteps: 9,
            elapsedMs: 1
        )
        let snapshotBytes = QVACClient.conservativeBufferedJSONBytes(
            prototype,
            elementCount: 1,
            fallback: Int.max
        )
        let maximumBufferedBytes = snapshotBytes - 1
        let transport = MockTransport()
        let profiling = ProfilingCounter()
        let client = QVACClient(
            testing: transport,
            maximumBufferedStreamBytes: maximumBufferedBytes,
            profilingMetadataHandler: { _ in profiling.increment() }
        )
        let output = Data([1, 2, 3, 4])
        let run = try await client.diffusion(
            modelId: "diffusion-model",
            prompt: "a lake",
            rpcOptions: .init(timeout: nil, profiling: .init(
                enabled: true,
                includeServerBreakdown: true
            ))
        )
        let frames = try await Self.waitForFrames(2, on: transport)
        let (id, _) = try Self.request(in: frames)
        await Self.feedServerStream(
            id: id,
            records: [#"{"type":"diffusionStream","step":1,"totalSteps":9,"elapsedMs":1}"#],
            to: transport,
            end: false
        )

        do {
            for try await _ in run.progressStream {}
            XCTFail("an indivisible progress snapshot above the client budget must overflow")
        } catch let overflow as QVACStreamBufferOverflow {
            XCTAssertEqual(overflow.stream, "diffusion.progressStream")
            XCTAssertEqual(overflow.maximumBufferedBytes, maximumBufferedBytes)
            XCTAssertEqual(overflow.attemptedBufferedBytes, snapshotBytes)
        }

        // Feed the terminal record only after the raw consumer has processed the
        // progress record. This keeps the test focused on the public progress
        // budget instead of intentionally saturating the separately bounded raw
        // queue with several structurally charged DATA frames at once.
        var terminalFrames = BareRPCCodec.__testEncodeStreamFrame(
            id: id,
            flags: [.response, .data],
            payload: .data(Data(
                (#"{"type":"diffusionStream","data":"\#(output.base64EncodedString())","done":true}"# + "\n").utf8
            ))
        )
        terminalFrames.append(BareRPCCodec.__testEncodeStreamFrame(
            id: id,
            flags: [.response, .data],
            payload: .data(Data(
                (#"{"__profilingTrailer":true,"__profiling":{"id":"diffusion-profile"}}"# + "\n").utf8
            ))
        ))
        terminalFrames.append(BareRPCCodec.__testEncodeStreamFrame(
            id: id,
            flags: [.response, .end]
        ))
        await transport.feed(terminalFrames)

        let outputs = try await run.outputs.value
        XCTAssertEqual(outputs, [output])
        XCTAssertEqual(
            profiling.value(),
            1,
            "diffusion output must resolve only after its terminal trailer is drained"
        )
        await client.close()
    }

    func test_video_generates_request_id_transforms_images_and_emits_progress() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let initImage = Data([0xCA, 0xFE])
        let controls = [Data([1]), Data([2])]
        let encodedVideo = Data([0x52, 0x49, 0x46, 0x46])

        let run = try await client.video(
            modelId: "video-model",
            mode: "img2vid",
            prompt: "move",
            initImage: initImage,
            controlFrames: controls
        )
        let frames = try await Self.waitForFrames(2, on: transport)
        let (id, request) = try Self.request(in: frames)
        XCTAssertFalse(run.requestId.isEmpty)
        XCTAssertEqual(request["requestId"] as? String, run.requestId)
        XCTAssertEqual(request["init_image"] as? String, initImage.base64EncodedString())
        XCTAssertEqual(
            request["control_frames"] as? [String],
            controls.map { $0.base64EncodedString() }
        )

        await Self.feedServerStream(
            id: id,
            records: [
                #"{"type":"videoStream","step":2,"totalSteps":8,"elapsedMs":12}"#,
                #"{"type":"videoStream","data":"\#(encodedVideo.base64EncodedString())","done":true,"stats":{"seed":17}}"#,
            ],
            to: transport
        )
        let outputs = try await run.outputs.value
        var progress: [QVACClient.VideoProgressTick] = []
        for try await tick in run.progressStream { progress.append(tick) }
        XCTAssertEqual(progress.count, 1)
        XCTAssertEqual(progress.first?.step, 2)
        XCTAssertEqual(progress.first?.totalSteps, 8)
        XCTAssertEqual(progress.first?.elapsedMs, 12)
        XCTAssertEqual(outputs, [encodedVideo])
        let stats = try await run.stats.value
        XCTAssertEqual(stats?.seed, 17)
        await client.close()
    }

    func test_video_progress_coalesces_by_byte_budget_without_failing_output() async throws {
        let prototype = QVACClient.VideoProgressTick(
            step: 1,
            totalSteps: 3,
            elapsedMs: 1
        )
        let snapshotBytes = QVACClient.conservativeBufferedJSONBytes(
            prototype,
            elementCount: 1,
            fallback: Int.max
        )
        let transport = MockTransport()
        let client = QVACClient(
            testing: transport,
            maximumBufferedStreamBytes: snapshotBytes * 2 - 1
        )
        let output = Data([0x52, 0x49, 0x46, 0x46])
        let run = try await client.video(
            modelId: "video-model",
            mode: "txt2vid",
            prompt: "move"
        )
        let frames = try await Self.waitForFrames(2, on: transport)
        let (id, _) = try Self.request(in: frames)
        await Self.feedServerStream(
            id: id,
            records: [
                #"{"type":"videoStream","step":1,"totalSteps":3,"elapsedMs":1}"#,
                #"{"type":"videoStream","step":2,"totalSteps":3,"elapsedMs":1}"#,
                #"{"type":"videoStream","step":3,"totalSteps":3,"elapsedMs":1}"#,
                #"{"type":"videoStream","data":"\#(output.base64EncodedString())","done":true}"#,
            ],
            to: transport
        )

        let outputs = try await run.outputs.value
        XCTAssertEqual(outputs, [output])
        var progress: [QVACClient.VideoProgressTick] = []
        for try await tick in run.progressStream { progress.append(tick) }
        XCTAssertEqual(progress.map(\.step), [3])
        await client.close()
    }

    func test_audio_gen_generates_request_id_emits_progress_and_assembles_pcm() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let first = Data([1, 2])
        let second = Data([3, 4])

        let run = try await client.audioGen(modelId: "audio-model", caption: "rain", bpm: 120)
        let frames = try await Self.waitForFrames(2, on: transport)
        let (id, request) = try Self.request(in: frames)
        XCTAssertFalse(run.requestId.isEmpty)
        XCTAssertEqual(request["requestId"] as? String, run.requestId)
        XCTAssertEqual(request["caption"] as? String, "rain")
        XCTAssertEqual(request["bpm"] as? Int, 120)

        await Self.feedServerStream(
            id: id,
            records: [
                #"{"type":"audioGenStream","progress":{"stage":"denoise","step":1,"total":2},"done":false}"#,
                #"{"type":"audioGenStream","data":"\#(first.base64EncodedString())","sampleRate":48000,"channels":2,"bitsPerSample":16,"done":false}"#,
                #"{"type":"audioGenStream","data":"\#(second.base64EncodedString())","sampleRate":48000,"channels":2,"bitsPerSample":16,"done":true,"stopReason":"completed"}"#,
            ],
            to: transport
        )
        let audio = try await run.audio.value
        var progress: [QVACClient.AudioGenProgress] = []
        for try await update in run.progressStream { progress.append(update) }
        XCTAssertEqual(progress.count, 1)
        XCTAssertEqual(progress.first?.stage, "denoise")
        XCTAssertEqual(progress.first?.step, 1)
        XCTAssertEqual(progress.first?.total, 2)
        XCTAssertEqual(audio.pcm, first + second)
        XCTAssertEqual(audio.sampleRate, 48_000)
        XCTAssertEqual(audio.channels, 2)
        XCTAssertEqual(audio.bitsPerSample, 16)
        let stats = try await run.stats.value
        XCTAssertNil(stats)
        await client.close()
    }

    func test_audio_gen_progress_coalesces_by_byte_budget_without_failing_audio() async throws {
        let rawProgress: JSONValue = .object([
            "stage": .string("denoise"),
            "step": .number(1),
            "total": .number(3),
        ])
        let snapshotBytes = QVACClient.conservativeBufferedJSONBytes(
            rawProgress,
            elementCount: 1,
            fallback: Int.max
        )
        let transport = MockTransport()
        let client = QVACClient(
            testing: transport,
            maximumBufferedStreamBytes: snapshotBytes * 2 - 1
        )
        let run = try await client.audioGen(modelId: "audio-model", caption: "rain")
        let frames = try await Self.waitForFrames(2, on: transport)
        let (id, _) = try Self.request(in: frames)
        await Self.feedServerStream(
            id: id,
            records: [
                #"{"type":"audioGenStream","progress":{"stage":"denoise","step":1,"total":3},"done":false}"#,
                #"{"type":"audioGenStream","progress":{"stage":"denoise","step":2,"total":3},"done":false}"#,
                #"{"type":"audioGenStream","progress":{"stage":"denoise","step":3,"total":3},"done":false}"#,
                #"{"type":"audioGenStream","data":"AQI=","sampleRate":48000,"channels":1,"bitsPerSample":16,"done":false}"#,
                #"{"type":"audioGenStream","done":true,"stopReason":"completed"}"#,
            ],
            to: transport
        )

        let audio = try await run.audio.value
        XCTAssertEqual(audio.pcm, Data([1, 2]))
        var progress: [QVACClient.AudioGenProgress] = []
        for try await update in run.progressStream { progress.append(update) }
        XCTAssertEqual(progress.map(\.step), [3])
        await client.close()
    }

    func test_audio_gen_rejects_unknown_017_stop_reason() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let run = try await client.audioGen(modelId: "audio-model", caption: "rain")
        let frames = try await Self.waitForFrames(2, on: transport)
        let (id, _) = try Self.request(in: frames)
        await Self.feedServerStream(
            id: id,
            records: [
                #"{"type":"audioGenStream","data":"AQI=","sampleRate":48000,"channels":1,"bitsPerSample":16,"done":true,"stopReason":"future-value"}"#,
            ],
            to: transport
        )

        do {
            _ = try await run.audio.value
            XCTFail("audioGen must reject stop reasons outside the pinned 0.17 contract")
        } catch let QVACError.protocolViolation(message) {
            XCTAssertTrue(message.contains("audioGenStream.stopReason"))
            XCTAssertTrue(message.contains("future-value"))
        } catch {
            XCTFail("expected protocol violation, got \(error)")
        }
        await client.close()
    }

    func test_audio_gen_enforces_pinned_017_response_constraints() async throws {
        let fixtures: [(record: String, expectedField: String)] = [
            (
                #"{"type":"audioGenStream","progress":{"stage":"denoise","step":-1,"total":2},"done":false}"#,
                "progress.step"
            ),
            (
                #"{"type":"audioGenStream","data":"","sampleRate":48000,"channels":1,"bitsPerSample":16,"done":true}"#,
                "base64 PCM"
            ),
            (
                #"{"type":"audioGenStream","data":"AQI=","sampleRate":0,"channels":1,"bitsPerSample":16,"done":true}"#,
                "sampleRate"
            ),
            (
                #"{"type":"audioGenStream","data":"AQI=","sampleRate":48000,"channels":0,"bitsPerSample":16,"done":true}"#,
                "channels"
            ),
            (
                #"{"type":"audioGenStream","data":"AQI=","sampleRate":48000,"channels":1,"bitsPerSample":0,"done":true}"#,
                "bitsPerSample"
            ),
            (
                #"{"type":"audioGenStream","data":"AQI=","channels":1,"bitsPerSample":16,"done":true}"#,
                "sampleRate"
            ),
            (
                #"{"type":"audioGenStream","sampleRate":48000,"channels":1,"bitsPerSample":16,"done":true}"#,
                "sampleRate"
            ),
        ]

        for fixture in fixtures {
            let transport = MockTransport()
            let client = QVACClient(testing: transport)
            let run = try await client.audioGen(modelId: "audio-model", caption: "rain")
            let frames = try await Self.waitForFrames(2, on: transport)
            let (id, _) = try Self.request(in: frames)
            await Self.feedServerStream(id: id, records: [fixture.record], to: transport)

            do {
                _ = try await run.audio.value
                XCTFail("audioGen accepted invalid \(fixture.expectedField)")
            } catch let QVACError.protocolViolation(message) {
                XCTAssertTrue(
                    message.contains(fixture.expectedField),
                    "expected \(fixture.expectedField) diagnostic, got \(message)"
                )
            } catch {
                XCTFail("expected protocol violation, got \(error)")
            }
            await client.close()
        }
    }

    func test_audio_gen_uses_last_data_frame_metadata_like_017_client() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let run = try await client.audioGen(modelId: "audio-model", caption: "rain")
        let frames = try await Self.waitForFrames(2, on: transport)
        let (id, _) = try Self.request(in: frames)
        await Self.feedServerStream(
            id: id,
            records: [
                #"{"type":"audioGenStream","data":"AQI=","sampleRate":48000,"channels":1,"bitsPerSample":16,"done":false}"#,
                #"{"type":"audioGenStream","data":"AwQ=","sampleRate":44100,"channels":1,"bitsPerSample":16,"done":true}"#,
            ],
            to: transport
        )

        let audio = try await run.audio.value
        XCTAssertEqual(audio.pcm, Data([1, 2, 3, 4]))
        XCTAssertEqual(audio.sampleRate, 44_100)
        XCTAssertEqual(audio.channels, 1)
        XCTAssertEqual(audio.bitsPerSample, 16)
        await client.close()
    }

    func test_audio_gen_accepts_optional_metadata_until_last_data_frame() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let run = try await client.audioGen(modelId: "audio-model", caption: "rain")
        let frames = try await Self.waitForFrames(2, on: transport)
        let (id, _) = try Self.request(in: frames)
        await Self.feedServerStream(
            id: id,
            records: [
                #"{"type":"audioGenStream","data":"AQI=","done":false}"#,
                #"{"type":"audioGenStream","data":"AwQ=","sampleRate":48000,"channels":2,"bitsPerSample":16,"done":true}"#,
            ],
            to: transport
        )

        let audio = try await run.audio.value
        XCTAssertEqual(audio.pcm, Data([1, 2, 3, 4]))
        XCTAssertEqual(audio.sampleRate, 48_000)
        XCTAssertEqual(audio.channels, 2)
        XCTAssertEqual(audio.bitsPerSample, 16)
        await client.close()
    }

    func test_text_to_speech_matches_017_stream_collect_and_sentence_result_modes() async throws {
        do {
            let transport = MockTransport()
            let client = QVACClient(testing: transport)
            let run = try await client.textToSpeech(
                modelId: "tts",
                text: "hello",
                stream: false
            )
            let frames = try await Self.waitForFrames(2, on: transport)
            let (id, request) = try Self.request(in: frames)
            XCTAssertEqual(request["stream"] as? Bool, false)
            XCTAssertEqual(request["sentenceStream"] as? Bool, false)
            XCTAssertEqual(request["inputType"] as? String, "text")
            await Self.feedServerStream(
                id: id,
                records: [
                    #"{"type":"textToSpeech","buffer":[0.1,0.2],"done":false}"#,
                    #"{"type":"textToSpeech","buffer":[0.3],"done":true}"#,
                ],
                to: transport
            )
            let buffer = try await run.buffer.value
            let done = try await run.done.value
            XCTAssertEqual(buffer, [0.1, 0.2, 0.3])
            XCTAssertTrue(done)
            var streamed: [Double] = []
            for try await sample in run.bufferStream { streamed.append(sample) }
            XCTAssertTrue(streamed.isEmpty)
            XCTAssertNil(run.chunkUpdates)
            await client.close()
        }

        do {
            let transport = MockTransport()
            let client = QVACClient(testing: transport)
            let run = try await client.textToSpeech(modelId: "tts", text: "hello")
            let frames = try await Self.waitForFrames(2, on: transport)
            let (id, request) = try Self.request(in: frames)
            // The published e8 schema defaults `stream` to true.
            XCTAssertEqual(request["stream"] as? Bool, true)
            await Self.feedServerStream(
                id: id,
                records: [
                    #"{"type":"textToSpeech","buffer":[1,2],"done":false}"#,
                    #"{"type":"textToSpeech","buffer":[3],"done":true}"#,
                ],
                to: transport
            )
            let buffer = try await run.buffer.value
            let done = try await run.done.value
            XCTAssertEqual(buffer, [])
            XCTAssertTrue(done)
            var samples: [Double] = []
            for try await sample in run.bufferStream { samples.append(sample) }
            XCTAssertEqual(samples, [1, 2, 3])
            await client.close()
        }

        do {
            let transport = MockTransport()
            let client = QVACClient(testing: transport)
            let run = try await client.textToSpeech(
                modelId: "tts",
                text: "First. Second.",
                sentenceStream: true
            )
            let frames = try await Self.waitForFrames(2, on: transport)
            let (id, request) = try Self.request(in: frames)
            XCTAssertEqual(request["stream"] as? Bool, true)
            XCTAssertEqual(request["sentenceStream"] as? Bool, true)
            await Self.feedServerStream(
                id: id,
                records: [
                    #"{"type":"textToSpeech","buffer":[0.25],"chunkIndex":0,"sentenceChunk":"First.","done":false}"#,
                    #"{"type":"textToSpeech","buffer":[],"done":true}"#,
                ],
                to: transport
            )
            let updates = try XCTUnwrap(run.chunkUpdates)
            var collected: [QVACClient.TtsSentenceChunkUpdate] = []
            for try await update in updates { collected.append(update) }
            XCTAssertEqual(collected, [.init(
                buffer: [0.25],
                chunkIndex: 0,
                sentenceChunk: "First."
            )])
            let done = try await run.done.value
            XCTAssertTrue(done)
            await client.close()
        }

        do {
            let client = QVACClient(testing: MockTransport())
            do {
                _ = try await client.textToSpeech(
                    modelId: "tts",
                    text: "hello",
                    stream: false,
                    sentenceStream: true
                )
                XCTFail("sentence streaming without audio streaming must be rejected")
            } catch let QVACError.invalidArgument(message) {
                XCTAssertTrue(message.contains("requires stream"))
            }
            await client.close()
        }
    }

    func test_tts_large_single_wire_chunk_streams_every_sample_without_overflow() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let run = try await client.textToSpeech(modelId: "tts", text: "hello")
        let frames = try await Self.waitForFrames(2, on: transport)
        let (id, _) = try Self.request(in: frames)
        let samples = (0..<4_096).map {
            Double($0)
        }
        let encoded = try JSONEncoder.qvac.encode(QVACResponse.textToSpeech(.init(
            buffer: samples,
            done: false
        )))
        await Self.feedServerStream(
            id: id,
            records: [
                String(decoding: encoded, as: UTF8.self),
                #"{"type":"textToSpeech","buffer":[],"done":true}"#,
            ],
            to: transport
        )

        let done = try await run.done.value
        XCTAssertTrue(done)
        var streamed: [Double] = []
        for try await sample in run.bufferStream { streamed.append(sample) }
        XCTAssertEqual(streamed, samples)
        await client.close()
    }

    func test_tts_lagging_lossless_views_do_not_fail_done_or_aggregate() async throws {
        let transport = MockTransport()
        let maximumBufferedBytes = 1_024
        let client = QVACClient(
            testing: transport,
            maximumBufferedStreamBytes: maximumBufferedBytes
        )
        let run = try await client.textToSpeech(
            modelId: "tts",
            text: "hello",
            sentenceStream: true
        )
        let frames = try await Self.waitForFrames(2, on: transport)
        let (id, _) = try Self.request(in: frames)
        let samples = Array(
            repeating: 0.0,
            count: maximumBufferedBytes / MemoryLayout<Double>.stride + 1
        )
        let encoded = try JSONEncoder.qvac.encode(QVACResponse.textToSpeech(.init(
            buffer: samples,
            done: false,
            chunkIndex: 0,
            sentenceChunk: "hello"
        )))
        await Self.feedServerStream(
            id: id,
            records: [
                String(decoding: encoded, as: UTF8.self),
                #"{"type":"textToSpeech","buffer":[],"done":true}"#,
            ],
            to: transport
        )

        let didFinish = try await run.done.value
        let collectedBuffer = try await run.buffer.value
        XCTAssertTrue(didFinish)
        XCTAssertEqual(collectedBuffer, [])

        let updates = try XCTUnwrap(run.chunkUpdates)
        do {
            for try await _ in updates {}
            XCTFail("the byte-bounded lagging sentence view must report overflow")
        } catch let overflow as QVACStreamBufferOverflow {
            XCTAssertEqual(overflow.stream, "textToSpeech.chunkUpdates")
            XCTAssertEqual(overflow.maximumBufferedBytes, maximumBufferedBytes)
            XCTAssertGreaterThan(overflow.attemptedBufferedBytes ?? 0, maximumBufferedBytes)
        }

        do {
            for try await _ in run.bufferStream {}
            XCTFail("the byte-bounded lagging audio view must report overflow")
        } catch let overflow as QVACStreamBufferOverflow {
            XCTAssertEqual(overflow.stream, "textToSpeech.bufferStream")
            XCTAssertEqual(overflow.maximumBufferedBytes, maximumBufferedBytes)
            XCTAssertEqual(
                overflow.attemptedBufferedBytes,
                samples.count * MemoryLayout<Double>.stride
            )
        }
        await client.close()
    }

    func test_translate_matches_017_stream_and_nonstream_result_semantics() async throws {
        do {
            let transport = MockTransport()
            let client = QVACClient(testing: transport)
            let run = try await client.translate(
                modelId: "translator",
                modelType: "llm",
                text: "hello",
                to: "fr"
            )
            let frames = try await Self.waitForFrames(2, on: transport)
            let (id, request) = try Self.request(in: frames)
            XCTAssertEqual(request["stream"] as? Bool, true)
            XCTAssertEqual(request["text"] as? String, "hello")
            XCTAssertNil(request["requestId"])
            await Self.feedServerStream(
                id: id,
                records: [
                    #"{"type":"translate","token":"Bon"}"#,
                    #"{"type":"translate","token":"jour"}"#,
                    #"{"type":"translate","token":"","done":true,"stats":{"totalTokens":2}}"#,
                ],
                to: transport
            )
            var tokens: [String] = []
            for try await token in run.tokenStream { tokens.append(token) }
            XCTAssertEqual(tokens, ["Bon", "jour"])
            let text = try await run.text.value
            let stats = try await run.stats.value
            XCTAssertEqual(text, "")
            XCTAssertEqual(stats?.totalTokens, 2)
            await client.close()
        }

        do {
            let transport = MockTransport()
            let client = QVACClient(testing: transport)
            let run = try await client.translate(
                modelId: "translator",
                modelType: "nmtcpp-translation",
                text: "hello",
                stream: false
            )
            let frames = try await Self.waitForFrames(2, on: transport)
            let (id, request) = try Self.request(in: frames)
            XCTAssertEqual(request["stream"] as? Bool, false)
            await Self.feedServerStream(
                id: id,
                records: [
                    #"{"type":"translate","token":"bon"}"#,
                    #"{"type":"translate","token":"jour","done":true,"stats":{"totalTime":12}}"#,
                ],
                to: transport
            )
            let text = try await run.text.value
            let stats = try await run.stats.value
            XCTAssertEqual(text, "bonjour")
            XCTAssertEqual(stats?.totalTime, 12)
            var tokens: [String] = []
            for try await token in run.tokenStream { tokens.append(token) }
            XCTAssertTrue(tokens.isEmpty)
            await client.close()
        }

        do {
            let transport = MockTransport()
            let client = QVACClient(testing: transport)
            let run = try await client.translate(
                modelId: "translator",
                modelType: "nmtcpp-translation",
                texts: ["hello", "world"],
                stream: false
            )
            let frames = try await Self.waitForFrames(2, on: transport)
            let (id, request) = try Self.request(in: frames)
            XCTAssertEqual(request["stream"] as? Bool, false)
            XCTAssertEqual(request["text"] as? [String], ["hello", "world"])
            XCTAssertEqual(request["modelType"] as? String, "nmtcpp-translation")
            XCTAssertNil(request["from"])
            XCTAssertNil(request["to"])
            XCTAssertNil(request["context"])
            await Self.feedServerStream(
                id: id,
                records: [
                    #"{"type":"translate","token":"bonjour"}"#,
                    #"{"type":"translate","token":"\n"}"#,
                    #"{"type":"translate","token":"monde"}"#,
                    #"{"type":"translate","token":"","done":true,"stats":{"totalTime":9}}"#,
                ],
                to: transport
            )
            let batchText = try await run.text.value
            let batchStats = try await run.stats.value
            XCTAssertEqual(batchText, "bonjour\nmonde")
            XCTAssertEqual(batchStats?.totalTime, 9)
            await client.close()
        }
    }

    func test_translate_rejects_inputs_outside_the_017_scalar_and_nmt_batch_schema() async {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)

        do {
            _ = try await client.translate(
                modelId: "translator",
                modelType: "nmtcpp-translation",
                text: ""
            )
            XCTFail("empty scalar text must fail before transport I/O")
        } catch let QVACError.invalidArgument(message) {
            XCTAssertTrue(message.contains("text must not be empty"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let invalidLLMTargets: [String?] = [nil, ""]
        for targetLanguage in invalidLLMTargets {
            do {
                _ = try await client.translate(
                    modelId: "translator",
                    modelType: "llamacpp-completion",
                    text: "hello",
                    to: targetLanguage
                )
                XCTFail("LLM translation requires a non-empty target language")
            } catch let QVACError.invalidArgument(message) {
                XCTAssertTrue(message.contains("target language"))
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }

        let invalidNMTOptions: [(from: String?, to: String?, context: String?)] = [
            ("en", nil, nil),
            (nil, "fr", nil),
            (nil, nil, "formal"),
        ]
        for options in invalidNMTOptions {
            do {
                _ = try await client.translate(
                    modelId: "translator",
                    modelType: "nmtcpp-translation",
                    text: "hello",
                    from: options.from,
                    to: options.to,
                    context: options.context
                )
                XCTFail("NMT translation must reject LLM-only fields")
            } catch let QVACError.invalidArgument(message) {
                XCTAssertTrue(message.contains("does not accept"))
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }

        do {
            _ = try await client.translate(
                modelId: "translator",
                modelType: "custom-translation",
                text: "hello"
            )
            XCTFail("unsupported translation model type must fail before transport I/O")
        } catch let QVACError.invalidArgument(message) {
            XCTAssertTrue(message.contains("modelType"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        for invalidTexts in [[], ["hello", ""]] {
            do {
                _ = try await client.translate(
                    modelId: "translator",
                    modelType: "nmtcpp-translation",
                    texts: invalidTexts
                )
                XCTFail("invalid batch must fail before transport I/O")
            } catch let QVACError.invalidArgument(message) {
                XCTAssertTrue(message.contains("translate texts"))
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }

        do {
            _ = try await client.translate(
                modelId: "translator",
                modelType: "llamacpp-completion",
                texts: ["hello"]
            )
            XCTFail("LLM translation must reject array input")
        } catch let QVACError.invalidArgument(message) {
            XCTAssertTrue(message.contains("batch input requires"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let outbound = await transport.outbound()
        XCTAssertTrue(outbound.isEmpty)
        await client.close()
    }

    func test_ocr_matches_017_stream_and_nonstream_result_semantics() async throws {
        do {
            let transport = MockTransport()
            let client = QVACClient(testing: transport)
            let run = try await client.ocr(
                modelId: "ocr",
                imageBytes: Data([1, 2, 3])
            )
            let frames = try await Self.waitForFrames(2, on: transport)
            let (id, request) = try Self.request(in: frames)
            XCTAssertNil(request["stream"])
            await Self.feedServerStream(
                id: id,
                records: [
                    #"{"type":"ocrStream","blocks":[{"text":"one","bbox":[1,2,3,4],"confidence":0.9}]}"#,
                    #"{"type":"ocrStream","blocks":[{"text":"two"}],"done":true,"stats":{"totalTime":10}}"#,
                ],
                to: transport
            )
            let blocks = try await run.blocks.value
            XCTAssertEqual(blocks.map(\.text), ["one", "two"])
            XCTAssertEqual(blocks.first?.boundingBox, [1, 2, 3, 4])
            let stats = try await run.stats.value
            XCTAssertEqual(stats?.totalTime, 10)
            var batches: [[QVACClient.OCRTextBlock]] = []
            for try await batch in run.blockStream { batches.append(batch) }
            XCTAssertTrue(batches.isEmpty)
            await client.close()
        }

        do {
            let transport = MockTransport()
            let client = QVACClient(testing: transport)
            let run = try await client.ocr(
                modelId: "ocr",
                imagePath: "/tmp/probe.png",
                stream: true
            )
            let frames = try await Self.waitForFrames(2, on: transport)
            let (id, _) = try Self.request(in: frames)
            await Self.feedServerStream(
                id: id,
                records: [
                    #"{"type":"ocrStream","blocks":[{"text":"streamed"}]}"#,
                    #"{"type":"ocrStream","done":true,"stats":{"detectionTime":4}}"#,
                ],
                to: transport
            )
            let blocks = try await run.blocks.value
            XCTAssertEqual(blocks, [])
            var batches: [[QVACClient.OCRTextBlock]] = []
            for try await batch in run.blockStream { batches.append(batch) }
            XCTAssertEqual(batches.map { $0.map(\.text) }, [["streamed"]])
            let stats = try await run.stats.value
            XCTAssertEqual(stats?.detectionTime, 4)
            await client.close()
        }
    }

    func test_extracted_ocr_translate_and_tts_views_outlive_run_wrapper() async throws {
        do {
            let transport = MockTransport()
            let client = QVACClient(testing: transport)
            var run: QVACClient.OCRRun? = try await client.ocr(
                modelId: "ocr",
                imagePath: "/tmp/probe.png"
            )
            let blocks = try XCTUnwrap(run).blocks
            run = nil
            let frames = try await Self.waitForFrames(2, on: transport)
            let (id, _) = try Self.request(in: frames)
            await Self.feedServerStream(
                id: id,
                records: [#"{"type":"ocrStream","blocks":[{"text":"retained"}],"done":true}"#],
                to: transport
            )
            let resolvedBlocks = try await blocks.value
            XCTAssertEqual(resolvedBlocks.map(\.text), ["retained"])
            await client.close()
        }

        do {
            let transport = MockTransport()
            let client = QVACClient(testing: transport)
            var run: QVACClient.TranslationRun? = try await client.translate(
                modelId: "translator",
                modelType: "llm",
                text: "hello",
                to: "fr"
            )
            let tokens = try XCTUnwrap(run).tokenStream
            run = nil
            let frames = try await Self.waitForFrames(2, on: transport)
            let (id, _) = try Self.request(in: frames)
            await Self.feedServerStream(
                id: id,
                records: [
                    #"{"type":"translate","token":"bonjour"}"#,
                    #"{"type":"translate","token":"","done":true}"#,
                ],
                to: transport
            )
            var collected: [String] = []
            for try await token in tokens { collected.append(token) }
            XCTAssertEqual(collected, ["bonjour"])
            await client.close()
        }

        do {
            let transport = MockTransport()
            let client = QVACClient(testing: transport)
            var run: QVACClient.TextToSpeechRun? = try await client.textToSpeech(
                modelId: "tts",
                text: "hello"
            )
            let samples = try XCTUnwrap(run).bufferStream
            let done = try XCTUnwrap(run).done
            run = nil
            let frames = try await Self.waitForFrames(2, on: transport)
            let (id, _) = try Self.request(in: frames)
            await Self.feedServerStream(
                id: id,
                records: [#"{"type":"textToSpeech","buffer":[0.25],"done":true}"#],
                to: transport
            )
            var collected: [Double] = []
            for try await sample in samples { collected.append(sample) }
            XCTAssertEqual(collected, [0.25])
            let didFinish = try await done.value
            XCTAssertTrue(didFinish)
            await client.close()
        }
    }

    func test_explicit_tts_run_cancel_releases_the_raw_stream() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let run = try await client.textToSpeech(modelId: "tts", text: "cancel me")
        _ = try await Self.waitForFrames(2, on: transport)

        run.cancel()
        do {
            _ = try await run.done.value
            XCTFail("cancelled synthesis must not resolve successfully")
        } catch is CancellationError {
            // Public Swift cancellation identity is intentionally preserved.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        let rpc = await client.rpc
        try await Self.waitForNoInFlight(rpc)
        await client.close()
    }

    func test_rich_server_stream_rejects_wrong_response_discriminator_immediately() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let run = try await client.upscale(
            modelId: "upscaler",
            image: Data([0x89, 0x50, 0x4e, 0x47])
        )
        let frames = try await Self.waitForFrames(2, on: transport)
        let (id, _) = try Self.request(in: frames)
        await Self.feedServerStream(
            id: id,
            records: [#"{"type":"videoStream","done":true}"#],
            to: transport
        )
        do {
            _ = try await run.outputs.value
            XCTFail("wrong response discriminator must not be ignored")
        } catch {
            assertProtocolViolation(error)
        }
        await client.close()
    }

    func test_conditional_progress_stream_rejects_wrong_response_discriminator_immediately() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let run = try await client.loadModelStreaming(
            modelSrc: "/models/model.gguf",
            modelType: "llamacpp-completion"
        )
        let frames = try await Self.waitForFrames(2, on: transport)
        let (id, _) = try Self.request(in: frames)
        await Self.feedServerStream(
            id: id,
            records: [#"{"type":"videoStream","done":true}"#],
            to: transport
        )
        do {
            _ = try await run.result.value
            XCTFail("conditional-progress streams must reject unrelated response types")
        } catch {
            assertProtocolViolation(error)
        }
        await client.close()
    }

    func test_pull_mapped_stream_rejects_wrong_response_discriminator_immediately() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let stream = try await client.loggingStream(id: "__all__")
        let frames = try await Self.waitForFrames(2, on: transport)
        let (id, _) = try Self.request(in: frames)
        await Self.feedServerStream(
            id: id,
            records: [#"{"type":"videoStream","done":true}"#],
            to: transport
        )
        do {
            var iterator = stream.makeAsyncIterator()
            _ = try await iterator.next()
            XCTFail("pull-mapped streams must reject unrelated response types")
        } catch {
            assertProtocolViolation(error)
        }
        await client.close()
    }

    func test_bci_one_shot_base64_and_request_id_are_preserved() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let neural = Data([0x11, 0x22, 0x33])

        let run = try await client.bciTranscribe(
            modelId: "bci-model",
            neuralData: .data(neural)
        )
        let frames = try await Self.waitForFrames(2, on: transport)
        let (id, request) = try Self.request(in: frames)
        XCTAssertEqual(request["requestId"] as? String, run.requestId)
        let neuralData = try XCTUnwrap(request["neuralData"] as? [String: Any])
        XCTAssertEqual(neuralData["type"] as? String, "base64")
        XCTAssertEqual(neuralData["value"] as? String, neural.base64EncodedString())

        await Self.feedServerStream(
            id: id,
            records: [
                #"{"type":"bciTranscribe","text":"hello "}"#,
                #"{"type":"bciTranscribe","text":"world","done":true,"stats":{"windows":3}}"#,
            ],
            to: transport
        )
        let outcome = try await run.result.value
        XCTAssertEqual(outcome.text, "hello world")
        XCTAssertEqual(outcome.stats, .object(["windows": .number(3)]))
        await client.close()
    }

    func test_batch_completion_request_id_and_correlated_events() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)

        let run = try await client.batchCompletion(
            modelId: "llm",
            prompts: [.init(id: "prompt-1", history: [.user("hello")])]
        )
        let frames = try await Self.waitForFrames(2, on: transport)
        let (id, request) = try Self.request(in: frames)
        XCTAssertEqual(request["requestId"] as? String, run.requestId)
        XCTAssertEqual(request["stream"] as? Bool, true)
        let byId = run.byId("prompt-1")

        await Self.feedServerStream(
            id: id,
            records: [
                #"{"type":"batchCompletionStream","ids":["prompt-1"],"events":[{"id":"prompt-1","event":{"type":"contentDelta","seq":0,"text":"hi"}}]}"#,
                #"{"type":"batchCompletionStream","events":[{"id":"prompt-1","event":{"type":"completionDone","seq":1,"stopReason":"eos","raw":{"fullText":"hi"}}}],"done":true,"stats":{"emittedTokens":1}}"#,
            ],
            to: transport
        )
        let ids = try await run.ids.value
        let results = try await run.results.value
        let final = try await byId.final.value
        let stats = try await run.stats.value
        var streamed: [QVACClient.BatchCompletionEvent] = []
        for try await event in run.events { streamed.append(event) }
        var perIdEvents: [QVACClient.CompletionEvent] = []
        for try await event in byId.events { perIdEvents.append(event) }
        XCTAssertEqual(ids, ["prompt-1"])
        XCTAssertEqual(results.map(\.id), ["prompt-1"])
        XCTAssertEqual(results.first?.final, final)
        XCTAssertEqual(final.contentText, "hi")
        XCTAssertEqual(final.stopReason, .eos)
        XCTAssertEqual(stats?.emittedTokens, 1)
        XCTAssertEqual(streamed.count, 2)
        XCTAssertEqual(perIdEvents, streamed.map(\.event))
        XCTAssertEqual(streamed.first?.id, "prompt-1")
        await client.close()
    }

    func test_batch_completion_without_wire_ids_keeps_original_prompt_order() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let run = try await client.batchCompletion(
            modelId: "llm",
            prompts: [
                .init(id: "first", history: [.user("one")]),
                .init(id: "second", history: [.user("two")]),
            ]
        )
        let frames = try await Self.waitForFrames(2, on: transport)
        let (id, _) = try Self.request(in: frames)
        await Self.feedServerStream(
            id: id,
            records: [
                #"{"type":"batchCompletionStream","events":[{"id":"second","event":{"type":"contentDelta","seq":0,"text":"two"}},{"id":"second","event":{"type":"completionDone","seq":1,"stopReason":"eos","raw":{"fullText":"two"}}},{"id":"first","event":{"type":"contentDelta","seq":0,"text":"one"}},{"id":"first","event":{"type":"completionDone","seq":1,"stopReason":"eos","raw":{"fullText":"one"}}}],"done":true}"#,
            ],
            to: transport
        )

        let ids = try await run.ids.value
        let results = try await run.results.value
        XCTAssertEqual(ids, ["first", "second"])
        XCTAssertEqual(results.map(\.id), ["first", "second"])
        XCTAssertEqual(results.map(\.final.contentText), ["one", "two"])
        await client.close()
    }

    func test_batch_single_terminal_frame_preserves_large_global_and_per_id_views() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let promptIDs = (0..<70).map { "prompt-\($0)" }
        let run = try await client.batchCompletion(
            modelId: "llm",
            prompts: promptIDs.map {
                .init(id: $0, history: [.user("complete \($0)")])
            },
            stream: false
        )
        let firstPrompt = run.byId(promptIDs[0])
        let frames = try await Self.waitForFrames(2, on: transport)
        let (id, _) = try Self.request(in: frames)

        let firstFragments = (0..<80).map { "\($0)|" }
        var wireEvents: [JSONValue] = firstFragments.enumerated().map { index, text in
            .object([
                "id": .string(promptIDs[0]),
                "event": .object([
                    "type": .string("contentDelta"),
                    "seq": .number(Double(index)),
                    "text": .string(text),
                ]),
            ])
        }
        let firstText = firstFragments.joined()
        wireEvents.append(.object([
            "id": .string(promptIDs[0]),
            "event": .object([
                "type": .string("completionDone"),
                "seq": .number(80),
                "stopReason": .string("eos"),
                "raw": .object(["fullText": .string(firstText)]),
            ]),
        ]))
        for promptID in promptIDs.dropFirst() {
            wireEvents.append(.object([
                "id": .string(promptID),
                "event": .object([
                    "type": .string("contentDelta"),
                    "seq": .number(0),
                    "text": .string(promptID),
                ]),
            ]))
            wireEvents.append(.object([
                "id": .string(promptID),
                "event": .object([
                    "type": .string("completionDone"),
                    "seq": .number(1),
                    "stopReason": .string("eos"),
                    "raw": .object(["fullText": .string(promptID)]),
                ]),
            ]))
        }
        let encoded = try JSONEncoder.qvac.encode(QVACResponse.batchCompletionStream(.init(
            events: wireEvents,
            done: true,
            ids: promptIDs
        )))
        await Self.feedServerStream(
            id: id,
            records: [String(decoding: encoded, as: UTF8.self)],
            to: transport
        )

        let ids = try await run.ids.value
        let results = try await run.results.value
        XCTAssertEqual(ids, promptIDs)
        XCTAssertEqual(results.map(\.id), promptIDs)
        XCTAssertEqual(results.first?.final.contentText, firstText)

        var globalEvents: [QVACClient.BatchCompletionEvent] = []
        for try await event in run.events { globalEvents.append(event) }
        XCTAssertEqual(globalEvents.count, wireEvents.count)
        XCTAssertEqual(
            Array(globalEvents.map(\.id).prefix(81)),
            Array(repeating: promptIDs[0], count: 81)
        )

        var firstEvents: [QVACClient.CompletionEvent] = []
        for try await event in firstPrompt.events { firstEvents.append(event) }
        XCTAssertEqual(firstEvents.count, 81)
        for (index, event) in firstEvents.dropLast().enumerated() {
            guard case .contentDelta(let sequence, let text) = event else {
                return XCTFail("first-prompt event \(index) is not a content delta")
            }
            XCTAssertEqual(sequence, index)
            XCTAssertEqual(text, firstFragments[index])
        }
        guard let lastEvent = firstEvents.last,
              case .done(let sequence, let reason, _) = lastEvent else {
            return XCTFail("the first prompt terminal event is missing")
        }
        XCTAssertEqual(sequence, 80)
        XCTAssertEqual(reason, .eos)
        let firstFinal = try await firstPrompt.final.value
        XCTAssertEqual(firstFinal.contentText, firstText)
        await client.close()
    }

    func test_batch_completion_rejects_duplicate_ids_before_transport() async {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        do {
            _ = try await client.batchCompletion(
                modelId: "llm",
                prompts: [
                    .init(id: "duplicate", history: [.user("one")]),
                    .init(id: "duplicate", history: [.user("two")]),
                ]
            )
            XCTFail("duplicate batch prompt ids must be rejected")
        } catch let QVACError.invalidArgument(message) {
            XCTAssertTrue(message.contains("must be unique"))
        } catch {
            XCTFail("expected invalidArgument, got \(error)")
        }
        let outboundFrames = Self.frames(in: await transport.outbound())
        XCTAssertTrue(outboundFrames.isEmpty)
        await client.close()
    }

    func test_batch_completion_cancellation_preserves_partial_prompt_state() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let run = try await client.batchCompletion(
            modelId: "llm",
            prompts: [.init(id: "prompt-1", history: [.user("keep going")])]
        )
        let byId = run.byId("prompt-1")
        let frames = try await Self.waitForFrames(2, on: transport)
        let (id, _) = try Self.request(in: frames)

        await Self.feedServerStream(
            id: id,
            records: [
                #"{"type":"batchCompletionStream","ids":["prompt-1"],"events":[{"id":"prompt-1","event":{"type":"contentDelta","seq":0,"text":"partial batch"}},{"id":"prompt-1","event":{"type":"completionStats","seq":1,"stats":{"emittedTokens":2}}}]}"#,
                #"{"type":"batchCompletionStream","events":[{"id":"prompt-1","event":{"type":"completionDone","seq":2,"stopReason":"cancelled","raw":{"fullText":"partial batch"}}}],"done":true}"#,
            ],
            to: transport
        )

        do {
            _ = try await byId.final.value
            XCTFail("a cancelled per-prompt aggregate must reject")
        } catch let QVACError.inferenceCancelled(requestId, partial) {
            XCTAssertEqual(requestId, run.requestId)
            XCTAssertEqual(partial.text, "partial batch")
            XCTAssertEqual(partial.toolCalls, [])
            XCTAssertEqual(partial.stats?.emittedTokens, 2)
        } catch {
            XCTFail("expected rich inference cancellation, got \(error)")
        }

        do {
            _ = try await run.results.value
            XCTFail("batch results must reject when any prompt is cancelled")
        } catch let QVACError.inferenceCancelled(requestId, partial) {
            XCTAssertEqual(requestId, run.requestId)
            XCTAssertEqual(partial.text, "partial batch")
        } catch {
            XCTFail("expected rich inference cancellation, got \(error)")
        }

        var events: [QVACClient.BatchCompletionEvent] = []
        for try await event in run.events { events.append(event) }
        XCTAssertEqual(events.count, 3)
        XCTAssertTrue(events.contains { event in
            guard case .done(_, let reason, _) = event.event else { return false }
            return reason == .cancelled
        })
        await client.close()
    }

    func test_finetune_stream_forces_progress_request_id_and_requires_terminal_result() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let run = try await client.finetuneStreaming(.init(modelId: "trainable", operation: "start"))
        let frames = try await Self.waitForFrames(2, on: transport)
        let (id, request) = try Self.request(in: frames)
        XCTAssertEqual(request["requestId"] as? String, run.requestId)
        XCTAssertEqual(request["withProgress"] as? Bool, true)

        await Self.feedServerStream(
            id: id,
            records: [
                #"{"type":"finetune:progress","accuracy":0.8,"accuracy_uncertainty":0.1,"current_batch":1,"current_epoch":2,"elapsed_ms":10,"eta_ms":20,"global_steps":3,"is_train":true,"loss":0.2,"loss_uncertainty":0.01,"modelId":"trainable","total_batches":4}"#,
                #"{"type":"finetune","status":"COMPLETED","stats":{"global_steps":3,"epochs_completed":2,"train_loss":0.2}}"#,
            ],
            to: transport
        )
        let result = try await run.result.value
        var progress: [FinetuneProgressResponse] = []
        for try await update in run.progress { progress.append(update) }
        XCTAssertEqual(result.status, "COMPLETED")
        XCTAssertEqual(progress.count, 1)
        XCTAssertEqual(progress.first?.currentEpoch, 2)
        await client.close()
    }

    func test_finetune_rejects_status_outside_pinned_017_contract() async throws {
        do {
            let transport = MockTransport()
            let client = QVACClient(testing: transport)
            let task = Task {
                try await client.finetune(.init(modelId: "trainable", operation: "getState"))
            }
            let frames = try await Self.waitForFrames(1, on: transport)
            let (id, _) = try Self.request(in: frames)
            try await Self.feedReply(
                id: id,
                response: .finetune(.init(status: "completed")),
                to: transport
            )
            do {
                _ = try await task.value
                XCTFail("unary finetune must validate its 0.17 status enum")
            } catch let QVACError.protocolViolation(message) {
                XCTAssertTrue(message.contains("finetune.status"))
                XCTAssertTrue(message.contains("completed"))
            } catch {
                XCTFail("expected protocol violation, got \(error)")
            }
            await client.close()
        }

        do {
            let transport = MockTransport()
            let client = QVACClient(testing: transport)
            let run = try await client.finetuneStreaming(
                .init(modelId: "trainable", operation: "start")
            )
            let frames = try await Self.waitForFrames(2, on: transport)
            let (id, _) = try Self.request(in: frames)
            await Self.feedServerStream(
                id: id,
                records: [#"{"type":"finetune","status":"completed"}"#],
                to: transport
            )
            do {
                _ = try await run.result.value
                XCTFail("streaming finetune must validate its 0.17 status enum")
            } catch let QVACError.protocolViolation(message) {
                XCTAssertTrue(message.contains("finetune.status"))
            } catch {
                XCTFail("expected protocol violation, got \(error)")
            }
            do {
                for try await _ in run.progress {}
                XCTFail("finetune progress must preserve terminal validation failures")
            } catch let QVACError.protocolViolation(message) {
                XCTAssertTrue(message.contains("finetune.status"))
            } catch {
                XCTFail("expected protocol violation, got \(error)")
            }
            await client.close()
        }
    }

    func test_finetune_rejects_stats_and_progress_outside_pinned_017_contract() async throws {
        do {
            let transport = MockTransport()
            let client = QVACClient(testing: transport)
            let task = Task {
                try await client.finetune(.init(modelId: "trainable", operation: "getState"))
            }
            let frames = try await Self.waitForFrames(1, on: transport)
            let (id, _) = try Self.request(in: frames)
            try await Self.feedReply(
                id: id,
                response: .finetune(.init(
                    status: "COMPLETED",
                    stats: .object(["epochs": .number(2)])
                )),
                to: transport
            )
            do {
                _ = try await task.value
                XCTFail("finetune must reject stats outside the strict 0.17 shape")
            } catch let QVACError.protocolViolation(message) {
                XCTAssertTrue(message.contains("finetune.stats"))
            } catch {
                XCTFail("expected protocol violation, got \(error)")
            }
            await client.close()
        }

        let invalidProgressRecords = [
            #"{"type":"finetune:progress","accuracy":0.8,"accuracy_uncertainty":null,"current_batch":-1,"current_epoch":0,"elapsed_ms":10,"eta_ms":20,"global_steps":3,"is_train":true,"loss":0.2,"loss_uncertainty":null,"modelId":"trainable","total_batches":4}"#,
            #"{"type":"finetune:progress","accuracy":{"unexpected":true},"accuracy_uncertainty":null,"current_batch":1,"current_epoch":0,"elapsed_ms":10,"eta_ms":20,"global_steps":3,"is_train":true,"loss":0.2,"loss_uncertainty":null,"modelId":"trainable","total_batches":4}"#,
        ]
        for record in invalidProgressRecords {
            let transport = MockTransport()
            let client = QVACClient(testing: transport)
            let run = try await client.finetuneStreaming(
                .init(modelId: "trainable", operation: "start")
            )
            let frames = try await Self.waitForFrames(2, on: transport)
            let (id, _) = try Self.request(in: frames)
            await Self.feedServerStream(id: id, records: [record], to: transport)

            do {
                _ = try await run.result.value
                XCTFail("finetune accepted invalid 0.17 progress")
            } catch let QVACError.protocolViolation(message) {
                XCTAssertTrue(message.contains("finetune:progress"))
            } catch {
                XCTFail("expected protocol violation, got \(error)")
            }
            do {
                for try await _ in run.progress {}
                XCTFail("the progress view must preserve its validation failure")
            } catch let QVACError.protocolViolation(message) {
                XCTAssertTrue(message.contains("finetune:progress"))
            } catch {
                XCTFail("expected protocol violation, got \(error)")
            }
            await client.close()
        }
    }

    func test_finetune_stream_rejects_unary_operation_before_writing_transport() async {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)

        do {
            _ = try await client.finetuneStreaming(
                .init(modelId: "trainable", operation: "cancel")
            )
            XCTFail("cancel is a unary finetune operation and must not open a progress stream")
        } catch let QVACError.invalidArgument(message) {
            XCTAssertTrue(message.contains("does not satisfy"))
            XCTAssertTrue(message.contains("operation"))
        } catch {
            XCTFail("expected QVACError.invalidArgument, got \(error)")
        }

        let outbound = await transport.outbound()
        XCTAssertTrue(
            Self.frames(in: outbound).isEmpty,
            "invalid conditional-progress calls must fail before writing a request frame"
        )
        await client.close()
    }

    func test_bci_duplex_request_id_options_binary_write_and_terminal_event() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let session = try await client.bciTranscribeStream(
            modelId: "bci-model",
            metadata: true,
            windowTimesteps: 128,
            hopTimesteps: 64,
            emit: "delta",
            rpcOptions: .init(timeout: nil)
        )
        var frames = try await Self.waitForFrames(3, on: transport)
        let (id, request) = try Self.duplexRequest(in: frames)
        XCTAssertEqual(request["requestId"] as? String, session.requestId)
        XCTAssertEqual(request["metadata"] as? Bool, true)
        let options = try XCTUnwrap(request["streamOpts"] as? [String: Any])
        XCTAssertEqual(options["windowTimesteps"] as? Int, 128)
        XCTAssertEqual(options["hopTimesteps"] as? Int, 64)
        XCTAssertEqual(options["emit"] as? String, "delta")

        let neuralChunk = Data([9, 8, 7])
        try await session.write(neuralChunk)
        try await session.end()
        frames = try await Self.waitForFrames(5, on: transport)
        let requestChunks = frames.compactMap { frame -> Data? in
            guard case .stream(_, let flags, .data(let data)) = frame,
                  flags.contains(.request) else { return nil }
            return data
        }
        XCTAssertEqual(requestChunks.last, neuralChunk)
        XCTAssertTrue(frames.contains { frame in
            guard case .stream(_, let flags, .control) = frame else { return false }
            return flags.contains(.request) && flags.contains(.end)
        })

        await Self.feedDuplex(
            id: id,
            records: [
                #"{"type":"bciTranscribeStream","text":"neural"}"#,
                #"{"type":"bciTranscribeStream","done":true,"stats":{"windows":1}}"#,
            ],
            to: transport,
            open: true,
            end: true
        )
        var events: [QVACClient.BciTranscribeStreamEvent] = []
        for try await event in session.events { events.append(event) }
        XCTAssertEqual(events, [
            .text("neural"),
            .done(stats: .object(["windows": .number(1)])),
        ])
        await client.close()
    }

    func test_transcribe_duplex_request_id_current_options_and_conversation_events() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let session = try await client.transcribeStream(
            modelId: "speech-model",
            metadata: true,
            emitVadEvents: true,
            endOfTurnSilenceMs: 400,
            vadRunIntervalMs: 50,
            parakeetStreamingConfig: .object(["leftContext": .number(4)]),
            rpcOptions: .init(timeout: nil)
        )
        let frames = try await Self.waitForFrames(3, on: transport)
        let (id, request) = try Self.duplexRequest(in: frames)
        XCTAssertFalse(session.requestId.isEmpty)
        XCTAssertEqual(request["requestId"] as? String, session.requestId)
        XCTAssertEqual(request["emitVadEvents"] as? Bool, true)
        XCTAssertEqual(request["endOfTurnSilenceMs"] as? Int, 400)
        XCTAssertEqual(request["vadRunIntervalMs"] as? Int, 50)
        XCTAssertNotNil(request["parakeetStreamingConfig"] as? [String: Any])

        try await session.end()
        await Self.feedDuplex(
            id: id,
            records: [
                #"{"type":"transcribeStream","vad":{"speaking":true,"probability":0.9}}"#,
                #"{"type":"transcribeStream","endOfTurn":{"source":"parakeet"}}"#,
                #"{"type":"transcribeStream","text":"hello"}"#,
                #"{"type":"transcribeStream","done":true}"#,
            ],
            to: transport,
            open: true,
            end: true
        )
        var events: [QVACClient.TranscribeStreamEvent] = []
        for try await event in session.events { events.append(event) }
        XCTAssertEqual(events, [
            .vad(.object(["speaking": .bool(true), "probability": .number(0.9)])),
            .endOfTurn(.object(["source": .string("parakeet")])),
            .text("hello"),
            .done,
        ])
        await client.close()
    }

    func test_completion_orchestration_request_id_callback_and_ndjson_tool_result() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let session = try await client.completionOrchestrate(
            modelId: "llm",
            history: [.user("weather")],
            tools: [.object(["name": .string("forecast")])],
            maxToolTurns: 4,
            rpcOptions: .init(timeout: nil)
        )
        var frames = try await Self.waitForFrames(3, on: transport)
        let (id, request) = try Self.duplexRequest(in: frames)
        XCTAssertEqual(request["requestId"] as? String, session.requestId)
        XCTAssertEqual(request["stream"] as? Bool, true)
        XCTAssertEqual(request["maxToolTurns"] as? Int, 4)

        let eventTask = Task { () throws -> [QVACClient.CompletionOrchestrationEvent] in
            var events: [QVACClient.CompletionOrchestrationEvent] = []
            for try await event in session.events {
                events.append(event)
                if case .toolCallback(let callback) = event {
                    try await session.sendToolResult(
                        callId: callback.callId,
                        result: .object(["temperature": .number(21)])
                    )
                }
            }
            return events
        }
        await Self.feedDuplex(
            id: id,
            records: [
                #"{"type":"completionOrchestrate","turn":1,"toolCallback":{"callId":"call-1","name":"forecast","arguments":{"city":"Delhi"}}}"#,
            ],
            to: transport,
            open: true,
            end: false
        )

        frames = try await Self.waitForFrames(4, on: transport)
        let requestChunks = frames.compactMap { frame -> Data? in
            guard case .stream(_, let flags, .data(let data)) = frame,
                  flags.contains(.request) else { return nil }
            return data
        }
        let toolLine = try XCTUnwrap(requestChunks.last)
        XCTAssertEqual(toolLine.last, 0x0A)
        let toolObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: toolLine.dropLast()) as? [String: Any]
        )
        XCTAssertEqual(toolObject["callId"] as? String, "call-1")
        let toolResult = try XCTUnwrap(toolObject["result"] as? [String: Any])
        XCTAssertEqual(toolResult["temperature"] as? Int, 21)

        try await session.end()
        await Self.feedDuplex(
            id: id,
            records: [#"{"type":"completionOrchestrate","done":true}"#],
            to: transport,
            open: false,
            end: true
        )
        let events = try await eventTask.value
        XCTAssertEqual(events.count, 2)
        guard case .toolCallback(let callback) = events[0] else {
            return XCTFail("expected tool callback")
        }
        XCTAssertEqual(callback.callId, "call-1")
        XCTAssertEqual(callback.name, "forecast")
        XCTAssertEqual(callback.arguments["city"], .string("Delhi"))
        XCTAssertEqual(events[1], .done(stopReason: nil))
        await client.close()
    }

    func test_completion_orchestration_drains_profiling_trailer_after_done() async throws {
        let transport = MockTransport()
        let profiling = ProfilingCounter()
        let client = QVACClient(
            testing: transport,
            profilingMetadataHandler: { _ in profiling.increment() }
        )
        let session = try await client.completionOrchestrate(
            modelId: "llm",
            history: [.user("hello")],
            tools: [],
            rpcOptions: .init(timeout: nil, profiling: .init(
                enabled: true,
                includeServerBreakdown: true
            ))
        )
        let frames = try await Self.waitForFrames(3, on: transport)
        let (id, _) = try Self.duplexRequest(in: frames)
        try await session.end()
        await Self.feedDuplex(
            id: id,
            records: [
                #"{"type":"completionOrchestrate","done":true}"#,
                #"{"__profilingTrailer":true,"__profiling":{"id":"duplex-profile"}}"#,
            ],
            to: transport,
            open: true,
            end: true
        )

        var iterator = session.events.makeAsyncIterator()
        let terminalEvent = try await iterator.next()
        XCTAssertEqual(terminalEvent, .done(stopReason: nil))
        XCTAssertEqual(
            profiling.value(),
            1,
            "the trailer must be captured before exposing the terminal event"
        )
        let end = try await iterator.next()
        XCTAssertNil(end)
        XCTAssertEqual(profiling.value(), 1)
        await client.close()
    }

    func test_eager_model_load_drains_profiling_trailer_before_success() async throws {
        let transport = MockTransport()
        let profiling = ProfilingCounter()
        let client = QVACClient(
            testing: transport,
            profilingMetadataHandler: { _ in profiling.increment() }
        )
        let run = try await client.loadModelStreaming(
            modelSrc: "/models/profiled.gguf",
            modelType: "llamacpp-completion",
            rpcOptions: .init(timeout: nil, profiling: .init(
                enabled: true,
                includeServerBreakdown: true
            ))
        )
        let frames = try await Self.waitForFrames(2, on: transport)
        let (id, _) = try Self.request(in: frames)
        await Self.feedServerStream(
            id: id,
            records: [
                #"{"type":"modelProgress","downloaded":25,"downloadKey":"weights","percentage":25,"total":100}"#,
                #"{"type":"loadModel","success":true,"modelId":"profiled-model"}"#,
                #"{"__profilingTrailer":true,"__profiling":{"id":"model-profile"}}"#,
            ],
            to: transport
        )

        let modelId = try await run.result.value
        XCTAssertEqual(modelId, "profiled-model")
        XCTAssertEqual(
            profiling.value(),
            1,
            "model-load success must not resolve before its profiling trailer is captured"
        )
        var progress: [QVACClient.ModelLoadProgress] = []
        for try await update in run.progress { progress.append(update) }
        XCTAssertEqual(progress.map(\.downloaded), [25])
        await client.close()
    }

    func test_eager_model_load_drains_profiling_trailer_before_error_envelope() async throws {
        let transport = MockTransport()
        let profiling = ProfilingCounter()
        let client = QVACClient(
            testing: transport,
            profilingMetadataHandler: { _ in profiling.increment() }
        )
        let run = try await client.loadModelStreaming(
            modelSrc: "/models/failing.gguf",
            modelType: "llamacpp-completion",
            rpcOptions: .init(timeout: nil, profiling: .init(enabled: true))
        )
        let frames = try await Self.waitForFrames(2, on: transport)
        let (id, _) = try Self.request(in: frames)
        await Self.feedServerStream(
            id: id,
            records: [
                #"{"type":"error","code":52200,"message":"load rejected"}"#,
                #"{"__profilingTrailer":true,"__profiling":{"id":"model-error-profile"}}"#,
            ],
            to: transport
        )

        do {
            _ = try await run.result.value
            XCTFail("model-load error envelope must reject")
        } catch let QVACError.server(code, message) {
            XCTAssertEqual(code, .modelLoadFailed)
            XCTAssertEqual(message, "load rejected")
        } catch {
            XCTFail("expected typed model-load failure, got \(error)")
        }
        XCTAssertEqual(
            profiling.value(),
            1,
            "declared stream failure must resolve only after profiling is captured"
        )
        await client.close()
    }

    func test_pull_mapped_error_envelope_drains_profiling_trailer_before_throwing() async throws {
        let transport = MockTransport()
        let profiling = ProfilingCounter()
        let client = QVACClient(
            testing: transport,
            profilingMetadataHandler: { _ in profiling.increment() }
        )
        let stream = try await client.loggingStream(
            id: "__all__",
            rpcOptions: .init(timeout: nil, profiling: .init(enabled: true))
        )
        let frames = try await Self.waitForFrames(2, on: transport)
        let (id, _) = try Self.request(in: frames)
        await Self.feedServerStream(
            id: id,
            records: [
                #"{"type":"error","code":52200.5,"message":"logging rejected"}"#,
                #"{"__profilingTrailer":true,"__profiling":{"id":"logging-error-profile"}}"#,
            ],
            to: transport
        )

        do {
            var iterator = stream.makeAsyncIterator()
            _ = try await iterator.next()
            XCTFail("logging error envelope must reject")
        } catch let QVACError.protocolViolation(message) {
            XCTAssertTrue(message.contains("integer"))
        } catch {
            XCTFail("expected malformed-code protocol violation, got \(error)")
        }
        XCTAssertEqual(
            profiling.value(),
            1,
            "pull-mapped errors must surface only after their profiling trailer is captured"
        )
        await client.close()
    }

    func test_video_malformed_terminal_drains_profiling_trailer_before_validation_error() async throws {
        let transport = MockTransport()
        let profiling = ProfilingCounter()
        let client = QVACClient(
            testing: transport,
            profilingMetadataHandler: { _ in profiling.increment() }
        )
        let run = try await client.video(
            modelId: "video-model",
            mode: "txt2vid",
            prompt: "move",
            rpcOptions: .init(timeout: nil, profiling: .init(enabled: true))
        )
        let frames = try await Self.waitForFrames(2, on: transport)
        let (id, _) = try Self.request(in: frames)
        await Self.feedServerStream(
            id: id,
            records: [
                #"{"type":"videoStream","data":"%%%","done":true}"#,
                #"{"__profilingTrailer":true,"__profiling":{"id":"video-invalid-profile"}}"#,
            ],
            to: transport
        )

        do {
            _ = try await run.outputs.value
            XCTFail("malformed terminal video data must reject")
        } catch {
            assertProtocolViolation(error)
        }
        XCTAssertEqual(profiling.value(), 1)
        await client.close()
    }

    func test_transcribe_malformed_terminal_drains_profiling_trailer_before_validation_error() async throws {
        let transport = MockTransport()
        let profiling = ProfilingCounter()
        let client = QVACClient(
            testing: transport,
            profilingMetadataHandler: { _ in profiling.increment() }
        )
        let run = try await client.transcribe(
            modelId: "asr",
            audioBytes: Data([1, 2]),
            rpcOptions: .init(timeout: nil, profiling: .init(enabled: true))
        )
        let frames = try await Self.waitForFrames(2, on: transport)
        let (id, _) = try Self.request(in: frames)
        await Self.feedServerStream(
            id: id,
            records: [
                #"{"type":"transcribe","segment":{"text":"bad","startMs":0},"done":true}"#,
                #"{"__profilingTrailer":true,"__profiling":{"id":"transcribe-invalid-profile"}}"#,
            ],
            to: transport
        )

        do {
            _ = try await run.result.value
            XCTFail("malformed terminal transcription segment must reject")
        } catch {
            assertProtocolViolation(error)
        }
        XCTAssertEqual(profiling.value(), 1)
        await client.close()
    }

    func test_finetune_drains_profiling_trailer_before_malformed_terminal_error() async throws {
        let transport = MockTransport()
        let profiling = ProfilingCounter()
        let client = QVACClient(
            testing: transport,
            profilingMetadataHandler: { _ in profiling.increment() }
        )
        let run = try await client.finetuneStreaming(
            .init(modelId: "trainable", operation: "start"),
            rpcOptions: .init(timeout: nil, profiling: .init(enabled: true))
        )
        let frames = try await Self.waitForFrames(2, on: transport)
        let (id, _) = try Self.request(in: frames)
        await Self.feedServerStream(
            id: id,
            records: [
                #"{"type":"finetune","status":"COMPLETED","stats":{"global_steps":3}}"#,
                #"{"__profilingTrailer":true,"__profiling":{"id":"finetune-invalid-profile"}}"#,
            ],
            to: transport
        )

        do {
            _ = try await run.result.value
            XCTFail("malformed finetune terminal must reject")
        } catch let QVACError.protocolViolation(message) {
            XCTAssertTrue(message.contains("finetune.stats"))
        } catch {
            XCTFail("expected protocol violation, got \(error)")
        }
        XCTAssertEqual(
            profiling.value(),
            1,
            "terminal validation errors must be reported only after profiling is captured"
        )
        await client.close()
    }

    func test_eager_model_load_rejects_domain_frame_after_terminal() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let run = try await client.loadModelStreaming(
            modelSrc: "/models/model.gguf",
            modelType: "llamacpp-completion"
        )
        let frames = try await Self.waitForFrames(2, on: transport)
        let (id, _) = try Self.request(in: frames)
        await Self.feedServerStream(
            id: id,
            records: [
                #"{"type":"modelProgress","downloaded":50,"downloadKey":"weights","percentage":50,"total":100}"#,
                #"{"type":"loadModel","success":true,"modelId":"terminal-model"}"#,
                #"{"type":"modelProgress","downloaded":100,"downloadKey":"late","percentage":100,"total":100}"#,
            ],
            to: transport
        )

        do {
            _ = try await run.result.value
            XCTFail("a model-load domain frame after terminal must reject the result")
        } catch {
            assertProtocolViolation(error)
        }

        var progress: [QVACClient.ModelLoadProgress] = []
        do {
            for try await update in run.progress { progress.append(update) }
            XCTFail("model-load progress must preserve the post-terminal protocol error")
        } catch {
            assertProtocolViolation(error)
        }
        XCTAssertEqual(
            progress.map(\.downloaded),
            [50],
            "the post-terminal domain frame must be rejected, not exposed as progress"
        )
        await client.close()
    }

    func test_eager_completion_drains_profiling_trailer_before_success() async throws {
        let transport = MockTransport()
        let profiling = ProfilingCounter()
        let client = QVACClient(
            testing: transport,
            profilingMetadataHandler: { _ in profiling.increment() }
        )
        let run = try await client.completion(
            modelId: "llm",
            history: [.user("hello")],
            rpcOptions: .init(timeout: nil, profiling: .init(
                enabled: true,
                includeServerBreakdown: true
            ))
        )
        let frames = try await Self.waitForFrames(2, on: transport)
        let (id, _) = try Self.request(in: frames)
        await Self.feedServerStream(
            id: id,
            records: [
                #"{"type":"completionStream","events":[{"type":"contentDelta","seq":0,"text":"ok"},{"type":"completionDone","seq":1,"stopReason":"eos","raw":{"fullText":"ok"}}],"done":true}"#,
                #"{"__profilingTrailer":true,"__profiling":{"id":"completion-profile"}}"#,
            ],
            to: transport
        )

        let final = try await run.final.value
        XCTAssertEqual(final.contentText, "ok")
        XCTAssertEqual(
            profiling.value(),
            1,
            "completion success must not resolve before its profiling trailer is captured"
        )
        var events: [QVACClient.CompletionEvent] = []
        for try await event in run.events { events.append(event) }
        XCTAssertEqual(events.count, 2)
        var tokens: [String] = []
        for try await token in run.tokenStream { tokens.append(token) }
        XCTAssertEqual(tokens, ["ok"])
        await client.close()
    }

    func test_eager_completion_rejects_domain_frame_after_terminal() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let run = try await client.completion(
            modelId: "llm",
            history: [.user("hello")]
        )
        let frames = try await Self.waitForFrames(2, on: transport)
        let (id, _) = try Self.request(in: frames)
        await Self.feedServerStream(
            id: id,
            records: [
                #"{"type":"completionStream","events":[{"type":"contentDelta","seq":0,"text":"ok"},{"type":"completionDone","seq":1,"stopReason":"eos","raw":{"fullText":"ok"}}],"done":true}"#,
                #"{"type":"completionStream","events":[{"type":"contentDelta","seq":2,"text":"late"}]}"#,
            ],
            to: transport
        )

        do {
            _ = try await run.final.value
            XCTFail("a completion domain frame after terminal must reject the result")
        } catch {
            assertProtocolViolation(error)
        }

        var iterator = run.events.makeAsyncIterator()
        let contentEvent = try await iterator.next()
        let doneEvent = try await iterator.next()
        XCTAssertEqual(contentEvent, .contentDelta(seq: 0, text: "ok"))
        XCTAssertEqual(
            doneEvent,
            .done(seq: 1, stopReason: .eos, rawFullText: "ok")
        )
        do {
            _ = try await iterator.next()
            XCTFail("lossless completion events must terminate with the protocol error")
        } catch {
            assertProtocolViolation(error)
        }
        await client.close()
    }

    func test_terminal_trailer_drain_has_a_finite_deadline() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let request = CompletionOrchestrateRequest(
            history: [],
            modelId: "llm",
            stream: true,
            tools: []
        )
        let raw: QVACDuplexSession<CompletionOrchestrateResponse> = try await client.duplexTyped(
            .completionOrchestrate(request),
            rpcOptions: .init(timeout: nil)
        )
        let frames = try await Self.waitForFrames(3, on: transport)
        let (id, _) = try Self.duplexRequest(in: frames)
        try await raw.end()
        await Self.feedDuplex(
            id: id,
            records: [#"{"type":"completionOrchestrate","done":true}"#],
            to: transport,
            open: true,
            end: false
        )

        let mapped: QVACResponseStream<Bool> = QVACClient.pullMap(
            raw.responses,
            operation: "completionOrchestrate",
            onTermination: { raw.destroy() },
            terminalDrainTimeout: .milliseconds(50)
        ) { frame in
            frame.done == true ? .emitThenDrain([true]) : .skip
        }
        var iterator = mapped.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            XCTFail("done without a profiling trailer or stream end must not hang")
        } catch let error as QVACError {
            guard case .requestTimedOut(let operation, let timeout) = error else {
                return XCTFail("expected requestTimedOut, got \(error)")
            }
            XCTAssertEqual(operation, "completionOrchestrate")
            XCTAssertEqual(timeout, .milliseconds(50))
        }
        try await Self.waitForNoInFlight(await client.rpc)
        await client.close()
    }

    func test_precancelled_pull_mapped_next_does_not_emit_pending_value() async throws {
        let source = QVACResponseStream<Int>(unfolding: { 1 }, onTermination: {})
        let mapped: QVACResponseStream<Int> = QVACClient.pullMap(
            source,
            operation: "precancelledPullMap"
        ) { value in
            .emitMany([value, value + 1])
        }
        let firstConsumed = AsyncGate()
        let releaseSecondRead = AsyncGate()
        let consumer = Task {
            var iterator = mapped.makeAsyncIterator()
            guard try await iterator.next() == 1 else {
                throw QVACError.protocolViolation("pull-map fixture did not emit its first value")
            }
            await firstConsumed.open()
            await releaseSecondRead.wait()
            return try await iterator.next()
        }

        await firstConsumed.wait()
        consumer.cancel()
        await releaseSecondRead.open()
        do {
            let value = try await consumer.value
            XCTFail("pre-cancelled mapped next() emitted buffered value \(String(describing: value))")
        } catch is CancellationError {
            // Expected: cancellation wins over the mapper's buffered second value.
        } catch {
            XCTFail("expected structured cancellation, got \(error)")
        }
        mapped.cancel()
    }

    func test_tts_duplex_done_without_audio_still_drains_profiling_trailer() async throws {
        let transport = MockTransport()
        let profiling = ProfilingCounter()
        let client = QVACClient(
            testing: transport,
            profilingMetadataHandler: { _ in profiling.increment() }
        )
        let session = try await client.textToSpeechStream(
            modelId: "tts-model",
            rpcOptions: .init(timeout: nil, profiling: .init(
                enabled: true,
                includeServerBreakdown: true
            ))
        )
        let frames = try await Self.waitForFrames(3, on: transport)
        let (id, _) = try Self.duplexRequest(in: frames)
        try await session.end()
        await Self.feedDuplex(
            id: id,
            records: [
                #"{"type":"textToSpeechStream","buffer":[],"done":true}"#,
                #"{"__profilingTrailer":true,"__profiling":{"id":"tts-profile"}}"#,
            ],
            to: transport,
            open: true,
            end: true
        )

        var chunks: [QVACClient.TtsStreamChunk] = []
        for try await chunk in session.chunks { chunks.append(chunk) }
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks.first?.buffer, [])
        XCTAssertEqual(chunks.first?.done, true)
        XCTAssertNil(chunks.first?.stats)
        XCTAssertEqual(profiling.value(), 1)
        await client.close()
    }

    func test_completion_orchestration_rejects_domain_frame_after_done() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let session = try await client.completionOrchestrate(
            modelId: "llm",
            history: [.user("hello")],
            tools: [],
            rpcOptions: .init(timeout: nil)
        )
        let frames = try await Self.waitForFrames(3, on: transport)
        let (id, _) = try Self.duplexRequest(in: frames)
        try await session.end()
        await Self.feedDuplex(
            id: id,
            records: [
                #"{"type":"completionOrchestrate","done":true}"#,
                #"{"type":"completionOrchestrate","turn":2,"events":[]}"#,
            ],
            to: transport,
            open: true,
            end: true
        )

        var iterator = session.events.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            XCTFail("a domain response after done must fail before terminal exposure")
        } catch {
            assertProtocolViolation(error)
        }
        await client.close()
    }

    func test_completion_orchestration_rejects_remote_end_without_done() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let session = try await client.completionOrchestrate(
            modelId: "llm",
            history: [.user("hello")],
            tools: [],
            rpcOptions: .init(timeout: nil)
        )
        let frames = try await Self.waitForFrames(3, on: transport)
        let (id, _) = try Self.duplexRequest(in: frames)
        try await session.end()
        await Self.feedDuplex(
            id: id,
            records: [#"{"type":"completionOrchestrate","turn":1,"events":[]}"#],
            to: transport,
            open: true,
            end: true
        )
        do {
            for try await _ in session.events {}
            XCTFail("orchestration must reject a stream without done")
        } catch {
            assertEndedWithoutTerminal(error)
        }
        await client.close()
    }

    func test_generated_wire_request_reply_routes_and_decodes_exact_type() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let replyTask = Task { try await client.wireHeartbeat(.init()) }
        let frames = try await Self.waitForFrames(1, on: transport)
        let (id, request) = try Self.request(in: frames)
        XCTAssertEqual(request["type"] as? String, "heartbeat")
        try await Self.feedReply(
            id: id,
            response: .heartbeat(.init(number: 17)),
            to: transport
        )
        let heartbeat = try await replyTask.value
        XCTAssertEqual(heartbeat.number, 17)
        await client.close()
    }

    func test_generated_wire_progress_stream_enforces_and_routes_manifest_condition() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        var request = LoadModelRequest(modelType: "llama")
        request.modelSrc = "/missing/model.gguf"
        request.modelConfig = .object([:])
        request.withProgress = true

        let stream = try await client.wireLoadModelProgress(request)
        let frames = try await Self.waitForFrames(2, on: transport)
        let (id, wire) = try Self.request(in: frames)
        XCTAssertEqual(wire["type"] as? String, "loadModel")
        XCTAssertEqual(wire["withProgress"] as? Bool, true)
        await Self.feedServerStream(
            id: id,
            records: [
                #"{"type":"modelProgress","downloadKey":"model","downloaded":1,"total":2,"percentage":50}"#,
                #"{"type":"loadModel","success":true,"modelId":"model-17"}"#,
            ],
            to: transport
        )
        var discriminators: [String] = []
        for try await response in stream { discriminators.append(response.discriminator) }
        XCTAssertEqual(discriminators, ["modelProgress", "loadModel"])

        do {
            _ = try await client.wireProgressStream(.heartbeat(.init()))
            XCTFail("heartbeat has no conditional progress transport")
        } catch let QVACError.invalidArgument(message) {
            XCTAssertTrue(message.contains("no conditional progress"))
        }
        await client.close()
    }

    func test_generated_wire_server_stream_routes_and_decodes_exact_type() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let request = CompletionStreamRequest(
            history: [.object(["role": .string("user"), "content": .string("hello")])],
            modelId: "llm",
            stream: true,
            requestId: "request-17"
        )
        let stream = try await client.wireCompletionStream(request)
        let frames = try await Self.waitForFrames(2, on: transport)
        let (id, wire) = try Self.request(in: frames)
        XCTAssertEqual(wire["requestId"] as? String, "request-17")
        await Self.feedServerStream(
            id: id,
            records: [#"{"type":"completionStream","events":[],"done":true}"#],
            to: transport
        )
        var responses: [CompletionStreamResponse] = []
        for try await response in stream { responses.append(response) }
        XCTAssertEqual(responses, [.init(events: [], done: true)])
        await client.close()
    }

    func test_low_level_wire_streams_preserve_error_union_until_explicit_trailer_drain() async throws {
        do {
            let transport = MockTransport()
            let profiling = ProfilingCounter()
            let client = QVACClient(
                testing: transport,
                profilingMetadataHandler: { _ in profiling.increment() }
            )
            let stream = try await client.wireServerStream(
                .completionStream(.init(history: [], modelId: "missing", stream: true)),
                rpcOptions: .init(timeout: nil, profiling: .init(enabled: true))
            )
            let frames = try await Self.waitForFrames(2, on: transport)
            let (id, _) = try Self.request(in: frames)
            await Self.feedServerStream(
                id: id,
                records: [
                    #"{"type":"error","code":52002,"message":"server-stream error"}"#,
                    #"{"__profilingTrailer":true,"__profiling":{"id":"wire-server-error"}}"#,
                ],
                to: transport
            )

            var iterator = stream.makeAsyncIterator()
            guard case .error(let error) = try await iterator.next() else {
                return XCTFail("wireServerStream must preserve the error union case")
            }
            XCTAssertEqual(error.code, 52_002)
            XCTAssertEqual(error.message, "server-stream error")
            XCTAssertEqual(profiling.value(), 0)
            let end = try await iterator.next()
            XCTAssertNil(end)
            XCTAssertEqual(profiling.value(), 1)
            await client.close()
        }

        do {
            let transport = MockTransport()
            let profiling = ProfilingCounter()
            let client = QVACClient(
                testing: transport,
                profilingMetadataHandler: { _ in profiling.increment() }
            )
            var request = LoadModelRequest(modelType: "llama")
            request.modelSrc = "/models/missing.gguf"
            request.modelConfig = .object([:])
            request.withProgress = true
            let stream = try await client.wireProgressStream(
                .loadModel(request),
                rpcOptions: .init(timeout: nil, profiling: .init(enabled: true))
            )
            let frames = try await Self.waitForFrames(2, on: transport)
            let (id, _) = try Self.request(in: frames)
            await Self.feedServerStream(
                id: id,
                records: [
                    #"{"type":"error","code":52200,"message":"progress error"}"#,
                    #"{"__profilingTrailer":true,"__profiling":{"id":"wire-progress-error"}}"#,
                ],
                to: transport
            )

            var iterator = stream.makeAsyncIterator()
            guard case .error(let error) = try await iterator.next() else {
                return XCTFail("wireProgressStream must preserve the error union case")
            }
            XCTAssertEqual(error.code, 52_200)
            XCTAssertEqual(error.message, "progress error")
            XCTAssertEqual(profiling.value(), 0)
            let end = try await iterator.next()
            XCTAssertNil(end)
            XCTAssertEqual(profiling.value(), 1)
            await client.close()
        }

        do {
            let transport = MockTransport()
            let profiling = ProfilingCounter()
            let client = QVACClient(
                testing: transport,
                profilingMetadataHandler: { _ in profiling.increment() }
            )
            let duplex = try await client.wireDuplex(
                .bciTranscribeStream(.init(modelId: "missing")),
                rpcOptions: .init(timeout: nil, profiling: .init(enabled: true))
            )
            let frames = try await Self.waitForFrames(3, on: transport)
            let (id, _) = try Self.duplexRequest(in: frames)
            await Self.feedDuplex(
                id: id,
                records: [
                    #"{"type":"error","code":52002,"message":"duplex error"}"#,
                    #"{"__profilingTrailer":true,"__profiling":{"id":"wire-duplex-error"}}"#,
                ],
                to: transport,
                open: true,
                end: true
            )

            var iterator = duplex.responses.makeAsyncIterator()
            guard case .error(let error) = try await iterator.next() else {
                return XCTFail("wireDuplex must preserve the error union case")
            }
            XCTAssertEqual(error.code, 52_002)
            XCTAssertEqual(error.message, "duplex error")
            XCTAssertEqual(profiling.value(), 0)
            let end = try await iterator.next()
            XCTAssertNil(end)
            XCTAssertEqual(profiling.value(), 1)
            await client.close()
        }
    }

    func test_generated_wire_server_error_drains_profiling_trailer_before_throwing() async throws {
        let transport = MockTransport()
        let profiling = ProfilingCounter()
        let client = QVACClient(
            testing: transport,
            profilingMetadataHandler: { _ in profiling.increment() }
        )
        let stream = try await client.wireCompletionStream(
            .init(
                history: [.object(["role": .string("user"), "content": .string("hello")])],
                modelId: "missing",
                stream: true
            ),
            rpcOptions: .init(timeout: nil, profiling: .init(enabled: true))
        )
        let frames = try await Self.waitForFrames(2, on: transport)
        let (id, _) = try Self.request(in: frames)
        await Self.feedServerStream(
            id: id,
            records: [
                #"{"type":"error","code":52002,"message":"model is unavailable"}"#,
                #"{"__profilingTrailer":true,"__profiling":{"id":"generated-error-profile"}}"#,
            ],
            to: transport
        )

        do {
            var iterator = stream.makeAsyncIterator()
            _ = try await iterator.next()
            XCTFail("generated server stream must surface the worker error")
        } catch let QVACError.server(code, message) {
            XCTAssertEqual(code, .modelNotFound)
            XCTAssertEqual(message, "model is unavailable")
        } catch {
            XCTFail("expected typed worker error, got \(error)")
        }
        XCTAssertEqual(
            profiling.value(),
            1,
            "generated stream errors must resolve only after profiling is captured"
        )
        await client.close()
    }

    func test_generated_wire_server_stream_is_pull_driven_for_slow_consumers() async throws {
        let transport = MockTransport()
        let profiling = ProfilingCounter()
        let client = QVACClient(
            testing: transport,
            profilingMetadataHandler: { _ in profiling.increment() }
        )
        let stream = try await client.wireCompletionStream(.init(
            history: [.object(["role": .string("user"), "content": .string("hello")])],
            modelId: "llm",
            stream: true
        ))
        let frames = try await Self.waitForFrames(2, on: transport)
        let (id, _) = try Self.request(in: frames)
        await Self.feedServerStream(
            id: id,
            records: [
                #"{"type":"completionStream","events":[],"done":false}"#,
                #"{"type":"completionStream","events":[],"done":true,"__profiling":{"id":"second"}}"#,
            ],
            to: transport
        )

        // No eager adapter task may decode ahead of the public consumer.
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(profiling.value(), 0)
        var iterator = stream.makeAsyncIterator()
        let first = try await iterator.next()
        XCTAssertEqual(first?.done, false)
        XCTAssertEqual(profiling.value(), 0)
        let second = try await iterator.next()
        XCTAssertEqual(second?.done, true)
        XCTAssertEqual(profiling.value(), 1)
        let end = try await iterator.next()
        XCTAssertNil(end)
        await client.close()
    }

    func test_generated_wire_server_stream_cancellation_propagates_to_raw_stream() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let stream = try await client.wireCompletionStream(.init(
            history: [.object(["role": .string("user"), "content": .string("hello")])],
            modelId: "llm",
            stream: true
        ))
        _ = try await Self.waitForFrames(2, on: transport)
        let consumer = Task { for try await _ in stream {} }
        await Task.yield()
        consumer.cancel()
        _ = try? await consumer.value

        let rpc = await client.rpc
        try await Self.waitForNoInFlight(rpc)
        let frames = try await Self.waitForFrames(3, on: transport)
        XCTAssertTrue(frames.contains { frame in
            guard case .stream(_, let flags, .control) = frame else { return false }
            return flags.contains(.response) && flags.contains(.destroy)
        })
        await client.close()
    }

    func test_generated_wire_duplex_routes_binary_io_and_decodes_exact_type() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let duplex = try await client.wireBciTranscribeStream(.init(
            modelId: "bci",
            requestId: "request-17"
        ), rpcOptions: .init(timeout: nil))
        var frames = try await Self.waitForFrames(3, on: transport)
        let (id, wire) = try Self.duplexRequest(in: frames)
        XCTAssertEqual(wire["requestId"] as? String, "request-17")

        let chunk = Data([0x01, 0x02])
        try await duplex.write(chunk)
        try await duplex.end()
        frames = try await Self.waitForFrames(5, on: transport)
        XCTAssertTrue(frames.contains { frame in
            guard case .stream(_, let flags, .data(let data)) = frame else { return false }
            return flags.contains(.request) && data == chunk
        })
        await Self.feedDuplex(
            id: id,
            records: [#"{"type":"bciTranscribeStream","text":"signal","done":true}"#],
            to: transport,
            open: true,
            end: true
        )
        var responses: [BciTranscribeStreamResponse] = []
        for try await response in duplex.responses { responses.append(response) }
        XCTAssertEqual(responses, [.init(done: true, text: "signal")])
        await client.close()
    }

    func test_concrete_duplex_error_drains_profiling_trailer_before_throwing() async throws {
        let transport = MockTransport()
        let profiling = ProfilingCounter()
        let client = QVACClient(
            testing: transport,
            profilingMetadataHandler: { _ in profiling.increment() }
        )
        let duplex = try await client.wireBciTranscribeStream(
            .init(modelId: "missing", requestId: "error-request"),
            rpcOptions: .init(timeout: nil, profiling: .init(enabled: true))
        )
        let frames = try await Self.waitForFrames(3, on: transport)
        let (id, _) = try Self.duplexRequest(in: frames)
        await Self.feedDuplex(
            id: id,
            records: [
                #"{"type":"error","code":52002,"message":"duplex model is unavailable"}"#,
                #"{"__profilingTrailer":true,"__profiling":{"id":"duplex-error-profile"}}"#,
            ],
            to: transport,
            open: true,
            end: true
        )

        do {
            var iterator = duplex.responses.makeAsyncIterator()
            _ = try await iterator.next()
            XCTFail("concrete duplex stream must surface the worker error")
        } catch let QVACError.server(code, message) {
            XCTAssertEqual(code, .modelNotFound)
            XCTAssertEqual(message, "duplex model is unavailable")
        } catch {
            XCTFail("expected typed worker error, got \(error)")
        }
        XCTAssertEqual(
            profiling.value(),
            1,
            "concrete duplex errors must resolve only after profiling is captured"
        )
        await client.close()
    }

    func test_generated_wire_router_rejects_mismatched_call_shapes_before_io() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        do {
            _ = try await client.wireRequestReply(.loggingStream(.init(id: "__all__")))
            XCTFail("server-stream method must not route through request/reply")
        } catch let QVACError.invalidArgument(message) {
            XCTAssertTrue(message.contains("server-stream"))
        }
        let outbound = await transport.outbound()
        XCTAssertTrue(outbound.isEmpty)
        await client.close()
    }

    func test_all_39_generated_typed_entry_points_are_publicly_callable() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let invalid = QVACRPCOptions(timeout: .milliseconds(1))
        let value = JSONValue.string("x")
        var exercised: [String] = []

        exercised.append("audioGenStream")
        await assertRejectsTinyTimeout("audioGenStream") {
            _ = try await client.wireAudioGenStream(
                .init(caption: "music", modelId: "m"), rpcOptions: invalid
            )
        }
        exercised.append("batchCompletionStream")
        await assertRejectsTinyTimeout("batchCompletionStream") {
            _ = try await client.wireBatchCompletionStream(
                .init(modelId: "m", prompts: [.object(["history": .array([])])]),
                rpcOptions: invalid
            )
        }
        exercised.append("bciTranscribe")
        await assertRejectsTinyTimeout("bciTranscribe") {
            _ = try await client.wireBciTranscribe(
                .init(
                    modelId: "m",
                    neuralData: .object(["type": .string("base64"), "value": .string("AA==")])
                ),
                rpcOptions: invalid
            )
        }
        exercised.append("bciTranscribeStream")
        await assertRejectsTinyTimeout("bciTranscribeStream") {
            _ = try await client.wireBciTranscribeStream(.init(modelId: "m"), rpcOptions: invalid)
        }
        exercised.append("cancel")
        await assertRejectsTinyTimeout("cancel") {
            _ = try await client.wireCancel(
                .init(operation: "request", requestId: "r"), rpcOptions: invalid
            )
        }
        exercised.append("classify")
        await assertRejectsTinyTimeout("classify") {
            _ = try await client.wireClassify(.init(image: "AA==", modelId: "m"), rpcOptions: invalid)
        }
        exercised.append("completionOrchestrate")
        await assertRejectsTinyTimeout("completionOrchestrate") {
            _ = try await client.wireCompletionOrchestrate(
                .init(history: [], modelId: "m", stream: true), rpcOptions: invalid
            )
        }
        exercised.append("completionStream")
        await assertRejectsTinyTimeout("completionStream") {
            _ = try await client.wireCompletionStream(
                .init(history: [], modelId: "m", stream: true), rpcOptions: invalid
            )
        }
        exercised.append("deleteCache")
        await assertRejectsTinyTimeout("deleteCache") {
            _ = try await client.wireDeleteCache(.init(all: true), rpcOptions: invalid)
        }
        exercised.append("diffusionStream")
        await assertRejectsTinyTimeout("diffusionStream") {
            _ = try await client.wireDiffusionStream(
                .init(modelId: "m", prompt: "p"), rpcOptions: invalid
            )
        }
        exercised.append("downloadAsset")
        await assertRejectsTinyTimeout("downloadAsset") {
            _ = try await client.wireDownloadAsset(
                .init(assetSrc: "https://example.invalid/model"), rpcOptions: invalid
            )
        }
        exercised.append("embed")
        await assertRejectsTinyTimeout("embed") {
            _ = try await client.wireEmbed(.init(modelId: "m", text: value), rpcOptions: invalid)
        }
        exercised.append("finetune")
        await assertRejectsTinyTimeout("finetune") {
            _ = try await client.wireFinetune(.init(modelId: "m"), rpcOptions: invalid)
        }
        exercised.append("getLoadedModelInfo")
        await assertRejectsTinyTimeout("getLoadedModelInfo") {
            _ = try await client.wireGetLoadedModelInfo(.init(modelId: "m"), rpcOptions: invalid)
        }
        exercised.append("getModelInfo")
        await assertRejectsTinyTimeout("getModelInfo") {
            _ = try await client.wireGetModelInfo(.init(name: "m"), rpcOptions: invalid)
        }
        exercised.append("getSystemResources")
        await assertRejectsTinyTimeout("getSystemResources") {
            _ = try await client.wireGetSystemResources(.init(sample: true), rpcOptions: invalid)
        }
        exercised.append("heartbeat")
        await assertRejectsTinyTimeout("heartbeat") {
            _ = try await client.wireHeartbeat(.init(), rpcOptions: invalid)
        }
        exercised.append("loadModel")
        await assertRejectsTinyTimeout("loadModel") {
            _ = try await client.wireLoadModel(
                .init(modelType: "llamacpp-completion"), rpcOptions: invalid
            )
        }
        exercised.append("loggingStream")
        await assertRejectsTinyTimeout("loggingStream") {
            _ = try await client.wireLoggingStream(.init(id: "sdk"), rpcOptions: invalid)
        }
        exercised.append("modelRegistryGetModel")
        await assertRejectsTinyTimeout("modelRegistryGetModel") {
            _ = try await client.wireModelRegistryGetModel(
                .init(registryPath: "org/model", registrySource: "huggingface"),
                rpcOptions: invalid
            )
        }
        exercised.append("modelRegistryList")
        await assertRejectsTinyTimeout("modelRegistryList") {
            _ = try await client.wireModelRegistryList(.init(), rpcOptions: invalid)
        }
        exercised.append("modelRegistrySearch")
        await assertRejectsTinyTimeout("modelRegistrySearch") {
            _ = try await client.wireModelRegistrySearch(
                .init(filter: "model"), rpcOptions: invalid
            )
        }
        exercised.append("ocrStream")
        await assertRejectsTinyTimeout("ocrStream") {
            _ = try await client.wireOcrStream(
                .init(
                    image: .object(["type": .string("base64"), "value": .string("AA==")]),
                    modelId: "m"
                ),
                rpcOptions: invalid
            )
        }
        exercised.append("pluginInvoke")
        await assertRejectsTinyTimeout("pluginInvoke") {
            _ = try await client.wirePluginInvoke(
                .init(handler: "run", modelId: "m", params: value), rpcOptions: invalid
            )
        }
        exercised.append("pluginInvokeStream")
        await assertRejectsTinyTimeout("pluginInvokeStream") {
            _ = try await client.wirePluginInvokeStream(
                .init(handler: "run", modelId: "m", params: value), rpcOptions: invalid
            )
        }
        exercised.append("provide")
        await assertRejectsTinyTimeout("provide") {
            _ = try await client.wireProvide(.init(), rpcOptions: invalid)
        }
        exercised.append("rag")
        await assertRejectsTinyTimeout("rag") {
            _ = try await client.wireRag(.init(operation: "listWorkspaces"), rpcOptions: invalid)
        }
        exercised.append("resume")
        await assertRejectsTinyTimeout("resume") {
            _ = try await client.wireResume(.init(), rpcOptions: invalid)
        }
        exercised.append("state")
        await assertRejectsTinyTimeout("state") {
            _ = try await client.wireState(.init(), rpcOptions: invalid)
        }
        exercised.append("stopProvide")
        await assertRejectsTinyTimeout("stopProvide") {
            _ = try await client.wireStopProvide(.init(), rpcOptions: invalid)
        }
        exercised.append("suspend")
        await assertRejectsTinyTimeout("suspend") {
            _ = try await client.wireSuspend(.init(), rpcOptions: invalid)
        }
        exercised.append("textToSpeech")
        await assertRejectsTinyTimeout("textToSpeech") {
            _ = try await client.wireTextToSpeech(
                .init(modelId: "m", text: "hello"), rpcOptions: invalid
            )
        }
        exercised.append("textToSpeechStream")
        await assertRejectsTinyTimeout("textToSpeechStream") {
            _ = try await client.wireTextToSpeechStream(.init(modelId: "m"), rpcOptions: invalid)
        }
        exercised.append("transcribe")
        await assertRejectsTinyTimeout("transcribe") {
            _ = try await client.wireTranscribe(
                .init(
                    audioChunk: .object(["type": .string("base64"), "value": .string("AA==")]),
                    modelId: "m"
                ),
                rpcOptions: invalid
            )
        }
        exercised.append("transcribeStream")
        await assertRejectsTinyTimeout("transcribeStream") {
            _ = try await client.wireTranscribeStream(.init(modelId: "m"), rpcOptions: invalid)
        }
        exercised.append("translate")
        await assertRejectsTinyTimeout("translate") {
            _ = try await client.wireTranslate(
                .init(
                    modelId: "m",
                    modelType: "nmtcpp-translation",
                    stream: true,
                    text: .one("hello")
                ),
                rpcOptions: invalid
            )
        }
        exercised.append("unloadModel")
        await assertRejectsTinyTimeout("unloadModel") {
            _ = try await client.wireUnloadModel(.init(modelId: "m"), rpcOptions: invalid)
        }
        exercised.append("upscaleStream")
        await assertRejectsTinyTimeout("upscaleStream") {
            _ = try await client.wireUpscaleStream(
                .init(image: "AA==", modelId: "m"), rpcOptions: invalid
            )
        }
        exercised.append("videoStream")
        await assertRejectsTinyTimeout("videoStream") {
            _ = try await client.wireVideoStream(
                .init(mode: "txt2vid", modelId: "m", prompt: "p"), rpcOptions: invalid
            )
        }

        XCTAssertEqual(exercised.count, 39)
        XCTAssertEqual(Set(exercised), Set(QVACSDKContract.methods.map(\.name)))
        let outbound = await transport.outbound()
        XCTAssertTrue(outbound.isEmpty, "local validation must run before transport I/O")
        await client.close()
    }

    func test_load_run_exposes_and_sends_request_id_before_resolution() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let run = try await client.loadModel(
            modelSrc: "/models/model.gguf",
            modelType: "llamacpp-completion"
        )
        let frames = try await Self.waitForFrames(1, on: transport)
        let (id, request) = try Self.request(in: frames)
        XCTAssertFalse(run.requestId.isEmpty)
        XCTAssertEqual(request["requestId"] as? String, run.requestId)
        XCTAssertEqual((request["modelConfig"] as? [String: Any])?.count, 0)
        XCTAssertEqual(request["seed"] as? Bool, false)
        try await Self.feedReply(
            id: id,
            response: .loadModel(.init(success: true, modelId: "model-17")),
            to: transport
        )
        let modelId = try await run.result.value
        XCTAssertEqual(modelId, "model-17")
        var progress: [QVACClient.ModelLoadProgress] = []
        for try await update in run.progress { progress.append(update) }
        XCTAssertTrue(progress.isEmpty)
        await client.close()
    }

    func test_descriptor_load_infers_type_and_preserves_seed_delegate_and_name() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let run = try await client.loadModel(
            modelSrc: .init(
                src: "hf:org/model",
                name: "friendly-name",
                registryPath: "ignored-client-metadata",
                engine: "llamacpp-completion"
            ),
            seed: true,
            delegate: .object(["peerId": .string("desktop-peer")])
        )
        let frames = try await Self.waitForFrames(1, on: transport)
        let (id, request) = try Self.request(in: frames)
        XCTAssertEqual(request["modelSrc"] as? String, "hf:org/model")
        XCTAssertEqual(request["modelName"] as? String, "friendly-name")
        XCTAssertEqual(request["modelType"] as? String, "llamacpp-completion")
        XCTAssertEqual(request["seed"] as? Bool, true)
        XCTAssertEqual(
            (request["delegate"] as? [String: Any])?["peerId"] as? String,
            "desktop-peer"
        )
        XCTAssertNil(request["registryPath"])
        try await Self.feedReply(
            id: id,
            response: .loadModel(.init(success: true, modelId: "model-17")),
            to: transport
        )
        let loadedModelId = try await run.result.value
        XCTAssertEqual(loadedModelId, "model-17")
        await client.close()
    }

    func test_reload_model_config_sends_only_exact_017_reload_fields() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let run = try await client.reloadModelConfig(
            modelId: "0123456789abcdef",
            modelType: "whisper",
            modelConfig: .object(["language": .string("es")])
        )
        let frames = try await Self.waitForFrames(1, on: transport)
        let (id, request) = try Self.request(in: frames)
        XCTAssertFalse(run.requestId.isEmpty)
        XCTAssertEqual(
            Set(request.keys),
            Set(["type", "modelId", "modelType", "modelConfig"])
        )
        XCTAssertEqual(request["modelId"] as? String, "0123456789abcdef")
        XCTAssertEqual(request["modelType"] as? String, "whispercpp-transcription")
        XCTAssertEqual(
            (request["modelConfig"] as? [String: Any])?["language"] as? String,
            "es"
        )
        try await Self.feedReply(
            id: id,
            response: .loadModel(.init(success: true, modelId: "0123456789abcdef")),
            to: transport
        )
        let reloadedModelId = try await run.result.value
        XCTAssertEqual(reloadedModelId, "0123456789abcdef")
        await client.close()
    }

    func test_reload_model_config_rejects_invalid_017_union_before_transport() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)

        do {
            _ = try await client.reloadModelConfig(
                modelId: "MODEL-17",
                modelConfig: .object([:])
            )
            XCTFail("invalid model id must be rejected")
        } catch let QVACError.invalidArgument(message) {
            XCTAssertTrue(message.contains("16 lowercase hexadecimal"))
        }

        do {
            _ = try await client.reloadModelConfig(
                modelId: "0123456789abcdef",
                modelType: "llamacpp-completion",
                modelConfig: .object([:])
            )
            XCTFail("unsupported reload model type must be rejected")
        } catch let QVACError.invalidArgument(message) {
            XCTAssertTrue(message.contains("only supports whispercpp-transcription"))
        }

        let outbound = await transport.outbound()
        XCTAssertTrue(Self.frames(in: outbound).isEmpty)
        await client.close()
    }

    func test_heartbeat_preserves_017_delegate() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let task = Task {
            try await client.heartbeat(delegate: .object(["peerId": .string("peer-17")]))
        }
        let frames = try await Self.waitForFrames(1, on: transport)
        let (id, request) = try Self.request(in: frames)
        XCTAssertEqual(
            (request["delegate"] as? [String: Any])?["peerId"] as? String,
            "peer-17"
        )
        try await Self.feedReply(
            id: id,
            response: .heartbeat(.init(number: 17)),
            to: transport
        )
        let heartbeat = try await task.value
        XCTAssertEqual(heartbeat.number, 17)
        await client.close()
    }

    func test_download_run_exposes_and_sends_request_id_before_resolution() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let run = try await client.downloadAsset(assetSrc: "https://example.invalid/model")
        let frames = try await Self.waitForFrames(1, on: transport)
        let (id, request) = try Self.request(in: frames)
        XCTAssertEqual(request["requestId"] as? String, run.requestId)
        try await Self.feedReply(
            id: id,
            response: .downloadAsset(.init(success: true, assetId: "asset-17")),
            to: transport
        )
        let assetId = try await run.result.value
        XCTAssertEqual(assetId, "asset-17")
        await client.close()
    }

    func test_embed_run_exposes_request_id_and_preserves_stats() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let run = try await client.embed(modelId: "embed-model", text: "hello")
        let frames = try await Self.waitForFrames(1, on: transport)
        let (id, request) = try Self.request(in: frames)
        XCTAssertEqual(request["requestId"] as? String, run.requestId)
        try await Self.feedReply(
            id: id,
            response: .embed(.init(
                embedding: .array([.number(0.25), .number(0.75)]),
                success: true,
                stats: .object(["tokens": .number(1)])
            )),
            to: transport
        )
        let outcome = try await run.result.value
        XCTAssertEqual(outcome.embedding, [0.25, 0.75])
        XCTAssertEqual(outcome.stats, .object(["tokens": .number(1)]))
        await client.close()
    }

    func test_rag_decorated_unary_and_progress_runs_send_request_ids() async throws {
        let unaryTransport = MockTransport()
        let unaryClient = QVACClient(testing: unaryTransport)
        let ingest = try await unaryClient.ragIngest(
            modelId: "embed-model",
            documents: [.init("hello")]
        )
        var frames = try await Self.waitForFrames(1, on: unaryTransport)
        var (id, request) = try Self.request(in: frames)
        XCTAssertEqual(request["requestId"] as? String, ingest.requestId)
        XCTAssertEqual(request["chunk"] as? Bool, true)
        XCTAssertNil(request["withProgress"])
        try await Self.feedReply(
            id: id,
            response: .rag(.init(
                operation: "ingest",
                success: true,
                droppedIndices: [],
                processed: [.object([
                    "status": .string("fulfilled"),
                    "id": .string("doc-1"),
                ])]
            )),
            to: unaryTransport
        )
        let ingestResult = try await ingest.result.value
        XCTAssertEqual(ingestResult.processed.count, 1)
        XCTAssertEqual(ingestResult.processed.first?.status, .fulfilled)
        XCTAssertEqual(ingestResult.processed.first?.id, "doc-1")
        await unaryClient.close()

        let streamTransport = MockTransport()
        let streamClient = QVACClient(testing: streamTransport)
        let reindex = try await streamClient.ragReindex(
            modelId: "embed-model",
            workspace: "docs",
            withProgress: true
        )
        frames = try await Self.waitForFrames(2, on: streamTransport)
        (id, request) = try Self.request(in: frames)
        XCTAssertEqual(request["requestId"] as? String, reindex.requestId)
        XCTAssertEqual(request["modelId"] as? String, "embed-model")
        XCTAssertEqual(request["withProgress"] as? Bool, true)
        XCTAssertNil(request["progressInterval"])
        await Self.feedServerStream(
            id: id,
            records: [
                #"{"type":"rag:progress","operation":"reindex","stage":"cluster","current":1,"total":2,"timestamp":17,"workspace":"docs"}"#,
                #"{"type":"rag","operation":"reindex","success":true,"result":{"reindexed":true}}"#,
            ],
            to: streamTransport
        )
        var progress: [RagProgressResponse] = []
        for try await update in reindex.progress { progress.append(update) }
        XCTAssertEqual(progress.count, 1)
        XCTAssertEqual(progress.first?.stage, "cluster")
        let reindexResult = try await reindex.result.value
        XCTAssertTrue(reindexResult.reindexed)
        XCTAssertNil(reindexResult.details)
        await streamClient.close()
    }

    func test_rag_rich_results_use_exact_017_content_shapes_and_search_defaults() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)

        let chunkTask = Task {
            try await client.ragChunk(documents: ["hello world"])
        }
        var frames = try await Self.waitForFrames(1, on: transport)
        var (id, request) = try Self.request(in: frames)
        XCTAssertEqual(request["documents"] as? [String], ["hello world"])
        try await Self.feedReply(
            id: id,
            response: .rag(.init(
                operation: "chunk",
                success: true,
                chunks: [.object([
                    "id": .string("chunk-1"),
                    "content": .string("hello world"),
                ])]
            )),
            to: transport
        )
        let chunks = try await chunkTask.value
        XCTAssertEqual(chunks.first?.id, "chunk-1")
        XCTAssertEqual(chunks.first?.content, "hello world")

        let searchTask = Task {
            try await client.ragSearch(modelId: "embed", query: "hello")
        }
        let priorFrameCount = frames.count
        frames = try await Self.waitForFrames(priorFrameCount + 1, on: transport)
        (id, request) = try Self.request(in: Array(frames.dropFirst(priorFrameCount)))
        XCTAssertEqual(request["topK"] as? Int, 5)
        XCTAssertEqual(request["n"] as? Int, 3)
        try await Self.feedReply(
            id: id,
            response: .rag(.init(
                operation: "search",
                success: true,
                results: [.object([
                    "id": .string("chunk-1"),
                    "content": .string("hello world"),
                    "score": .number(0.75),
                ])]
            )),
            to: transport
        )
        let results = try await searchTask.value
        XCTAssertEqual(results.first?.content, "hello world")
        XCTAssertEqual(results.first?.score, 0.75)

        await client.close()
    }

    func test_bursty_model_progress_coalesces_to_newest_window_and_result_resolves() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let run = try await client.loadModelStreaming(
            modelSrc: "/models/model.gguf",
            modelType: "llamacpp-completion"
        )
        let frames = try await Self.waitForFrames(2, on: transport)
        let (id, _) = try Self.request(in: frames)
        let emittedCount = QVACClient.publicProgressBufferCapacity * 3 + 7
        var records = (0..<emittedCount).map { index in
            let key = index.isMultiple(of: 2) ? "weights" : "tokenizer"
            return #"{"type":"modelProgress","downloaded":\#(index),"downloadKey":"\#(key)","percentage":\#(index),"total":\#(emittedCount),"shardInfo":{"currentShard":1,"totalShards":2,"shardName":"model-00001-of-00002.gguf","overallDownloaded":\#(index),"overallTotal":\#(emittedCount),"overallPercentage":\#(index)},"fileSetInfo":{"setKey":"model-files","currentFile":"tokenizer.json","fileIndex":1,"totalFiles":2,"overallDownloaded":\#(index),"overallTotal":\#(emittedCount),"overallPercentage":\#(index)}}"#
        }
        records.append(#"{"type":"loadModel","success":true,"modelId":"model-after-burst"}"#)
        await Self.feedServerStream(id: id, records: records, to: transport)
        let modelId = try await run.result.value
        XCTAssertEqual(modelId, "model-after-burst")

        var progress: [QVACClient.ModelLoadProgress] = []
        for try await update in run.progress { progress.append(update) }
        XCTAssertEqual(progress.count, QVACClient.publicProgressBufferCapacity)
        XCTAssertEqual(
            progress.map(\.downloaded),
            (emittedCount - QVACClient.publicProgressBufferCapacity..<emittedCount)
                .map { Double($0) }
        )
        XCTAssertEqual(
            progress.map(\.downloadKey),
            (emittedCount - QVACClient.publicProgressBufferCapacity..<emittedCount)
                .map { $0.isMultiple(of: 2) ? "weights" : "tokenizer" }
        )
        XCTAssertEqual(progress.last?.shardInfo?.currentShard, 1)
        XCTAssertEqual(progress.last?.shardInfo?.totalShards, 2)
        XCTAssertEqual(progress.last?.shardInfo?.shardName, "model-00001-of-00002.gguf")
        XCTAssertEqual(progress.last?.shardInfo?.overallDownloaded, Double(emittedCount - 1))
        XCTAssertEqual(progress.last?.fileSetInfo?.setKey, "model-files")
        XCTAssertEqual(progress.last?.fileSetInfo?.currentFile, "tokenizer.json")
        XCTAssertEqual(progress.last?.fileSetInfo?.fileIndex, 1)
        XCTAssertEqual(progress.last?.fileSetInfo?.totalFiles, 2)
        XCTAssertEqual(progress.last?.fileSetInfo?.overallDownloaded, Double(emittedCount - 1))
        let rpc = await client.rpc
        try await Self.waitForNoInFlight(rpc)
        await client.close()
    }

    func test_model_progress_metadata_requires_known_fields_and_ignores_extensions() throws {
        let shard = try QVACClient.ModelShardProgress(wire: .object([
            "currentShard": .number(1),
            "totalShards": .number(2),
            "shardName": .string("model-00001-of-00002.gguf"),
            "overallDownloaded": .number(50),
            "overallTotal": .number(100),
            "overallPercentage": .number(50),
        ]))
        XCTAssertEqual(shard.currentShard, 1)
        XCTAssertEqual(shard.shardName, "model-00001-of-00002.gguf")

        XCTAssertThrowsError(try QVACClient.ModelShardProgress(wire: .object([
            "currentShard": .number(1),
            "totalShards": .number(2),
        ]))) { error in
            guard case QVACError.protocolViolation(let message) = error else {
                return XCTFail("expected protocolViolation, got \(error)")
            }
            XCTAssertTrue(message.contains("shardName must be a string"))
        }

        let fileSet = try QVACClient.ModelFileSetProgress(wire: .object([
            "setKey": .string("model-files"),
            "currentFile": .string("tokenizer.json"),
            "fileIndex": .number(1),
            "totalFiles": .number(2),
            "overallDownloaded": .number(50),
            "overallTotal": .number(100),
            "overallPercentage": .number(50),
            "unexpected": .bool(true),
        ]))
        XCTAssertEqual(fileSet.setKey, "model-files")
        XCTAssertEqual(fileSet.currentFile, "tokenizer.json")
        XCTAssertEqual(fileSet.fileIndex, 1)
        XCTAssertEqual(fileSet.totalFiles, 2)
    }

    func test_bursty_asset_progress_coalesces_without_hiding_terminal_result() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let run = try await client.downloadAssetStreaming(
            assetSrc: "https://example.invalid/model"
        )
        let frames = try await Self.waitForFrames(2, on: transport)
        let (id, _) = try Self.request(in: frames)
        let emittedCount = QVACClient.publicProgressBufferCapacity * 2 + 3
        var records = (0..<emittedCount).map { index in
            #"{"type":"modelProgress","downloaded":\#(index),"downloadKey":"asset","percentage":\#(index),"total":\#(emittedCount)}"#
        }
        records.append(
            #"{"type":"downloadAsset","success":true,"assetId":"asset-after-burst"}"#
        )
        await Self.feedServerStream(id: id, records: records, to: transport)

        let assetId = try await run.result.value
        XCTAssertEqual(assetId, "asset-after-burst")
        var progress: [QVACClient.ModelLoadProgress] = []
        for try await update in run.progress { progress.append(update) }
        XCTAssertEqual(progress.count, QVACClient.publicProgressBufferCapacity)
        XCTAssertEqual(
            progress.map(\.downloaded),
            (emittedCount - QVACClient.publicProgressBufferCapacity..<emittedCount)
                .map { Double($0) }
        )
        XCTAssertEqual(progress.last?.downloaded, Double(emittedCount - 1))
        let rpc = await client.rpc
        try await Self.waitForNoInFlight(rpc)
        await client.close()
    }

    func test_model_progress_preserves_missing_terminal_error_at_eof() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let run = try await client.loadModelStreaming(
            modelSrc: "/models/model.gguf",
            modelType: "llamacpp-completion"
        )
        let frames = try await Self.waitForFrames(2, on: transport)
        let (id, _) = try Self.request(in: frames)
        await Self.feedServerStream(
            id: id,
            records: [
                #"{"type":"modelProgress","downloaded":1,"downloadKey":"model","percentage":1,"total":100}"#,
            ],
            to: transport
        )

        do {
            _ = try await run.result.value
            XCTFail("loadModel must reject EOF without its terminal response")
        } catch let QVACError.protocolViolation(message) {
            XCTAssertEqual(message, "loadModel stream ended without resolution")
        } catch {
            XCTFail("expected protocol violation, got \(error)")
        }

        var progress: [QVACClient.ModelLoadProgress] = []
        do {
            for try await update in run.progress { progress.append(update) }
            XCTFail("model progress must preserve the missing-terminal error")
        } catch let QVACError.protocolViolation(message) {
            XCTAssertEqual(message, "loadModel stream ended without resolution")
        } catch {
            XCTFail("expected protocol violation, got \(error)")
        }
        XCTAssertEqual(progress.map(\.downloaded), [1])
        let rpc = await client.rpc
        try await Self.waitForNoInFlight(rpc)
        await client.close()
    }

    func test_asset_progress_preserves_missing_terminal_error_at_eof() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let run = try await client.downloadAssetStreaming(
            assetSrc: "https://example.invalid/model"
        )
        let frames = try await Self.waitForFrames(2, on: transport)
        let (id, _) = try Self.request(in: frames)
        await Self.feedServerStream(
            id: id,
            records: [
                #"{"type":"modelProgress","downloaded":1,"downloadKey":"asset","percentage":1,"total":100}"#,
            ],
            to: transport
        )

        do {
            _ = try await run.result.value
            XCTFail("downloadAsset must reject EOF without its terminal response")
        } catch let QVACError.protocolViolation(message) {
            XCTAssertEqual(message, "downloadAsset stream ended without resolution")
        } catch {
            XCTFail("expected protocol violation, got \(error)")
        }

        var progress: [QVACClient.ModelLoadProgress] = []
        do {
            for try await update in run.progress { progress.append(update) }
            XCTFail("asset progress must preserve the missing-terminal error")
        } catch let QVACError.protocolViolation(message) {
            XCTAssertEqual(message, "downloadAsset stream ended without resolution")
        } catch {
            XCTFail("expected protocol violation, got \(error)")
        }
        XCTAssertEqual(progress.map(\.downloaded), [1])
        let rpc = await client.rpc
        try await Self.waitForNoInFlight(rpc)
        await client.close()
    }

    func test_batched_lossless_fanout_overflow_preserves_complete_accepted_batches() async throws {
        let maximumBytes = 4_096
        let (stream, sink) = QVACClient.makeBufferedStream(
            of: Int.self,
            name: "batched-lossless-test",
            maximumBufferedBytes: maximumBytes
        )
        for batch in 0...QVACClient.publicStreamBufferCapacity {
            sink.yield(
                contentsOf: [batch * 2, batch * 2 + 1],
                estimatedBytes: 2 * MemoryLayout<Int>.stride
            )
        }
        sink.finish()

        var received: [Int] = []
        do {
            for try await value in stream { received.append(value) }
            XCTFail("the 65th queued producer batch must overflow")
        } catch let overflow as QVACStreamBufferOverflow {
            XCTAssertEqual(overflow.stream, "batched-lossless-test")
            XCTAssertEqual(overflow.capacity, QVACClient.publicStreamBufferCapacity)
            XCTAssertEqual(overflow.maximumBufferedBytes, maximumBytes)
            XCTAssertEqual(
                overflow.attemptedBufferedBytes,
                (QVACClient.publicStreamBufferCapacity + 1)
                    * 2 * MemoryLayout<Int>.stride
            )
        }
        XCTAssertEqual(
            received,
            Array(0..<(QVACClient.publicStreamBufferCapacity * 2)),
            "overflow must reject the entire next batch, never a partial batch"
        )
    }

    func test_batched_lossless_fanout_releases_each_consumed_batch_immediately() async throws {
        let (stream, sink) = QVACClient.makeBufferedStream(
            of: BufferedPayloadProbe.self,
            name: "batch-release-test",
            maximumBufferedBytes: 1_024
        )
        var producerReference: BufferedPayloadProbe? = .init()
        weak let lifetimeProbe = producerReference
        sink.yield(contentsOf: [try XCTUnwrap(producerReference)], estimatedBytes: 1)
        producerReference = nil

        var iterator = stream.makeAsyncIterator()
        var consumed = try await iterator.next()
        XCTAssertTrue(consumed === lifetimeProbe)
        consumed = nil
        XCTAssertNil(
            lifetimeProbe,
            "a consumed payload must not remain retained in an unaccounted queue slot"
        )

        sink.finish()
        let end = try await iterator.next()
        XCTAssertNil(end)
    }

    func test_batched_lossless_fanout_rejects_oversized_batch_with_active_waiter() async throws {
        let maximumBytes = 8
        let channel = QVACBufferedStreamChannel<Int>(
            streamName: "active-waiter-byte-limit-test",
            maximumBufferedBatches: QVACClient.publicStreamBufferCapacity,
            maximumBufferedBytes: maximumBytes
        )
        let consumer = Task { try await channel.next() }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while !channel.hasPendingWaiterForTesting() {
            guard clock.now < deadline else {
                consumer.cancel()
                return XCTFail("consumer did not register its pending next() in time")
            }
            try await Task.sleep(for: .milliseconds(1))
        }

        switch channel.yield([1, 2], estimatedBytes: maximumBytes + 1) {
        case .overflowed:
            break
        case .enqueued, .coalesced, .terminated:
            XCTFail("an oversized batch must overflow even when a consumer is already waiting")
        }

        do {
            _ = try await consumer.value
            XCTFail("the waiting consumer must receive the byte-limit overflow")
        } catch let overflow as QVACStreamBufferOverflow {
            XCTAssertEqual(overflow.stream, "active-waiter-byte-limit-test")
            XCTAssertEqual(overflow.capacity, QVACClient.publicStreamBufferCapacity)
            XCTAssertEqual(overflow.maximumBufferedBytes, maximumBytes)
            XCTAssertEqual(overflow.attemptedBufferedBytes, maximumBytes + 1)
        }
    }

    func test_batched_lossless_fanout_enforces_single_consumer_without_poisoning_first() async throws {
        let (stream, sink) = QVACClient.makeBufferedStream(
            of: Int.self,
            name: "single-consumer-test",
            maximumBufferedBytes: 1_024
        )
        var first = stream.makeAsyncIterator()
        var second = stream.makeAsyncIterator()
        do {
            _ = try await second.next()
            XCTFail("a second QVACBufferedStream iterator must fail")
        } catch let QVACError.protocolViolation(message) {
            XCTAssertTrue(message.contains("exactly one iterator"))
        }

        sink.yield(contentsOf: [1, 2, 3], estimatedBytes: 24)
        sink.finish()
        let firstValue = try await first.next()
        let secondValue = try await first.next()
        let thirdValue = try await first.next()
        let end = try await first.next()
        XCTAssertEqual(firstValue, 1)
        XCTAssertEqual(secondValue, 2)
        XCTAssertEqual(thirdValue, 3)
        XCTAssertNil(end)
    }

    func test_batched_lossless_fanout_iterator_copies_share_one_cursor_and_lease() async throws {
        let (stream, sink) = QVACClient.makeBufferedStream(
            of: Int.self,
            name: "copied-iterator-test",
            maximumBufferedBytes: 1_024
        )
        sink.yield(contentsOf: [1, 2, 3], estimatedBytes: 24)
        sink.finish()

        var original = stream.makeAsyncIterator()
        let first = try await original.next()
        XCTAssertEqual(first, 1)
        XCTAssertEqual(sink.retainedBytesForTesting(), 24)

        var copy = original
        let second = try await copy.next()
        let third = try await original.next()
        XCTAssertEqual(second, 2)
        XCTAssertEqual(third, 3)
        XCTAssertEqual(
            sink.retainedBytesForTesting(),
            0,
            "one shared cursor must acknowledge the producer batch exactly once"
        )
        let copyEnd = try await copy.next()
        let originalEnd = try await original.next()
        XCTAssertNil(copyEnd)
        XCTAssertNil(originalEnd)
    }

    func test_batched_lossless_fanout_counts_queued_and_partially_consumed_bytes() async throws {
        let maximumBytes = 10
        let (stream, sink) = QVACClient.makeBufferedStream(
            of: Int.self,
            name: "queued-in-flight-byte-limit-test",
            maximumBufferedBytes: maximumBytes
        )
        guard case .enqueued = sink.yield(contentsOf: [1, 2], estimatedBytes: 6) else {
            return XCTFail("the first batch must be accepted")
        }
        guard case .enqueued = sink.yield(contentsOf: [3], estimatedBytes: 4) else {
            return XCTFail("the second batch must fill the remaining budget")
        }
        XCTAssertEqual(sink.retainedBytesForTesting(), maximumBytes)

        var iterator = stream.makeAsyncIterator()
        let first = try await iterator.next()
        XCTAssertEqual(first, 1)
        XCTAssertEqual(
            sink.retainedBytesForTesting(),
            maximumBytes,
            "dequeue must transfer the batch's byte lease to the iterator"
        )

        guard case .overflowed = sink.yield(contentsOf: [4], estimatedBytes: 1) else {
            return XCTFail("queued plus partially consumed bytes must enforce the shared budget")
        }
        XCTAssertEqual(sink.retainedBytesForTesting(), maximumBytes)

        let second = try await iterator.next()
        XCTAssertEqual(second, 2)
        XCTAssertEqual(sink.retainedBytesForTesting(), 4)
        let third = try await iterator.next()
        XCTAssertEqual(third, 3)
        XCTAssertEqual(sink.retainedBytesForTesting(), 0)
        do {
            _ = try await iterator.next()
            XCTFail("the rejected batch must leave the stream terminally overflowed")
        } catch let overflow as QVACStreamBufferOverflow {
            XCTAssertEqual(overflow.stream, "queued-in-flight-byte-limit-test")
            XCTAssertEqual(overflow.maximumBufferedBytes, maximumBytes)
            XCTAssertEqual(overflow.attemptedBufferedBytes, maximumBytes + 1)
        }
    }

    func test_batched_lossless_fanout_counts_direct_handoff_until_cancellation() async throws {
        let maximumBytes = 8
        let (stream, sink) = QVACClient.makeBufferedStream(
            of: Int.self,
            name: "direct-in-flight-byte-limit-test",
            maximumBufferedBytes: maximumBytes
        )
        let holder = BufferedIteratorHolder(stream)
        let firstValue = Task { try await holder.next() }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while !sink.hasPendingWaiterForTesting() {
            guard clock.now < deadline else {
                firstValue.cancel()
                return XCTFail("consumer did not register its pending next() in time")
            }
            try await Task.sleep(for: .milliseconds(1))
        }

        guard case .enqueued = sink.yield(contentsOf: [1, 2], estimatedBytes: 6) else {
            return XCTFail("a direct-handoff batch within budget must be accepted")
        }
        let first = try await firstValue.value
        XCTAssertEqual(first, 1)
        XCTAssertEqual(
            sink.retainedBytesForTesting(),
            6,
            "direct delivery must remain charged while the iterator holds the batch tail"
        )
        guard case .overflowed = sink.yield(contentsOf: [3], estimatedBytes: 3) else {
            return XCTFail("a partial direct-handoff batch must count toward overflow")
        }
        XCTAssertEqual(sink.retainedBytesForTesting(), 6)

        let gate = AsyncGate()
        let canceledNext = Task {
            await gate.wait()
            return try await holder.next()
        }
        canceledNext.cancel()
        await gate.open()
        do {
            _ = try await canceledNext.value
            XCTFail("the canceled iterator must reject its unconsumed batch tail")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(
            sink.retainedBytesForTesting(),
            0,
            "iterator cancellation must release its in-flight byte lease"
        )
    }

    func test_batched_lossless_fanout_drop_releases_in_flight_payload_and_bytes() async throws {
        let (stream, sink) = QVACClient.makeBufferedStream(
            of: BufferedPayloadProbe.self,
            name: "dropped-in-flight-byte-lease-test",
            maximumBufferedBytes: 8
        )
        var firstReference: BufferedPayloadProbe? = .init()
        var secondReference: BufferedPayloadProbe? = .init()
        weak let firstLifetime = firstReference
        weak let secondLifetime = secondReference
        sink.yield(
            contentsOf: [
                try XCTUnwrap(firstReference),
                try XCTUnwrap(secondReference),
            ],
            estimatedBytes: 6
        )
        firstReference = nil
        secondReference = nil

        let holder = BufferedIteratorHolder(stream)
        var first = try await holder.next()
        XCTAssertTrue(first === firstLifetime)
        first = nil
        XCTAssertNotNil(firstLifetime)
        XCTAssertNotNil(secondLifetime)
        XCTAssertEqual(sink.retainedBytesForTesting(), 6)

        holder.drop()
        XCTAssertNil(firstLifetime)
        XCTAssertNil(secondLifetime)
        XCTAssertEqual(sink.retainedBytesForTesting(), 0)
        guard case .terminated = sink.yield(contentsOf: [.init()], estimatedBytes: 1) else {
            return XCTFail("dropping the only iterator must terminate the producer sink")
        }
    }

    func test_coalescing_progress_stream_retains_newest_count_bounded_window() async throws {
        let capacity = QVACClient.publicProgressBufferCapacity
        let (stream, sink) = QVACClient.makeCoalescingProgressStream(
            of: Int.self,
            name: "count-bounded-progress-test",
            maximumBufferedBytes: 1_024
        )
        for value in 0...capacity {
            let result = sink.yield(contentsOf: [value], estimatedBytes: 1)
            if value < capacity {
                guard case .enqueued = result else {
                    return XCTFail("snapshots within the count window must be enqueued")
                }
            } else {
                guard case .coalesced = result else {
                    return XCTFail("the oldest snapshot must be evicted at the count limit")
                }
            }
        }
        sink.finish()

        var received: [Int] = []
        for try await value in stream { received.append(value) }
        XCTAssertEqual(received, Array(1...capacity))
        XCTAssertEqual(sink.retainedBytesForTesting(), 0)
    }

    func test_coalescing_progress_stream_evicts_oldest_until_byte_budget_fits() async throws {
        let (stream, sink) = QVACClient.makeCoalescingProgressStream(
            of: Int.self,
            name: "byte-bounded-progress-test",
            maximumBufferedBytes: 10
        )
        guard case .enqueued = sink.yield(contentsOf: [0], estimatedBytes: 4) else {
            return XCTFail("the first progress snapshot must be accepted")
        }
        guard case .enqueued = sink.yield(contentsOf: [1], estimatedBytes: 4) else {
            return XCTFail("the second progress snapshot must be accepted")
        }
        guard case .coalesced = sink.yield(contentsOf: [2], estimatedBytes: 4) else {
            return XCTFail("the oldest snapshot must be evicted to satisfy the byte budget")
        }
        XCTAssertEqual(sink.retainedBytesForTesting(), 8)
        guard case .coalesced = sink.yield(contentsOf: [3], estimatedBytes: 7) else {
            return XCTFail("multiple old snapshots must be evicted when necessary")
        }
        XCTAssertEqual(sink.retainedBytesForTesting(), 7)
        sink.finish()

        var received: [Int] = []
        for try await value in stream { received.append(value) }
        XCTAssertEqual(received, [3])
        XCTAssertEqual(sink.retainedBytesForTesting(), 0)
    }

    func test_coalescing_progress_stream_does_not_fail_or_evict_queued_snapshots_behind_in_flight_lease() async throws {
        let (stream, sink) = QVACClient.makeCoalescingProgressStream(
            of: Int.self,
            name: "in-flight-coalescing-progress-test",
            maximumBufferedBytes: 10
        )
        guard case .enqueued = sink.yield(contentsOf: [0, 1], estimatedBytes: 7) else {
            return XCTFail("the first progress batch must be accepted")
        }
        guard case .enqueued = sink.yield(contentsOf: [2], estimatedBytes: 3) else {
            return XCTFail("the queued snapshot must fill the remaining budget")
        }

        var iterator = stream.makeAsyncIterator()
        let first = try await iterator.next()
        XCTAssertEqual(first, 0)
        XCTAssertEqual(sink.retainedBytesForTesting(), 10)

        guard case .coalesced = sink.yield(contentsOf: [3], estimatedBytes: 4) else {
            return XCTFail("an incoming observation blocked by an active lease must coalesce")
        }
        XCTAssertEqual(
            sink.retainedBytesForTesting(),
            10,
            "coalescing must preserve the active lease and already-accepted queue"
        )

        sink.finish()
        let second = try await iterator.next()
        let queued = try await iterator.next()
        let end = try await iterator.next()
        XCTAssertEqual(second, 1)
        XCTAssertEqual(queued, 2)
        XCTAssertNil(end)
        XCTAssertEqual(sink.retainedBytesForTesting(), 0)
    }

    func test_coalescing_progress_stream_rejects_single_oversized_snapshot() async throws {
        let maximumBytes = 8
        let (stream, sink) = QVACClient.makeCoalescingProgressStream(
            of: Int.self,
            name: "oversized-progress-test",
            maximumBufferedBytes: maximumBytes
        )
        guard case .enqueued = sink.yield(contentsOf: [1], estimatedBytes: 4) else {
            return XCTFail("the initial progress snapshot must be accepted")
        }
        guard case .overflowed = sink.yield(contentsOf: [2], estimatedBytes: 9) else {
            return XCTFail("one indivisible snapshot larger than the byte budget must fail")
        }
        XCTAssertEqual(
            sink.retainedBytesForTesting(),
            4,
            "rejecting an oversized snapshot must preserve previously accepted snapshots"
        )

        var iterator = stream.makeAsyncIterator()
        let first = try await iterator.next()
        XCTAssertEqual(first, 1)
        do {
            _ = try await iterator.next()
            XCTFail("the coalescing view must explicitly report an indivisible oversized snapshot")
        } catch let overflow as QVACStreamBufferOverflow {
            XCTAssertEqual(overflow.stream, "oversized-progress-test")
            XCTAssertEqual(overflow.capacity, QVACClient.publicProgressBufferCapacity)
            XCTAssertEqual(overflow.maximumBufferedBytes, maximumBytes)
            XCTAssertEqual(overflow.attemptedBufferedBytes, 13)
        }
        XCTAssertEqual(sink.retainedBytesForTesting(), 0)
    }

    func test_buffered_json_retained_size_accounts_for_all_value_shapes() {
        let nodeBytes = MemoryLayout<JSONValue>.stride
        let nullBytes = QVACBufferedJSONRetainedSizeEstimator.estimate(.null)
        let boolBytes = QVACBufferedJSONRetainedSizeEstimator.estimate(.bool(true))
        let numberBytes = QVACBufferedJSONRetainedSizeEstimator.estimate(.number(42))
        let stringBytes = QVACBufferedJSONRetainedSizeEstimator.estimate(.string("payload"))
        let emptyArrayBytes = QVACBufferedJSONRetainedSizeEstimator.estimate(.array([]))
        let arrayBytes = QVACBufferedJSONRetainedSizeEstimator.estimate(
            .array([.null, .bool(false), .number(1), .string("value")])
        )
        let emptyObjectBytes = QVACBufferedJSONRetainedSizeEstimator.estimate(.object([:]))
        let shortKeyObjectBytes = QVACBufferedJSONRetainedSizeEstimator.estimate(
            .object(["k": .null])
        )
        let longKeyObjectBytes = QVACBufferedJSONRetainedSizeEstimator.estimate(
            .object([String(repeating: "k", count: 1_024): .null])
        )
        let batchBytes = QVACBufferedJSONRetainedSizeEstimator.estimate([
            .null,
            .bool(true),
            .number(1),
            .string("value"),
        ])

        XCTAssertGreaterThan(nullBytes, nodeBytes)
        XCTAssertGreaterThan(boolBytes, nodeBytes)
        XCTAssertGreaterThan(numberBytes, boolBytes)
        XCTAssertGreaterThan(stringBytes, numberBytes)
        XCTAssertGreaterThan(emptyArrayBytes, nullBytes)
        XCTAssertGreaterThan(arrayBytes, emptyArrayBytes)
        XCTAssertGreaterThan(emptyObjectBytes, nullBytes)
        XCTAssertGreaterThan(shortKeyObjectBytes, emptyObjectBytes)
        XCTAssertGreaterThan(longKeyObjectBytes, shortKeyObjectBytes)
        XCTAssertGreaterThan(
            batchBytes,
            QVACBufferedJSONRetainedSizeEstimator.saturatingAdd(
                QVACBufferedJSONRetainedSizeEstimator.saturatingAdd(
                    nullBytes,
                    boolBytes
                ),
                QVACBufferedJSONRetainedSizeEstimator.saturatingAdd(
                    numberBytes,
                    QVACBufferedJSONRetainedSizeEstimator.estimate(.string("value"))
                )
            )
        )
    }

    func test_buffered_json_estimate_accounts_for_deep_container_trees() throws {
        let depth = 128
        var nested: JSONValue = .null
        for _ in 0..<depth { nested = .array([nested]) }

        let encodedBytes = try JSONEncoder.qvac.encode(nested).count
        let encodedOnlyEstimate = QVACBufferedJSONRetainedSizeEstimator.saturatingAdd(
            QVACBufferedJSONRetainedSizeEstimator.saturatingMultiply(encodedBytes, 2),
            128
        )
        let retainedEstimate = QVACBufferedJSONRetainedSizeEstimator.estimate(nested)
        let combinedEstimate = QVACClient.conservativeBufferedJSONBytes(
            nested,
            elementCount: 1,
            fallback: 1
        )
        let retainedBatchEstimate = QVACBufferedJSONRetainedSizeEstimator.estimate([nested])
        let combinedBatchEstimate = QVACClient.conservativeBufferedJSONBytes(
            [nested],
            elementCount: 0,
            fallback: 1
        )

        XCTAssertGreaterThan(retainedEstimate, encodedOnlyEstimate)
        XCTAssertGreaterThanOrEqual(combinedEstimate, retainedEstimate)
        XCTAssertGreaterThan(retainedBatchEstimate, retainedEstimate)
        XCTAssertGreaterThanOrEqual(combinedBatchEstimate, retainedBatchEstimate)

        var excessiveNesting: JSONValue = .null
        for _ in 0...QVACBufferedJSONRetainedSizeEstimator.maximumNestingDepth {
            excessiveNesting = .array([excessiveNesting])
        }
        XCTAssertEqual(
            QVACBufferedJSONRetainedSizeEstimator.estimate(excessiveNesting),
            Int.max
        )
        XCTAssertEqual(
            QVACClient.conservativeBufferedJSONBytes(
                excessiveNesting,
                elementCount: 1,
                fallback: 4_096
            ),
            Int.max,
            "structural saturation must happen before attempting JSON encoding"
        )
    }

    func test_buffered_json_estimate_saturates_and_preserves_safe_fallback() {
        XCTAssertEqual(
            QVACBufferedJSONRetainedSizeEstimator.saturatingAdd(Int.max, 1),
            Int.max
        )
        XCTAssertEqual(
            QVACBufferedJSONRetainedSizeEstimator.saturatingMultiply(Int.max, 2),
            Int.max
        )
        XCTAssertEqual(
            QVACClient.conservativeBufferedJSONBytes(
                ["value"],
                elementCount: Int.max,
                fallback: 1
            ),
            Int.max
        )
        XCTAssertEqual(
            QVACClient.conservativeBufferedJSONBytes(
                RejectingEncodableProbe(),
                elementCount: 1,
                fallback: 4_096
            ),
            4_097,
            "an unmeasurable payload must exceed, not exactly fill, its buffer budget"
        )
    }

    func test_model_progress_preserves_terminal_failure_after_burst() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let run = try await client.loadModelStreaming(
            modelSrc: "/models/model.gguf",
            modelType: "llamacpp-completion"
        )
        let frames = try await Self.waitForFrames(2, on: transport)
        let (id, _) = try Self.request(in: frames)
        let emittedCount = QVACClient.publicProgressBufferCapacity + 11
        var records = (0..<emittedCount).map { index in
            #"{"type":"modelProgress","downloaded":\#(index),"downloadKey":"model","percentage":\#(index),"total":\#(emittedCount)}"#
        }
        records.append(
            #"{"type":"loadModel","success":false,"error":"checksum mismatch"}"#
        )
        await Self.feedServerStream(id: id, records: records, to: transport)

        do {
            _ = try await run.result.value
            XCTFail("the authoritative result must preserve the worker failure")
        } catch let error as QVACError {
            guard case .server(let code, let message) = error else {
                return XCTFail("unexpected result error: \(error)")
            }
            XCTAssertEqual(code, .modelLoadFailed)
            XCTAssertEqual(message, "checksum mismatch")
        }

        var progress: [QVACClient.ModelLoadProgress] = []
        do {
            for try await update in run.progress { progress.append(update) }
            XCTFail("progress must end with the authoritative worker failure")
        } catch let error as QVACError {
            guard case .server(let code, let message) = error else {
                return XCTFail("unexpected progress error: \(error)")
            }
            XCTAssertEqual(code, .modelLoadFailed)
            XCTAssertEqual(message, "checksum mismatch")
        }
        XCTAssertEqual(progress.count, QVACClient.publicProgressBufferCapacity)
        XCTAssertEqual(progress.last?.downloaded, Double(emittedCount - 1))
        let rpc = await client.rpc
        try await Self.waitForNoInFlight(rpc)
        await client.close()
    }

    func test_model_progress_preserves_malformed_terminal_error_after_burst() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let run = try await client.loadModelStreaming(
            modelSrc: "/models/model.gguf",
            modelType: "llamacpp-completion"
        )
        let frames = try await Self.waitForFrames(2, on: transport)
        let (id, _) = try Self.request(in: frames)
        var records = (0...QVACClient.publicProgressBufferCapacity).map { index in
            #"{"type":"modelProgress","downloaded":\#(index),"downloadKey":"model","percentage":\#(index),"total":100}"#
        }
        records.append(#"{"type":"loadModel","success":true}"#)
        await Self.feedServerStream(id: id, records: records, to: transport)

        do {
            _ = try await run.result.value
            XCTFail("a successful terminal response without modelId must fail")
        } catch let QVACError.protocolViolation(message) {
            XCTAssertTrue(message.contains("missing modelId"))
        }

        var progress: [QVACClient.ModelLoadProgress] = []
        do {
            for try await update in run.progress { progress.append(update) }
            XCTFail("progress must preserve the malformed-terminal error")
        } catch let QVACError.protocolViolation(message) {
            XCTAssertTrue(message.contains("missing modelId"))
        }
        XCTAssertEqual(progress.count, QVACClient.publicProgressBufferCapacity)
        XCTAssertEqual(progress.first?.downloaded, 1)
        XCTAssertEqual(
            progress.last?.downloaded,
            Double(QVACClient.publicProgressBufferCapacity)
        )
        let rpc = await client.rpc
        try await Self.waitForNoInFlight(rpc)
        await client.close()
    }

    func test_cancelling_progress_observer_does_not_cancel_authoritative_result() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let run = try await client.loadModelStreaming(
            modelSrc: "/models/model.gguf",
            modelType: "llamacpp-completion"
        )
        let frames = try await Self.waitForFrames(2, on: transport)
        let (id, _) = try Self.request(in: frames)

        let observer = Task { for try await _ in run.progress {} }
        await Task.yield()
        observer.cancel()
        _ = try? await observer.value

        await Self.feedServerStream(
            id: id,
            records: [
                #"{"type":"modelProgress","downloaded":100,"downloadKey":"model","percentage":100,"total":100}"#,
                #"{"type":"loadModel","success":true,"modelId":"model-after-observer-cancel"}"#,
            ],
            to: transport
        )
        let modelId = try await run.result.value
        XCTAssertEqual(modelId, "model-after-observer-cancel")
        let rpc = await client.rpc
        try await Self.waitForNoInFlight(rpc)
        await client.close()
    }

    func test_unload_keeps_017_connection_open_for_followup_requests() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let unloadTask = Task { try await client.unloadModel(modelId: "model-17") }
        var frames = try await Self.waitForFrames(1, on: transport)
        var (id, request) = try Self.request(in: frames)
        XCTAssertEqual(request["type"] as? String, "unloadModel")
        try await Self.feedReply(
            id: id,
            response: .unloadModel(.init(
                success: true,
                hasActiveModels: false,
                hasActiveProviders: false
            )),
            to: transport
        )
        _ = try await unloadTask.value

        let heartbeatTask = Task { try await client.heartbeat() }
        frames = try await Self.waitForFrames(2, on: transport)
        let requests = frames.compactMap { frame -> (UInt64, [String: Any])? in
            guard case .request(let requestId, _, _, .some(let data)) = frame,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return (requestId, object)
        }
        (id, request) = try XCTUnwrap(requests.last)
        XCTAssertEqual(request["type"] as? String, "heartbeat")
        try await Self.feedReply(
            id: id,
            response: .heartbeat(.init(number: 18)),
            to: transport
        )
        let heartbeat = try await heartbeatTask.value
        XCTAssertEqual(heartbeat.number, 18)
        await client.close()
    }

    func test_unload_auto_close_closes_only_after_last_model_and_provider() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let unloadTask = Task {
            try await client.unloadModel(modelId: "model-17", autoClose: true)
        }
        let frames = try await Self.waitForFrames(1, on: transport)
        let (id, _) = try Self.request(in: frames)
        try await Self.feedReply(
            id: id,
            response: .unloadModel(.init(
                success: true,
                hasActiveModels: false,
                hasActiveProviders: false
            )),
            to: transport
        )
        _ = try await unloadTask.value
        let isClosed = await transport.isClosed()
        XCTAssertTrue(isClosed)
    }

    func test_completion_terminal_success_drains_closed_raw_stream_without_leak() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let run = try await client.completion(modelId: "llm", history: [.user("hello")])
        let frames = try await Self.waitForFrames(2, on: transport)
        let (id, _) = try Self.request(in: frames)
        await Self.feedServerStream(
            id: id,
            records: [#"{"type":"completionStream","events":[],"done":true}"#],
            to: transport
        )
        _ = try await run.final.value
        let rpc = await client.rpc
        try await Self.waitForNoInFlight(rpc)
        await client.close()
    }

    func test_orchestration_outer_event_cancellation_destroys_both_halves_without_leak() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let session = try await client.completionOrchestrate(
            modelId: "llm",
            history: [.user("weather")],
            tools: [],
            rpcOptions: .init(timeout: nil)
        )
        _ = try await Self.waitForFrames(3, on: transport)
        let consumer = Task { for try await _ in session.events {} }
        await Task.yield()
        consumer.cancel()
        _ = try? await consumer.value

        let rpc = await client.rpc
        try await Self.waitForNoInFlight(rpc)
        let frames = try await Self.waitForFrames(5, on: transport)
        XCTAssertTrue(frames.contains { frame in
            guard case .stream(_, let flags, .control) = frame else { return false }
            return flags.contains(.request) && flags.contains(.close)
        })
        XCTAssertTrue(frames.contains { frame in
            guard case .stream(_, let flags, .control) = frame else { return false }
            return flags.contains(.response) && flags.contains(.destroy)
        })
        await client.close()
    }

    func test_duplex_outer_event_cancellation_destroys_both_halves_without_leak() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let session = try await client.bciTranscribeStream(
            modelId: "bci-model",
            rpcOptions: .init(timeout: nil)
        )
        _ = try await Self.waitForFrames(3, on: transport)
        let consumer = Task {
            for try await _ in session.events {}
        }
        await Task.yield()
        consumer.cancel()
        _ = try? await consumer.value

        let rpc = await client.rpc
        try await Self.waitForNoInFlight(rpc)
        let frames = try await Self.waitForFrames(5, on: transport)
        XCTAssertTrue(frames.contains { frame in
            guard case .stream(_, let flags, .control) = frame else { return false }
            return flags.contains(.request) && flags.contains(.close)
        })
        XCTAssertTrue(frames.contains { frame in
            guard case .stream(_, let flags, .control) = frame else { return false }
            return flags.contains(.response) && flags.contains(.destroy)
        })
        await client.close()
    }

    func test_mapped_server_stream_cancellation_propagates_to_raw_stream() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let stream = try await client.invokePluginStream(
            modelId: "plugin-model",
            handler: "events",
            params: ["probe": true],
            as: JSONValue.self
        )
        _ = try await Self.waitForFrames(2, on: transport)
        let consumer = Task {
            for try await _ in stream {}
        }
        await Task.yield()
        consumer.cancel()
        _ = try? await consumer.value

        let rpc = await client.rpc
        try await Self.waitForNoInFlight(rpc)
        let frames = try await Self.waitForFrames(3, on: transport)
        XCTAssertTrue(frames.contains { frame in
            guard case .stream(_, let flags, .control) = frame else { return false }
            return flags.contains(.response) && flags.contains(.destroy)
        })
        await client.close()
    }

    func test_logging_mapped_stream_cancellation_propagates_to_raw_stream() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let stream = try await client.loggingStream(id: "__all__")
        _ = try await Self.waitForFrames(2, on: transport)
        let consumer = Task { for try await _ in stream {} }
        await Task.yield()
        consumer.cancel()
        _ = try? await consumer.value

        let rpc = await client.rpc
        try await Self.waitForNoInFlight(rpc)
        let frames = try await Self.waitForFrames(3, on: transport)
        XCTAssertTrue(frames.contains { frame in
            guard case .stream(_, let flags, .control) = frame else { return false }
            return flags.contains(.response) && flags.contains(.destroy)
        })
        await client.close()
    }

    func test_split_result_task_cancellation_releases_raw_stream() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let run = try await client.video(
            modelId: "video-model",
            mode: "txt2vid",
            prompt: "long running"
        )
        _ = try await Self.waitForFrames(2, on: transport)
        run.outputs.cancel()
        _ = try? await run.outputs.value

        let rpc = await client.rpc
        try await Self.waitForNoInFlight(rpc)
        let frames = try await Self.waitForFrames(3, on: transport)
        XCTAssertTrue(frames.contains { frame in
            guard case .stream(_, let flags, .control) = frame else { return false }
            return flags.contains(.response) && flags.contains(.destroy)
        })
        await client.close()
    }

    func test_batch_result_cancellation_releases_raw_stream_and_all_promises() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let run = try await client.batchCompletion(
            modelId: "llm",
            prompts: [.init(id: "one", history: [.user("long running")])]
        )
        _ = try await Self.waitForFrames(2, on: transport)
        run.results.cancel()
        do {
            _ = try await run.results.value
            XCTFail("a cancelled batch result task must throw CancellationError")
        } catch is CancellationError {
            // Expected: caller cancellation must not be rewritten as a protocol error.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        _ = try? await run.ids.value
        _ = try? await run.stats.value

        let rpc = await client.rpc
        try await Self.waitForNoInFlight(rpc)
        let frames = try await Self.waitForFrames(3, on: transport)
        XCTAssertTrue(frames.contains { frame in
            guard case .stream(_, let flags, .control) = frame else { return false }
            return flags.contains(.response) && flags.contains(.destroy)
        })
        await client.close()
    }

    func test_batch_late_by_id_preserves_original_stream_failure() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let run = try await client.batchCompletion(
            modelId: "llm",
            prompts: [.init(id: "one", history: [.user("hello")])]
        )
        let frames = try await Self.waitForFrames(2, on: transport)
        let (id, _) = try Self.request(in: frames)
        await Self.feedServerStream(
            id: id,
            records: [#"{"type":"heartbeat","number":1}"#],
            to: transport
        )

        do {
            _ = try await run.results.value
            XCTFail("batch results must preserve the unexpected-response failure")
        } catch let QVACError.protocolViolation(message) {
            XCTAssertTrue(message.contains("returned heartbeat"))
        } catch {
            XCTFail("expected protocol violation, got \(error)")
        }

        let late = run.byId("one")
        do {
            _ = try await late.final.value
            XCTFail("late byId final must receive the original stream failure")
        } catch let QVACError.protocolViolation(message) {
            XCTAssertTrue(message.contains("returned heartbeat"))
        } catch {
            XCTFail("expected protocol violation, got \(error)")
        }
        do {
            for try await _ in late.events {}
            XCTFail("late byId events must receive the original stream failure")
        } catch let QVACError.protocolViolation(message) {
            XCTAssertTrue(message.contains("returned heartbeat"))
        } catch {
            XCTFail("expected protocol violation, got \(error)")
        }
        await client.close()
    }

    func test_batch_unknown_by_id_lookups_do_not_accumulate_coordinator_state() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let run = try await client.batchCompletion(
            modelId: "llm",
            prompts: [.init(history: [.user("hello")])]
        )
        XCTAssertEqual(run.__testPerIDStateCount(), 0)

        for index in 0..<100 {
            let unknown = run.byId("unknown-\(index)")
            do {
                _ = try await unknown.final.value
                XCTFail("unknown byId lookup must reject")
            } catch let QVACError.server(code, _) {
                XCTAssertEqual(code, .completionFailed)
            } catch {
                XCTFail("expected completionFailed, got \(error)")
            }
        }
        XCTAssertEqual(
            run.__testPerIDStateCount(),
            0,
            "arbitrary unknown ids must not be retained by the coordinator"
        )

        let frames = try await Self.waitForFrames(2, on: transport)
        let (id, _) = try Self.request(in: frames)
        await Self.feedServerStream(
            id: id,
            records: [
                #"{"type":"batchCompletionStream","ids":["batch-1"],"events":[]}"#,
                #"{"type":"batchCompletionStream","events":[{"id":"batch-1","event":{"type":"completionDone","seq":0}}],"done":true}"#,
            ],
            to: transport
        )
        let ids = try await run.ids.value
        let final = try await run.byId("batch-1").final.value
        XCTAssertEqual(ids, ["batch-1"])
        XCTAssertEqual(final.contentText, "")
        XCTAssertEqual(run.__testPerIDStateCount(), 1)
        await client.close()
    }

    func test_vla_uses_exact_plugin_shape_and_little_endian_tensors() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let task = Task {
            try await client.vla(.init(
                modelId: "vla-model",
                images: [[1, -2, 0.5]],
                imageWidth: 1,
                imageHeight: 1,
                state: [1.5, -2],
                tokens: [1, -2, 0x01020304],
                mask: [0, 255, 1],
                noise: [Float(bitPattern: 0x8000_0000), 3.25]
            ))
        }
        let frames = try await Self.waitForFrames(1, on: transport)
        let (id, request) = try Self.request(in: frames)
        XCTAssertEqual(request["type"] as? String, "pluginInvoke")
        XCTAssertEqual(request["modelId"] as? String, "vla-model")
        XCTAssertEqual(request["handler"] as? String, "vlaRun")
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["type"] as? String, "vlaRun")
        XCTAssertEqual(params["modelId"] as? String, "vla-model")
        XCTAssertEqual(params["images"] as? [String], ["AACAPwAAAMAAAAA/"])
        XCTAssertEqual(params["state"] as? String, "AADAPwAAAMA=")
        XCTAssertEqual(params["tokens"] as? String, "AQAAAP7///8EAwIB")
        XCTAssertEqual(params["mask"] as? String, "AP8B")
        XCTAssertEqual(params["noise"] as? String, "AAAAgAAAUEA=")

        try await Self.feedReply(
            id: id,
            response: .pluginInvoke(.init(result: .object([
                "actions": .string("AACAPwAAAMAAAAA/"),
                "actionDim": .number(3),
                "chunkSize": .number(1),
                "stats": .object([
                    "vision_ms": .number(2.5),
                    "backendDevice": .number(1),
                ]),
            ]))),
            to: transport
        )
        let result = try await task.value
        XCTAssertEqual(result.actions, [1, -2, 0.5])
        XCTAssertEqual(result.actionDimension, 3)
        XCTAssertEqual(result.chunkSize, 1)
        XCTAssertEqual(result.stats?.visionMs, 2.5)
        XCTAssertEqual(result.stats?.backendDevice, 1)
        await client.close()
    }

    func test_vla_hparams_uses_exact_plugin_shape_and_typed_result() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let task = Task { try await client.vlaHparams(modelId: "vla-model") }
        let frames = try await Self.waitForFrames(1, on: transport)
        let (id, request) = try Self.request(in: frames)
        XCTAssertEqual(request["handler"] as? String, "vlaHparams")
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["type"] as? String, "vlaHparams")
        XCTAssertEqual(params["modelId"] as? String, "vla-model")

        try await Self.feedReply(
            id: id,
            response: .pluginInvoke(.init(result: .object([
                "hparams": .object([
                    "chunkSize": .number(8),
                    "actionDim": .number(7),
                    "maxActionDim": .number(32),
                    "maxStateDim": .number(32),
                    "tokenizerMaxLength": .number(48),
                    "visionImageSize": .number(512),
                    "numCameras": .number(2),
                    "stateInputMode": .string("continuous"),
                    "imageInputMode": .string("pixels"),
                ]),
                "backendName": .string("Metal"),
            ]))),
            to: transport
        )
        let result = try await task.value
        XCTAssertEqual(result.backendName, "Metal")
        XCTAssertEqual(result.hyperparameters.chunkSize, 8)
        XCTAssertEqual(result.hyperparameters.actionDimension, 7)
        XCTAssertEqual(result.hyperparameters.numberOfCameras, 2)
        XCTAssertEqual(result.hyperparameters.stateInputMode, .continuous)
        XCTAssertEqual(result.hyperparameters.imageInputMode, .pixels)
        await client.close()
    }

    func test_rich_wrappers_validate_integer_fields_without_narrowing_numeric_rag_indices() async throws {
        do {
            let transport = MockTransport()
            let client = QVACClient(testing: transport)
            let run = try await client.completion(modelId: "llm", history: [.user("hello")])
            let frames = try await Self.waitForFrames(2, on: transport)
            let (id, _) = try Self.request(in: frames)
            await Self.feedServerStream(
                id: id,
                records: [
                    #"{"type":"completionStream","events":[{"type":"contentDelta","seq":1e100,"text":"unsafe"}],"done":true}"#,
                ],
                to: transport
            )
            do {
                _ = try await run.final.value
                XCTFail("huge completion seq must be rejected")
            } catch { assertProtocolViolation(error) }
            await client.close()
        }

        do {
            let transport = MockTransport()
            let client = QVACClient(testing: transport)
            let run = try await client.transcribeWithMetadata(
                modelId: "speech",
                audioPath: "/tmp/probe.wav"
            )
            let frames = try await Self.waitForFrames(2, on: transport)
            let (id, _) = try Self.request(in: frames)
            await Self.feedServerStream(
                id: id,
                records: [
                    #"{"type":"transcribe","segment":{"id":1,"text":"unsafe","startMs":1.5,"endMs":2},"done":true}"#,
                ],
                to: transport
            )
            do {
                _ = try await run.result.value
                XCTFail("fractional segment timestamp must be rejected")
            } catch { assertProtocolViolation(error) }
            await client.close()
        }

        do {
            let transport = MockTransport()
            let client = QVACClient(testing: transport)
            let run = try await client.ragIngest(
                modelId: "embed",
                documents: [.init("probe")]
            )
            let frames = try await Self.waitForFrames(1, on: transport)
            let (id, _) = try Self.request(in: frames)
            try await Self.feedReply(
                id: id,
                response: .rag(.init(
                    operation: "ingest",
                    success: true,
                    droppedIndices: [1.25],
                    processed: []
                )),
                to: transport
            )
            let result = try await run.result.value
            XCTAssertEqual(result.droppedIndices, [1.25])
            await client.close()
        }

        do {
            let transport = MockTransport()
            let client = QVACClient(testing: transport)
            let run = try await client.audioGen(modelId: "audio", caption: "probe")
            let frames = try await Self.waitForFrames(2, on: transport)
            let (id, _) = try Self.request(in: frames)
            await Self.feedServerStream(
                id: id,
                records: [
                    #"{"type":"audioGenStream","progress":{"stage":"denoise","step":1e100,"total":2},"done":false}"#,
                ],
                to: transport
            )
            do {
                _ = try await run.audio.value
                XCTFail("huge AudioGen progress step must be rejected")
            } catch { assertProtocolViolation(error) }
            await client.close()
        }
    }
}
