import XCTest
@testable import QVACClient

/// Protocol-level tests for the public operations added with the published 0.17.0
/// contract. These run through the real typed client and bare-rpc multiplexer; only
/// the byte transport is replaced with an in-memory peer.
final class QVACSDK017OperationSemanticsTests: XCTestCase {
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

        nonisolated func inboundStream() -> AsyncThrowingStream<Data, Error> {
            inbound.stream
        }

        func write(_ data: Data) async throws {
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
            history: [.user("hello")],
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
                #"{"type":"audioGenStream","data":"\#(second.base64EncodedString())","sampleRate":48000,"channels":2,"bitsPerSample":16,"done":true}"#,
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
                #"{"type":"finetune","status":"completed","stats":{"epochs":2}}"#,
            ],
            to: transport
        )
        let result = try await run.result.value
        var progress: [FinetuneProgressResponse] = []
        for try await update in run.progress { progress.append(update) }
        XCTAssertEqual(result.status, "completed")
        XCTAssertEqual(progress.count, 1)
        XCTAssertEqual(progress.first?.currentEpoch, 2)
        await client.close()
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
            emit: "delta"
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
            parakeetStreamingConfig: .object(["leftContext": .number(4)])
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
            maxToolTurns: 4
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

    func test_completion_orchestration_rejects_remote_end_without_done() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let session = try await client.completionOrchestrate(
            modelId: "llm",
            history: [.user("hello")],
            tools: []
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
        ))
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

    func test_unconsumed_progress_overflow_is_explicit_but_result_still_resolves() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let run = try await client.loadModelStreaming(
            modelSrc: "/models/model.gguf",
            modelType: "llamacpp-completion"
        )
        let frames = try await Self.waitForFrames(2, on: transport)
        let (id, _) = try Self.request(in: frames)
        var records = (0...QVACClient.publicStreamBufferCapacity).map { index in
            #"{"type":"modelProgress","downloaded":\#(index),"downloadKey":"model","percentage":1,"total":100}"#
        }
        records.append(#"{"type":"loadModel","success":true,"modelId":"model-after-overflow"}"#)
        await Self.feedServerStream(id: id, records: records, to: transport)
        let modelId = try await run.result.value
        XCTAssertEqual(modelId, "model-after-overflow")
        do {
            for try await _ in run.progress {}
            XCTFail("the lagging progress view must report its bounded-buffer overflow")
        } catch let overflow as QVACStreamBufferOverflow {
            XCTAssertEqual(overflow.capacity, QVACClient.publicStreamBufferCapacity)
        }
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

    func test_completion_terminal_success_destroys_still_open_raw_stream() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let run = try await client.completion(modelId: "llm", history: [.user("hello")])
        let frames = try await Self.waitForFrames(2, on: transport)
        let (id, _) = try Self.request(in: frames)
        await Self.feedServerStream(
            id: id,
            records: [#"{"type":"completionStream","events":[],"done":true}"#],
            to: transport,
            end: false
        )
        _ = try await run.final.value
        let rpc = await client.rpc
        try await Self.waitForNoInFlight(rpc)
        let teardownFrames = try await Self.waitForFrames(3, on: transport)
        XCTAssertTrue(teardownFrames.contains { frame in
            guard case .stream(_, let flags, .control) = frame else { return false }
            return flags.contains(.response) && flags.contains(.destroy)
        })
        await client.close()
    }

    func test_orchestration_outer_event_cancellation_destroys_both_halves_without_leak() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let session = try await client.completionOrchestrate(
            modelId: "llm",
            history: [.user("weather")],
            tools: []
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
        let session = try await client.bciTranscribeStream(modelId: "bci-model")
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
        _ = try? await run.results.value
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

    func test_rich_wrappers_reject_fractional_and_huge_wire_integers_without_trapping() async throws {
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
            do {
                _ = try await run.result.value
                XCTFail("fractional RAG dropped index must be rejected")
            } catch { assertProtocolViolation(error) }
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
