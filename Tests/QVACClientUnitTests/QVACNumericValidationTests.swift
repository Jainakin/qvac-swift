import Foundation
import XCTest
@testable import QVACClient

/// Boundary validation for numeric values that cross Swift's JSON/JavaScript wire.
/// Every rejected input is asserted to fail before a transport write.
final class QVACNumericValidationTests: XCTestCase {
    private final class InboundPipe: @unchecked Sendable {
        let stream: AsyncThrowingStream<Data, Error>
        let continuation: AsyncThrowingStream<Data, Error>.Continuation

        init() {
            var captured: AsyncThrowingStream<Data, Error>.Continuation!
            stream = AsyncThrowingStream { captured = $0 }
            continuation = captured
        }
    }

    private enum UnexpectedTransportWrite: Error {
        case attempted
    }

    private actor RecordingTransport: BareTransport {
        nonisolated private let inbound = InboundPipe()
        private var writtenBytes = 0

        nonisolated func inboundStream() -> AsyncThrowingStream<Data, Error> {
            inbound.stream
        }

        func write(_ data: Data) async throws {
            writtenBytes += data.count
            throw UnexpectedTransportWrite.attempted
        }

        func close() {
            inbound.continuation.finish()
        }

        func byteCount() -> Int {
            writtenBytes
        }
    }

    private func assertInvalidArgument(
        _ expectedMessage: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("invalid input was accepted", file: file, line: line)
        } catch let QVACError.invalidArgument(message) {
            XCTAssertEqual(message, expectedMessage, file: file, line: line)
        } catch {
            XCTFail(
                "expected QVACError.invalidArgument, got \(error)",
                file: file,
                line: line
            )
        }
    }

    private func assertNoWrites(
        to transport: RecordingTransport,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let byteCount = await transport.byteCount()
        XCTAssertEqual(
            byteCount,
            0,
            "local numeric validation must run before transport I/O",
            file: file,
            line: line
        )
    }

    func test_text_to_speech_stream_rejects_nonpositive_and_nonfinite_buffer_controls_before_io() async {
        let transport = RecordingTransport()
        let client = QVACClient(testing: transport)
        let invalidValues: [Double] = [0, -1, .nan, .infinity, -Double.infinity]

        for value in invalidValues {
            await assertInvalidArgument(
                "textToSpeechStream maxBufferScalars must be a finite positive number"
            ) {
                _ = try await client.textToSpeechStream(
                    modelId: "tts-model",
                    maxBufferScalars: value
                )
            }
            await assertInvalidArgument(
                "textToSpeechStream flushAfterMs must be a finite positive number"
            ) {
                _ = try await client.textToSpeechStream(
                    modelId: "tts-model",
                    flushAfterMs: value
                )
            }
        }

        await assertNoWrites(to: transport)
        await client.close()
    }

    func test_rag_rejects_nonfinite_chunk_numbers_and_invalid_progress_intervals_before_io() async {
        let transport = RecordingTransport()
        let client = QVACClient(testing: transport)
        let nonfiniteValues: [Double] = [.nan, .infinity, -Double.infinity]

        for value in nonfiniteValues {
            await assertInvalidArgument(
                "rag chunk chunkOpts.chunkSize must be a finite number"
            ) {
                _ = try await client.ragChunk(
                    documents: ["document"],
                    chunkOpts: .init(chunkSize: value)
                )
            }
            await assertInvalidArgument(
                "rag chunk chunkOpts.chunkSize must be a finite number"
            ) {
                _ = try await client.ragChunk(
                    documents: "document",
                    chunkOpts: .init(chunkSize: value)
                )
            }
            await assertInvalidArgument(
                "rag ingest chunkOpts.chunkSize must be a finite number"
            ) {
                _ = try await client.ragIngest(
                    modelId: "embedding-model",
                    documents: ["document"],
                    chunkOpts: .init(chunkSize: value)
                )
            }
            await assertInvalidArgument(
                "rag ingest chunkOpts.chunkSize must be a finite number"
            ) {
                _ = try await client.ragIngest(
                    modelId: "embedding-model",
                    documents: "document",
                    chunkOpts: .init(chunkSize: value)
                )
            }

            await assertInvalidArgument(
                "rag chunk chunkOpts.chunkOverlap must be a finite number"
            ) {
                _ = try await client.ragChunk(
                    documents: ["document"],
                    chunkOpts: .init(chunkOverlap: value)
                )
            }
            await assertInvalidArgument(
                "rag chunk chunkOpts.chunkOverlap must be a finite number"
            ) {
                _ = try await client.ragChunk(
                    documents: "document",
                    chunkOpts: .init(chunkOverlap: value)
                )
            }
            await assertInvalidArgument(
                "rag ingest chunkOpts.chunkOverlap must be a finite number"
            ) {
                _ = try await client.ragIngest(
                    modelId: "embedding-model",
                    documents: ["document"],
                    chunkOpts: .init(chunkOverlap: value)
                )
            }
            await assertInvalidArgument(
                "rag ingest chunkOpts.chunkOverlap must be a finite number"
            ) {
                _ = try await client.ragIngest(
                    modelId: "embedding-model",
                    documents: "document",
                    chunkOpts: .init(chunkOverlap: value)
                )
            }
        }

        let invalidIntervals: [Double] = [0, -1, .nan, .infinity, -Double.infinity]
        let validEmbeddedDocument = QVACClient.RagEmbeddedDocument(
            id: "document",
            content: "document",
            embedding: [0.25, 0.75],
            embeddingModelId: "embedding-model"
        )
        for value in invalidIntervals {
            await assertInvalidArgument(
                "rag ingest progressInterval must be a finite positive number"
            ) {
                _ = try await client.ragIngest(
                    modelId: "embedding-model",
                    documents: ["document"],
                    progressInterval: value
                )
            }
            await assertInvalidArgument(
                "rag ingest progressInterval must be a finite positive number"
            ) {
                _ = try await client.ragIngest(
                    modelId: "embedding-model",
                    documents: "document",
                    progressInterval: value
                )
            }
            await assertInvalidArgument(
                "rag saveEmbeddings progressInterval must be a finite positive number"
            ) {
                _ = try await client.ragSaveEmbeddings(
                    documents: [validEmbeddedDocument],
                    progressInterval: value
                )
            }
        }

        await assertNoWrites(to: transport)
        await client.close()
    }

    func test_rag_save_embeddings_rejects_nonfinite_vector_values_before_io() async {
        let transport = RecordingTransport()
        let client = QVACClient(testing: transport)

        for value in [Double.nan, .infinity, -Double.infinity] {
            await assertInvalidArgument(
                "rag saveEmbeddings documents[1].embedding[1] must be a finite number"
            ) {
                _ = try await client.ragSaveEmbeddings(documents: [
                    .init(
                        id: "valid",
                        content: "valid document",
                        embedding: [0.25, 0.75],
                        embeddingModelId: "embedding-model"
                    ),
                    .init(
                        id: "invalid",
                        content: "invalid document",
                        embedding: [0.25, value, 0.75],
                        embeddingModelId: "embedding-model"
                    ),
                ])
            }
        }

        await assertNoWrites(to: transport)
        await client.close()
    }

    func test_bci_stream_rejects_nonpositive_and_wire_unsafe_timestep_counts_before_io() async {
        let transport = RecordingTransport()
        let client = QVACClient(testing: transport)
        let maximumExactWireInteger = 9_007_199_254_740_991
        let invalidCounts = [
            (value: 0, diagnostic: "must be positive"),
            (value: -1, diagnostic: "must be positive"),
            (
                value: maximumExactWireInteger + 1,
                diagnostic: "must not exceed 9007199254740991, "
                    + "the largest exactly representable JSON integer"
            ),
            (
                value: Int.max,
                diagnostic: "must not exceed 9007199254740991, "
                    + "the largest exactly representable JSON integer"
            ),
        ]

        for invalid in invalidCounts {
            await assertInvalidArgument("windowTimesteps \(invalid.diagnostic)") {
                _ = try await client.bciTranscribeStream(
                    modelId: "bci-model",
                    windowTimesteps: invalid.value
                )
            }
            await assertInvalidArgument("hopTimesteps \(invalid.diagnostic)") {
                _ = try await client.bciTranscribeStream(
                    modelId: "bci-model",
                    hopTimesteps: invalid.value
                )
            }
        }

        await assertNoWrites(to: transport)
        await client.close()
    }
}
