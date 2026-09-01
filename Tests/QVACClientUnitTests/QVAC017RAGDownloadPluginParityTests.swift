import Foundation
import XCTest
@testable import QVACClient

/// Focused wire-level coverage for 0.17 parity details that are easy to lose when
/// adapting JavaScript unions and async generators to Swift overloads and streams.
final class QVAC017RAGDownloadPluginParityTests: XCTestCase {
    private final class InboundPipe: @unchecked Sendable {
        let stream: AsyncThrowingStream<Data, Error>
        let continuation: AsyncThrowingStream<Data, Error>.Continuation

        init() {
            var captured: AsyncThrowingStream<Data, Error>.Continuation!
            stream = AsyncThrowingStream { captured = $0 }
            continuation = captured
        }
    }

    private final class ProfilingCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() {
            lock.withLock { count += 1 }
        }

        func value() -> Int {
            lock.withLock { count }
        }
    }

    private actor MockTransport: BareTransport {
        nonisolated private let inbound = InboundPipe()
        private var outboundBytes = Data()
        private var isClosed = false

        nonisolated func inboundStream() -> AsyncThrowingStream<Data, Error> {
            inbound.stream
        }

        func write(_ data: Data) async throws {
            outboundBytes.append(data)
        }

        func close() {
            guard !isClosed else { return }
            isClosed = true
            inbound.continuation.finish()
        }

        func feed(_ data: Data) {
            inbound.continuation.yield(data)
        }

        func outbound() -> Data { outboundBytes }
    }

    private static func decodedFrames(in data: Data) -> [BareRPCFrame] {
        let reader = BareRPCFrameReader()
        try? reader.append(data)
        var frames: [BareRPCFrame] = []
        while let frame = reader.next() { frames.append(frame) }
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
            let frames = decodedFrames(in: await transport.outbound())
            if frames.count >= count { return frames }
            try await Task.sleep(for: .milliseconds(5))
        }
        let frames = decodedFrames(in: await transport.outbound())
        XCTFail("timed out waiting for \(count) outbound frames; got \(frames.count)")
        return frames
    }

    private static func request(
        in frames: [BareRPCFrame]
    ) throws -> (id: UInt64, body: [String: Any]) {
        for frame in frames {
            if case .request(let id, _, _, .some(let data)) = frame {
                let object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: data) as? [String: Any]
                )
                return (id, object)
            }
        }
        throw QVACError.protocolViolation("test peer did not observe a request payload")
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

    func test_downloadAsset_descriptor_is_transformed_to_src_for_unary_request() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let descriptor = QVACClient.ModelDescriptor(
            src: "https://example.invalid/model.gguf",
            name: "catalog-name",
            modelId: "registry-id",
            engine: "llamacpp-completion",
            expectedSize: 17
        )

        let run = try await client.downloadAsset(assetSrc: descriptor, seed: true)
        let frames = try await Self.waitForFrames(1, on: transport)
        let (id, request) = try Self.request(in: frames)
        XCTAssertEqual(request["assetSrc"] as? String, descriptor.src)
        XCTAssertEqual(request["seed"] as? Bool, true)
        XCTAssertNil(request["name"])
        XCTAssertNil(request["modelId"])
        XCTAssertNil(request["engine"])

        try await Self.feedReply(
            id: id,
            response: .downloadAsset(.init(success: true, assetId: "asset-id")),
            to: transport
        )
        let assetId = try await run.result.value
        XCTAssertEqual(assetId, "asset-id")
        await client.close()
    }

    func test_downloadAssetStreaming_descriptor_uses_same_src_transform() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let descriptor = QVACClient.ModelDescriptor(
            src: "pear://012345/model.gguf",
            name: "ignored-by-download"
        )

        let run = try await client.downloadAssetStreaming(assetSrc: descriptor)
        let frames = try await Self.waitForFrames(2, on: transport)
        let (id, request) = try Self.request(in: frames)
        XCTAssertEqual(request["assetSrc"] as? String, descriptor.src)
        XCTAssertEqual(request["withProgress"] as? Bool, true)
        await Self.feedServerStream(
            id: id,
            records: [
                #"{"type":"downloadAsset","success":true,"assetId":"streamed-asset"}"#,
            ],
            to: transport
        )
        let assetId = try await run.result.value
        XCTAssertEqual(assetId, "streamed-asset")
        await client.close()
    }

    func test_ragChunk_accepts_scalar_document_input() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let resultTask = Task {
            try await client.ragChunk(documents: "one document")
        }

        let frames = try await Self.waitForFrames(1, on: transport)
        let (id, request) = try Self.request(in: frames)
        XCTAssertEqual(request["documents"] as? String, "one document")
        try await Self.feedReply(
            id: id,
            response: .rag(.init(
                operation: "chunk",
                success: true,
                chunks: [.object([
                    "id": .string("chunk-1"),
                    "content": .string("one document"),
                ])]
            )),
            to: transport
        )
        let chunks = try await resultTask.value
        XCTAssertEqual(chunks, [.init(id: "chunk-1", content: "one document")])
        await client.close()
    }

    func test_ragIngest_accepts_scalar_and_preserves_numeric_droppedIndices() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let run = try await client.ragIngest(
            modelId: "embedding-model",
            documents: "one document"
        )

        let frames = try await Self.waitForFrames(1, on: transport)
        let (id, request) = try Self.request(in: frames)
        XCTAssertEqual(request["documents"] as? String, "one document")
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

    func test_ragSearch_accepts_positive_fractional_topKAndN() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let resultTask = Task {
            try await client.ragSearch(
                modelId: "embedding-model",
                query: "query",
                topK: 2.5,
                n: 1.25
            )
        }

        let frames = try await Self.waitForFrames(1, on: transport)
        let (id, request) = try Self.request(in: frames)
        XCTAssertEqual(request["topK"] as? Double, 2.5)
        XCTAssertEqual(request["n"] as? Double, 1.25)
        try await Self.feedReply(
            id: id,
            response: .rag(.init(operation: "search", success: true, results: [])),
            to: transport
        )
        let results = try await resultTask.value
        XCTAssertTrue(results.isEmpty)
        await client.close()
    }

    func test_ragSearch_rejects_nonpositive_and_nonfinite_numbers_before_transport() async {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)

        for (topK, n) in [(0.0, 1.0), (1.0, -0.5), (.infinity, 1.0), (1.0, .nan)] {
            do {
                _ = try await client.ragSearch(
                    modelId: "embedding-model",
                    query: "query",
                    topK: topK,
                    n: n
                )
                XCTFail("invalid topK/n unexpectedly reached the transport")
            } catch let QVACError.invalidArgument(message) {
                XCTAssertTrue(message.contains("finite number greater than zero"))
            } catch {
                XCTFail("expected invalidArgument, got \(error)")
            }
        }

        let outbound = await transport.outbound()
        XCTAssertTrue(outbound.isEmpty)
        await client.close()
    }

    func test_rag_stream_ignores_other_operation_progress_and_drains_profile() async throws {
        let transport = MockTransport()
        let profiling = ProfilingCounter()
        let client = QVACClient(
            testing: transport,
            profilingMetadataHandler: { _ in profiling.increment() }
        )
        let run = try await client.ragIngest(
            modelId: "embedding-model",
            documents: ["document"],
            withProgress: true
        )
        let frames = try await Self.waitForFrames(2, on: transport)
        let (id, _) = try Self.request(in: frames)
        await Self.feedServerStream(
            id: id,
            records: [
                #"{"type":"rag:progress","operation":"reindex","workspace":"docs","stage":"cluster","current":1,"total":2,"timestamp":1}"#,
                #"{"type":"rag:progress","operation":"ingest","workspace":"docs","stage":"embed","current":2,"total":3,"timestamp":2}"#,
                #"{"type":"rag","operation":"ingest","success":true,"processed":[],"droppedIndices":[]}"#,
                #"{"__profilingTrailer":true,"__profiling":{"id":"rag-profile"}}"#,
            ],
            to: transport
        )

        let result = try await run.result.value
        XCTAssertTrue(result.processed.isEmpty)
        XCTAssertEqual(profiling.value(), 1)
        var progress: [RagProgressResponse] = []
        for try await event in run.progress { progress.append(event) }
        XCTAssertEqual(progress.map(\.operation), ["ingest"])
        XCTAssertEqual(progress.map(\.stage), ["embed"])
        await client.close()
    }

    func test_plugin_stream_accepts_eof_without_done_and_done_only_suppresses_its_frame() async throws {
        let transport = MockTransport()
        let profiling = ProfilingCounter()
        let client = QVACClient(
            testing: transport,
            profilingMetadataHandler: { _ in profiling.increment() }
        )
        let chunksTask = Task { () throws -> [String] in
            let stream: QVACResponseStream<String> = try await client.invokePluginStream(
                modelId: "plugin-model",
                handler: "stream",
                params: ["prompt": "hello"],
                as: String.self
            )
            var chunks: [String] = []
            for try await chunk in stream { chunks.append(chunk) }
            return chunks
        }

        let frames = try await Self.waitForFrames(2, on: transport)
        let (id, _) = try Self.request(in: frames)
        await Self.feedServerStream(
            id: id,
            records: [
                #"{"type":"pluginInvokeStream","result":"first"}"#,
                #"{"type":"pluginInvokeStream","result":"suppressed","done":true}"#,
                #"{"type":"pluginInvokeStream","result":"last","done":false}"#,
                #"{"__profilingTrailer":true,"__profiling":{"id":"plugin-profile"}}"#,
            ],
            to: transport
        )

        let chunks = try await chunksTask.value
        XCTAssertEqual(chunks, ["first", "last"])
        XCTAssertEqual(profiling.value(), 1)
        await client.close()
    }
}
