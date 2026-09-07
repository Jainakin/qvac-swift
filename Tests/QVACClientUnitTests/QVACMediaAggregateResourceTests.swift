import Foundation
import XCTest
@testable import QVACClient

/// Cumulative retained-memory contracts for eager media result adapters.
///
/// Each fixture exercises the production encoder, bare-rpc multiplexer, NDJSON
/// decoder, terminal handling, and public adapter. Only transport bytes are
/// scripted, so exact-boundary and teardown behavior remain deterministic.
final class QVACMediaAggregateResourceTests: XCTestCase {
    private enum FixtureError: Error {
        case missingRequest
        case timedOut(String)
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

    private final class ObservationCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() {
            lock.withLock { count += 1 }
        }

        func value() -> Int {
            lock.withLock { count }
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

    private struct RunViews: Sendable {
        let result: Task<[Data], Error>
        let dependent: Task<Void, Error>
        let observer: Task<Void, Error>?
    }

    private enum BinaryArrayOperation: String, CaseIterable, Sendable {
        case diffusion = "diffusionStream"
        case upscale = "upscaleStream"
        case video = "videoStream"

        func start(
            on client: QVACClient,
            observationCounter: ObservationCounter? = nil
        ) async throws -> RunViews {
            switch self {
            case .diffusion:
                let run = try await client.diffusion(
                    modelId: "diffusion",
                    prompt: "bounded output",
                    rpcOptions: .init(timeout: nil)
                )
                return RunViews(
                    result: run.outputs,
                    dependent: Task { _ = try await run.stats.value },
                    observer: Task {
                        for try await _ in run.progressStream {
                            observationCounter?.increment()
                        }
                    }
                )
            case .upscale:
                let run = try await client.upscale(
                    modelId: "upscale",
                    image: Data([1]),
                    rpcOptions: .init(timeout: nil)
                )
                return RunViews(
                    result: run.outputs,
                    dependent: Task { _ = try await run.stats.value },
                    observer: nil
                )
            case .video:
                let run = try await client.video(
                    VideoStreamRequest(
                        mode: "txt2vid",
                        modelId: "video",
                        prompt: "bounded output"
                    ),
                    rpcOptions: .init(timeout: nil)
                )
                return RunViews(
                    result: run.outputs,
                    dependent: Task { _ = try await run.stats.value },
                    observer: Task {
                        for try await _ in run.progressStream {
                            observationCounter?.increment()
                        }
                    }
                )
            }
        }

        func record(data: Data, done: Bool) -> String {
            record(encoded: data.base64EncodedString(), done: done)
        }

        func record(encoded: String, done: Bool, includeProgress: Bool = false) -> String {
            let doneField = done ? ",\"done\":true" : ""
            let progressField = includeProgress && self != .upscale
                ? ",\"step\":1,\"totalSteps\":1,\"elapsedMs\":1"
                : ""
            return "{\"type\":\"\(rawValue)\",\"data\":\""
                + encoded
                + "\""
                + progressField
                + doneField
                + "}"
        }
    }

    private static func frames(in data: Data) -> [BareRPCFrame] {
        let reader = BareRPCFrameReader()
        try? reader.append(data)
        var result: [BareRPCFrame] = []
        while let frame = reader.next() { result.append(frame) }
        return result
    }

    private static func waitForRequest(
        on transport: PeerTransport,
        excluding excludedID: UInt64? = nil,
        timeout: Duration = .seconds(2)
    ) async throws -> UInt64 {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            for frame in frames(in: await transport.outbound()) {
                if case .request(let id, _, _, .some) = frame, id != excludedID {
                    return id
                }
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("timed out waiting for an outbound request")
        throw FixtureError.missingRequest
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

    private static func proveClientRemainsUsable(
        _ client: QVACClient,
        transport: PeerTransport,
        after requestID: UInt64
    ) async throws {
        let heartbeat = Task {
            try await client.heartbeat(rpcOptions: .init(timeout: nil))
        }
        let heartbeatID = try await waitForRequest(
            on: transport,
            excluding: requestID
        )
        let payload = try JSONEncoder.qvac.encode(
            QVACResponse.heartbeat(.init(number: 17))
        )
        await transport.feed(BareRPCCodec.__testEncodeResponseFrame(
            id: heartbeatID,
            stream: [],
            payload: .success(payload)
        ))
        let response = try await heartbeat.value
        XCTAssertEqual(response.number, 17)
        try await waitForNoInFlight(await client.rpc)
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

    private static func waitForDestroy(
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
            let resource,
            let actualMaximum,
            let actualAttempted
        ) = error as? QVACError else {
            return XCTFail("expected resourceLimitExceeded, got \(error)", file: file, line: line)
        }
        XCTAssertEqual(actualOperation, operation, file: file, line: line)
        XCTAssertEqual(resource, "accumulated result bytes", file: file, line: line)
        XCTAssertEqual(actualMaximum, maximum, file: file, line: line)
        XCTAssertEqual(actualAttempted, attempted, file: file, line: line)
    }

    private func awaitResourceLimit<Value: Sendable>(
        _ task: Task<Value, Error>,
        operation: String,
        maximum: Int,
        attempted: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await task.value
            XCTFail("expected cumulative result limit failure", file: file, line: line)
        } catch {
            assertResourceLimit(
                error,
                operation: operation,
                maximum: maximum,
                attempted: attempted,
                file: file,
                line: line
            )
        }
    }

    private func awaitProtocolViolation<Value: Sendable>(
        _ task: Task<Value, Error>,
        containing expectedText: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await task.value
            XCTFail("expected protocol violation", file: file, line: line)
        } catch let QVACError.protocolViolation(message) {
            XCTAssertTrue(
                message.contains(expectedText),
                "expected '\(expectedText)' in '\(message)'",
                file: file,
                line: line
            )
        } catch {
            XCTFail("expected protocol violation, got \(error)", file: file, line: line)
        }
    }

    func test_binary_output_arrays_accept_exact_budget_and_fail_one_byte_below() async throws {
        let first = Data([0x01])
        let second = Data([0x02])
        let retainedBytes = QVACClient.retainedBinaryArrayElementBytes(first.count)
            + QVACClient.retainedBinaryArrayElementBytes(second.count)

        for operation in BinaryArrayOperation.allCases {
            do {
                let transport = PeerTransport()
                let client = QVACClient(
                    testing: transport,
                    maximumAccumulatedResultBytes: retainedBytes
                )
                let views = try await operation.start(on: client)
                let requestID = try await Self.waitForRequest(on: transport)
                await Self.feedServerStream(
                    id: requestID,
                    records: [
                        operation.record(data: first, done: false),
                        operation.record(data: second, done: true),
                    ],
                    to: transport,
                    end: true
                )

                let output = try await views.result.value
                XCTAssertEqual(output, [first, second])
                try await views.dependent.value
                if let observer = views.observer { try await observer.value }
                try await Self.waitForNoInFlight(await client.rpc)
                let outbound = await transport.outbound()
                XCTAssertEqual(
                    Self.destroyCount(
                        id: requestID,
                        in: Self.frames(in: outbound)
                    ),
                    0,
                    "\(operation.rawValue) emitted a redundant DESTROY after remote END"
                )
                await client.close()
            }

            do {
                let maximum = retainedBytes - 1
                let transport = PeerTransport()
                let client = QVACClient(
                    testing: transport,
                    maximumAccumulatedResultBytes: maximum
                )
                let views = try await operation.start(on: client)
                let requestID = try await Self.waitForRequest(on: transport)
                await Self.feedServerStream(
                    id: requestID,
                    records: [
                        operation.record(data: first, done: false),
                        operation.record(data: second, done: true),
                    ],
                    to: transport,
                    end: false
                )

                await awaitResourceLimit(
                    views.result,
                    operation: operation.rawValue,
                    maximum: maximum,
                    attempted: retainedBytes
                )
                await awaitResourceLimit(
                    views.dependent,
                    operation: operation.rawValue,
                    maximum: maximum,
                    attempted: retainedBytes
                )
                if let observer = views.observer {
                    await awaitResourceLimit(
                        observer,
                        operation: operation.rawValue,
                        maximum: maximum,
                        attempted: retainedBytes
                    )
                }
                try await Self.waitForDestroy(id: requestID, on: transport)
                try await Self.waitForNoInFlight(await client.rpc)
                try await Self.proveClientRemainsUsable(
                    client,
                    transport: transport,
                    after: requestID
                )
                await client.close()
                let outbound = await transport.outbound()
                XCTAssertEqual(
                    Self.destroyCount(
                        id: requestID,
                        in: Self.frames(in: outbound)
                    ),
                    1,
                    "\(operation.rawValue) must destroy an over-budget RPC exactly once"
                )
            }
        }
    }

    func test_nonterminal_media_overage_fails_observers_and_preserves_client() async throws {
        let operation = BinaryArrayOperation.diffusion
        let first = Data([0x01])
        let second = Data([0x02])
        let attempted = QVACClient.retainedBinaryArrayElementBytes(first.count)
            + QVACClient.retainedBinaryArrayElementBytes(second.count)
        let maximum = attempted - 1
        let transport = PeerTransport()
        let client = QVACClient(
            testing: transport,
            maximumAccumulatedResultBytes: maximum
        )
        let views = try await operation.start(on: client)
        let requestID = try await Self.waitForRequest(on: transport)
        await Self.feedServerStream(
            id: requestID,
            records: [
                operation.record(data: first, done: false),
                operation.record(data: second, done: false),
            ],
            to: transport,
            end: false
        )

        await awaitResourceLimit(
            views.result,
            operation: operation.rawValue,
            maximum: maximum,
            attempted: attempted
        )
        await awaitResourceLimit(
            views.dependent,
            operation: operation.rawValue,
            maximum: maximum,
            attempted: attempted
        )
        if let observer = views.observer {
            await awaitResourceLimit(
                observer,
                operation: operation.rawValue,
                maximum: maximum,
                attempted: attempted
            )
        } else {
            XCTFail("diffusion must expose a progress observer")
        }
        try await Self.waitForDestroy(id: requestID, on: transport)
        try await Self.waitForNoInFlight(await client.rpc)
        try await Self.proveClientRemainsUsable(
            client,
            transport: transport,
            after: requestID
        )
        await client.close()
        let outbound = await transport.outbound()
        XCTAssertEqual(
            Self.destroyCount(id: requestID, in: Self.frames(in: outbound)),
            1
        )
    }

    func test_binary_output_adapters_reject_invalid_alphabet_and_padding_without_publication() async throws {
        for invalidBase64 in ["AA?=", "AA=A"] {
            for operation in BinaryArrayOperation.allCases {
                let transport = PeerTransport()
                let client = QVACClient(
                    testing: transport,
                    maximumAccumulatedResultBytes: 1_024
                )
                let observationCounter = ObservationCounter()
                let views = try await operation.start(
                    on: client,
                    observationCounter: observationCounter
                )
                let requestID = try await Self.waitForRequest(on: transport)
                let carriesProgress = operation != .upscale
                await Self.feedServerStream(
                    id: requestID,
                    records: [
                        operation.record(
                            encoded: invalidBase64,
                            done: !carriesProgress,
                            includeProgress: carriesProgress
                        ),
                    ],
                    to: transport,
                    end: !carriesProgress
                )

                await awaitProtocolViolation(
                    views.result,
                    containing: "invalid base64"
                )
                await awaitProtocolViolation(
                    views.dependent,
                    containing: "invalid base64"
                )
                if let observer = views.observer {
                    await awaitProtocolViolation(
                        observer,
                        containing: "invalid base64"
                    )
                    XCTAssertEqual(
                        observationCounter.value(),
                        0,
                        "\(operation.rawValue) published progress from an invalid record"
                    )
                }
                try await Self.waitForNoInFlight(await client.rpc)
                await client.close()
            }
        }
    }

    func test_audio_output_rejects_invalid_alphabet_and_padding_without_publication() async throws {
        for invalidBase64 in ["AA?=", "AA=A"] {
            let transport = PeerTransport()
            let client = QVACClient(
                testing: transport,
                maximumAccumulatedResultBytes: 1_024
            )
            let run = try await client.audioGen(
                modelId: "audio",
                caption: "invalid PCM",
                rpcOptions: .init(timeout: nil)
            )
            let stats = Task<Void, Error> { _ = try await run.stats.value }
            let observationCounter = ObservationCounter()
            let progress = Task<Void, Error> {
                for try await _ in run.progressStream {
                    observationCounter.increment()
                }
            }
            let requestID = try await Self.waitForRequest(on: transport)
            let record = "{\"type\":\"audioGenStream\",\"data\":\""
                + invalidBase64
                + "\",\"sampleRate\":48000,\"channels\":1,\"bitsPerSample\":16,"
                + "\"progress\":{\"stage\":\"decode\",\"step\":1,\"total\":1},"
                + "\"done\":false}"
            await Self.feedServerStream(
                id: requestID,
                records: [record],
                to: transport,
                end: false
            )

            await awaitProtocolViolation(run.audio, containing: "invalid base64")
            await awaitProtocolViolation(stats, containing: "invalid base64")
            await awaitProtocolViolation(progress, containing: "invalid base64")
            XCTAssertEqual(
                observationCounter.value(),
                0,
                "audioGenStream published progress from an invalid record"
            )
            try await Self.waitForNoInFlight(await client.rpc)
            await client.close()
        }
    }

    func test_audio_pcm_accepts_exact_budget_and_all_views_fail_one_byte_below() async throws {
        let first = Data([1, 2])
        let second = Data([3, 4])
        let retainedBytes = QVACClient.retainedContiguousDataAppendBytes(first.count)
            + QVACClient.retainedContiguousDataAppendBytes(second.count)

        for maximum in [retainedBytes, retainedBytes - 1] {
            let transport = PeerTransport()
            let client = QVACClient(
                testing: transport,
                maximumAccumulatedResultBytes: maximum
            )
            let run = try await client.audioGen(
                modelId: "audio",
                caption: "bounded PCM",
                rpcOptions: .init(timeout: nil)
            )
            let stats = Task<Void, Error> { _ = try await run.stats.value }
            let progress = Task<Void, Error> {
                for try await _ in run.progressStream {}
            }
            let requestID = try await Self.waitForRequest(on: transport)
            let firstRecord = "{\"type\":\"audioGenStream\",\"data\":\""
                + first.base64EncodedString()
                + "\",\"sampleRate\":48000,\"channels\":1,\"bitsPerSample\":16,"
                + "\"done\":false}"
            let terminalRecord = "{\"type\":\"audioGenStream\",\"data\":\""
                + second.base64EncodedString()
                + "\",\"sampleRate\":48000,\"channels\":1,\"bitsPerSample\":16,"
                + "\"done\":true,\"stopReason\":\"completed\"}"
            await Self.feedServerStream(
                id: requestID,
                records: [firstRecord, terminalRecord],
                to: transport,
                end: maximum == retainedBytes
            )

            if maximum == retainedBytes {
                let audio = try await run.audio.value
                XCTAssertEqual(audio.pcm, first + second)
                XCTAssertEqual(audio.sampleRate, 48_000)
                try await stats.value
                try await progress.value
                try await Self.waitForNoInFlight(await client.rpc)
                let outbound = await transport.outbound()
                XCTAssertEqual(
                    Self.destroyCount(
                        id: requestID,
                        in: Self.frames(in: outbound)
                    ),
                    0
                )
            } else {
                await awaitResourceLimit(
                    run.audio,
                    operation: "audioGenStream",
                    maximum: maximum,
                    attempted: retainedBytes
                )
                await awaitResourceLimit(
                    stats,
                    operation: "audioGenStream",
                    maximum: maximum,
                    attempted: retainedBytes
                )
                await awaitResourceLimit(
                    progress,
                    operation: "audioGenStream",
                    maximum: maximum,
                    attempted: retainedBytes
                )
                try await Self.waitForDestroy(id: requestID, on: transport)
                try await Self.waitForNoInFlight(await client.rpc)
                try await Self.proveClientRemainsUsable(
                    client,
                    transport: transport,
                    after: requestID
                )
            }
            await client.close()
            let outbound = await transport.outbound()
            XCTAssertEqual(
                Self.destroyCount(
                    id: requestID,
                    in: Self.frames(in: outbound)
                ),
                maximum == retainedBytes ? 0 : 1
            )
        }
    }

    func test_nonstream_tts_accepts_exact_budget_and_dependent_tasks_fail_one_byte_below() async throws {
        let retainedBytes = 2 * MemoryLayout<Double>.stride * 2
        for maximum in [retainedBytes, retainedBytes - 1] {
            let transport = PeerTransport()
            let client = QVACClient(
                testing: transport,
                maximumAccumulatedResultBytes: maximum
            )
            let run = try await client.textToSpeech(
                modelId: "tts",
                text: "bounded samples",
                stream: false,
                rpcOptions: .init(timeout: nil)
            )
            let requestID = try await Self.waitForRequest(on: transport)
            await Self.feedServerStream(
                id: requestID,
                records: [
                    #"{"type":"textToSpeech","buffer":[1],"done":false}"#,
                    #"{"type":"textToSpeech","buffer":[2],"done":true}"#,
                ],
                to: transport,
                end: maximum == retainedBytes
            )

            if maximum == retainedBytes {
                let buffer = try await run.buffer.value
                let done = try await run.done.value
                XCTAssertEqual(buffer, [1, 2])
                XCTAssertTrue(done)
                try await Self.waitForNoInFlight(await client.rpc)
            } else {
                await awaitResourceLimit(
                    run.buffer,
                    operation: "textToSpeech",
                    maximum: maximum,
                    attempted: retainedBytes
                )
                await awaitResourceLimit(
                    run.done,
                    operation: "textToSpeech",
                    maximum: maximum,
                    attempted: retainedBytes
                )
                try await Self.waitForDestroy(id: requestID, on: transport)
                try await Self.waitForNoInFlight(await client.rpc)
                try await Self.proveClientRemainsUsable(
                    client,
                    transport: transport,
                    after: requestID
                )
            }
            await client.close()
            let outbound = await transport.outbound()
            XCTAssertEqual(
                Self.destroyCount(
                    id: requestID,
                    in: Self.frames(in: outbound)
                ),
                maximum == retainedBytes ? 0 : 1
            )
        }
    }

    func test_nonstream_ocr_counts_structural_memory_at_exact_boundary_and_plus_one() async throws {
        let firstWire: [JSONValue] = [.object(["text": .string("first")])]
        let secondWire: [JSONValue] = [.object([
            "text": .string("second"),
            "bbox": .array([.number(1), .number(2), .number(3), .number(4)]),
        ])]
        let firstCost = QVACClient.conservativeBufferedJSONBytes(
            firstWire,
            elementCount: firstWire.count,
            fallback: Int.max
        )
        let secondCost = QVACClient.conservativeBufferedJSONBytes(
            secondWire,
            elementCount: secondWire.count,
            fallback: Int.max
        )
        let retainedBytes = firstCost + secondCost

        for maximum in [retainedBytes, retainedBytes - 1] {
            let transport = PeerTransport()
            let client = QVACClient(
                testing: transport,
                maximumAccumulatedResultBytes: maximum
            )
            let run = try await client.ocr(
                modelId: "ocr",
                imageBytes: Data(),
                stream: false,
                rpcOptions: .init(timeout: nil)
            )
            let requestID = try await Self.waitForRequest(on: transport)
            await Self.feedServerStream(
                id: requestID,
                records: [
                    #"{"type":"ocrStream","blocks":[{"text":"first"}]}"#,
                    #"{"type":"ocrStream","blocks":[{"text":"second","bbox":[1,2,3,4]}],"done":true}"#,
                ],
                to: transport,
                end: maximum == retainedBytes
            )

            if maximum == retainedBytes {
                let blocks = try await run.blocks.value
                XCTAssertEqual(blocks.map(\.text), ["first", "second"])
                XCTAssertEqual(blocks.last?.boundingBox, [1, 2, 3, 4])
                _ = try await run.stats.value
                try await Self.waitForNoInFlight(await client.rpc)
            } else {
                await awaitResourceLimit(
                    run.blocks,
                    operation: "ocrStream",
                    maximum: maximum,
                    attempted: retainedBytes
                )
                let stats = Task<Void, Error> { _ = try await run.stats.value }
                await awaitResourceLimit(
                    stats,
                    operation: "ocrStream",
                    maximum: maximum,
                    attempted: retainedBytes
                )
                try await Self.waitForDestroy(id: requestID, on: transport)
                try await Self.waitForNoInFlight(await client.rpc)
                try await Self.proveClientRemainsUsable(
                    client,
                    transport: transport,
                    after: requestID
                )
            }
            await client.close()
            let outbound = await transport.outbound()
            XCTAssertEqual(
                Self.destroyCount(
                    id: requestID,
                    in: Self.frames(in: outbound)
                ),
                maximum == retainedBytes ? 0 : 1
            )
        }
    }
}
