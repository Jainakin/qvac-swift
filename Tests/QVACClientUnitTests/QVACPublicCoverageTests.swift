import Foundation
import XCTest
@testable import QVACClient

/// Behavior-focused coverage for the public wrappers that sit above the generated
/// QVAC 0.17 wire contract. The in-memory peer exercises the real encoder, bare-rpc
/// multiplexer, response decoder, and public validation logic without a model or
/// network dependency.
final class QVACPublicCoverageTests: XCTestCase {
    private final class InboundPipe: @unchecked Sendable {
        let stream: AsyncThrowingStream<Data, Error>
        let continuation: AsyncThrowingStream<Data, Error>.Continuation

        init() {
            var captured: AsyncThrowingStream<Data, Error>.Continuation!
            stream = AsyncThrowingStream { captured = $0 }
            continuation = captured
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

        func outbound() -> Data {
            outboundBytes
        }
    }

    private static func requests(in data: Data) -> [(id: UInt64, body: [String: Any])] {
        let reader = BareRPCFrameReader()
        try? reader.append(data)
        var result: [(UInt64, [String: Any])] = []
        while let frame = reader.next() {
            guard case .request(let id, _, _, .some(let payload)) = frame,
                  let body = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
            else { continue }
            result.append((id, body))
        }
        return result
    }

    private static func waitForRequest(
        _ index: Int,
        on transport: PeerTransport,
        timeout: Duration = .seconds(1)
    ) async throws -> (id: UInt64, body: [String: Any]) {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            let observed = requests(in: await transport.outbound())
            if observed.indices.contains(index) { return observed[index] }
            try await Task.sleep(for: .milliseconds(5))
        }
        let observed = requests(in: await transport.outbound())
        XCTFail("timed out waiting for request index \(index); received \(observed.count)")
        throw QVACError.protocolViolation("test peer did not receive the expected request")
    }

    private static func feedReply(
        id: UInt64,
        response: QVACResponse,
        to transport: PeerTransport
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
        to transport: PeerTransport
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

    private static func exchange<Value: Sendable>(
        request index: Int,
        on transport: PeerTransport,
        replyingWith response: QVACResponse,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> (task: Task<Value, Error>, request: [String: Any]) {
        let task = Task { try await operation() }
        let request = try await waitForRequest(index, on: transport)
        try await feedReply(id: request.id, response: response, to: transport)
        return (task, request.body)
    }

    private func assertProtocolViolation<Value: Sendable>(
        _ task: Task<Value, Error>,
        contains expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await task.value
            XCTFail("expected protocol violation", file: file, line: line)
        } catch let QVACError.protocolViolation(message) {
            XCTAssertTrue(
                message.contains(expected),
                "'\(message)' does not contain '\(expected)'",
                file: file,
                line: line
            )
        } catch {
            XCTFail("expected protocol violation, got \(error)", file: file, line: line)
        }
    }

    private static func invalidArgumentMessage<Value>(
        _ operation: () async throws -> Value,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> String {
        do {
            _ = try await operation()
            XCTFail("expected invalid argument", file: file, line: line)
            return ""
        } catch let QVACError.invalidArgument(message) {
            return message
        } catch {
            XCTFail("expected invalid argument, got \(error)", file: file, line: line)
            return ""
        }
    }

    func test_error_descriptions_cover_every_public_failure_family() throws {
        let toolCall = try QVACClient.CompletionToolCall(wire: .object([
            "id": .string("call-1"),
            "name": .string("weather"),
            "arguments": .object(["city": .string("Pune")]),
        ]))
        let partial = QVACClient.InferenceCancelledPartial(
            text: "partial",
            toolCalls: [toolCall]
        )

        XCTAssertEqual(
            QVACError.client(.invalidResponseType, message: nil).description,
            "QVAC client error 50001 (invalidResponseType): no message"
        )
        XCTAssertEqual(
            QVACError.server(.modelNotFound, message: "missing").description,
            "QVAC server error 52002 (modelNotFound): missing"
        )
        XCTAssertEqual(
            QVACError.serverUntyped(code: 60001, message: nil).description,
            "QVAC server error 60001 (addon-defined): no message"
        )
        XCTAssertEqual(
            QVACError.inferenceCancelled(requestId: "request-1", partial: partial).description,
            "QVAC inference request-1 was cancelled (partial text: 7 characters, tool calls: 1)"
        )
        XCTAssertEqual(
            QVACError.transport(
                reason: "socket closed",
                underlying: CocoaError(.fileReadUnknown)
            ).description,
            "QVAC transport error: socket closed"
        )
        XCTAssertEqual(
            QVACError.connectionReset.description,
            "QVAC worker reconnected; in-memory model and session state was lost. "
                + "Reload required state, then retry the operation."
        )
        XCTAssertEqual(
            QVACError.requestTimedOut(operation: "embed", after: .seconds(2)).description,
            "QVAC request 'embed' timed out after 2.0 seconds"
        )
        XCTAssertEqual(
            QVACError.streamBufferOverflow(
                operation: "completion",
                maximumBytes: 1_024,
                attemptedBytes: 1_025
            ).description,
            "QVAC stream 'completion' exceeded its 1024-byte buffer (attempted 1025 bytes)"
        )
        XCTAssertEqual(
            QVACError.resourceLimitExceeded(
                operation: "completion",
                resource: "accumulated result bytes",
                maximumBytes: 2_048,
                attemptedBytes: 2_049
            ).description,
            "QVAC operation 'completion' exceeded its 2048-byte accumulated result bytes "
                + "limit (attempted 2049 bytes)"
        )
        XCTAssertEqual(
            QVACError.invalidArgument("modelId is empty").description,
            "QVAC invalid argument: modelId is empty"
        )
        XCTAssertEqual(
            QVACError.protocolViolation("unexpected heartbeat").description,
            "QVAC protocol violation: unexpected heartbeat"
        )
        XCTAssertEqual(
            QVACError.encoding("invalid JSON").description,
            "QVAC encoding error: invalid JSON"
        )
    }

    func test_error_wire_mapping_distinguishes_registry_client_server_and_addon_codes() {
        guard case .server(.registryFailedToConnect, let registryMessage) =
            QVACError.fromWire(code: 19_001, message: "registry down")
        else { return XCTFail("registry code must map to a typed server error") }
        XCTAssertEqual(registryMessage, "registry down")

        guard case .client(.invalidResponseType, let clientMessage) =
            QVACError.fromWire(code: 50_001, message: "bad type")
        else { return XCTFail("client code must map to a typed client error") }
        XCTAssertEqual(clientMessage, "bad type")

        guard case .server(.modelAlreadyRegistered, let serverMessage) =
            QVACError.fromWire(code: 52_001, message: nil)
        else { return XCTFail("worker code must map to a typed server error") }
        XCTAssertNil(serverMessage)

        guard case .serverUntyped(50_999, let addonMessage) =
            QVACError.fromWire(code: 50_999, message: "extension failure")
        else { return XCTFail("unknown numeric code must remain an untyped server error") }
        XCTAssertEqual(addonMessage, "extension failure")
    }

    func test_stream_overflow_values_are_equatable_and_describe_the_active_budget() {
        let elementOverflow = QVACStreamBufferOverflow(stream: "tokens", capacity: 64)
        XCTAssertEqual(elementOverflow.stream, "tokens")
        XCTAssertEqual(elementOverflow.capacity, 64)
        XCTAssertNil(elementOverflow.maximumBufferedBytes)
        XCTAssertNil(elementOverflow.attemptedBufferedBytes)
        XCTAssertEqual(
            elementOverflow.description,
            "QVAC stream 'tokens' exceeded its 64-element buffer"
        )
        XCTAssertEqual(
            elementOverflow,
            QVACStreamBufferOverflow(stream: "tokens", capacity: 64)
        )

        let byteOverflow = QVACStreamBufferOverflow(
            stream: "finetune.progress",
            capacity: 8,
            maximumBufferedBytes: 4_096,
            attemptedBufferedBytes: 4_321
        )
        XCTAssertEqual(byteOverflow.maximumBufferedBytes, 4_096)
        XCTAssertEqual(byteOverflow.attemptedBufferedBytes, 4_321)
        XCTAssertEqual(
            byteOverflow.description,
            "QVAC stream 'finetune.progress' exceeded its 8-batch / "
                + "4096-byte buffer (attempted 4321 bytes)"
        )
        XCTAssertNotEqual(elementOverflow, byteOverflow)
    }

    func test_cancel_sends_native_shapes_and_maps_acknowledgement_and_failure() async throws {
        let transport = PeerTransport()
        let client = QVACClient(testing: transport)

        let targeted = Task {
            try await client.cancel(.request(requestId: "request-17", clearCache: true))
        }
        var request = try await Self.waitForRequest(0, on: transport)
        XCTAssertEqual(request.body["type"] as? String, "cancel")
        XCTAssertEqual(request.body["operation"] as? String, "request")
        XCTAssertEqual(request.body["requestId"] as? String, "request-17")
        XCTAssertEqual(request.body["clearCache"] as? Bool, true)
        XCTAssertNil(request.body["modelId"])
        try await Self.feedReply(
            id: request.id,
            response: .cancel(.init(success: true, cancelled: 2)),
            to: transport
        )
        let acknowledgement = try await targeted.value
        XCTAssertEqual(acknowledgement, .init(cancelled: 2))

        let broad = Task {
            try await client.cancel(.broad(modelId: "model-17", kind: "completion"))
        }
        request = try await Self.waitForRequest(1, on: transport)
        XCTAssertEqual(request.body["operation"] as? String, "broad")
        XCTAssertEqual(request.body["modelId"] as? String, "model-17")
        XCTAssertEqual(request.body["kind"] as? String, "completion")
        XCTAssertNil(request.body["requestId"])
        try await Self.feedReply(
            id: request.id,
            response: .cancel(.init(success: false, error: "not cancellable")),
            to: transport
        )
        do {
            _ = try await broad.value
            XCTFail("failed cancellation must throw")
        } catch let QVACError.server(code, message) {
            XCTAssertEqual(code, .cancelFailed)
            XCTAssertEqual(message, "not cancellable")
        } catch {
            XCTFail("expected typed cancel failure, got \(error)")
        }

        let mismatched = Task {
            try await client.cancel(.request(requestId: "request-mismatch"))
        }
        request = try await Self.waitForRequest(2, on: transport)
        try await Self.feedReply(
            id: request.id,
            response: .heartbeat(.init(number: 1)),
            to: transport
        )
        await assertProtocolViolation(mismatched, contains: "expected cancel response")
        await client.close()
    }

    func test_heartbeat_rejects_a_valid_but_mismatched_contract_response() async throws {
        let transport = PeerTransport()
        let client = QVACClient(testing: transport)
        let task = Task { try await client.heartbeat() }
        let request = try await Self.waitForRequest(0, on: transport)
        try await Self.feedReply(
            id: request.id,
            response: .state(.init(state: "active")),
            to: transport
        )
        await assertProtocolViolation(task, contains: "expected heartbeat response, got state")
        await client.close()
    }

    func test_batch_embed_preserves_input_order_request_id_and_stats() async throws {
        let transport = PeerTransport()
        let client = QVACClient(testing: transport)
        let run = try await client.embed(
            modelId: "embed-model",
            texts: ["first", "second"]
        )
        let request = try await Self.waitForRequest(0, on: transport)
        XCTAssertEqual(request.body["modelId"] as? String, "embed-model")
        XCTAssertEqual(request.body["text"] as? [String], ["first", "second"])
        XCTAssertEqual(request.body["requestId"] as? String, run.requestId)
        try await Self.feedReply(
            id: request.id,
            response: .embed(.init(
                embedding: .array([
                    .array([.number(0.1), .number(0.2)]),
                    .array([.number(0.3), .number(0.4)]),
                ]),
                success: true,
                stats: .object(["tokens": .number(2)])
            )),
            to: transport
        )
        let outcome = try await run.result.value
        XCTAssertEqual(outcome.embedding, [[0.1, 0.2], [0.3, 0.4]])
        XCTAssertEqual(outcome.stats, .object(["tokens": .number(2)]))
        await client.close()
    }

    func test_single_embed_rejects_worker_failure_and_each_invalid_vector_shape() async throws {
        let cases: [(EmbedResponse, QVACErrorCode?, String)] = [
            (.init(embedding: .null, success: false, error: "backend failed"), .embedFailed, "backend failed"),
            (.init(embedding: .string("not-a-vector"), success: true), nil, "unexpected embedding shape"),
            (.init(embedding: .array([.number(0.1), .string("bad")]), success: true), nil, "embedding element not a number"),
        ]

        for (response, expectedCode, expectedMessage) in cases {
            let transport = PeerTransport()
            let client = QVACClient(testing: transport)
            let run = try await client.embed(modelId: "embed-model", text: "hello")
            let request = try await Self.waitForRequest(0, on: transport)
            try await Self.feedReply(id: request.id, response: .embed(response), to: transport)
            do {
                _ = try await run.result.value
                XCTFail("invalid single embedding response must throw")
            } catch let QVACError.server(code, message) {
                XCTAssertEqual(code, expectedCode)
                XCTAssertEqual(message, expectedMessage)
            } catch let QVACError.protocolViolation(message) {
                XCTAssertNil(expectedCode)
                XCTAssertTrue(message.contains(expectedMessage))
            } catch {
                XCTFail("unexpected embedding error: \(error)")
            }
            await client.close()
        }

        let transport = PeerTransport()
        let client = QVACClient(testing: transport)
        let run = try await client.embed(modelId: "embed-model", text: "hello")
        let request = try await Self.waitForRequest(0, on: transport)
        try await Self.feedReply(
            id: request.id,
            response: .heartbeat(.init(number: 2)),
            to: transport
        )
        await assertProtocolViolation(run.result, contains: "expected embed response, got heartbeat")
        await client.close()
    }

    func test_batch_embed_rejects_worker_failure_and_each_invalid_matrix_shape() async throws {
        let cases: [(EmbedResponse, QVACErrorCode?, String)] = [
            (.init(embedding: .null, success: false, error: "batch failed"), .embedFailed, "batch failed"),
            (.init(embedding: .object([:]), success: true), nil, "unexpected embedding shape"),
            (.init(embedding: .array([.number(1)]), success: true), nil, "row not an array"),
            (.init(embedding: .array([.array([.number(1), .bool(true)])]), success: true), nil, "element not a number"),
        ]

        for (response, expectedCode, expectedMessage) in cases {
            let transport = PeerTransport()
            let client = QVACClient(testing: transport)
            let run = try await client.embed(modelId: "embed-model", texts: ["a", "b"])
            let request = try await Self.waitForRequest(0, on: transport)
            try await Self.feedReply(id: request.id, response: .embed(response), to: transport)
            do {
                _ = try await run.result.value
                XCTFail("invalid batch embedding response must throw")
            } catch let QVACError.server(code, message) {
                XCTAssertEqual(code, expectedCode)
                XCTAssertEqual(message, expectedMessage)
            } catch let QVACError.protocolViolation(message) {
                XCTAssertNil(expectedCode)
                XCTAssertTrue(message.contains(expectedMessage))
            } catch {
                XCTFail("unexpected batch embedding error: \(error)")
            }
            await client.close()
        }

        let transport = PeerTransport()
        let client = QVACClient(testing: transport)
        let run = try await client.embed(modelId: "embed-model", texts: ["a"])
        let request = try await Self.waitForRequest(0, on: transport)
        try await Self.feedReply(
            id: request.id,
            response: .heartbeat(.init(number: 3)),
            to: transport
        )
        await assertProtocolViolation(run.result, contains: "expected embed response, got heartbeat")
        await client.close()
    }

    func test_delete_cache_preserves_request_and_maps_success_failure_and_wrong_type() async throws {
        let transport = PeerTransport()
        let client = QVACClient(testing: transport)

        var exchange = try await Self.exchange(
            request: 0,
            on: transport,
            replyingWith: .deleteCache(.init(success: true))
        ) {
            try await client.deleteCache(.init(modelId: "model-17"))
        }
        XCTAssertEqual(exchange.request["type"] as? String, "deleteCache")
        XCTAssertEqual(exchange.request["modelId"] as? String, "model-17")
        XCTAssertNil(exchange.request["all"])
        let deleteResult = try await exchange.task.value
        XCTAssertTrue(deleteResult.success)

        exchange = try await Self.exchange(
            request: 1,
            on: transport,
            replyingWith: .deleteCache(.init(success: false, error: "cache locked"))
        ) {
            try await client.deleteCache(.init(all: true))
        }
        do {
            _ = try await exchange.task.value
            XCTFail("deleteCache failure must throw")
        } catch let QVACError.server(code, message) {
            XCTAssertEqual(code, .deleteCacheFailed)
            XCTAssertEqual(message, "cache locked")
        } catch {
            XCTFail("expected typed delete-cache failure, got \(error)")
        }

        exchange = try await Self.exchange(
            request: 2,
            on: transport,
            replyingWith: .heartbeat(.init(number: 4))
        ) {
            try await client.deleteCache(.init(kvCacheKey: "session-17"))
        }
        await assertProtocolViolation(
            exchange.task,
            contains: "expected deleteCache response, got heartbeat"
        )
        await client.close()
    }

    func test_unary_finetune_rejects_progress_mode_wrong_type_and_malformed_stats() async throws {
        do {
            let transport = PeerTransport()
            let client = QVACClient(testing: transport)
            var request = FinetuneRequest(modelId: "trainable", operation: "start")
            request.withProgress = true
            do {
                _ = try await client.finetune(request)
                XCTFail("unary finetune must reject progress mode")
            } catch let QVACError.invalidArgument(message) {
                XCTAssertTrue(message.contains("must use finetuneStreaming"))
            } catch {
                XCTFail("expected local invalid-argument error, got \(error)")
            }
            let outbound = await transport.outbound()
            XCTAssertTrue(outbound.isEmpty, "local validation must happen before transport I/O")
            await client.close()
        }

        do {
            let transport = PeerTransport()
            let client = QVACClient(testing: transport)
            let wrong = try await Self.exchange(
                request: 0,
                on: transport,
                replyingWith: .heartbeat(.init(number: 1))
            ) {
                try await client.finetune(.init(modelId: "trainable", operation: "getState"))
            }
            await assertProtocolViolation(
                wrong.task,
                contains: "expected finetune response, got heartbeat"
            )
            await client.close()
        }

        let malformedStats: [(JSONValue, String)] = [
            (.array([]), "finetune.stats must be an object"),
            (
                .object([
                    "global_steps": .string("one"),
                    "epochs_completed": .number(1),
                ]),
                "must be an integer"
            ),
            (
                .object([
                    "global_steps": .number(-1),
                    "epochs_completed": .number(1),
                ]),
                "must be nonnegative"
            ),
            (
                .object([
                    "global_steps": .number(1),
                    "epochs_completed": .number(1),
                    "train_loss": .string("unknown"),
                ]),
                "must be a finite number"
            ),
            (
                .object([
                    "global_steps": .number(1),
                    "epochs_completed": .number(1),
                    "train_loss_uncertainty": .bool(false),
                ]),
                "must be a finite number or null"
            ),
        ]

        for malformed in malformedStats {
            let transport = PeerTransport()
            let client = QVACClient(testing: transport)
            let response = try await Self.exchange(
                request: 0,
                on: transport,
                replyingWith: .finetune(.init(status: "COMPLETED", stats: malformed.0))
            ) {
                try await client.finetune(.init(modelId: "trainable", operation: "getState"))
            }
            await assertProtocolViolation(
                response.task,
                contains: malformed.1
            )
            await client.close()
        }

        let transport = PeerTransport()
        let client = QVACClient(testing: transport)
        let valid = try await Self.exchange(
            request: 0,
            on: transport,
            replyingWith: .finetune(.init(
                status: "COMPLETED",
                stats: .object([
                    "global_steps": .number(10),
                    "epochs_completed": .number(2),
                    "train_loss": .number(0.25),
                    "train_loss_uncertainty": .null,
                    "val_accuracy_uncertainty": .number(0.01),
                ])
            ))
        ) {
            try await client.finetune(.init(modelId: "trainable", operation: "getState"))
        }
        let validResult = try await valid.task.value
        XCTAssertEqual(validResult.status, "COMPLETED")
        XCTAssertNotNil(validResult.stats)
        await client.close()
    }

    func test_streaming_finetune_fails_for_worker_error_unexpected_record_and_missing_terminal() async throws {
        enum ExpectedFailure {
            case server
            case unexpected
            case missingTerminal
        }
        let cases: [(records: [String], expected: ExpectedFailure)] = [
            (
                [#"{"type":"error","code":52420,"message":"training rejected by policy"}"#],
                .server
            ),
            ([#"{"type":"heartbeat","number":1}"#], .unexpected),
            (
                [#"{"type":"finetune:progress","accuracy":0.8,"accuracy_uncertainty":null,"current_batch":1,"current_epoch":0,"elapsed_ms":10,"eta_ms":20,"global_steps":1,"is_train":true,"loss":0.2,"loss_uncertainty":null,"modelId":"trainable","total_batches":4}"#],
                .missingTerminal
            ),
        ]

        for testCase in cases {
            let transport = PeerTransport()
            let client = QVACClient(testing: transport)
            let run = try await client.finetuneStreaming(
                .init(modelId: "trainable", operation: "start")
            )
            let request = try await Self.waitForRequest(0, on: transport)
            await Self.feedServerStream(
                id: request.id,
                records: testCase.records,
                to: transport
            )

            do {
                _ = try await run.result.value
                XCTFail("invalid finetune stream must not resolve successfully")
            } catch let QVACError.server(code, message) {
                if case .server = testCase.expected {
                    XCTAssertEqual(code, .requestRejectedByPolicy)
                    XCTAssertEqual(message, "training rejected by policy")
                } else {
                    XCTFail("unexpected server error: \(code)")
                }
            } catch let QVACError.protocolViolation(message) {
                if case .unexpected = testCase.expected {
                    XCTAssertTrue(
                        message.contains(
                            "expected finetune or finetune:progress response, got heartbeat"
                        )
                    )
                } else {
                    XCTFail("unexpected protocol violation: \(message)")
                }
            } catch let QVACError.client(code, message) {
                if case .missingTerminal = testCase.expected {
                    XCTAssertEqual(code, .streamEndedWithoutResponse)
                    XCTAssertEqual(message, "finetune stream ended without a terminal response")
                } else {
                    XCTFail("unexpected client error: \(code)")
                }
            } catch {
                XCTFail("unexpected finetune stream error: \(error)")
            }
            await client.close()
        }
    }

    func test_model_and_system_metadata_wrappers_preserve_exact_requests_and_results() async throws {
        let transport = PeerTransport()
        let client = QVACClient(testing: transport)

        let loaded = try await Self.exchange(
            request: 0,
            on: transport,
            replyingWith: .getLoadedModelInfo(.init(info: .object([
                "modelId": .string("model-17"),
                "loaded": .bool(true),
            ])))
        ) {
            try await client.getLoadedModelInfo(modelId: "model-17")
        }
        XCTAssertEqual(loaded.request["type"] as? String, "getLoadedModelInfo")
        XCTAssertEqual(loaded.request["modelId"] as? String, "model-17")
        let loadedResult = try await loaded.task.value
        XCTAssertEqual(
            loadedResult,
            .object(["modelId": .string("model-17"), "loaded": .bool(true)])
        )

        let model = try await Self.exchange(
            request: 1,
            on: transport,
            replyingWith: .getModelInfo(.init(modelInfo: .object([
                "name": .string("org/model"),
                "engine": .string("llamacpp"),
            ])))
        ) {
            try await client.getModelInfo(name: "org/model")
        }
        XCTAssertEqual(model.request["type"] as? String, "getModelInfo")
        XCTAssertEqual(model.request["name"] as? String, "org/model")
        let modelResult = try await model.task.value
        XCTAssertEqual(
            modelResult,
            .object(["name": .string("org/model"), "engine": .string("llamacpp")])
        )

        let resources = try await Self.exchange(
            request: 2,
            on: transport,
            replyingWith: .getSystemResources(.init(
                capabilities: .object(["gpu": .bool(true)]),
                sample: .object(["freeMemory": .number(1_024)])
            ))
        ) {
            try await client.getSystemResources(sample: true)
        }
        XCTAssertEqual(resources.request["type"] as? String, "getSystemResources")
        XCTAssertEqual(resources.request["sample"] as? Bool, true)
        let resourceResult = try await resources.task.value
        XCTAssertEqual(resourceResult.capabilities, .object(["gpu": .bool(true)]))
        XCTAssertEqual(resourceResult.sample, .object(["freeMemory": .number(1_024)]))
        await client.close()
    }

    func test_model_and_system_metadata_wrappers_reject_crossed_response_types() async throws {
        let transport = PeerTransport()
        let client = QVACClient(testing: transport)

        let loaded = try await Self.exchange(
            request: 0,
            on: transport,
            replyingWith: .heartbeat(.init(number: 1))
        ) {
            try await client.getLoadedModelInfo(modelId: "model")
        }
        await assertProtocolViolation(
            loaded.task,
            contains: "expected getLoadedModelInfo response, got heartbeat"
        )

        let model = try await Self.exchange(
            request: 1,
            on: transport,
            replyingWith: .heartbeat(.init(number: 2))
        ) {
            try await client.getModelInfo(name: "model")
        }
        await assertProtocolViolation(
            model.task,
            contains: "expected getModelInfo response, got heartbeat"
        )

        let resources = try await Self.exchange(
            request: 2,
            on: transport,
            replyingWith: .heartbeat(.init(number: 3))
        ) {
            try await client.getSystemResources()
        }
        await assertProtocolViolation(
            resources.task,
            contains: "expected getSystemResources response, got heartbeat"
        )
        await client.close()
    }

    func test_model_registry_wrappers_preserve_filters_and_return_required_payloads() async throws {
        let transport = PeerTransport()
        let client = QVACClient(testing: transport)
        let first = JSONValue.object(["path": .string("org/first")])
        let second = JSONValue.object(["path": .string("org/second")])

        let list = try await Self.exchange(
            request: 0,
            on: transport,
            replyingWith: .modelRegistryList(.init(success: true, models: [first, second]))
        ) {
            try await client.modelRegistryList()
        }
        XCTAssertEqual(Set(list.request.keys), ["type"])
        let listResult = try await list.task.value
        XCTAssertEqual(listResult, [first, second])

        let search = try await Self.exchange(
            request: 1,
            on: transport,
            replyingWith: .modelRegistrySearch(.init(success: true, models: [second]))
        ) {
            try await client.modelRegistrySearch(
                filter: "vision",
                engine: "ggml",
                quantization: "q4",
                addon: "image"
            )
        }
        XCTAssertEqual(search.request["filter"] as? String, "vision")
        XCTAssertEqual(search.request["engine"] as? String, "ggml")
        XCTAssertEqual(search.request["quantization"] as? String, "q4")
        XCTAssertEqual(search.request["addon"] as? String, "image")
        let searchResult = try await search.task.value
        XCTAssertEqual(searchResult, [second])

        let get = try await Self.exchange(
            request: 2,
            on: transport,
            replyingWith: .modelRegistryGetModel(.init(success: true, model: first))
        ) {
            try await client.modelRegistryGetModel(
                registryPath: "org/first",
                registrySource: "huggingface"
            )
        }
        XCTAssertEqual(get.request["registryPath"] as? String, "org/first")
        XCTAssertEqual(get.request["registrySource"] as? String, "huggingface")
        let getResult = try await get.task.value
        XCTAssertEqual(getResult, first)
        await client.close()
    }

    func test_model_registry_wrappers_fail_closed_for_missing_payloads_and_wrong_types() async throws {
        let transport = PeerTransport()
        let client = QVACClient(testing: transport)

        let listFailure = try await Self.exchange(
            request: 0,
            on: transport,
            replyingWith: .modelRegistryList(.init(success: false, error: "registry offline"))
        ) {
            try await client.modelRegistryList()
        }
        do {
            _ = try await listFailure.task.value
            XCTFail("registry-list failure must throw")
        } catch let QVACError.server(code, message) {
            XCTAssertEqual(code, .qvacModelRegistryQueryFailed)
            XCTAssertEqual(message, "registry offline")
        } catch {
            XCTFail("expected registry error, got \(error)")
        }

        let listMissing = try await Self.exchange(
            request: 1,
            on: transport,
            replyingWith: .modelRegistryList(.init(success: true, models: nil))
        ) {
            try await client.modelRegistryList()
        }
        do {
            _ = try await listMissing.task.value
            XCTFail("successful registry-list envelope without models must throw")
        } catch let QVACError.server(code, message) {
            XCTAssertEqual(code, .qvacModelRegistryQueryFailed)
            XCTAssertNil(message)
        } catch {
            XCTFail("expected fail-closed registry error, got \(error)")
        }

        let searchFailure = try await Self.exchange(
            request: 2,
            on: transport,
            replyingWith: .modelRegistrySearch(.init(success: false, error: "bad filter"))
        ) {
            try await client.modelRegistrySearch(filter: "invalid")
        }
        do {
            _ = try await searchFailure.task.value
            XCTFail("registry-search failure must throw")
        } catch let QVACError.server(code, message) {
            XCTAssertEqual(code, .qvacModelRegistryQueryFailed)
            XCTAssertEqual(message, "bad filter")
        } catch {
            XCTFail("expected registry error, got \(error)")
        }

        let getFailure = try await Self.exchange(
            request: 3,
            on: transport,
            replyingWith: .modelRegistryGetModel(.init(success: true, model: nil))
        ) {
            try await client.modelRegistryGetModel(
                registryPath: "missing/model",
                registrySource: "huggingface"
            )
        }
        do {
            _ = try await getFailure.task.value
            XCTFail("registry-get success without a model must throw")
        } catch let QVACError.server(code, message) {
            XCTAssertEqual(code, .qvacModelRegistryQueryFailed)
            XCTAssertNil(message)
        } catch {
            XCTFail("expected fail-closed registry error, got \(error)")
        }

        let wrongList = try await Self.exchange(
            request: 4,
            on: transport,
            replyingWith: .heartbeat(.init(number: 4))
        ) {
            try await client.modelRegistryList()
        }
        await assertProtocolViolation(
            wrongList.task,
            contains: "expected modelRegistryList response, got heartbeat"
        )

        let wrongSearch = try await Self.exchange(
            request: 5,
            on: transport,
            replyingWith: .heartbeat(.init(number: 5))
        ) {
            try await client.modelRegistrySearch()
        }
        await assertProtocolViolation(
            wrongSearch.task,
            contains: "expected modelRegistrySearch response, got heartbeat"
        )

        let wrongGet = try await Self.exchange(
            request: 6,
            on: transport,
            replyingWith: .heartbeat(.init(number: 6))
        ) {
            try await client.modelRegistryGetModel(
                registryPath: "org/model",
                registrySource: "huggingface"
            )
        }
        await assertProtocolViolation(
            wrongGet.task,
            contains: "expected modelRegistryGetModel response, got heartbeat"
        )
        await client.close()
    }

    func test_provider_wrappers_preserve_firewall_and_map_failures_and_wrong_types() async throws {
        let transport = PeerTransport()
        let client = QVACClient(testing: transport)

        let start = try await Self.exchange(
            request: 0,
            on: transport,
            replyingWith: .provide(.init(success: true, publicKey: "provider-key"))
        ) {
            try await client.startQVACProvider(
                firewall: .object(["allow": .array([.string("peer-1")])])
            )
        }
        XCTAssertEqual(start.request["type"] as? String, "provide")
        XCTAssertEqual(
            start.request["firewall"] as? [String: [String]],
            ["allow": ["peer-1"]]
        )
        let startResult = try await start.task.value
        XCTAssertEqual(startResult.publicKey, "provider-key")

        let stop = try await Self.exchange(
            request: 1,
            on: transport,
            replyingWith: .stopProvide(.init(success: true))
        ) {
            try await client.stopQVACProvider()
        }
        XCTAssertEqual(Set(stop.request.keys), ["type"])
        let stopResult = try await stop.task.value
        XCTAssertTrue(stopResult.success)

        let startFailure = try await Self.exchange(
            request: 2,
            on: transport,
            replyingWith: .provide(.init(success: false, error: "provider unavailable"))
        ) {
            try await client.startQVACProvider()
        }
        do {
            _ = try await startFailure.task.value
            XCTFail("provider start failure must throw")
        } catch let QVACError.client(code, message) {
            XCTAssertEqual(code, .providerStartFailed)
            XCTAssertEqual(message, "provider unavailable")
        } catch {
            XCTFail("expected provider-start error, got \(error)")
        }

        let stopFailure = try await Self.exchange(
            request: 3,
            on: transport,
            replyingWith: .stopProvide(.init(success: false, error: "provider busy"))
        ) {
            try await client.stopQVACProvider()
        }
        do {
            _ = try await stopFailure.task.value
            XCTFail("provider stop failure must throw")
        } catch let QVACError.client(code, message) {
            XCTAssertEqual(code, .providerStopFailed)
            XCTAssertEqual(message, "provider busy")
        } catch {
            XCTFail("expected provider-stop error, got \(error)")
        }

        let inconsistentStart = try await Self.exchange(
            request: 4,
            on: transport,
            replyingWith: .provide(.init(
                success: true,
                error: "inconsistent provider start",
                publicKey: "must-not-publish"
            ))
        ) {
            try await client.startQVACProvider()
        }
        do {
            _ = try await inconsistentStart.task.value
            XCTFail("a present provider-start error must take precedence over success")
        } catch let QVACError.client(code, message) {
            XCTAssertEqual(code, .providerStartFailed)
            XCTAssertEqual(message, "inconsistent provider start")
        }

        let inconsistentStop = try await Self.exchange(
            request: 5,
            on: transport,
            replyingWith: .stopProvide(.init(
                success: true,
                error: "inconsistent provider stop"
            ))
        ) {
            try await client.stopQVACProvider()
        }
        do {
            _ = try await inconsistentStop.task.value
            XCTFail("a present provider-stop error must take precedence over success")
        } catch let QVACError.client(code, message) {
            XCTAssertEqual(code, .providerStopFailed)
            XCTAssertEqual(message, "inconsistent provider stop")
        }

        let wrongStart = try await Self.exchange(
            request: 6,
            on: transport,
            replyingWith: .heartbeat(.init(number: 1))
        ) {
            try await client.startQVACProvider()
        }
        await assertProtocolViolation(
            wrongStart.task,
            contains: "expected provide response, got heartbeat"
        )

        let wrongStop = try await Self.exchange(
            request: 7,
            on: transport,
            replyingWith: .heartbeat(.init(number: 2))
        ) {
            try await client.stopQVACProvider()
        }
        await assertProtocolViolation(
            wrongStop.task,
            contains: "expected stopProvide response, got heartbeat"
        )
        await client.close()
    }

    func test_lifecycle_wrappers_accept_exact_acknowledgements_and_reject_crossed_types() async throws {
        let transport = PeerTransport()
        let client = QVACClient(testing: transport)

        let suspend = try await Self.exchange(
            request: 0,
            on: transport,
            replyingWith: .suspend(.init())
        ) {
            try await client.suspend()
        }
        XCTAssertEqual(Set(suspend.request.keys), ["type"])
        _ = try await suspend.task.value

        let resume = try await Self.exchange(
            request: 1,
            on: transport,
            replyingWith: .resume(.init())
        ) {
            try await client.resume()
        }
        XCTAssertEqual(Set(resume.request.keys), ["type"])
        _ = try await resume.task.value

        let state = try await Self.exchange(
            request: 2,
            on: transport,
            replyingWith: .state(.init(state: "suspended"))
        ) {
            try await client.state()
        }
        XCTAssertEqual(Set(state.request.keys), ["type"])
        let stateResult = try await state.task.value
        XCTAssertEqual(stateResult, "suspended")

        let wrongSuspend = try await Self.exchange(
            request: 3,
            on: transport,
            replyingWith: .resume(.init())
        ) {
            try await client.suspend()
        }
        await assertProtocolViolation(
            wrongSuspend.task,
            contains: "expected suspend response, got resume"
        )

        let wrongResume = try await Self.exchange(
            request: 4,
            on: transport,
            replyingWith: .suspend(.init())
        ) {
            try await client.resume()
        }
        await assertProtocolViolation(
            wrongResume.task,
            contains: "expected resume response, got suspend"
        )

        let unknownState = try await Self.exchange(
            request: 5,
            on: transport,
            replyingWith: .state(.init(state: "paused"))
        ) {
            try await client.state()
        }
        await assertProtocolViolation(
            unknownState.task,
            contains: "state response must be active, suspending, suspended, or resuming"
        )

        let wrongState = try await Self.exchange(
            request: 6,
            on: transport,
            replyingWith: .heartbeat(.init(number: 1))
        ) {
            try await client.state()
        }
        await assertProtocolViolation(
            wrongState.task,
            contains: "expected state response, got heartbeat"
        )
        await client.close()
    }

    func test_binary_convenience_apis_enforce_raw_and_encoded_budgets_before_io() async {
        let transport = PeerTransport()
        let client = QVACClient(
            testing: transport,
            maximumWireMessageBytes: 64,
            maximumInlineBinaryBytes: 32
        )
        let overRawBudget = Data(repeating: 0xA5, count: 33)
        let halfWireBudget = Data(repeating: 0x5A, count: 24)

        var message = await Self.invalidArgumentMessage {
            try await client.upscale(modelId: "model", image: overRawBudget)
        }
        XCTAssertTrue(message.contains("maximumInlineBinaryBytes 32"))

        message = await Self.invalidArgumentMessage {
            try await client.video(
                modelId: "model",
                mode: "img2vid",
                prompt: "move",
                initImage: overRawBudget
            )
        }
        XCTAssertTrue(message.contains("maximumInlineBinaryBytes 32"))

        message = await Self.invalidArgumentMessage {
            try await client.classify(modelId: "model", image: overRawBudget)
        }
        XCTAssertTrue(message.contains("maximumInlineBinaryBytes 32"))

        message = await Self.invalidArgumentMessage {
            try await client.diffusion(
                modelId: "model",
                prompt: "image",
                initImages: [halfWireBudget, halfWireBudget]
            )
        }
        XCTAssertTrue(message.contains("maximumInlineBinaryBytes 32"))

        message = await Self.invalidArgumentMessage {
            try await client.ocr(modelId: "model", imageBytes: overRawBudget)
        }
        XCTAssertTrue(message.contains("maximumInlineBinaryBytes 32"))

        message = await Self.invalidArgumentMessage {
            try await client.transcribe(modelId: "model", audioBytes: overRawBudget)
        }
        XCTAssertTrue(message.contains("maximumInlineBinaryBytes 32"))

        message = await Self.invalidArgumentMessage {
            try await client.bciTranscribe(modelId: "model", neuralData: .data(overRawBudget))
        }
        XCTAssertTrue(message.contains("maximumInlineBinaryBytes 32"))

        let vlaParameters = QVACClient.VLAParameters(
            modelId: "model",
            images: [[Float](repeating: 0, count: 8)],
            imageWidth: 1,
            imageHeight: 1,
            state: [],
            tokens: [1],
            mask: [1]
        )
        message = await Self.invalidArgumentMessage {
            try await client.vla(vlaParameters)
        }
        XCTAssertTrue(message.contains("maximumInlineBinaryBytes 32"))

        let outbound = await transport.outbound()
        XCTAssertTrue(outbound.isEmpty, "budget rejection must happen before transport I/O")
        await client.close()
    }

    func test_vla_rejects_oversized_plugin_reply_before_json_decoding() async throws {
        let transport = PeerTransport()
        let actionLimit = 4 * 1_024 * 1_024
        let encodedLimit = try XCTUnwrap(qvacBase64EncodedByteCount(actionLimit))
            + 64 * 1_024
        let client = QVACClient(
            testing: transport,
            maximumAccumulatedResultBytes: actionLimit * 2,
            maximumVLAActionBytes: actionLimit
        )
        let task = Task {
            try await client.vla(.init(
                modelId: "model",
                images: [[0, 0, 0]],
                imageWidth: 1,
                imageHeight: 1,
                state: [],
                tokens: [1],
                mask: [1]
            ))
        }
        let request = try await Self.waitForRequest(0, on: transport)
        let oversized = Data(
            repeating: 0,
            count: encodedLimit + 1
        )
        await transport.feed(BareRPCCodec.__testEncodeResponseFrame(
            id: request.id,
            stream: [],
            payload: .success(oversized)
        ))
        do {
            _ = try await task.value
            XCTFail("oversized VLA plugin response must fail before JSON decoding")
        } catch let QVACError.resourceLimitExceeded(
            operation,
            resource,
            maximumBytes,
            attemptedBytes
        ) {
            XCTAssertEqual(operation, "pluginInvoke")
            XCTAssertEqual(resource, "response bytes")
            XCTAssertEqual(maximumBytes, encodedLimit)
            XCTAssertEqual(attemptedBytes, encodedLimit + 1)
        } catch {
            XCTFail("expected resourceLimitExceeded, got \(error)")
        }
        await client.close()
    }
}
