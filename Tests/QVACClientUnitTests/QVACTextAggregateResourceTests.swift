import Foundation
import XCTest
@testable import QVACClient

/// Resource-safety contracts for eager text aggregators.
///
/// Every fixture traverses the production request encoder, bare-rpc multiplexer,
/// NDJSON decoder, terminal drain, and public adapter. The in-memory peer controls
/// only transport bytes, which makes cumulative-limit and teardown races
/// deterministic without requiring a model.
final class QVACTextAggregateResourceTests: XCTestCase {
    private enum FixtureError: Error {
        case timedOut(String)
        case missingRequest
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

    private actor PeerTransport: BareTransport {
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

    private final class StreamProbe<Element: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Element] = []
        private var error: Error?
        private var completed = false
        func append(_ value: Element) { lock.withLock { values.append(value) } }
        func finish(_ error: Error?) { lock.withLock { self.error = error; completed = true } }
        func snapshot() -> ([Element], Error?, Bool) { lock.withLock { (values, error, completed) } }
    }

    @discardableResult
    private static func record<Element: Sendable>(
        _ stream: QVACBufferedStream<Element>, in probe: StreamProbe<Element>
    ) -> Task<Void, Never> {
        Task {
            do {
                for try await value in stream { probe.append(value) }
                probe.finish(nil)
            } catch { probe.finish(error) }
        }
    }

    private static func waitForProbe<Element: Sendable>(
        _ probe: StreamProbe<Element>, timeout: Duration = .seconds(2)
    ) async throws -> ([Element], Error?, Bool) {
        let deadline = ContinuousClock().now.advanced(by: timeout)
        while ContinuousClock().now < deadline {
            let value = probe.snapshot()
            if value.2 { return value }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw FixtureError.timedOut("stream probe completion")
    }

    private static func frames(in data: Data) -> [BareRPCFrame] {
        let reader = BareRPCFrameReader()
        try? reader.append(data)
        var frames: [BareRPCFrame] = []
        while let frame = reader.next() { frames.append(frame) }
        return frames
    }

    private static func waitForRequest(
        on transport: PeerTransport,
        excluding excluded: Set<UInt64> = [],
        timeout: Duration = .seconds(2)
    ) async throws -> (id: UInt64, body: [String: Any]) {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            for frame in frames(in: await transport.outbound()) {
                guard case .request(let id, _, _, .some(let payload)) = frame else {
                    continue
                }
                guard !excluded.contains(id) else { continue }
                return (
                    id,
                    try XCTUnwrap(
                        JSONSerialization.jsonObject(with: payload) as? [String: Any]
                    )
                )
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("timed out waiting for an outbound request")
        throw FixtureError.missingRequest
    }

    private static func proveHeartbeatReuse(
        _ client: QVACClient, transport: PeerTransport, excluding id: UInt64
    ) async throws {
        let heartbeat = Task {
            try await client.heartbeat(rpcOptions: .init(timeout: .seconds(1)))
        }
        let request = try await waitForRequest(on: transport, excluding: [id])
        let payload = try JSONEncoder.qvac.encode(
            QVACResponse.heartbeat(.init(number: 17))
        )
        await transport.feed(BareRPCCodec.__testEncodeResponseFrame(
            id: request.id, stream: [], payload: .success(payload)
        ))
        let response = try await heartbeat.value
        XCTAssertEqual(response.number, 17)
        let rpc = await client.rpc
        try await waitForNoInFlight(rpc)
    }

    private static func feedServerStream(
        id: UInt64,
        records: [String],
        to transport: PeerTransport,
        end: Bool
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
        timeout: Duration = .seconds(2)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await rpc.__testInFlightCounts() == (0, 0, 0) { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw FixtureError.timedOut(
            "zero in-flight RPC state; observed \(await rpc.__testInFlightCounts())"
        )
    }

    private static func waitForOneDestroy(
        id: UInt64,
        on transport: PeerTransport,
        timeout: Duration = .seconds(2)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if destroyCount(id: id, in: frames(in: await transport.outbound())) == 1 {
                return
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw FixtureError.timedOut("one response DESTROY for request \(id)")
    }

    private static func destroyCount(id: UInt64, in frames: [BareRPCFrame]) -> Int {
        frames.reduce(into: 0) { count, frame in
            guard case .stream(let frameID, let flags, _) = frame,
                  frameID == id,
                  flags.contains(.response),
                  flags.contains(.destroy) else { return }
            count += 1
        }
    }

    private func assertResourceLimit(
        _ error: Error,
        operation: String,
        maximum: Int,
        attempted: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .resourceLimitExceeded(
            let actualOperation,
            _,
            let actualMaximum,
            let actualAttempted
        ) = error as? QVACError else {
            return XCTFail("expected resourceLimitExceeded, got \(error)", file: file, line: line)
        }
        XCTAssertEqual(actualOperation, operation, file: file, line: line)
        XCTAssertEqual(actualMaximum, maximum, file: file, line: line)
        XCTAssertEqual(actualAttempted, attempted, file: file, line: line)
    }

    private func assertEmptyResourceLimitedProbe<Element: Sendable>(
        _ probe: StreamProbe<Element>, maximum: Int, attempted: Int
    ) async throws {
        let snapshot = try await Self.waitForProbe(probe)
        XCTAssertTrue(snapshot.0.isEmpty, "a rejected frame must publish no partial values")
        let error = try XCTUnwrap(snapshot.1)
        assertResourceLimit(
            error, operation: "completionStream", maximum: maximum, attempted: attempted
        )
    }

    private func assertEmptyPostTerminalViolation<Element>(
        _ snapshot: ([Element], Error?, Bool),
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(snapshot.0.isEmpty, file: file, line: line)
        guard case .protocolViolation(let message) = snapshot.1 as? QVACError else {
            XCTFail(
                "expected post-terminal protocolViolation, got \(String(describing: snapshot.1))",
                file: file,
                line: line
            )
            return
        }
        XCTAssertTrue(
            message.contains("domain response after its terminal frame"),
            message,
            file: file,
            line: line
        )
    }

    func test_completion_accepts_an_exact_conservative_result_budget() async throws {
        let maximumBufferedBytes = 1024 * 1024
        let firstCost = QVACClient.retainedStringAggregateAppendBytes("bounded")
        let thinkingCost = QVACClient.retainedStringAggregateAppendBytes("reason")
        let call = try QVACClient.CompletionToolCall(wire: .object([
            "id": .string("call"), "name": .string("lookup"),
            "arguments": .object(["city": .string("Delhi")]), "raw": .string("wire"),
        ]))
        let toolCost = QVACClient.retainedCompletionAggregateBytes(for: .toolCall(seq: 2, call: call))
        let terminalCost = QVACClient.retainedStringAggregateAppendBytes("bounded")
        let budget = firstCost + thinkingCost + toolCost + terminalCost
        let transport = PeerTransport()
        let client = QVACClient(
            testing: transport,
            maximumAccumulatedResultBytes: budget,
            maximumBufferedStreamBytes: maximumBufferedBytes
        )
        let run = try await client.completion(
            modelId: "model",
            history: [.user("prompt")],
            stream: false,
            rpcOptions: .init(timeout: nil)
        )
        let request = try await Self.waitForRequest(on: transport)
        await Self.feedServerStream(
            id: request.id,
            records: [
                #"{"type":"completionStream","events":[{"type":"contentDelta","seq":0,"text":"bounded"},{"type":"thinkingDelta","seq":1,"text":"reason"},{"type":"toolCall","seq":2,"call":{"id":"call","name":"lookup","arguments":{"city":"Delhi"},"raw":"wire"}}]}"#,
                #"{"type":"completionStream","events":[{"type":"completionDone","seq":3,"stopReason":"eos","raw":{"fullText":"bounded"}}],"done":true}"#,
            ],
            to: transport,
            end: true
        )

        let final = try await run.final.value
        XCTAssertEqual(final.contentText, "bounded")
        XCTAssertEqual(final.raw.fullText, "bounded")
        XCTAssertEqual(final.thinkingText, "reason")
        XCTAssertEqual(final.toolCalls, [call])
        XCTAssertEqual(final.stopReason, .eos)
        let rpc = await client.rpc
        try await Self.waitForNoInFlight(rpc)
        let outboundBeforeClose = await transport.outbound()
        XCTAssertEqual(
            Self.destroyCount(id: request.id, in: Self.frames(in: outboundBeforeClose)),
            0,
            "a clean terminal END must not emit a redundant DESTROY"
        )
        await client.close()
    }

    func test_completion_cache_normalization_is_precharged_at_the_exact_boundary() async throws {
        let visible = "visible"
        let fullText = "<think>private reasoning</think> visible"
        let aggregateBytes = QVACClient.retainedStringAggregateAppendBytes(visible)
            + QVACClient.retainedStringAggregateAppendBytes(fullText)
        let cacheBytes = QVACClient.retainedStringAggregateAppendBytes(fullText)
        let exactBytes = aggregateBytes + cacheBytes
        let record = #"{"type":"completionStream","events":[{"type":"contentDelta","seq":0,"text":"visible"},{"type":"completionDone","seq":1,"stopReason":"eos","raw":{"fullText":"<think>private reasoning</think> visible"}}],"done":true}"#

        do {
            let transport = PeerTransport()
            let client = QVACClient(
                testing: transport,
                maximumAccumulatedResultBytes: exactBytes
            )
            let run = try await client.completion(
                modelId: "model",
                history: [.user("prompt")],
                stream: false,
                rpcOptions: .init(timeout: nil)
            )
            let request = try await Self.waitForRequest(on: transport)
            await Self.feedServerStream(
                id: request.id,
                records: [record],
                to: transport,
                end: true
            )
            let final = try await run.final.value
            XCTAssertEqual(final.raw.fullText, fullText)
            XCTAssertEqual(final.cacheableAssistantContent, visible)
            let rpc = await client.rpc
            try await Self.waitForNoInFlight(rpc)
            await client.close()
        }

        do {
            let maximum = exactBytes - 1
            let transport = PeerTransport()
            let client = QVACClient(
                testing: transport,
                maximumAccumulatedResultBytes: maximum
            )
            let run = try await client.completion(
                modelId: "model",
                history: [.user("prompt")],
                stream: false,
                rpcOptions: .init(timeout: nil)
            )
            let eventProbe = StreamProbe<QVACClient.CompletionEvent>()
            Self.record(run.events, in: eventProbe)
            let request = try await Self.waitForRequest(on: transport)
            await Self.feedServerStream(
                id: request.id,
                records: [record],
                to: transport,
                end: true
            )
            do {
                _ = try await run.final.value
                XCTFail("normalization must not allocate beyond the result budget")
            } catch {
                assertResourceLimit(
                    error,
                    operation: "completionStream",
                    maximum: maximum,
                    attempted: exactBytes
                )
            }
            try await assertEmptyResourceLimitedProbe(
                eventProbe,
                maximum: maximum,
                attempted: exactBytes
            )
            let rpc = await client.rpc
            try await Self.waitForNoInFlight(rpc)
            await client.close()
        }
    }

    func test_completion_rejects_the_first_cumulative_overage_and_destroys_once() async throws {
        let maximumBufferedBytes = 1024 * 1024
        let firstCost = QVACClient.retainedStringAggregateAppendBytes("first")
        let secondCost = QVACClient.retainedStringAggregateAppendBytes("second")
        let transport = PeerTransport()
        let client = QVACClient(
            testing: transport,
            maximumAccumulatedResultBytes: firstCost,
            maximumBufferedStreamBytes: maximumBufferedBytes
        )
        let run = try await client.completion(
            modelId: "model",
            history: [.user("prompt")],
            stream: false,
            rpcOptions: .init(timeout: nil)
        )
        let request = try await Self.waitForRequest(on: transport)
        await Self.feedServerStream(
            id: request.id,
            records: [
                #"{"type":"completionStream","events":[{"type":"contentDelta","seq":0,"text":"first"}]}"#,
                #"{"type":"completionStream","events":[{"type":"contentDelta","seq":1,"text":"second"}]}"#,
            ],
            to: transport,
            end: false
        )

        do {
            _ = try await run.final.value
            XCTFail("expected the cumulative completion result limit to fail")
        } catch {
            assertResourceLimit(
                error,
                operation: "completionStream",
                maximum: firstCost,
                attempted: firstCost + secondCost
            )
        }
        let rpc = await client.rpc
        try await Self.waitForOneDestroy(id: request.id, on: transport)
        try await Self.waitForNoInFlight(rpc)
        try await Self.proveHeartbeatReuse(client, transport: transport, excluding: request.id)
        await client.close()
        let outboundAfterClose = await transport.outbound()
        XCTAssertEqual(
            Self.destroyCount(id: request.id, in: Self.frames(in: outboundAfterClose)),
            1
        )
    }

    func test_completion_same_frame_overage_is_atomic_across_every_public_view() async throws {
        let firstCost = QVACClient.retainedStringAggregateAppendBytes("first")
        let secondCost = QVACClient.retainedStringAggregateAppendBytes("second")
        let transport = PeerTransport()
        let client = QVACClient(
            testing: transport,
            maximumAccumulatedResultBytes: firstCost
        )
        let run = try await client.completion(
            modelId: "model", history: [.user("prompt")], stream: true,
            rpcOptions: .init(timeout: nil)
        )
        let eventProbe = StreamProbe<QVACClient.CompletionEvent>()
        let tokenProbe = StreamProbe<String>()
        let toolProbe = StreamProbe<QVACClient.CompletionToolCall>()
        Self.record(run.events, in: eventProbe)
        Self.record(run.tokenStream, in: tokenProbe)
        Self.record(run.toolCallStream, in: toolProbe)
        let request = try await Self.waitForRequest(on: transport)
        await Self.feedServerStream(
            id: request.id,
            records: [
                #"{"type":"completionStream","events":[{"type":"contentDelta","seq":0,"text":"first"},{"type":"contentDelta","seq":1,"text":"second"}]}"#,
            ],
            to: transport,
            end: false
        )
        let attempted = firstCost + secondCost
        let finalResult = await run.final.result.map { _ in () }
        let textResult = await run.text.result.map { _ in () }
        let toolCallsResult = await run.toolCalls.result.map { _ in () }
        let statsResult = await run.stats.result.map { _ in () }
        let taskResults = [finalResult, textResult, toolCallsResult, statsResult]
        for result in taskResults {
            guard case .failure(let error) = result else {
                XCTFail("expected every completion aggregate view to fail"); continue
            }
            assertResourceLimit(error, operation: "completionStream", maximum: firstCost, attempted: attempted)
        }
        try await assertEmptyResourceLimitedProbe(eventProbe, maximum: firstCost, attempted: attempted)
        try await assertEmptyResourceLimitedProbe(tokenProbe, maximum: firstCost, attempted: attempted)
        try await assertEmptyResourceLimitedProbe(toolProbe, maximum: firstCost, attempted: attempted)
        let rpc = await client.rpc
        try await Self.waitForOneDestroy(id: request.id, on: transport)
        try await Self.waitForNoInFlight(rpc)
        try await Self.proveHeartbeatReuse(client, transport: transport, excluding: request.id)
        await client.close()
        let outbound = await transport.outbound()
        XCTAssertEqual(Self.destroyCount(id: request.id, in: Self.frames(in: outbound)), 1)
    }

    func test_completion_terminal_frame_is_not_published_before_post_terminal_validation() async throws {
        let transport = PeerTransport()
        let client = QVACClient(testing: transport)
        let run = try await client.completion(
            modelId: "model",
            history: [.user("prompt")],
            stream: true,
            rpcOptions: .init(timeout: nil)
        )
        let eventProbe = StreamProbe<QVACClient.CompletionEvent>()
        let tokenProbe = StreamProbe<String>()
        let toolProbe = StreamProbe<QVACClient.CompletionToolCall>()
        Self.record(run.events, in: eventProbe)
        Self.record(run.tokenStream, in: tokenProbe)
        Self.record(run.toolCallStream, in: toolProbe)
        let request = try await Self.waitForRequest(on: transport)
        await Self.feedServerStream(
            id: request.id,
            records: [
                #"{"type":"completionStream","events":[{"type":"contentDelta","seq":0,"text":"terminal"},{"type":"toolCall","seq":1,"call":{"id":"call","name":"lookup","arguments":{}}},{"type":"completionDone","seq":2,"stopReason":"eos"}],"done":true}"#,
                #"{"type":"completionStream","events":[{"type":"contentDelta","seq":3,"text":"late"}]}"#,
            ],
            to: transport,
            end: true
        )

        guard case .failure(let finalError) = await run.final.result else {
            XCTFail("post-terminal domain data must fail completion"); return
        }
        guard case .protocolViolation(let finalMessage) = finalError as? QVACError else {
            XCTFail("expected protocolViolation, got \(finalError)"); return
        }
        XCTAssertTrue(finalMessage.contains("domain response after its terminal frame"))

        assertEmptyPostTerminalViolation(try await Self.waitForProbe(eventProbe))
        assertEmptyPostTerminalViolation(try await Self.waitForProbe(tokenProbe))
        assertEmptyPostTerminalViolation(try await Self.waitForProbe(toolProbe))
        await client.close()
    }

    func test_tts_terminal_audio_is_not_published_before_post_terminal_validation() async throws {
        let transport = PeerTransport()
        let client = QVACClient(testing: transport)
        let run = try await client.textToSpeech(
            modelId: "tts",
            text: "speak",
            stream: true,
            sentenceStream: true,
            rpcOptions: .init(timeout: nil)
        )
        let bufferProbe = StreamProbe<Double>()
        let chunkProbe = StreamProbe<QVACClient.TtsSentenceChunkUpdate>()
        Self.record(run.bufferStream, in: bufferProbe)
        let updates = try XCTUnwrap(run.chunkUpdates)
        Self.record(updates, in: chunkProbe)
        let request = try await Self.waitForRequest(on: transport)
        await Self.feedServerStream(
            id: request.id,
            records: [
                #"{"type":"textToSpeech","buffer":[7],"chunkIndex":0,"sentenceChunk":"terminal","done":true}"#,
                #"{"type":"textToSpeech","buffer":[8],"done":false}"#,
            ],
            to: transport,
            end: true
        )

        guard case .failure(let doneError) = await run.done.result else {
            XCTFail("post-terminal domain data must fail textToSpeech"); return
        }
        guard case .protocolViolation(let doneMessage) = doneError as? QVACError else {
            XCTFail("expected protocolViolation, got \(doneError)"); return
        }
        XCTAssertTrue(doneMessage.contains("domain response after its terminal frame"))

        let bufferSnapshot = try await Self.waitForProbe(bufferProbe)
        XCTAssertTrue(bufferSnapshot.0.isEmpty)
        guard case .protocolViolation = bufferSnapshot.1 as? QVACError else {
            XCTFail("buffer stream exposed terminal audio or returned the wrong error")
            return
        }
        let chunkSnapshot = try await Self.waitForProbe(chunkProbe)
        XCTAssertTrue(chunkSnapshot.0.isEmpty)
        guard case .protocolViolation = chunkSnapshot.1 as? QVACError else {
            XCTFail("chunk stream exposed a terminal update or returned the wrong error")
            return
        }
        await client.close()
    }

    func test_nonstream_translation_counts_retained_utf8_capacity_at_exact_boundary() async throws {
        let transport = PeerTransport()
        let client = QVACClient(testing: transport, maximumAccumulatedResultBytes: 6)
        let run = try await client.translate(
            modelId: "nmt",
            modelType: "nmt",
            text: "input",
            stream: false,
            rpcOptions: .init(timeout: nil)
        )
        let request = try await Self.waitForRequest(on: transport)
        await Self.feedServerStream(
            id: request.id,
            records: [
                #"{"type":"translate","token":"é"}"#,
                #"{"type":"translate","token":"x","done":true}"#,
            ],
            to: transport,
            end: true
        )
        let translated = try await run.text.value
        XCTAssertEqual(translated, "éx")
        let rpc = await client.rpc
        try await Self.waitForNoInFlight(rpc)
        await client.close()
    }

    func test_nonstream_translation_overage_destroys_the_live_rpc_once() async throws {
        let transport = PeerTransport()
        let client = QVACClient(testing: transport, maximumAccumulatedResultBytes: 4)
        let run = try await client.translate(
            modelId: "nmt",
            modelType: "nmt",
            text: "input",
            stream: false,
            rpcOptions: .init(timeout: nil)
        )
        let request = try await Self.waitForRequest(on: transport)
        await Self.feedServerStream(
            id: request.id,
            records: [
                #"{"type":"translate","token":"é"}"#,
                #"{"type":"translate","token":"x"}"#,
            ],
            to: transport,
            end: false
        )
        let textResult = await run.text.result
        let statsResult = await run.stats.result
        for result in [textResult.map { _ in () }, statsResult.map { _ in () }] {
            guard case .failure(let error) = result else {
                XCTFail("expected every translation aggregate view to fail")
                continue
            }
            assertResourceLimit(
                error,
                operation: "translate",
                maximum: 4,
                attempted: 6
            )
        }
        let rpc = await client.rpc
        try await Self.waitForOneDestroy(id: request.id, on: transport)
        try await Self.waitForNoInFlight(rpc)
        await client.close()
        let outboundAfterClose = await transport.outbound()
        XCTAssertEqual(
            Self.destroyCount(id: request.id, in: Self.frames(in: outboundAfterClose)),
            1
        )
    }

    func test_bci_result_budget_accepts_exact_boundary_and_rejects_terminal_and_nonterminal_overage() async throws {
        let fragmentCost = QVACClient.retainedStringAggregateAppendBytes("a")

        do {
            let transport = PeerTransport()
            let client = QVACClient(
                testing: transport,
                maximumAccumulatedResultBytes: fragmentCost * 2
            )
            let run = try await client.bciTranscribe(
                modelId: "bci",
                neuralData: .data(Data()),
                rpcOptions: .init(timeout: nil)
            )
            let request = try await Self.waitForRequest(on: transport)
            await Self.feedServerStream(
                id: request.id,
                records: [
                    #"{"type":"bciTranscribe","text":"a"}"#,
                    #"{"type":"bciTranscribe","text":"a","done":true}"#,
                ],
                to: transport,
                end: true
            )
            let outcome = try await run.result.value
            XCTAssertEqual(outcome.text, "aa")
            let rpc = await client.rpc
            try await Self.waitForNoInFlight(rpc)
            let outbound = await transport.outbound()
            XCTAssertEqual(
                Self.destroyCount(id: request.id, in: Self.frames(in: outbound)),
                0
            )
            await client.close()
        }

        for terminal in [false, true] {
            let transport = PeerTransport()
            let maximum = fragmentCost * 2 - 1
            let client = QVACClient(
                testing: transport,
                maximumAccumulatedResultBytes: maximum
            )
            let run = try await client.bciTranscribe(
                modelId: "bci",
                neuralData: .data(Data()),
                rpcOptions: .init(timeout: nil)
            )
            let request = try await Self.waitForRequest(on: transport)
            let second = terminal
                ? #"{"type":"bciTranscribe","text":"a","done":true}"#
                : #"{"type":"bciTranscribe","text":"a"}"#
            await Self.feedServerStream(
                id: request.id,
                records: [#"{"type":"bciTranscribe","text":"a"}"#, second],
                to: transport,
                end: false
            )
            do {
                _ = try await run.result.value
                XCTFail("expected \(terminal ? "terminal" : "nonterminal") BCI overage")
            } catch {
                assertResourceLimit(
                    error,
                    operation: "bciTranscribe",
                    maximum: maximum,
                    attempted: fragmentCost * 2
                )
            }
            let rpc = await client.rpc
            try await Self.waitForOneDestroy(id: request.id, on: transport)
            try await Self.waitForNoInFlight(rpc)
            try await Self.proveHeartbeatReuse(client, transport: transport, excluding: request.id)
            await client.close()
            let outbound = await transport.outbound()
            XCTAssertEqual(
                Self.destroyCount(id: request.id, in: Self.frames(in: outbound)),
                1
            )
        }
    }

    func test_transcription_structural_result_cost_is_cumulative_and_fail_closed() async throws {
        let segment: JSONValue = .object([
            "id": .number(1),
            "text": .string("segment"),
            "startMs": .number(0),
            "endMs": .number(10),
            "append": .bool(true),
        ])
        let segmentCost = QVACClient.conservativeBufferedJSONBytes(
            segment,
            elementCount: 1,
            fallback: Int.max
        )
        let transport = PeerTransport()
        let client = QVACClient(testing: transport, maximumAccumulatedResultBytes: 2)
        let run = try await client.transcribe(
            modelId: "asr",
            audioPath: "/fixture.wav",
            rpcOptions: .init(timeout: nil)
        )
        let request = try await Self.waitForRequest(on: transport)
        await Self.feedServerStream(
            id: request.id,
            records: [
                #"{"type":"transcribe","text":"a"}"#,
                #"{"type":"transcribe","segment":{"id":1,"text":"segment","startMs":0,"endMs":10,"append":true}}"#,
            ],
            to: transport,
            end: false
        )
        do {
            _ = try await run.result.value
            XCTFail("expected the structural transcription result limit to fail")
        } catch {
            assertResourceLimit(
                error,
                operation: "transcribe",
                maximum: 2,
                attempted: 2 + segmentCost
            )
        }
        let rpc = await client.rpc
        try await Self.waitForOneDestroy(id: request.id, on: transport)
        try await Self.waitForNoInFlight(rpc)
        await client.close()
        let outboundAfterClose = await transport.outbound()
        XCTAssertEqual(
            Self.destroyCount(id: request.id, in: Self.frames(in: outboundAfterClose)),
            1
        )
    }

    func test_empty_bci_and_transcribe_data_match_the_017_base64_contract() async throws {
        let bciTransport = PeerTransport()
        let bciClient = QVACClient(testing: bciTransport)
        let bciRun = try await bciClient.bciTranscribe(
            modelId: "bci",
            neuralData: .data(Data()),
            rpcOptions: .init(timeout: nil)
        )
        let bciRequest = try await Self.waitForRequest(on: bciTransport)
        let neuralData = try XCTUnwrap(bciRequest.body["neuralData"] as? [String: Any])
        XCTAssertEqual(neuralData["type"] as? String, "base64")
        XCTAssertEqual(neuralData["value"] as? String, "")
        await Self.feedServerStream(
            id: bciRequest.id,
            records: [#"{"type":"bciTranscribe","done":true}"#],
            to: bciTransport,
            end: true
        )
        let bciResult = try await bciRun.result.value
        XCTAssertEqual(bciResult.text, "")
        XCTAssertTrue(bciResult.segments.isEmpty)
        await bciClient.close()

        let transcribeTransport = PeerTransport()
        let transcribeClient = QVACClient(testing: transcribeTransport)
        let transcribeRun = try await transcribeClient.transcribe(
            modelId: "asr",
            audioBytes: Data(),
            rpcOptions: .init(timeout: nil)
        )
        let transcribeRequest = try await Self.waitForRequest(on: transcribeTransport)
        let audioChunk = try XCTUnwrap(
            transcribeRequest.body["audioChunk"] as? [String: Any]
        )
        XCTAssertEqual(audioChunk["type"] as? String, "base64")
        XCTAssertEqual(audioChunk["value"] as? String, "")
        await Self.feedServerStream(
            id: transcribeRequest.id,
            records: [#"{"type":"transcribe","done":true}"#],
            to: transcribeTransport,
            end: true
        )
        let transcribeResult = try await transcribeRun.result.value
        XCTAssertEqual(transcribeResult.text, "")
        XCTAssertTrue(transcribeResult.segments.isEmpty)
        await transcribeClient.close()
    }
}
