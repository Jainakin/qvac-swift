import XCTest
@testable import QVACClient

/// Focused integration coverage for the byte-bounded observational progress
/// surfaces shared by asset downloads and RAG operations.
final class QVACDownloadAndRAGProgressBufferingTests: XCTestCase {
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

        func outbound() -> Data {
            outboundBytes
        }
    }

    private static func frames(in data: Data) -> [BareRPCFrame] {
        let reader = BareRPCFrameReader()
        try? reader.append(data)
        var frames: [BareRPCFrame] = []
        while let frame = reader.next() {
            frames.append(frame)
        }
        return frames
    }

    private static func waitForFrames(
        _ count: Int,
        on transport: MockTransport,
        timeout: Duration = .seconds(1)
    ) async throws -> [BareRPCFrame] {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            let frames = frames(in: await transport.outbound())
            if frames.count >= count {
                return frames
            }
            try await Task.sleep(for: .milliseconds(5))
        }

        let frames = frames(in: await transport.outbound())
        XCTFail("timed out waiting for \(count) outbound bare-rpc frames; got \(frames.count)")
        return frames
    }

    private static func requestID(in frames: [BareRPCFrame]) throws -> UInt64 {
        for frame in frames {
            if case .request(let id, _, _, .some) = frame {
                return id
            }
        }
        throw QVACError.protocolViolation("test peer did not observe an inline request")
    }

    private static func encodedRecord(_ response: QVACResponse) throws -> String {
        String(decoding: try JSONEncoder.qvac.encode(response), as: UTF8.self)
    }

    private static func feedServerStream(
        id: UInt64,
        responses: [QVACResponse],
        to transport: MockTransport
    ) async throws {
        var inbound = BareRPCCodec.__testEncodeResponseFrame(
            id: id,
            stream: [.open],
            payload: .success(nil)
        )
        for response in responses {
            let record = try encodedRecord(response)
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

    func test_downloadAsset_countBudgetRetainsNewestWindowWithoutBlockingResult() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let run = try await client.downloadAssetStreaming(
            assetSrc: "https://example.invalid/model"
        )
        let frames = try await Self.waitForFrames(2, on: transport)
        let id = try Self.requestID(in: frames)
        let emittedCount = QVACClient.publicProgressBufferCapacity + 7
        var responses = (0..<emittedCount).map { index in
            QVACResponse.modelProgress(.init(
                downloadKey: "asset",
                downloaded: Double(index),
                percentage: Double(index),
                total: Double(emittedCount)
            ))
        }
        responses.append(.downloadAsset(.init(
            success: true,
            assetId: "asset-after-count-coalescing"
        )))
        try await Self.feedServerStream(id: id, responses: responses, to: transport)

        let assetID = try await run.result.value
        XCTAssertEqual(assetID, "asset-after-count-coalescing")

        var observed: [QVACClient.ModelLoadProgress] = []
        for try await progress in run.progress {
            observed.append(progress)
        }
        XCTAssertEqual(observed.count, QVACClient.publicProgressBufferCapacity)
        XCTAssertEqual(
            observed.map(\.downloaded),
            (emittedCount - QVACClient.publicProgressBufferCapacity..<emittedCount)
                .map(Double.init)
        )
        await client.close()
    }

    func test_rag_byteBudgetCoalescesToNewestSnapshotWithoutBlockingResult() async throws {
        let snapshots = (1...3).map { current in
            RagProgressResponse(
                current: Double(current),
                operation: "reindex",
                stage: "cluster",
                timestamp: 17,
                total: 3,
                workspace: "docs"
            )
        }
        let estimatedBytes = snapshots.map {
            QVACClient.conservativeBufferedJSONBytes(
                $0,
                elementCount: 1,
                fallback: Int.max
            )
        }
        XCTAssertTrue(estimatedBytes.allSatisfy { $0 == estimatedBytes[0] })
        let maximumBufferedBytes = estimatedBytes[0] * 2 - 1

        let transport = MockTransport()
        let client = QVACClient(
            testing: transport,
            maximumBufferedStreamBytes: maximumBufferedBytes
        )
        let run = try await client.ragReindex(
            modelId: "embed-model",
            workspace: "docs",
            withProgress: true
        )
        let frames = try await Self.waitForFrames(2, on: transport)
        let id = try Self.requestID(in: frames)
        var responses = snapshots.map(QVACResponse.ragProgress)
        responses.append(.rag(.init(
            operation: "reindex",
            success: true,
            result: .object(["reindexed": .bool(true)])
        )))
        try await Self.feedServerStream(id: id, responses: responses, to: transport)

        let result = try await run.result.value
        XCTAssertTrue(result.reindexed)

        var observed: [RagProgressResponse] = []
        for try await progress in run.progress {
            observed.append(progress)
        }
        XCTAssertEqual(observed.map(\.current), [3])
        XCTAssertEqual(observed.first?.stage, "cluster")
        await client.close()
    }

    func test_downloadAsset_oversizedProgressFailsOnlyItsView() async throws {
        let snapshot = ModelProgressResponse(
            downloadKey: String(repeating: "x", count: 512),
            downloaded: 1,
            percentage: 50,
            total: 2
        )
        let estimatedBytes = QVACClient.conservativeBufferedJSONBytes(
            snapshot,
            elementCount: 1,
            fallback: Int.max
        )
        let maximumBufferedBytes = estimatedBytes - 1
        let transport = MockTransport()
        let client = QVACClient(
            testing: transport,
            maximumBufferedStreamBytes: maximumBufferedBytes
        )
        let run = try await client.downloadAssetStreaming(
            assetSrc: "https://example.invalid/oversized-progress"
        )
        let frames = try await Self.waitForFrames(2, on: transport)
        let id = try Self.requestID(in: frames)
        try await Self.feedServerStream(
            id: id,
            responses: [
                .modelProgress(snapshot),
                .downloadAsset(.init(success: true, assetId: "asset-still-succeeds")),
            ],
            to: transport
        )

        let assetID = try await run.result.value
        XCTAssertEqual(assetID, "asset-still-succeeds")

        do {
            for try await _ in run.progress {
                XCTFail("an indivisible oversized progress snapshot must not be emitted")
            }
            XCTFail("the oversized observational view must report its byte overflow")
        } catch let overflow as QVACStreamBufferOverflow {
            XCTAssertEqual(overflow.stream, "downloadAsset.progress")
            XCTAssertEqual(overflow.capacity, QVACClient.publicProgressBufferCapacity)
            XCTAssertEqual(overflow.maximumBufferedBytes, maximumBufferedBytes)
            XCTAssertEqual(overflow.attemptedBufferedBytes, estimatedBytes)
        } catch {
            XCTFail("expected QVACStreamBufferOverflow, got \(error)")
        }
        await client.close()
    }
}
