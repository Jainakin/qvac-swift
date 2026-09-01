import Foundation
import XCTest
@testable import QVACClient

/// Focused parity coverage for operation-specific RAG request and error behavior.
final class QVACRAGErrorParityTests: XCTestCase {
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

    private static func waitForRequest(
        on transport: MockTransport,
        timeout: Duration = .seconds(1)
    ) async throws -> (id: UInt64, body: [String: Any]) {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while clock.now < deadline {
            for frame in frames(in: await transport.outbound()) {
                if case .request(let id, _, _, .some(let data)) = frame {
                    let body = try XCTUnwrap(
                        JSONSerialization.jsonObject(with: data) as? [String: Any]
                    )
                    return (id, body)
                }
            }
            try await Task.sleep(for: .milliseconds(5))
        }

        throw QVACError.protocolViolation("timed out waiting for the RAG request")
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

    func test_reindex_matches_017_request_shape_and_failure_error() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let run = try await client.ragReindex(
            modelId: "embedding-model",
            workspace: "documents"
        )
        let request = try await Self.waitForRequest(on: transport)

        XCTAssertEqual(request.body["operation"] as? String, "reindex")
        XCTAssertEqual(request.body["modelId"] as? String, "embedding-model")
        XCTAssertEqual(request.body["workspace"] as? String, "documents")
        XCTAssertNil(request.body["progressInterval"])

        try await Self.feedReply(
            id: request.id,
            response: .rag(.init(
                operation: "reindex",
                success: false,
                error: "workspace is not initialized"
            )),
            to: transport
        )

        do {
            _ = try await run.result.value
            XCTFail("expected reindex failure")
        } catch QVACError.server(let code, let message) {
            XCTAssertEqual(code, .ragSaveFailed)
            XCTAssertEqual(message, "workspace is not initialized")
        } catch {
            XCTFail("expected RAG_SAVE_FAILED, got \(error)")
        }

        await client.close()
    }

    func test_delete_embeddings_forwards_optional_model_id() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let operation = Task {
            try await client.ragDeleteEmbeddings(
                ids: ["document-1"],
                modelId: "embedding-model",
                workspace: "documents"
            )
        }
        let request = try await Self.waitForRequest(on: transport)

        XCTAssertEqual(request.body["operation"] as? String, "deleteEmbeddings")
        XCTAssertEqual(request.body["ids"] as? [String], ["document-1"])
        XCTAssertEqual(request.body["modelId"] as? String, "embedding-model")
        XCTAssertEqual(request.body["workspace"] as? String, "documents")

        try await Self.feedReply(
            id: request.id,
            response: .rag(.init(operation: "deleteEmbeddings", success: true)),
            to: transport
        )
        try await operation.value
        await client.close()
    }

    func test_save_embeddings_matches_017_request_and_result_shapes() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let run = try await client.ragSaveEmbeddings(
            documents: [.init(
                id: "document-1",
                content: "A pre-embedded document",
                embedding: [0.25, -0.5, 0.75],
                embeddingModelId: "embedding-model",
                metadata: ["source": .string("unit-test")]
            )],
            modelId: "embedding-model",
            workspace: "documents"
        )
        let request = try await Self.waitForRequest(on: transport)

        XCTAssertEqual(request.body["operation"] as? String, "saveEmbeddings")
        XCTAssertEqual(request.body["modelId"] as? String, "embedding-model")
        XCTAssertEqual(request.body["workspace"] as? String, "documents")
        XCTAssertEqual(request.body["requestId"] as? String, run.requestId)
        let documents = try XCTUnwrap(request.body["documents"] as? [[String: Any]])
        XCTAssertEqual(documents.count, 1)
        XCTAssertEqual(documents[0]["id"] as? String, "document-1")
        XCTAssertEqual(documents[0]["content"] as? String, "A pre-embedded document")
        XCTAssertEqual(documents[0]["embeddingModelId"] as? String, "embedding-model")
        XCTAssertEqual(documents[0]["embedding"] as? [Double], [0.25, -0.5, 0.75])
        XCTAssertEqual(
            (documents[0]["metadata"] as? [String: Any])?["source"] as? String,
            "unit-test"
        )

        try await Self.feedReply(
            id: request.id,
            response: .rag(.init(
                operation: "saveEmbeddings",
                success: true,
                processed: [.object([
                    "status": .string("fulfilled"),
                    "id": .string("document-1"),
                ])]
            )),
            to: transport
        )

        let results = try await run.result.value
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].status, .fulfilled)
        XCTAssertEqual(results[0].id, "document-1")
        XCTAssertNil(results[0].error)
        await client.close()
    }
}
