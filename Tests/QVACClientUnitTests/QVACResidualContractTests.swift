import Foundation
import XCTest
@testable import QVACClient

#if canImport(Darwin)
import Darwin
#endif

/// Residual adversarial coverage for public adapters whose happy paths are already
/// specified elsewhere. These cases focus on malformed worker output, terminal
/// semantics, and resource teardown rather than duplicating successful examples.
final class QVACResidualContractTests: XCTestCase {
    private final class InboundPipe: @unchecked Sendable {
        let stream: AsyncThrowingStream<Data, Error>
        let continuation: AsyncThrowingStream<Data, Error>.Continuation

        init() {
            let pair = AsyncThrowingStream<Data, Error>.makeStream()
            stream = pair.stream
            continuation = pair.continuation
        }
    }

    /// In-memory bare-rpc peer that acknowledges duplex opens and records exact
    /// outbound frames. Tests still exercise the production framing and adapters.
    private actor MockTransport: BareTransport {
        nonisolated private let inbound = InboundPipe()
        private var outboundBytes = Data()
        private var acknowledgedDuplexIDs: Set<UInt64> = []
        private var closed = false

        nonisolated func inboundStream() -> AsyncThrowingStream<Data, Error> {
            inbound.stream
        }

        func write(_ data: Data) throws {
            guard !closed else { throw BareRPCConnectionClosed() }
            outboundBytes.append(data)

            let reader = BareRPCFrameReader()
            try reader.append(data)
            while let frame = reader.next() {
                guard case .request(let id, _, let flags, _) = frame,
                      flags.contains(.open),
                      acknowledgedDuplexIDs.insert(id).inserted else { continue }

                var acknowledgement = BareRPCCodec.__testEncodeStreamFrame(
                    id: id,
                    flags: [.request, .open]
                )
                acknowledgement.append(BareRPCCodec.__testEncodeStreamFrame(
                    id: id,
                    flags: [.response, .open]
                ))
                inbound.continuation.yield(acknowledgement)
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
    }

    private static func frames(in bytes: Data) throws -> [BareRPCFrame] {
        let reader = BareRPCFrameReader()
        try reader.append(bytes)
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
            let frames = try Self.frames(in: await transport.outbound())
            if frames.count >= count { return frames }
            try await Task.sleep(for: .milliseconds(2))
        }
        let frames = try Self.frames(in: await transport.outbound())
        throw QVACError.protocolViolation(
            "test peer expected \(count) outbound frames, observed \(frames.count)"
        )
    }

    private static func requestID(in frames: [BareRPCFrame]) throws -> UInt64 {
        for frame in frames {
            if case .request(let id, _, _, _) = frame { return id }
        }
        throw QVACError.protocolViolation("test peer did not observe a request")
    }

    private static func feedUnary(
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
        var bytes = BareRPCCodec.__testEncodeResponseFrame(
            id: id,
            stream: [.open],
            payload: .success(nil)
        )
        for record in records {
            bytes.append(BareRPCCodec.__testEncodeStreamFrame(
                id: id,
                flags: [.response, .data],
                payload: .data(Data((record + "\n").utf8))
            ))
        }
        bytes.append(BareRPCCodec.__testEncodeStreamFrame(
            id: id,
            flags: [.response, .end]
        ))
        await transport.feed(bytes)
    }

    private static func feedDuplex(
        id: UInt64,
        records: [String],
        to transport: MockTransport
    ) async {
        var bytes = Data()
        for record in records {
            bytes.append(BareRPCCodec.__testEncodeStreamFrame(
                id: id,
                flags: [.response, .data],
                payload: .data(Data((record + "\n").utf8))
            ))
        }
        bytes.append(BareRPCCodec.__testEncodeStreamFrame(
            id: id,
            flags: [.response, .end]
        ))
        await transport.feed(bytes)
    }

    private static func unaryResult<T: Sendable>(
        response: QVACResponse,
        operation: @escaping @Sendable (QVACClient) async throws -> T
    ) async throws -> Result<T, Error> {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let task = Task { try await operation(client) }
        do {
            let id = try requestID(in: try await waitForFrames(1, on: transport))
            try await feedUnary(id: id, response: response, to: transport)
            let result = await task.result
            await client.close()
            return result
        } catch {
            task.cancel()
            await client.close()
            throw error
        }
    }

    private static func serverStreamResult<T: Sendable>(
        records: [String],
        operation: @escaping @Sendable (QVACClient) async throws -> T
    ) async throws -> Result<T, Error> {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let task = Task { try await operation(client) }
        do {
            let id = try requestID(in: try await waitForFrames(1, on: transport))
            await feedServerStream(id: id, records: records, to: transport)
            let result = await task.result
            await client.close()
            return result
        } catch {
            task.cancel()
            await client.close()
            throw error
        }
    }

    private func assertProtocolViolation<T>(
        _ result: Result<T, Error>,
        contains fragment: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .failure(let error) = result,
              case .protocolViolation(let message) = error as? QVACError else {
            return XCTFail("expected protocol violation, got \(result)", file: file, line: line)
        }
        XCTAssertTrue(message.contains(fragment), message, file: file, line: line)
    }

    private func assertFailure<T>(
        _ result: Result<T, Error>,
        code expectedCode: QVACErrorCode,
        message expectedMessage: String,
        clientSide: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .failure(let error) = result else {
            return XCTFail("expected QVAC failure, got \(result)", file: file, line: line)
        }
        switch (clientSide, error as? QVACError) {
        case (false, .server(let code, let message)),
             (true, .client(let code, let message)):
            XCTAssertEqual(code, expectedCode, file: file, line: line)
            XCTAssertEqual(message, expectedMessage, file: file, line: line)
        default:
            XCTFail("expected typed QVAC failure, got \(error)", file: file, line: line)
        }
    }

    // MARK: - Shared wire/error boundaries

    func test_high_level_success_responses_reject_present_errors_across_every_family() async throws {
        let message = "inconsistent success response"

        let cancel: Result<QVACClient.CancelAcknowledgement, Error> = try await Self.unaryResult(
            response: .cancel(.init(success: true, cancelled: 1, error: message))
        ) { client in
            try await client.cancel(.request(requestId: "request"))
        }
        assertFailure(cancel, code: .cancelFailed, message: message)

        let deleteCache: Result<DeleteCacheResponse, Error> = try await Self.unaryResult(
            response: .deleteCache(.init(success: true, error: message))
        ) { client in
            try await client.deleteCache(.init(all: true))
        }
        assertFailure(deleteCache, code: .deleteCacheFailed, message: message)

        let download: Result<String, Error> = try await Self.unaryResult(
            response: .downloadAsset(.init(
                success: true,
                assetId: "must-not-publish",
                error: message
            ))
        ) { client in
            let run = try await client.downloadAsset(assetSrc: "hf:asset")
            return try await run.result.value
        }
        assertFailure(download, code: .downloadAssetFailed, message: message)

        let embed: Result<QVACClient.EmbeddingOutcome<[Double]>, Error> = try await Self.unaryResult(
            response: .embed(.init(
                embedding: .array([.number(1)]),
                success: true,
                error: message
            ))
        ) { client in
            let run = try await client.embed(modelId: "embed", text: "text")
            return try await run.result.value
        }
        assertFailure(embed, code: .embedFailed, message: message)

        let load: Result<String, Error> = try await Self.unaryResult(
            response: .loadModel(.init(
                success: true,
                error: message,
                modelId: "must-not-publish"
            ))
        ) { client in
            let run = try await client.loadModel(
                modelSrc: "hf:model",
                modelType: "llamacpp-completion"
            )
            return try await run.result.value
        }
        assertFailure(load, code: .modelLoadFailed, message: message)

        let registryList: Result<[JSONValue], Error> = try await Self.unaryResult(
            response: .modelRegistryList(.init(success: true, error: message, models: []))
        ) { client in
            try await client.modelRegistryList()
        }
        assertFailure(registryList, code: .qvacModelRegistryQueryFailed, message: message)

        let registrySearch: Result<[JSONValue], Error> = try await Self.unaryResult(
            response: .modelRegistrySearch(.init(success: true, error: message, models: []))
        ) { client in
            try await client.modelRegistrySearch(filter: "model")
        }
        assertFailure(registrySearch, code: .qvacModelRegistryQueryFailed, message: message)

        let registryGet: Result<JSONValue, Error> = try await Self.unaryResult(
            response: .modelRegistryGetModel(.init(
                success: true,
                error: message,
                model: .object(["id": .string("must-not-publish")])
            ))
        ) { client in
            try await client.modelRegistryGetModel(
                registryPath: "org/model",
                registrySource: "huggingface"
            )
        }
        assertFailure(registryGet, code: .qvacModelRegistryQueryFailed, message: message)

        let provide: Result<ProvideResponse, Error> = try await Self.unaryResult(
            response: .provide(.init(
                success: true,
                error: message,
                publicKey: "must-not-publish"
            ))
        ) { client in
            try await client.startQVACProvider()
        }
        assertFailure(
            provide,
            code: .providerStartFailed,
            message: message,
            clientSide: true
        )

        let rag: Result<[QVACClient.RagWorkspaceInfo], Error> = try await Self.unaryResult(
            response: .rag(.init(
                operation: "listWorkspaces",
                success: true,
                error: message,
                workspaces: []
            ))
        ) { client in
            try await client.ragListWorkspaces()
        }
        assertFailure(rag, code: .ragListWorkspacesFailed, message: message)

        let stopProvide: Result<StopProvideResponse, Error> = try await Self.unaryResult(
            response: .stopProvide(.init(success: true, error: message))
        ) { client in
            try await client.stopQVACProvider()
        }
        assertFailure(
            stopProvide,
            code: .providerStopFailed,
            message: message,
            clientSide: true
        )

        let unload: Result<UnloadModelResponse, Error> = try await Self.unaryResult(
            response: .unloadModel(.init(success: true, error: message))
        ) { client in
            try await client.unloadModel(modelId: "model")
        }
        assertFailure(unload, code: .modelUnloadFailed, message: message)
    }

    func test_unexpected_error_union_uses_checked_typed_error_mapping() {
        do {
            try QVACClient.rejectUnexpectedResponse(
                .error(.init(message: "model missing", code: 52_002)),
                expected: "heartbeat"
            )
        } catch let QVACError.server(code, message) {
            XCTAssertEqual(code, .modelNotFound)
            XCTAssertEqual(message, "model missing")
        } catch {
            XCTFail("unexpected checked wire error: \(error)")
        }

        do {
            try QVACClient.rejectUnexpectedResponse(
                .error(.init(message: "fractional code", code: 52_002.5)),
                expected: "heartbeat"
            )
        } catch let QVACError.protocolViolation(message) {
            XCTAssertTrue(message.contains("error.code"), message)
        } catch {
            XCTFail("unexpected malformed-code error: \(error)")
        }
    }

    func test_error_descriptions_apply_nil_fallbacks_for_server_and_empty_partial_state() {
        XCTAssertEqual(
            QVACError.server(.modelNotFound, message: nil).description,
            "QVAC server error 52002 (modelNotFound): no message"
        )
        let empty = QVACClient.InferenceCancelledPartial(text: nil, toolCalls: nil)
        XCTAssertEqual(
            QVACError.inferenceCancelled(requestId: "cancelled", partial: empty).description,
            "QVAC inference cancelled was cancelled (partial text: 0 characters, tool calls: 0)"
        )
    }

    // MARK: - Asset download terminal contracts

    func test_download_asset_unary_rejects_wrong_response_discriminator() async throws {
        let result: Result<String, Error> = try await Self.unaryResult(
            response: .heartbeat(.init(number: 1))
        ) { client in
            let run = try await client.downloadAsset(assetSrc: "https://example.invalid/model")
            return try await run.result.value
        }
        assertProtocolViolation(result, contains: "expected downloadAsset")
    }

    func test_download_asset_unary_distinguishes_worker_failure_and_missing_asset_id() async throws {
        let failed: Result<String, Error> = try await Self.unaryResult(
            response: .downloadAsset(.init(success: false, error: "disk full"))
        ) { client in
            let run = try await client.downloadAsset(assetSrc: "https://example.invalid/model")
            return try await run.result.value
        }
        guard case .failure(let failedError) = failed,
              case .server(let code, let message) = failedError as? QVACError else {
            return XCTFail("expected typed download failure, got \(failed)")
        }
        XCTAssertEqual(code, .downloadAssetFailed)
        XCTAssertEqual(message, "disk full")

        let missingID: Result<String, Error> = try await Self.unaryResult(
            response: .downloadAsset(.init(success: true))
        ) { client in
            let run = try await client.downloadAsset(assetSrc: "https://example.invalid/model")
            return try await run.result.value
        }
        assertProtocolViolation(missingID, contains: "missing assetId")
    }

    func test_download_asset_stream_maps_wire_errors_and_rejects_unrelated_frames() async throws {
        let wireError: Result<String, Error> = try await Self.serverStreamResult(
            records: [#"{"type":"error","code":52002,"message":"missing source"}"#]
        ) { client in
            let run = try await client.downloadAssetStreaming(
                assetSrc: "https://example.invalid/model"
            )
            return try await run.result.value
        }
        guard case .failure(let streamError) = wireError,
              case .server(let code, let message) = streamError as? QVACError else {
            return XCTFail("expected typed streamed download failure, got \(wireError)")
        }
        XCTAssertEqual(code, .modelNotFound)
        XCTAssertEqual(message, "missing source")

        let unrelated: Result<String, Error> = try await Self.serverStreamResult(
            records: [#"{"type":"heartbeat","number":7}"#]
        ) { client in
            let run = try await client.downloadAssetStreaming(
                assetSrc: "https://example.invalid/model"
            )
            return try await run.result.value
        }
        assertProtocolViolation(unrelated, contains: "downloadAsset or modelProgress")
    }

    // MARK: - Plugin bounded-response contract

    func test_bounded_plugin_invocation_rejects_wrong_response_discriminator() async throws {
        let result: Result<JSONValue, Error> = try await Self.unaryResult(
            response: .heartbeat(.init(number: 9))
        ) { client in
            try await client.invokePluginWithResponseLimit(
                modelId: "plugin-model",
                handler: "bounded-handler",
                params: ["prompt": "hello"],
                rpcOptions: .init(),
                maximumResponseBytes: 4_096
            )
        }
        assertProtocolViolation(result, contains: "expected pluginInvoke")
    }

    // MARK: - Text-to-speech duplex terminal contracts

    func test_tts_stream_text_write_preserves_utf8_and_destroy_closes_both_directions() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let session = try await client.textToSpeechStream(
            modelId: "tts-model",
            rpcOptions: .init(timeout: nil)
        )
        let initial = try await Self.waitForFrames(3, on: transport)
        let id = try Self.requestID(in: initial)

        let text = "Grüße 👋"
        try await session.write(text: text)
        let afterWrite = try await Self.waitForFrames(4, on: transport)
        let requestData = afterWrite.compactMap { frame -> Data? in
            guard case .stream(let frameID, let flags, .data(let data)) = frame,
                  frameID == id,
                  flags.contains(.request) else { return nil }
            return data
        }
        XCTAssertEqual(requestData.last, Data(text.utf8))

        session.destroy()
        let closed = try await Self.waitForFrames(6, on: transport)
        XCTAssertTrue(closed.contains { frame in
            guard case .stream(let frameID, let flags, .control) = frame else { return false }
            return frameID == id && flags.contains(.request) && flags.contains(.close)
        })
        XCTAssertTrue(closed.contains { frame in
            guard case .stream(let frameID, let flags, .control) = frame else { return false }
            return frameID == id && flags.contains(.response) && flags.contains(.destroy)
        })
        await client.close()
    }

    func test_tts_stream_rejects_eof_without_terminal_done_frame() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let session = try await client.textToSpeechStream(
            modelId: "tts-model",
            rpcOptions: .init(timeout: nil)
        )
        let id = try Self.requestID(in: try await Self.waitForFrames(3, on: transport))
        await Self.feedDuplex(
            id: id,
            records: [#"{"type":"textToSpeechStream","buffer":[1,-1],"done":false}"#],
            to: transport
        )

        var iterator = session.chunks.makeAsyncIterator()
        let first = try await iterator.next()
        XCTAssertEqual(first?.buffer, [1, -1])
        do {
            _ = try await iterator.next()
            XCTFail("TTS EOF without done must reject")
        } catch let QVACError.client(code, message) {
            XCTAssertEqual(code, .streamEndedWithoutResponse)
            XCTAssertTrue(message?.contains("textToSpeechStream") == true)
        } catch {
            XCTFail("unexpected TTS terminal error: \(error)")
        }
        await client.close()
    }

    // MARK: - BCI duplex response contracts

    func test_bci_stream_emits_live_and_terminal_segment_payloads_in_order() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let session = try await client.bciTranscribeStream(
            modelId: "bci-model",
            metadata: true,
            rpcOptions: .init(timeout: nil)
        )
        let id = try Self.requestID(in: try await Self.waitForFrames(3, on: transport))
        await Self.feedDuplex(
            id: id,
            records: [
                #"{"type":"bciTranscribeStream","segment":{"id":1,"text":"live","startMs":0,"endMs":10,"append":true}}"#,
                #"{"type":"bciTranscribeStream","done":true,"segment":{"id":2,"text":"terminal","startMs":10,"endMs":20,"append":false},"text":"tail","stats":{"windows":2}}"#,
            ],
            to: transport
        )

        var events: [QVACClient.BciTranscribeStreamEvent] = []
        for try await event in session.events { events.append(event) }
        XCTAssertEqual(events.count, 4)
        guard case .segment(let live) = events[0],
              case .segment(let terminal) = events[1] else {
            await client.close()
            return XCTFail("expected live and terminal segment events")
        }
        XCTAssertEqual(live.id, 1)
        XCTAssertEqual(live.text, "live")
        XCTAssertTrue(live.append)
        XCTAssertEqual(terminal.id, 2)
        XCTAssertEqual(terminal.text, "terminal")
        XCTAssertFalse(terminal.append)
        XCTAssertEqual(events[2], .text("tail"))
        XCTAssertEqual(events[3], .done(stats: .object(["windows": .number(2)])))
        await client.close()
    }

    func test_bci_stream_maps_worker_error_and_rejects_eof_without_done() async throws {
        do {
            let transport = MockTransport()
            let client = QVACClient(testing: transport)
            let session = try await client.bciTranscribeStream(
                modelId: "bci-model",
                rpcOptions: .init(timeout: nil)
            )
            let id = try Self.requestID(in: try await Self.waitForFrames(3, on: transport))
            await Self.feedDuplex(
                id: id,
                records: [#"{"type":"bciTranscribeStream","error":"decoder failed"}"#],
                to: transport
            )
            do {
                for try await _ in session.events {}
                XCTFail("BCI worker error must reject")
            } catch let QVACError.server(code, message) {
                XCTAssertEqual(code, .transcriptionFailed)
                XCTAssertEqual(message, "decoder failed")
            } catch {
                XCTFail("unexpected BCI worker error: \(error)")
            }
            await client.close()
        }

        do {
            let transport = MockTransport()
            let client = QVACClient(testing: transport)
            let session = try await client.bciTranscribeStream(
                modelId: "bci-model",
                rpcOptions: .init(timeout: nil)
            )
            let id = try Self.requestID(in: try await Self.waitForFrames(3, on: transport))
            await Self.feedDuplex(
                id: id,
                records: [#"{"type":"bciTranscribeStream","text":"partial"}"#],
                to: transport
            )
            do {
                for try await _ in session.events {}
                XCTFail("BCI EOF without done must reject")
            } catch let QVACError.client(code, message) {
                XCTAssertEqual(code, .streamEndedWithoutResponse)
                XCTAssertTrue(message?.contains("bciTranscribeStream") == true)
            } catch {
                XCTFail("unexpected BCI EOF error: \(error)")
            }
            await client.close()
        }
    }

    func test_bci_stream_malformed_terminal_segment_is_protocol_violation_and_destroy_is_explicit() async throws {
        do {
            let transport = MockTransport()
            let client = QVACClient(testing: transport)
            let session = try await client.bciTranscribeStream(
                modelId: "bci-model",
                metadata: true,
                rpcOptions: .init(timeout: nil)
            )
            let id = try Self.requestID(in: try await Self.waitForFrames(3, on: transport))
            await Self.feedDuplex(
                id: id,
                records: [
                    #"{"type":"bciTranscribeStream","done":true,"segment":{"text":"missing timing"}}"#,
                ],
                to: transport
            )
            do {
                for try await _ in session.events {}
                XCTFail("malformed terminal BCI segment must reject")
            } catch let QVACError.protocolViolation(message) {
                XCTAssertTrue(message.contains("segment"), message)
            } catch {
                XCTFail("unexpected malformed BCI error: \(error)")
            }
            await client.close()
        }

        do {
            let transport = MockTransport()
            let client = QVACClient(testing: transport)
            let session = try await client.bciTranscribeStream(
                modelId: "bci-model",
                rpcOptions: .init(timeout: nil)
            )
            let id = try Self.requestID(in: try await Self.waitForFrames(3, on: transport))
            session.destroy()
            let frames = try await Self.waitForFrames(5, on: transport)
            XCTAssertTrue(frames.contains { frame in
                guard case .stream(let frameID, let flags, .control) = frame else { return false }
                return frameID == id && flags.contains(.request) && flags.contains(.close)
            })
            XCTAssertTrue(frames.contains { frame in
                guard case .stream(let frameID, let flags, .control) = frame else { return false }
                return frameID == id && flags.contains(.response) && flags.contains(.destroy)
            })
            await client.close()
        }
    }

    // MARK: - RAG malformed terminal contracts

    func test_rag_ingest_variants_require_processed_and_dropped_indices() async throws {
        let arrayResult: Result<QVACClient.RagIngestResult, Error> = try await Self.unaryResult(
            response: .rag(.init(operation: "ingest", success: true, processed: []))
        ) { client in
            let run = try await client.ragIngest(modelId: "embed", documents: ["doc"])
            return try await run.result.value
        }
        assertProtocolViolation(arrayResult, contains: "processed or droppedIndices")

        let scalarResult: Result<QVACClient.RagIngestResult, Error> = try await Self.unaryResult(
            response: .rag(.init(operation: "ingest", success: true, droppedIndices: []))
        ) { client in
            let run = try await client.ragIngest(modelId: "embed", documents: "doc")
            return try await run.result.value
        }
        assertProtocolViolation(scalarResult, contains: "processed or droppedIndices")
    }

    func test_rag_query_chunk_save_and_reindex_require_operation_specific_fields() async throws {
        let search: Result<[QVACClient.RagSearchResult], Error> = try await Self.unaryResult(
            response: .rag(.init(operation: "search", success: true))
        ) { client in
            try await client.ragSearch(modelId: "embed", query: "query")
        }
        assertProtocolViolation(search, contains: "omitted results")

        let arrayChunk: Result<[QVACClient.RagChunk], Error> = try await Self.unaryResult(
            response: .rag(.init(operation: "chunk", success: true))
        ) { client in
            try await client.ragChunk(documents: ["doc"])
        }
        assertProtocolViolation(arrayChunk, contains: "omitted chunks")

        let scalarChunk: Result<[QVACClient.RagChunk], Error> = try await Self.unaryResult(
            response: .rag(.init(operation: "chunk", success: true))
        ) { client in
            try await client.ragChunk(documents: "doc")
        }
        assertProtocolViolation(scalarChunk, contains: "omitted chunks")

        let save: Result<[QVACClient.RagSaveResult], Error> = try await Self.unaryResult(
            response: .rag(.init(operation: "saveEmbeddings", success: true))
        ) { client in
            let run = try await client.ragSaveEmbeddings(documents: [
                .init(id: "id", content: "doc", embedding: [1], embeddingModelId: "embed"),
            ])
            return try await run.result.value
        }
        assertProtocolViolation(save, contains: "omitted processed")

        let reindex: Result<QVACClient.RagReindexResult, Error> = try await Self.unaryResult(
            response: .rag(.init(operation: "reindex", success: true))
        ) { client in
            let run = try await client.ragReindex(workspace: "workspace")
            return try await run.result.value
        }
        assertProtocolViolation(reindex, contains: "omitted result")
    }

    func test_rag_unary_paths_reject_wrong_response_discriminators() async throws {
        let runPath: Result<QVACClient.RagIngestResult, Error> = try await Self.unaryResult(
            response: .heartbeat(.init(number: 1))
        ) { client in
            let run = try await client.ragIngest(modelId: "embed", documents: ["doc"])
            return try await run.result.value
        }
        assertProtocolViolation(runPath, contains: "expected rag response")

        let directPath: Result<[QVACClient.RagSearchResult], Error> = try await Self.unaryResult(
            response: .heartbeat(.init(number: 2))
        ) { client in
            try await client.ragSearch(modelId: "embed", query: "query")
        }
        assertProtocolViolation(directPath, contains: "expected rag response")
    }

    func test_rag_result_parsers_reject_worker_schema_drift() async throws {
        let malformedSearch: Result<[QVACClient.RagSearchResult], Error> = try await Self.unaryResult(
            response: .rag(.init(
                operation: "search",
                success: true,
                results: [.object(["id": .string("id"), "score": .number(0.9)])]
            ))
        ) { client in
            try await client.ragSearch(modelId: "embed", query: "query")
        }
        assertProtocolViolation(malformedSearch, contains: "string id/content and numeric score")

        let malformedSave: Result<[QVACClient.RagSaveResult], Error> = try await Self.unaryResult(
            response: .rag(.init(
                operation: "saveEmbeddings",
                success: true,
                processed: [.object(["status": .string("pending")])]
            ))
        ) { client in
            let run = try await client.ragSaveEmbeddings(documents: [
                .init(id: "id", content: "doc", embedding: [1], embeddingModelId: "embed"),
            ])
            return try await run.result.value
        }
        assertProtocolViolation(malformedSave, contains: "fulfilled or rejected status")

        let malformedSaveId: Result<[QVACClient.RagSaveResult], Error> = try await Self.unaryResult(
            response: .rag(.init(
                operation: "saveEmbeddings",
                success: true,
                processed: [.object([
                    "status": .string("fulfilled"),
                    "id": .number(7),
                ])]
            ))
        ) { client in
            let run = try await client.ragSaveEmbeddings(documents: [
                .init(id: "id", content: "doc", embedding: [1], embeddingModelId: "embed"),
            ])
            return try await run.result.value
        }
        assertProtocolViolation(malformedSaveId, contains: "id must be a string when present")

        let malformedSaveError: Result<[QVACClient.RagSaveResult], Error> = try await Self.unaryResult(
            response: .rag(.init(
                operation: "saveEmbeddings",
                success: true,
                processed: [.object([
                    "status": .string("rejected"),
                    "error": .bool(true),
                ])]
            ))
        ) { client in
            let run = try await client.ragSaveEmbeddings(documents: [
                .init(id: "id", content: "doc", embedding: [1], embeddingModelId: "embed"),
            ])
            return try await run.result.value
        }
        assertProtocolViolation(
            malformedSaveError,
            contains: "error must be a string when present"
        )

        let malformedReindex: Result<QVACClient.RagReindexResult, Error> = try await Self.unaryResult(
            response: .rag(.init(
                operation: "reindex",
                success: true,
                result: .object(["details": .object([:])])
            ))
        ) { client in
            let run = try await client.ragReindex(workspace: "workspace")
            return try await run.result.value
        }
        assertProtocolViolation(malformedReindex, contains: "must contain reindexed")

        let malformedReindexDetails: Result<QVACClient.RagReindexResult, Error> =
            try await Self.unaryResult(
                response: .rag(.init(
                    operation: "reindex",
                    success: true,
                    result: .object([
                        "reindexed": .bool(true),
                        "details": .string("not-an-object"),
                    ])
                ))
            ) { client in
                let run = try await client.ragReindex(workspace: "workspace")
                return try await run.result.value
            }
        assertProtocolViolation(
            malformedReindexDetails,
            contains: "details must be an object when present"
        )

        let malformedWorkspace: Result<[QVACClient.RagWorkspaceInfo], Error> = try await Self.unaryResult(
            response: .rag(.init(
                operation: "listWorkspaces",
                success: true,
                workspaces: [.object(["name": .string("workspace")])]
            ))
        ) { client in
            try await client.ragListWorkspaces()
        }
        assertProtocolViolation(malformedWorkspace, contains: "string name and bool open")
    }

    #if canImport(Darwin)
    // MARK: - Unix-domain transport ownership

    func test_uds_inbound_consumer_cancellation_closes_transport_and_reader() async throws {
        var sockets = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else {
            throw UnixDomainSocketTransport.SpawnError.socketConfigurationFailed(errno: errno)
        }
        let transport: UnixDomainSocketTransport
        do {
            transport = try UnixDomainSocketTransport.__testConnectedTransport(clientFD: sockets[0])
        } catch {
            _ = Darwin.close(sockets[0])
            _ = Darwin.close(sockets[1])
            throw error
        }
        defer { _ = Darwin.close(sockets[1]) }

        let enteredRead = expectation(description: "consumer entered transport read")
        let consumer = Task { () throws -> Data? in
            var iterator = transport.inboundStream().makeAsyncIterator()
            enteredRead.fulfill()
            return try await iterator.next()
        }
        await fulfillment(of: [enteredRead], timeout: 1)
        for _ in 0..<8 { await Task.yield() }
        consumer.cancel()

        do {
            _ = try await consumer.value
            XCTFail("canceled inbound transport read must reject")
        } catch is CancellationError {
            // Expected structured cancellation.
        } catch {
            XCTFail("unexpected inbound cancellation error: \(error)")
        }

        // The cancellation handler owns teardown. An explicit close joins that
        // in-flight cleanup and proves it is idempotent and reader-complete.
        await transport.close()
        XCTAssertTrue(transport.__testReaderFinished())
        XCTAssertFalse(FileManager.default.fileExists(atPath: transport.socketPath))
    }
    #endif
}
