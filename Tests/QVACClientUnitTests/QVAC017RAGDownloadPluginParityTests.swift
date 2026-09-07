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

    func test_rag_chunk_options_and_embedded_metadata_preserve_every_017_field() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let chunksTask = Task {
            try await client.ragChunk(
                documents: ["first", "second"],
                chunkOpts: .init(
                    chunkSize: 128.5,
                    chunkOverlap: 16.25,
                    chunkStrategy: .paragraph,
                    splitStrategy: .sentence
                )
            )
        }

        var frames = try await Self.waitForFrames(1, on: transport)
        var (id, request) = try Self.request(in: frames)
        let options = try XCTUnwrap(request["chunkOpts"] as? [String: Any])
        XCTAssertEqual(options["chunkSize"] as? Double, 128.5)
        XCTAssertEqual(options["chunkOverlap"] as? Double, 16.25)
        XCTAssertEqual(options["chunkStrategy"] as? String, "paragraph")
        XCTAssertEqual(options["splitStrategy"] as? String, "sentence")
        try await Self.feedReply(
            id: id,
            response: .rag(.init(operation: "chunk", success: true, chunks: [])),
            to: transport
        )
        let chunks = try await chunksTask.value
        XCTAssertTrue(chunks.isEmpty)

        let saveRun = try await client.ragSaveEmbeddings(
            documents: [
                .init(
                    id: "doc-1",
                    content: "content",
                    embedding: [0.25, 0.75],
                    embeddingModelId: "embed-model",
                    metadata: ["source": .string("unit-test")]
                ),
            ],
            modelId: "embed-model",
            workspace: "docs"
        )
        frames = try await Self.waitForFrames(2, on: transport)
        (id, request) = try Self.request(in: Array(frames.dropFirst()))
        let documents = try XCTUnwrap(request["documents"] as? [[String: Any]])
        let first = try XCTUnwrap(documents.first)
        XCTAssertEqual(first["id"] as? String, "doc-1")
        XCTAssertEqual(first["content"] as? String, "content")
        XCTAssertEqual(first["embedding"] as? [Double], [0.25, 0.75])
        XCTAssertEqual(first["embeddingModelId"] as? String, "embed-model")
        XCTAssertEqual((first["metadata"] as? [String: String])?["source"], "unit-test")
        try await Self.feedReply(
            id: id,
            response: .rag(.init(
                operation: "saveEmbeddings",
                success: true,
                processed: [.object([
                    "status": .string("rejected"),
                    "error": .string("duplicate"),
                ])]
            )),
            to: transport
        )
        let saved = try await saveRun.result.value
        XCTAssertEqual(saved, [.init(status: .rejected, id: nil, error: "duplicate")])
        await client.close()
    }

    func test_rag_workspace_lifecycle_round_trips_typed_results_and_exact_requests() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)

        let listTask = Task { try await client.ragListWorkspaces() }
        var frames = try await Self.waitForFrames(1, on: transport)
        var (id, request) = try Self.request(in: frames)
        XCTAssertEqual(request["operation"] as? String, "listWorkspaces")
        try await Self.feedReply(
            id: id,
            response: .rag(.init(
                operation: "listWorkspaces",
                success: true,
                workspaces: [
                    .object(["name": .string("open-docs"), "open": .bool(true)]),
                    .object(["name": .string("archive"), "open": .bool(false)]),
                ]
            )),
            to: transport
        )
        let workspaces = try await listTask.value
        XCTAssertEqual(
            workspaces,
            [
                .init(name: "open-docs", open: true),
                .init(name: "archive", open: false),
            ]
        )

        let closeTask = Task {
            try await client.ragCloseWorkspace(workspace: "open-docs", deleteOnClose: true)
        }
        frames = try await Self.waitForFrames(2, on: transport)
        (id, request) = try Self.request(in: Array(frames.dropFirst()))
        XCTAssertEqual(request["operation"] as? String, "closeWorkspace")
        XCTAssertEqual(request["workspace"] as? String, "open-docs")
        XCTAssertEqual(request["deleteOnClose"] as? Bool, true)
        try await Self.feedReply(
            id: id,
            response: .rag(.init(operation: "closeWorkspace", success: true)),
            to: transport
        )
        try await closeTask.value

        let deleteTask = Task { try await client.ragDeleteWorkspace(workspace: "archive") }
        frames = try await Self.waitForFrames(3, on: transport)
        (id, request) = try Self.request(in: Array(frames.dropFirst(2)))
        XCTAssertEqual(request["operation"] as? String, "deleteWorkspace")
        XCTAssertEqual(request["workspace"] as? String, "archive")
        try await Self.feedReply(
            id: id,
            response: .rag(.init(operation: "deleteWorkspace", success: true)),
            to: transport
        )
        try await deleteTask.value

        do {
            try await client.ragDeleteWorkspace(workspace: "")
            XCTFail("empty workspace name must be rejected locally")
        } catch let QVACError.invalidArgument(message) {
            XCTAssertTrue(message.contains("workspace must not be empty"))
        }
        do {
            try await client.ragDeleteEmbeddings(ids: [])
            XCTFail("empty embedding id list must be rejected locally")
        } catch let QVACError.invalidArgument(message) {
            XCTAssertTrue(message.contains("ids must not be empty"))
        }
        await client.close()
    }

    func test_rag_unary_adapters_reject_missing_wrong_and_mismatched_results() async throws {
        do {
            let transport = MockTransport()
            let client = QVACClient(testing: transport)
            let task = Task { try await client.ragListWorkspaces() }
            let frames = try await Self.waitForFrames(1, on: transport)
            let (id, _) = try Self.request(in: frames)
            try await Self.feedReply(
                id: id,
                response: .rag(.init(operation: "listWorkspaces", success: true)),
                to: transport
            )
            do {
                _ = try await task.value
                XCTFail("missing workspace array must fail")
            } catch let QVACError.protocolViolation(message) {
                XCTAssertTrue(message.contains("omitted workspaces"))
            }
            await client.close()
        }

        do {
            let transport = MockTransport()
            let client = QVACClient(testing: transport)
            let task = Task { try await client.ragChunk(documents: ["document"]) }
            let frames = try await Self.waitForFrames(1, on: transport)
            let (id, _) = try Self.request(in: frames)
            try await Self.feedReply(
                id: id,
                response: .rag(.init(
                    operation: "chunk",
                    success: true,
                    chunks: [.object(["id": .string("missing-content")])]
                )),
                to: transport
            )
            do {
                _ = try await task.value
                XCTFail("malformed chunk must fail")
            } catch let QVACError.protocolViolation(message) {
                XCTAssertTrue(message.contains("string id and content"))
            }
            await client.close()
        }

        do {
            let transport = MockTransport()
            let client = QVACClient(testing: transport)
            let task = Task { try await client.ragSearch(modelId: "embed", query: "query") }
            let frames = try await Self.waitForFrames(1, on: transport)
            let (id, _) = try Self.request(in: frames)
            try await Self.feedReply(
                id: id,
                response: .rag(.init(operation: "chunk", success: true, results: [])),
                to: transport
            )
            do {
                _ = try await task.value
                XCTFail("mismatched RAG operation must fail")
            } catch let QVACError.protocolViolation(message) {
                XCTAssertTrue(message.contains("≠ search"))
            }
            await client.close()
        }

        do {
            let transport = MockTransport()
            let client = QVACClient(testing: transport)
            let task = Task { try await client.ragSearch(modelId: "embed", query: "") }
            do {
                _ = try await task.value
                XCTFail("empty query must fail")
            } catch let QVACError.invalidArgument(message) {
                XCTAssertTrue(message.contains("query must not be empty"))
            }
            let outbound = await transport.outbound()
            XCTAssertTrue(outbound.isEmpty)
            await client.close()
        }
    }

    func test_rag_progress_stream_propagates_worker_error_wrong_type_and_missing_terminal() async throws {
        enum Fixture {
            case workerError
            case wrongType
            case missingTerminal
        }

        for fixture in [Fixture.workerError, .wrongType, .missingTerminal] {
            let transport = MockTransport()
            let client = QVACClient(testing: transport)
            let run = try await client.ragIngest(
                modelId: "embedding-model",
                documents: ["document"],
                withProgress: true
            )
            let frames = try await Self.waitForFrames(2, on: transport)
            let (id, _) = try Self.request(in: frames)
            switch fixture {
            case .workerError:
                await Self.feedServerStream(
                    id: id,
                    records: [#"{"type":"error","code":52800,"message":"save failed"}"#],
                    to: transport
                )
            case .wrongType:
                await Self.feedServerStream(
                    id: id,
                    records: [#"{"type":"heartbeat","number":1}"#],
                    to: transport
                )
            case .missingTerminal:
                await Self.feedServerStream(
                    id: id,
                    records: [
                        #"{"type":"rag:progress","operation":"ingest","workspace":"docs","stage":"embed","current":1,"total":2,"timestamp":1}"#,
                    ],
                    to: transport
                )
            }

            do {
                _ = try await run.result.value
                XCTFail("malformed RAG progress sequence must fail")
            } catch let QVACError.server(code, message) {
                if case .workerError = fixture {
                    XCTAssertEqual(code, .ragSaveFailed)
                    XCTAssertEqual(message, "save failed")
                } else {
                    XCTFail("unexpected server error for \(fixture)")
                }
            } catch let QVACError.protocolViolation(message) {
                if case .wrongType = fixture {
                    XCTAssertTrue(message.contains("rag or rag:progress"))
                } else {
                    XCTFail("unexpected protocol violation for \(fixture): \(message)")
                }
            } catch let QVACError.client(code, _) {
                if case .missingTerminal = fixture {
                    XCTAssertEqual(code, .streamEndedWithoutResponse)
                } else {
                    XCTFail("unexpected client error for \(fixture)")
                }
            } catch {
                XCTFail("unexpected RAG failure for \(fixture): \(error)")
            }
            await client.close()
        }
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
