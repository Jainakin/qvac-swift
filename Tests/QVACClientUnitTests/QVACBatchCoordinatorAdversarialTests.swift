import Foundation
import XCTest
@testable import QVACClient

/// Adversarial lifecycle specifications for the batch-completion coordinator and
/// the video adapter's split result tasks.
///
/// The fixture replaces only the byte transport. Requests, stream framing,
/// decoding, coordinator state transitions, cancellation, and teardown all use
/// the production implementation.
final class QVACBatchCoordinatorAdversarialTests: XCTestCase {
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
        private var closeCallCount = 0

        nonisolated func inboundStream() -> AsyncThrowingStream<Data, Error> {
            inbound.stream
        }

        func write(_ data: Data) {
            outboundBytes.append(data)
        }

        func close() {
            closeCallCount += 1
            guard !closed else { return }
            closed = true
            inbound.continuation.finish()
        }

        func feed(_ data: Data) {
            inbound.continuation.yield(data)
        }

        func outbound() -> Data { outboundBytes }
        func closeCalls() -> Int { closeCallCount }
    }

    private final class ValueBox<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value?

        func set(_ value: Value) {
            lock.withLock { self.value = value }
        }

        func get() -> Value? {
            lock.withLock { value }
        }
    }

    private final class StreamProbe<Element: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Element] = []
        private var terminalError: Error?
        private var completed = false

        func append(_ value: Element) {
            lock.withLock { values.append(value) }
        }

        func finish(throwing error: Error?) {
            lock.withLock {
                terminalError = error
                completed = true
            }
        }

        func snapshot() -> (values: [Element], error: Error?, completed: Bool) {
            lock.withLock { (values, terminalError, completed) }
        }
    }

    @discardableResult
    private static func record<Element: Sendable>(
        _ stream: QVACBufferedStream<Element>,
        in probe: StreamProbe<Element>
    ) -> Task<Void, Never> {
        Task {
            do {
                for try await value in stream {
                    probe.append(value)
                }
                probe.finish(throwing: nil)
            } catch {
                probe.finish(throwing: error)
            }
        }
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
                guard case .request(let id, _, _, .some(let data)) = frame,
                      !excluded.contains(id) else { continue }
                let body = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: data) as? [String: Any]
                )
                return (id, body)
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("timed out waiting for an outbound bare-rpc request")
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

    /// Continue an already-open response stream without emitting a second OPEN.
    private static func feedServerContinuation(
        id: UInt64,
        records: [String],
        to transport: PeerTransport,
        end: Bool
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

    private static func waitForResult<Value: Sendable>(
        of task: Task<Value, Error>,
        named name: String,
        timeout: Duration = .seconds(2)
    ) async throws -> Result<Value, Error> {
        let box = ValueBox<Result<Value, Error>>()
        let observer = Task { box.set(await task.result) }
        defer { observer.cancel() }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let result = box.get() { return result }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw FixtureError.timedOut(name)
    }

    private static func waitForProbe<Element: Sendable>(
        _ probe: StreamProbe<Element>,
        minimumCount: Int? = nil,
        completed: Bool? = nil,
        name: String,
        timeout: Duration = .seconds(2)
    ) async throws -> (values: [Element], error: Error?, completed: Bool) {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            let snapshot = probe.snapshot()
            let countMatches = minimumCount.map { snapshot.values.count >= $0 } ?? true
            let completionMatches = completed.map { snapshot.completed == $0 } ?? true
            if countMatches && completionMatches { return snapshot }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw FixtureError.timedOut(name)
    }

    private static func waitForNoInFlight(
        _ rpc: BareRPCClient,
        timeout: Duration = .seconds(2)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            let counts = await rpc.__testInFlightCounts()
            if counts == (0, 0, 0) { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw FixtureError.timedOut(
            "zero bare-rpc in-flight state; observed \(await rpc.__testInFlightCounts())"
        )
    }

    private static func waitForPerIDStateCount(
        _ expected: Int,
        in run: QVACClient.BatchCompletionRun,
        timeout: Duration = .seconds(2)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if run.__testPerIDStateCount() == expected { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw FixtureError.timedOut(
            "\(expected) batch per-id states; observed \(run.__testPerIDStateCount())"
        )
    }

    private static func waitForDestroy(
        id: UInt64,
        on transport: PeerTransport,
        timeout: Duration = .seconds(2)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if destroyFrames(id: id, in: frames(in: await transport.outbound())).count == 1 {
                return
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw FixtureError.timedOut("one response DESTROY for request \(id)")
    }

    private static func destroyFrames(
        id: UInt64,
        in frames: [BareRPCFrame]
    ) -> [BareRPCFrame] {
        frames.filter { frame in
            guard case .stream(let frameID, let flags, _) = frame else { return false }
            return frameID == id && flags.contains(.destroy)
        }
    }

    @discardableResult
    private func assertProtocolViolation<Value>(
        _ result: Result<Value, Error>,
        equals expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> String? {
        guard case .failure(let error) = result,
              case .protocolViolation(let message) = error as? QVACError else {
            XCTFail("expected protocolViolation, got \(result)", file: file, line: line)
            return nil
        }
        XCTAssertEqual(message, expected, file: file, line: line)
        return message
    }

    private func assertCancellation<Value>(
        _ result: Result<Value, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .failure(let error) = result else {
            return XCTFail("expected CancellationError, got \(result)", file: file, line: line)
        }
        XCTAssertTrue(error is CancellationError, "got \(error)", file: file, line: line)
    }

    private func assertResourceLimit<Value>(
        _ result: Result<Value, Error>,
        maximum: Int,
        attempted: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .failure(let error) = result,
              case .resourceLimitExceeded(
                let operation,
                _,
                let actualMaximum,
                let actualAttempted
              ) = error as? QVACError else {
            return XCTFail("expected resourceLimitExceeded, got \(result)", file: file, line: line)
        }
        XCTAssertEqual(operation, "batchCompletionStream", file: file, line: line)
        XCTAssertEqual(actualMaximum, maximum, file: file, line: line)
        XCTAssertEqual(actualAttempted, attempted, file: file, line: line)
    }

    func test_nonterminal_duplicate_ids_reject_atomically_without_publishing_events() async throws {
        let transport = PeerTransport()
        let client = QVACClient(testing: transport)
        let run = try await client.batchCompletion(
            modelId: "llm",
            prompts: [
                .init(id: "caller-a", history: [.user("first")]),
                .init(id: "caller-b", history: [.user("second")]),
            ],
            rpcOptions: .init(timeout: nil)
        )
        let callerA = run.byId("caller-a")
        let callerB = run.byId("caller-b")

        let globalProbe = StreamProbe<QVACClient.BatchCompletionEvent>()
        let callerAProbe = StreamProbe<QVACClient.CompletionEvent>()
        let callerBProbe = StreamProbe<QVACClient.CompletionEvent>()
        let globalRead = Self.record(run.events, in: globalProbe)
        let callerARead = Self.record(callerA.events, in: callerAProbe)
        let callerBRead = Self.record(callerB.events, in: callerBProbe)

        let request = try await Self.waitForRequest(on: transport)
        await Self.feedServerStream(
            id: request.id,
            records: [
                #"{"type":"batchCompletionStream","ids":["duplicate","duplicate"],"events":[{"id":"caller-a","event":{"type":"contentDelta","seq":0,"text":"must-not-publish"}}]}"#,
            ],
            to: transport,
            end: false
        )

        let expected = "batchCompletionStream ids must contain exactly one unique id per prompt"
        _ = assertProtocolViolation(
            try await Self.waitForResult(of: run.ids, named: "batch ids"),
            equals: expected
        )
        _ = assertProtocolViolation(
            try await Self.waitForResult(of: run.results, named: "batch results"),
            equals: expected
        )
        _ = assertProtocolViolation(
            try await Self.waitForResult(of: run.stats, named: "batch stats"),
            equals: expected
        )
        _ = assertProtocolViolation(
            try await Self.waitForResult(of: callerA.final, named: "caller-a final"),
            equals: expected
        )
        _ = assertProtocolViolation(
            try await Self.waitForResult(of: callerB.final, named: "caller-b final"),
            equals: expected
        )

        let global = try await Self.waitForProbe(
            globalProbe, completed: true, name: "global event rejection"
        )
        let perA = try await Self.waitForProbe(
            callerAProbe, completed: true, name: "caller-a event rejection"
        )
        let perB = try await Self.waitForProbe(
            callerBProbe, completed: true, name: "caller-b event rejection"
        )
        XCTAssertTrue(global.values.isEmpty)
        XCTAssertTrue(perA.values.isEmpty)
        XCTAssertTrue(perB.values.isEmpty)
        for error in [global.error, perA.error, perB.error] {
            guard case .protocolViolation(let message) = error as? QVACError else {
                XCTFail("every event observer must receive the atomic frame error")
                continue
            }
            XCTAssertEqual(message, expected)
        }

        await globalRead.value
        await callerARead.value
        await callerBRead.value
        try await Self.waitForNoInFlight(await client.rpc)
        await client.close()
    }

    func test_terminal_addon_id_remap_fails_every_caller_view_without_partial_success() async throws {
        let transport = PeerTransport()
        let client = QVACClient(testing: transport)
        let run = try await client.batchCompletion(
            modelId: "llm",
            prompts: [
                .init(id: "caller-a", history: [.user("first")]),
                .init(id: "caller-b", history: [.user("second")]),
            ],
            rpcOptions: .init(timeout: nil)
        )
        let callerA = run.byId("caller-a")
        let callerB = run.byId("caller-b")

        let globalProbe = StreamProbe<QVACClient.BatchCompletionEvent>()
        let callerAProbe = StreamProbe<QVACClient.CompletionEvent>()
        let callerBProbe = StreamProbe<QVACClient.CompletionEvent>()
        let globalRead = Self.record(run.events, in: globalProbe)
        let callerARead = Self.record(callerA.events, in: callerAProbe)
        let callerBRead = Self.record(callerB.events, in: callerBProbe)

        let request = try await Self.waitForRequest(on: transport)
        await Self.feedServerStream(
            id: request.id,
            records: [
                #"{"type":"batchCompletionStream","ids":["addon-a","addon-b"],"events":[{"id":"addon-a","event":{"type":"contentDelta","seq":0,"text":"must-not-publish"}},{"id":"addon-a","event":{"type":"completionDone","seq":1,"stopReason":"eos","raw":{"fullText":"must-not-publish"}}},{"id":"addon-b","event":{"type":"completionDone","seq":0,"stopReason":"eos","raw":{"fullText":""}}}],"done":true,"stats":{"emittedTokens":1}}"#,
            ],
            to: transport,
            end: true
        )

        let expected = "batchCompletionStream introduced more ids than requested prompts"
        _ = assertProtocolViolation(
            try await Self.waitForResult(of: run.ids, named: "remapped ids"),
            equals: expected
        )
        _ = assertProtocolViolation(
            try await Self.waitForResult(of: run.results, named: "remapped results"),
            equals: expected
        )
        _ = assertProtocolViolation(
            try await Self.waitForResult(of: run.stats, named: "remapped stats"),
            equals: expected
        )
        _ = assertProtocolViolation(
            try await Self.waitForResult(of: callerA.final, named: "remapped caller-a final"),
            equals: expected
        )
        _ = assertProtocolViolation(
            try await Self.waitForResult(of: callerB.final, named: "remapped caller-b final"),
            equals: expected
        )

        let global = try await Self.waitForProbe(
            globalProbe, completed: true, name: "remapped global events"
        )
        let perA = try await Self.waitForProbe(
            callerAProbe, completed: true, name: "remapped caller-a events"
        )
        let perB = try await Self.waitForProbe(
            callerBProbe, completed: true, name: "remapped caller-b events"
        )
        XCTAssertTrue(global.values.isEmpty, "terminal remap must not leak parsed events")
        XCTAssertTrue(perA.values.isEmpty, "caller-a must not observe partial success")
        XCTAssertTrue(perB.values.isEmpty, "caller-b must not observe partial success")
        for error in [global.error, perA.error, perB.error] {
            guard case .protocolViolation(let message) = error as? QVACError else {
                XCTFail("every remapped-id observer must receive the coordinator error")
                continue
            }
            XCTAssertEqual(message, expected)
        }

        await globalRead.value
        await callerARead.value
        await callerBRead.value
        try await Self.waitForNoInFlight(await client.rpc)
        await client.close()
    }

    func test_lagging_event_views_overflow_without_poisoning_authoritative_batch_results() async throws {
        let bufferBudget = 1024 * 1024
        let transport = PeerTransport()
        let client = QVACClient(
            testing: transport,
            maximumBufferedStreamBytes: bufferBudget
        )
        let run = try await client.batchCompletion(
            modelId: "llm",
            prompts: [.init(id: "prompt", history: [.user("stream every fragment")])],
            rpcOptions: .init(timeout: nil)
        )
        let prompt = run.byId("prompt")
        let request = try await Self.waitForRequest(on: transport)

        // Each response record is one producer batch. Leave both public event
        // views unread until the producer has exceeded their 64-batch capacity.
        // The coordinator's accumulator is deliberately independent of those
        // observational queues and must still retain every fragment.
        let fragments = (0..<65).map { "fragment-\($0)|" }
        let wireEvents: [JSONValue] = fragments.enumerated().map { index, fragment in
            .object([
                "id": .string("prompt"),
                "event": .object([
                    "type": .string("contentDelta"),
                    "seq": .number(Double(index)),
                    "text": .string(fragment),
                ]),
            ])
        }
        var expectedAttemptedBytes = 0
        let records = try wireEvents.enumerated().map { index, event in
            expectedAttemptedBytes += QVACClient.conservativeBufferedJSONBytes(
                [event],
                elementCount: 1,
                fallback: bufferBudget
            )
            let response = QVACResponse.batchCompletionStream(.init(
                events: [event],
                ids: index == 0 ? ["prompt"] : nil
            ))
            return String(
                decoding: try JSONEncoder.qvac.encode(response),
                as: UTF8.self
            )
        }
        let completeText = fragments.joined()
        let terminalEvent: JSONValue = .object([
            "id": .string("prompt"),
            "event": .object([
                "type": .string("completionDone"),
                "seq": .number(65),
                "stopReason": .string("eos"),
                "raw": .object(["fullText": .string(completeText)]),
            ]),
        ])
        let terminalRecord = String(
            decoding: try JSONEncoder.qvac.encode(QVACResponse.batchCompletionStream(.init(
                events: [terminalEvent],
                done: true,
                stats: .object(["emittedTokens": .number(65)])
            ))),
            as: UTF8.self
        )
        await Self.feedServerStream(
            id: request.id,
            records: records + [terminalRecord],
            to: transport,
            end: true
        )

        let idsResult = try await Self.waitForResult(of: run.ids, named: "overflow batch ids")
        let resultsResult = try await Self.waitForResult(
            of: run.results,
            named: "overflow batch results"
        )
        let statsResult = try await Self.waitForResult(
            of: run.stats,
            named: "overflow batch stats"
        )
        let finalResult = try await Self.waitForResult(
            of: prompt.final,
            named: "overflow prompt final"
        )
        let ids = try idsResult.get()
        let results = try resultsResult.get()
        let stats = try statsResult.get()
        let final = try finalResult.get()
        XCTAssertEqual(ids, ["prompt"])
        XCTAssertEqual(results.map(\.id), ["prompt"])
        XCTAssertEqual(results.first?.final, final)
        XCTAssertEqual(final.contentText, completeText)
        XCTAssertEqual(final.raw.fullText, completeText)
        XCTAssertEqual(final.stopReason, .eos)
        XCTAssertEqual(stats?.emittedTokens, 65)

        let globalProbe = StreamProbe<QVACClient.BatchCompletionEvent>()
        let promptProbe = StreamProbe<QVACClient.CompletionEvent>()
        let globalRead = Self.record(run.events, in: globalProbe)
        let promptRead = Self.record(prompt.events, in: promptProbe)
        let global = try await Self.waitForProbe(
            globalProbe,
            minimumCount: 64,
            completed: true,
            name: "overflowed global batch event view"
        )
        let perID = try await Self.waitForProbe(
            promptProbe,
            minimumCount: 64,
            completed: true,
            name: "overflowed per-id batch event view"
        )
        await globalRead.value
        await promptRead.value

        let acceptedEvents: [QVACClient.CompletionEvent] = fragments.prefix(64)
            .enumerated()
            .map { .contentDelta(seq: $0.offset, text: $0.element) }
        XCTAssertEqual(global.values.count, 64)
        XCTAssertEqual(global.values.map(\.id), Array(repeating: "prompt", count: 64))
        XCTAssertEqual(global.values.map(\.event), acceptedEvents)
        XCTAssertEqual(perID.values, acceptedEvents)
        XCTAssertEqual(
            global.error as? QVACStreamBufferOverflow,
            QVACStreamBufferOverflow(
                stream: "batchCompletion.events",
                capacity: 64,
                maximumBufferedBytes: bufferBudget,
                attemptedBufferedBytes: expectedAttemptedBytes
            )
        )
        XCTAssertEqual(
            perID.error as? QVACStreamBufferOverflow,
            QVACStreamBufferOverflow(
                stream: "batchCompletion.byId(prompt).events",
                capacity: 64,
                maximumBufferedBytes: bufferBudget,
                attemptedBufferedBytes: expectedAttemptedBytes
            )
        )

        let rpc = await client.rpc
        try await Self.waitForNoInFlight(rpc)
        let outboundBeforeClose = await transport.outbound()
        XCTAssertTrue(
            Self.destroyFrames(
                id: request.id,
                in: Self.frames(in: outboundBeforeClose)
            ).isEmpty,
            "a clean peer END must not trigger a redundant DESTROY"
        )
        await client.close()
        await client.close()
        let closeCalls = await transport.closeCalls()
        XCTAssertEqual(closeCalls, 1)
        try await Self.waitForNoInFlight(rpc)
    }

    func test_event_created_addon_id_absent_from_terminal_ids_fails_only_that_view() async throws {
        let transport = PeerTransport()
        let client = QVACClient(testing: transport)
        let run = try await client.batchCompletion(
            modelId: "llm",
            prompts: [.init(history: [.user("let the addon assign an id")])],
            rpcOptions: .init(timeout: nil)
        )
        XCTAssertEqual(run.__testPerIDStateCount(), 0)
        let request = try await Self.waitForRequest(on: transport)

        await Self.feedServerStream(
            id: request.id,
            records: [
                #"{"type":"batchCompletionStream","events":[{"id":"addon-a","event":{"type":"contentDelta","seq":0,"text":"orphaned event"}}]}"#,
            ],
            to: transport,
            end: false
        )
        try await Self.waitForPerIDStateCount(1, in: run)
        let addon = run.byId("addon-a")

        // Upstream 0.17 falls back to the original positional id when a terminal
        // frame omits `ids`. The event-created id remains observable, but it is
        // not selected as a result and its final alone must reject.
        await Self.feedServerContinuation(
            id: request.id,
            records: [
                #"{"type":"batchCompletionStream","events":[],"done":true,"stats":{"emittedTokens":0}}"#,
            ],
            to: transport,
            end: true
        )

        let idsResult = try await Self.waitForResult(
            of: run.ids,
            named: "fallback positional ids"
        )
        let resultsResult = try await Self.waitForResult(
            of: run.results,
            named: "fallback positional results"
        )
        let statsResult = try await Self.waitForResult(
            of: run.stats,
            named: "fallback positional stats"
        )
        let addonFinalResult = try await Self.waitForResult(
            of: addon.final,
            named: "unselected addon final"
        )
        let ids = try idsResult.get()
        let results = try resultsResult.get()
        let stats = try statsResult.get()
        XCTAssertEqual(ids, ["0"])
        XCTAssertEqual(results.map(\.id), ["0"])
        XCTAssertEqual(results.first?.final.contentText, "")
        XCTAssertEqual(results.first?.final.raw.fullText, "")
        XCTAssertNil(results.first?.final.stopReason)
        XCTAssertEqual(stats?.emittedTokens, 0)
        guard case .failure(let addonError) = addonFinalResult,
              case .server(let code, let message) = addonError as? QVACError else {
            return XCTFail("unselected addon final must reject with completionFailed")
        }
        XCTAssertEqual(code, .completionFailed)
        XCTAssertEqual(message, "Unknown batch prompt id \"addon-a\".")

        let addonProbe = StreamProbe<QVACClient.CompletionEvent>()
        let addonRead = Self.record(addon.events, in: addonProbe)
        let observedAddon = try await Self.waitForProbe(
            addonProbe,
            minimumCount: 1,
            completed: true,
            name: "unselected addon's buffered events"
        )
        await addonRead.value
        XCTAssertEqual(
            observedAddon.values,
            [.contentDelta(seq: 0, text: "orphaned event")]
        )
        XCTAssertNil(
            observedAddon.error,
            "the event view ends normally after delivering already-accepted events"
        )

        let globalProbe = StreamProbe<QVACClient.BatchCompletionEvent>()
        let globalRead = Self.record(run.events, in: globalProbe)
        let global = try await Self.waitForProbe(
            globalProbe,
            minimumCount: 1,
            completed: true,
            name: "global addon event view"
        )
        await globalRead.value
        XCTAssertEqual(global.values.map(\.id), ["addon-a"])
        XCTAssertEqual(
            global.values.map(\.event),
            [.contentDelta(seq: 0, text: "orphaned event")]
        )
        XCTAssertNil(global.error)

        XCTAssertEqual(
            run.__testPerIDStateCount(),
            2,
            "only the event-created and fallback states should be retained"
        )
        let rpc = await client.rpc
        try await Self.waitForNoInFlight(rpc)
        let outboundBeforeClose = await transport.outbound()
        XCTAssertTrue(
            Self.destroyFrames(
                id: request.id,
                in: Self.frames(in: outboundBeforeClose)
            ).isEmpty,
            "a clean peer END must not trigger a redundant DESTROY"
        )
        await client.close()
        await client.close()
        let closeCalls = await transport.closeCalls()
        XCTAssertEqual(closeCalls, 1)
        try await Self.waitForNoInFlight(rpc)
    }

    func test_cumulative_batch_result_limit_rejects_every_view_and_destroys_once() async throws {
        let firstEvent: JSONValue = .object([
            "id": .string("prompt"),
            "event": .object([
                "type": .string("contentDelta"),
                "seq": .number(0),
                "text": .string("first"),
            ]),
        ])
        let secondEvent: JSONValue = .object([
            "id": .string("prompt"),
            "event": .object([
                "type": .string("contentDelta"),
                "seq": .number(1),
                "text": .string("second"),
            ]),
        ])
        let firstCost = QVACClient.retainedStringAggregateAppendBytes("first")
        let secondCost = QVACClient.retainedStringAggregateAppendBytes("second")
        let transport = PeerTransport()
        let client = QVACClient(
            testing: transport,
            maximumAccumulatedResultBytes: firstCost
        )
        let run = try await client.batchCompletion(
            modelId: "llm",
            prompts: [.init(id: "prompt", history: [.user("bounded")])],
            rpcOptions: .init(timeout: nil)
        )
        let prompt = run.byId("prompt")
        let globalProbe = StreamProbe<QVACClient.BatchCompletionEvent>()
        let promptProbe = StreamProbe<QVACClient.CompletionEvent>()
        Self.record(run.events, in: globalProbe)
        Self.record(prompt.events, in: promptProbe)
        let request = try await Self.waitForRequest(on: transport)
        let records = [String(
            decoding: try JSONEncoder.qvac.encode(
                QVACResponse.batchCompletionStream(.init(events: [firstEvent, secondEvent]))
            ),
            as: UTF8.self
        )]
        await Self.feedServerStream(
            id: request.id,
            records: records,
            to: transport,
            end: false
        )

        let attempted = firstCost + secondCost
        assertResourceLimit(
            try await Self.waitForResult(of: run.ids, named: "limited batch ids"),
            maximum: firstCost,
            attempted: attempted
        )
        assertResourceLimit(
            try await Self.waitForResult(of: run.results, named: "limited batch results"),
            maximum: firstCost,
            attempted: attempted
        )
        assertResourceLimit(
            try await Self.waitForResult(of: run.stats, named: "limited batch stats"),
            maximum: firstCost,
            attempted: attempted
        )
        assertResourceLimit(
            try await Self.waitForResult(of: prompt.final, named: "limited prompt final"),
            maximum: firstCost,
            attempted: attempted
        )
        for snapshot in [
            try await Self.waitForProbe(globalProbe, completed: true, name: "global limit"),
        ] {
            XCTAssertTrue(snapshot.values.isEmpty)
            let error = try XCTUnwrap(snapshot.error)
            assertResourceLimit(
                Result<Void, Error>.failure(error), maximum: firstCost, attempted: attempted
            )
        }
        let promptSnapshot = try await Self.waitForProbe(
            promptProbe, completed: true, name: "prompt limit"
        )
        XCTAssertTrue(promptSnapshot.values.isEmpty)
        assertResourceLimit(
            Result<Void, Error>.failure(try XCTUnwrap(promptSnapshot.error)),
            maximum: firstCost,
            attempted: attempted
        )

        let rpc = await client.rpc
        try await Self.waitForDestroy(id: request.id, on: transport)
        try await Self.waitForNoInFlight(rpc)
        try await Self.proveHeartbeatReuse(client, transport: transport, excluding: request.id)
        await client.close()
        let outboundAfterClose = await transport.outbound()
        XCTAssertEqual(
            Self.destroyFrames(id: request.id, in: Self.frames(in: outboundAfterClose)).count,
            1
        )
    }

    func test_batch_addon_id_and_terminal_ids_reservations_accept_exact_and_reject_plus_one() async throws {
        let addonID = "addon"
        let addonCost = QVACBufferedJSONRetainedSizeEstimator.saturatingAdd(
            QVACClient.retainedStringAggregateAppendBytes(addonID),
            QVACBufferedJSONRetainedSizeEstimator.saturatingMultiply(
                MemoryLayout<String>.stride, 2
            )
        )

        do {
            let transport = PeerTransport()
            let client = QVACClient(testing: transport, maximumAccumulatedResultBytes: addonCost)
            let run = try await client.batchCompletion(
                modelId: "llm",
                prompts: [.init(history: [.user("prompt")])],
                rpcOptions: .init(timeout: nil)
            )
            let request = try await Self.waitForRequest(on: transport)
            await Self.feedServerStream(
                id: request.id,
                records: [#"{"type":"batchCompletionStream","events":[{"id":"addon","event":{"type":"rawDelta","seq":0,"text":"wire-only"}}]}"#],
                to: transport,
                end: false
            )
            try await Self.waitForPerIDStateCount(1, in: run)
            await Self.feedServerContinuation(
                id: request.id,
                records: [#"{"type":"batchCompletionStream","events":[],"done":true}"#],
                to: transport,
                end: true
            )
            _ = try await run.ids.value
            await client.close()
        }

        do {
            let maximum = addonCost - 1
            let transport = PeerTransport()
            let client = QVACClient(testing: transport, maximumAccumulatedResultBytes: maximum)
            let run = try await client.batchCompletion(
                modelId: "llm",
                prompts: [.init(history: [.user("prompt")])],
                rpcOptions: .init(timeout: nil)
            )
            let globalProbe = StreamProbe<QVACClient.BatchCompletionEvent>()
            Self.record(run.events, in: globalProbe)
            let request = try await Self.waitForRequest(on: transport)
            await Self.feedServerStream(
                id: request.id,
                records: [#"{"type":"batchCompletionStream","events":[{"id":"addon","event":{"type":"rawDelta","seq":0,"text":"wire-only"}}]}"#],
                to: transport,
                end: false
            )
            assertResourceLimit(
                try await Self.waitForResult(of: run.ids, named: "addon ids"),
                maximum: maximum, attempted: addonCost
            )
            let snapshot = try await Self.waitForProbe(
                globalProbe, completed: true, name: "rejected addon event"
            )
            XCTAssertTrue(snapshot.values.isEmpty)
            assertResourceLimit(
                Result<Void, Error>.failure(try XCTUnwrap(snapshot.error)),
                maximum: maximum, attempted: addonCost
            )
            let rpc = await client.rpc
            try await Self.waitForDestroy(id: request.id, on: transport)
            try await Self.waitForNoInFlight(rpc)
            try await Self.proveHeartbeatReuse(client, transport: transport, excluding: request.id)
            await client.close()
        }

        let ids: [String] = ["prompt"]
        let idsCost = QVACClient.conservativeBufferedJSONBytes(
            ids, elementCount: ids.count, fallback: Int.max
        )
        let terminalRecord = #"{"type":"batchCompletionStream","ids":["prompt"],"events":[{"id":"prompt","event":{"type":"completionDone","seq":0,"stopReason":"eos"}}],"done":true}"#

        do {
            let transport = PeerTransport()
            let client = QVACClient(testing: transport, maximumAccumulatedResultBytes: idsCost)
            let run = try await client.batchCompletion(
                modelId: "llm",
                prompts: [.init(id: "prompt", history: [.user("prompt")])],
                rpcOptions: .init(timeout: nil)
            )
            let request = try await Self.waitForRequest(on: transport)
            await Self.feedServerStream(id: request.id, records: [terminalRecord], to: transport, end: true)
            let resolvedIDs = try await run.ids.value
            XCTAssertEqual(resolvedIDs, ids)
            _ = try await run.results.value
            let rpc = await client.rpc
            try await Self.waitForNoInFlight(rpc)
            await client.close()
        }

        do {
            let maximum = idsCost - 1
            let transport = PeerTransport()
            let client = QVACClient(testing: transport, maximumAccumulatedResultBytes: maximum)
            let run = try await client.batchCompletion(
                modelId: "llm",
                prompts: [.init(id: "prompt", history: [.user("prompt")])],
                rpcOptions: .init(timeout: nil)
            )
            let prompt = run.byId("prompt")
            let globalProbe = StreamProbe<QVACClient.BatchCompletionEvent>()
            let promptProbe = StreamProbe<QVACClient.CompletionEvent>()
            Self.record(run.events, in: globalProbe)
            Self.record(prompt.events, in: promptProbe)
            let request = try await Self.waitForRequest(on: transport)
            await Self.feedServerStream(id: request.id, records: [terminalRecord], to: transport, end: false)
            for result in [
                try await Self.waitForResult(of: run.ids, named: "ids overage").map { _ in () },
                try await Self.waitForResult(of: run.results, named: "results overage").map { _ in () },
                try await Self.waitForResult(of: run.stats, named: "stats overage").map { _ in () },
                try await Self.waitForResult(of: prompt.final, named: "prompt overage").map { _ in () },
            ] {
                assertResourceLimit(result, maximum: maximum, attempted: idsCost)
            }
            let global = try await Self.waitForProbe(globalProbe, completed: true, name: "global ids overage")
            let perID = try await Self.waitForProbe(promptProbe, completed: true, name: "per-id ids overage")
            XCTAssertTrue(global.values.isEmpty)
            XCTAssertTrue(perID.values.isEmpty)
            let rpc = await client.rpc
            try await Self.waitForDestroy(id: request.id, on: transport)
            try await Self.waitForNoInFlight(rpc)
            try await Self.proveHeartbeatReuse(client, transport: transport, excluding: request.id)
            await client.close()
        }
    }

    func test_batch_cache_normalization_is_precharged_before_terminal_publication() async throws {
        let visible = "visible"
        let fullText = "<think>private reasoning</think> visible"
        let aggregateBytes = QVACClient.retainedStringAggregateAppendBytes(visible)
            + QVACClient.retainedStringAggregateAppendBytes(fullText)
        let cacheBytes = QVACClient.retainedStringAggregateAppendBytes(fullText)
        let exactBytes = aggregateBytes + cacheBytes
        let record = #"{"type":"batchCompletionStream","events":[{"id":"prompt","event":{"type":"contentDelta","seq":0,"text":"visible"}},{"id":"prompt","event":{"type":"completionDone","seq":1,"stopReason":"eos","raw":{"fullText":"<think>private reasoning</think> visible"}}}],"done":true}"#

        do {
            let transport = PeerTransport()
            let client = QVACClient(
                testing: transport,
                maximumAccumulatedResultBytes: exactBytes
            )
            let run = try await client.batchCompletion(
                modelId: "llm",
                prompts: [.init(id: "prompt", history: [.user("bounded")])],
                rpcOptions: .init(timeout: nil)
            )
            let request = try await Self.waitForRequest(on: transport)
            await Self.feedServerStream(
                id: request.id,
                records: [record],
                to: transport,
                end: true
            )
            let results = try await run.results.value
            XCTAssertEqual(results.map(\.id), ["prompt"])
            XCTAssertEqual(results.first?.final.raw.fullText, fullText)
            XCTAssertEqual(results.first?.final.cacheableAssistantContent, visible)
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
            let run = try await client.batchCompletion(
                modelId: "llm",
                prompts: [.init(id: "prompt", history: [.user("bounded")])],
                rpcOptions: .init(timeout: nil)
            )
            let prompt = run.byId("prompt")
            let globalProbe = StreamProbe<QVACClient.BatchCompletionEvent>()
            let promptProbe = StreamProbe<QVACClient.CompletionEvent>()
            Self.record(run.events, in: globalProbe)
            Self.record(prompt.events, in: promptProbe)
            let request = try await Self.waitForRequest(on: transport)
            await Self.feedServerStream(
                id: request.id,
                records: [record],
                to: transport,
                end: true
            )

            for result in [
                try await Self.waitForResult(of: run.ids, named: "cache-limited ids").map { _ in () },
                try await Self.waitForResult(of: run.results, named: "cache-limited results").map { _ in () },
                try await Self.waitForResult(of: run.stats, named: "cache-limited stats").map { _ in () },
                try await Self.waitForResult(of: prompt.final, named: "cache-limited final").map { _ in () },
            ] {
                assertResourceLimit(result, maximum: maximum, attempted: exactBytes)
            }
            let global = try await Self.waitForProbe(
                globalProbe,
                completed: true,
                name: "cache-limited global events"
            )
            let perID = try await Self.waitForProbe(
                promptProbe,
                completed: true,
                name: "cache-limited prompt events"
            )
            XCTAssertTrue(global.values.isEmpty)
            XCTAssertTrue(perID.values.isEmpty)
            assertResourceLimit(
                Result<Void, Error>.failure(try XCTUnwrap(global.error)),
                maximum: maximum,
                attempted: exactBytes
            )
            assertResourceLimit(
                Result<Void, Error>.failure(try XCTUnwrap(perID.error)),
                maximum: maximum,
                attempted: exactBytes
            )
            let rpc = await client.rpc
            try await Self.waitForNoInFlight(rpc)
            await client.close()
        }
    }

    func test_video_output_cancellation_settles_siblings_and_destroys_exactly_once() async throws {
        let transport = PeerTransport()
        let client = QVACClient(testing: transport)
        let run = try await client.video(
            modelId: "video-model",
            mode: "txt2vid",
            prompt: "long-running",
            rpcOptions: .init(timeout: nil)
        )
        let progressProbe = StreamProbe<QVACClient.VideoProgressTick>()
        let progressRead = Self.record(run.progressStream, in: progressProbe)

        let request = try await Self.waitForRequest(on: transport)
        await Self.feedServerStream(
            id: request.id,
            records: [
                #"{"type":"videoStream","step":1,"totalSteps":8,"elapsedMs":12}"#,
            ],
            to: transport,
            end: false
        )
        let activeProgress = try await Self.waitForProbe(
            progressProbe,
            minimumCount: 1,
            completed: false,
            name: "first video progress tick"
        )
        XCTAssertEqual(
            activeProgress.values,
            [.init(step: 1, totalSteps: 8, elapsedMs: 12)]
        )
        let activeCounts = await (await client.rpc).__testInFlightCounts()
        XCTAssertEqual(activeCounts.sends, 0)
        XCTAssertEqual(activeCounts.streams, 1)
        XCTAssertEqual(activeCounts.duplexes, 0)

        run.outputs.cancel()

        assertCancellation(
            try await Self.waitForResult(of: run.outputs, named: "cancelled video outputs")
        )
        assertCancellation(
            try await Self.waitForResult(of: run.stats, named: "cancelled video stats")
        )
        let terminalProgress = try await Self.waitForProbe(
            progressProbe,
            completed: true,
            name: "cancelled video progress stream"
        )
        XCTAssertEqual(
            terminalProgress.values,
            [.init(step: 1, totalSteps: 8, elapsedMs: 12)]
        )
        XCTAssertTrue(
            terminalProgress.error is CancellationError,
            "progress sibling must settle with CancellationError, got \(String(describing: terminalProgress.error))"
        )
        await progressRead.value

        let rpc = await client.rpc
        try await Self.waitForNoInFlight(rpc)
        try await Self.waitForDestroy(id: request.id, on: transport)
        _ = await rpc.__testInFlightCounts() // Actor barrier for queued idempotent teardown calls.
        await client.close()

        let finalCounts = await rpc.__testInFlightCounts()
        XCTAssertEqual(finalCounts.sends, 0)
        XCTAssertEqual(finalCounts.streams, 0)
        XCTAssertEqual(finalCounts.duplexes, 0)
        let destroys = Self.destroyFrames(
            id: request.id,
            in: Self.frames(in: await transport.outbound())
        )
        XCTAssertEqual(destroys.count, 1, "video cancellation must emit exactly one DESTROY")
        guard case .stream(let destroyID, let flags, .control) = destroys[0] else {
            return XCTFail("video teardown must be a control stream frame")
        }
        XCTAssertEqual(destroyID, request.id)
        XCTAssertEqual(flags, [.response, .destroy])
    }
}
