import XCTest
@testable import QVACClient

final class QVACRuntimeContractTests: XCTestCase {
    func test_unary_and_streaming_load_requests_default_missing_model_config_to_empty_object() throws {
        let unary = QVACClient.makeLoadModelRequest(
            modelSrc: "npm:model",
            modelType: "llamacpp-completion",
            modelConfig: nil,
            modelName: nil,
            requestId: "unary-request",
            withProgress: false
        )
        let streaming = QVACClient.makeLoadModelRequest(
            modelSrc: "npm:model",
            modelType: "llamacpp-completion",
            modelConfig: nil,
            modelName: nil,
            requestId: "stream-request",
            withProgress: true
        )

        let unaryJSON = try Self.object(for: .loadModel(unary))
        let streamingJSON = try Self.object(for: .loadModel(streaming))
        XCTAssertEqual((unaryJSON["modelConfig"] as? [String: Any])?.count, 0)
        XCTAssertEqual((streamingJSON["modelConfig"] as? [String: Any])?.count, 0)
        XCTAssertNil(unaryJSON["withProgress"])
        XCTAssertEqual(streamingJSON["withProgress"] as? Bool, true)
        XCTAssertEqual(unaryJSON["requestId"] as? String, "unary-request")
        XCTAssertEqual(streamingJSON["requestId"] as? String, "stream-request")
        XCTAssertEqual(unaryJSON["seed"] as? Bool, false)
        XCTAssertEqual(streamingJSON["seed"] as? Bool, false)
    }

    func test_load_request_builder_preserves_explicit_model_config() throws {
        let request = QVACClient.makeLoadModelRequest(
            modelSrc: "npm:model",
            modelType: "llamacpp-completion",
            modelConfig: .object(["contextSize": .number(4096)]),
            modelName: "named",
            requestId: "request-id",
            withProgress: false,
            seed: true,
            delegate: .object(["peerId": .string("desktop-peer")])
        )
        let json = try Self.object(for: .loadModel(request))
        let config = try XCTUnwrap(json["modelConfig"] as? [String: Any])
        XCTAssertEqual(config["contextSize"] as? Double, 4096)
        XCTAssertEqual(json["modelName"] as? String, "named")
        XCTAssertEqual(json["seed"] as? Bool, true)
        XCTAssertEqual(
            (json["delegate"] as? [String: Any])?["peerId"] as? String,
            "desktop-peer"
        )
    }

    func test_load_request_builder_normalizes_pinned_model_aliases_and_preserves_custom_types() throws {
        let alias = QVACClient.makeLoadModelRequest(
            modelSrc: "hf:model",
            modelType: "diffusion",
            modelConfig: nil,
            modelName: nil,
            requestId: "alias-request",
            withProgress: false
        )
        XCTAssertEqual(alias.modelType, "sdcpp-generation")

        let custom = QVACClient.makeLoadModelRequest(
            modelSrc: "plugin:model",
            modelType: "vendor-custom-model",
            modelConfig: nil,
            modelName: nil,
            requestId: "custom-request",
            withProgress: false
        )
        XCTAssertEqual(custom.modelType, "vendor-custom-model")
    }

    func test_cancel_request_target_uses_only_native_017_fields() throws {
        let request = QVACClient.makeCancelRequest(
            .request(requestId: "request-123", clearCache: true)
        )
        let json = try Self.object(for: .cancel(request))
        XCTAssertEqual(json["type"] as? String, "cancel")
        XCTAssertEqual(json["operation"] as? String, "request")
        XCTAssertEqual(json["requestId"] as? String, "request-123")
        XCTAssertEqual(json["clearCache"] as? Bool, true)
        XCTAssertNil(json["modelId"])
        XCTAssertNil(json["kind"])
    }

    func test_cancel_broad_target_uses_only_native_017_fields() throws {
        let request = QVACClient.makeCancelRequest(
            .broad(modelId: "model-123", kind: "completion")
        )
        let json = try Self.object(for: .cancel(request))
        XCTAssertEqual(json["type"] as? String, "cancel")
        XCTAssertEqual(json["operation"] as? String, "broad")
        XCTAssertEqual(json["modelId"] as? String, "model-123")
        XCTAssertEqual(json["kind"] as? String, "completion")
        XCTAssertNil(json["requestId"])
        XCTAssertNil(json["clearCache"])
    }

    func test_timeout_validation_matches_017_minimum() throws {
        // @qvac/sdk 0.17 permits an optional per-call override. Swift keeps the
        // wire-compatible explicit-nil escape hatch while making ordinary calls
        // bounded so a missing worker reply cannot hang an application forever.
        XCTAssertEqual(QVACRPCOptions().timeout, .seconds(60))
        XCTAssertEqual(
            try QVACClient.validatedRPCOptions(.init()),
            QVACRPCOptions.defaultTimeout
        )
        XCTAssertNil(QVACRPCOptions(timeout: nil).timeout)
        XCTAssertNil(try QVACClient.validatedTimeout(nil))
        XCTAssertEqual(
            try QVACClient.validatedTimeout(.milliseconds(100)),
            .milliseconds(100)
        )
        XCTAssertThrowsError(try QVACClient.validatedTimeout(.milliseconds(99))) { error in
            guard case QVACError.invalidArgument = error else {
                return XCTFail("expected invalidArgument, got \(error)")
            }
        }
    }

    func test_health_check_and_force_new_connection_match_017_local_noop_semantics() throws {
        XCTAssertEqual(
            try QVACClient.validatedRPCOptions(QVACRPCOptions(
                healthCheckTimeout: .milliseconds(100),
                forceNewConnection: true
            )),
            QVACRPCOptions.defaultTimeout
        )
        XCTAssertThrowsError(try QVACClient.validatedRPCOptions(QVACRPCOptions(
            healthCheckTimeout: .milliseconds(99)
        ))) { error in
            guard case QVACError.invalidArgument = error else {
                return XCTFail("expected invalidArgument, got \(error)")
            }
        }
    }

    func test_profiling_request_envelopes_match_017_enabled_disabled_and_omitted_shapes() throws {
        let request = Data(#"{"type":"heartbeat"}"#.utf8)

        XCTAssertEqual(
            try QVACClient.applyingProfilingOptions(nil, to: request),
            request,
            "omitted profiling must not mutate the request"
        )
        XCTAssertEqual(
            try QVACClient.applyingProfilingOptions(QVACProfilingOptions(), to: request),
            request,
            "an omitted enabled flag follows the upstream disabled default"
        )

        let disabled = try Self.jsonObject(try QVACClient.applyingProfilingOptions(
            QVACProfilingOptions(enabled: false),
            to: request
        ))
        XCTAssertEqual(disabled["type"] as? String, "heartbeat")
        let disabledMeta = try XCTUnwrap(disabled["__profiling"] as? [String: Any])
        XCTAssertEqual(disabledMeta.count, 1)
        XCTAssertEqual(disabledMeta["enabled"] as? Bool, false)

        let enabled = try Self.jsonObject(try QVACClient.applyingProfilingOptions(
            QVACProfilingOptions(
                enabled: true,
                includeServerBreakdown: true,
                includeResourceGauges: false,
                mode: .verbose
            ),
            to: request
        ))
        let enabledMeta = try XCTUnwrap(enabled["__profiling"] as? [String: Any])
        XCTAssertEqual(enabledMeta["enabled"] as? Bool, true)
        XCTAssertEqual(enabledMeta["includeServer"] as? Bool, true)
        XCTAssertEqual(enabledMeta["includeResources"] as? Bool, false)
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(enabledMeta["id"] as? String)))
        XCTAssertNil(enabledMeta["mode"], "mode is local profiler retention, not wire metadata")
    }

    func test_response_profiling_metadata_is_captured_and_stripped_for_unary_and_trailer() throws {
        struct Response: Decodable, Equatable { let success: Bool }
        let capture = ProfilingCapture()
        let handler: @Sendable (QVACProfilingMetadata) -> Void = { capture.append($0) }

        let response: Response = try QVACClient.decodeOrThrowStatic(
            Response.self,
            from: Data(#"{"success":true,"__profiling":{"id":"unary"}}"#.utf8),
            profilingMetadataHandler: handler
        )
        XCTAssertEqual(response, Response(success: true))

        let trailer: Response? = try QVACClient.decodeStreamRecord(
            Response.self,
            from: Data(#"{"__profilingTrailer":true,"__profiling":{"id":"stream"}}"#.utf8),
            profilingMetadataHandler: handler
        )
        XCTAssertNil(trailer)
        XCTAssertEqual(capture.values(), [
            QVACProfilingMetadata(value: .object(["id": .string("unary")])),
            QVACProfilingMetadata(value: .object(["id": .string("stream")])),
        ])
    }

    func test_default_worklet_arguments_json_escape_arbitrary_home_path() throws {
        let home = URL(fileURLWithPath: "/tmp/qvac-\"quoted\\path\nline")
        let arguments = QVACClient.Configuration.defaultWorkletArguments(homeDirectory: home)
        XCTAssertEqual(arguments.count, 3)
        let config = try Self.jsonObject(Data(arguments[2].utf8))
        XCTAssertEqual(config["HOME_DIR"] as? String, home.path)
    }

    func test_worklet_bundle_read_failure_is_normalized_to_public_transport_error() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
        XCTAssertThrowsError(
            try QVACClient.Configuration.readWorkletBundleData(from: missing)
        ) { error in
            guard case let QVACError.transport(reason, underlying) = error else {
                return XCTFail("expected transport, got \(error)")
            }
            XCTAssertEqual(reason, "could not read bundled worker.mobile.bundle")
            XCTAssertNotNil(underlying)
        }
    }

    func test_ios_handshake_context_selects_017_mobile_defaults() throws {
        let context = QVACRuntimeContext.iOSDefault
        XCTAssertEqual(context.runtime, "react-native")
        XCTAssertEqual(context.platform, "ios")
        XCTAssertEqual(context.deviceBrand, "Apple")
        XCTAssertNil(context.deviceModel)

        let data = try JSONEncoder.qvac.encode(InitConfigEnvelope(
            config: nil,
            runtimeContext: context
        ))
        let envelope = try Self.jsonObject(data)
        let encodedContext = try XCTUnwrap(envelope["runtimeContext"] as? [String: Any])
        XCTAssertEqual(encodedContext["runtime"] as? String, "react-native")
        XCTAssertEqual(encodedContext["platform"] as? String, "ios")
        XCTAssertEqual(encodedContext["deviceBrand"] as? String, "Apple")
    }

    func test_qvac_encoder_factory_is_safe_under_parallel_use() async throws {
        let expected = try JSONEncoder.qvac.encode(QVACRequest.heartbeat(HeartbeatRequest()))
        let outputs = try await withThrowingTaskGroup(of: Data.self) { group in
            for _ in 0..<500 {
                group.addTask {
                    try JSONEncoder.qvac.encode(QVACRequest.heartbeat(HeartbeatRequest()))
                }
            }
            var values: [Data] = []
            for try await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(outputs.count, 500)
        XCTAssertTrue(outputs.allSatisfy { $0 == expected })
    }

    func test_low_level_timeout_maps_to_public_operation_error() {
        let mapped = QVACClient.publicRPCError(
            BareRPCRequestTimeout(timeout: .seconds(3)),
            operation: "heartbeat"
        )
        guard case QVACError.requestTimedOut(let operation, let timeout) = mapped else {
            return XCTFail("unexpected mapping: \(mapped)")
        }
        XCTAssertEqual(operation, "heartbeat")
        XCTAssertEqual(timeout, .seconds(3))
    }

    func test_malformed_response_containing_profiling_key_is_normalized_to_encoding_error() {
        struct Response: Decodable { let success: Bool }
        let malformed = Data(#"{"__profiling": {"id":"p"}, "success": tru}"#.utf8)

        XCTAssertThrowsError(try QVACClient.decodeOrThrowStatic(Response.self, from: malformed)) { error in
            guard case QVACError.encoding = error else {
                return XCTFail("expected QVACError.encoding, got \(error)")
            }
        }
    }

    func test_unary_error_envelope_uses_generated_schema_and_checked_integer_code() {
        struct Response: Decodable { let success: Bool }
        let malformedCodes = [
            #"{"type":"error","message":"bad","code":1.5}"#,
            #"{"type":"error","message":"bad","code":1e300}"#,
            #"{"type":"error","message":"bad","code":"40001"}"#,
            #"{"type":"error","message":"bad","code":true}"#,
            #"{"type":"error","code":40001}"#,
        ]
        for payload in malformedCodes {
            XCTAssertThrowsError(try QVACClient.decodeOrThrowStatic(
                Response.self,
                from: Data(payload.utf8)
            )) { error in
                guard case QVACError.protocolViolation = error else {
                    return XCTFail("expected protocolViolation for \(payload), got \(error)")
                }
            }
        }
    }

    func test_generated_response_union_maps_valid_and_malformed_error_envelopes() {
        let capture = ProfilingCapture()
        XCTAssertNoThrow(try {
            let response = try QVACClient.decodeOrThrowStatic(
                QVACResponse.self,
                from: Data(
                    #"{"type":"heartbeat","number":42,"__profiling":{"id":"union-success"}}"#.utf8
                ),
                profilingMetadataHandler: { capture.append($0) }
            )
            XCTAssertEqual(response, .heartbeat(HeartbeatResponse(number: 42)))
        }())
        XCTAssertEqual(capture.values(), [
            QVACProfilingMetadata(value: .object(["id": .string("union-success")])),
        ])

        XCTAssertThrowsError(try QVACClient.decodeOrThrowStatic(
            QVACResponse.self,
            from: Data(#"{"type":"error","message":"invalid reply","code":50001}"#.utf8)
        )) { error in
            guard case QVACError.client(.invalidResponseType, let message) = error else {
                return XCTFail("expected typed invalidResponseType, got \(error)")
            }
            XCTAssertEqual(message, "invalid reply")
        }

        XCTAssertThrowsError(try QVACClient.decodeOrThrowStatic(
            QVACResponse.self,
            from: Data(#"{"type":"error","message":"addon reply"}"#.utf8)
        )) { error in
            guard case QVACError.serverUntyped(0, let message) = error else {
                return XCTFail("expected absent code to preserve 0 fallback, got \(error)")
            }
            XCTAssertEqual(message, "addon reply")
        }

        for invalidCode in ["50001.5", "1e100", #""50001""#, "true"] {
            XCTAssertThrowsError(try QVACClient.decodeOrThrowStatic(
                QVACResponse.self,
                from: Data(
                    #"{"type":"error","message":"bad code","code":\#(invalidCode)}"#.utf8
                )
            )) { error in
                guard case QVACError.protocolViolation = error else {
                    return XCTFail("expected invalid code protocolViolation, got \(error)")
                }
            }
        }

        XCTAssertThrowsError(try QVACClient.decodeOrThrowStatic(
            QVACResponse.self,
            from: Data(#"{"type":"error","code":50001}"#.utf8)
        )) { error in
            guard case QVACError.protocolViolation = error else {
                return XCTFail("expected malformed error protocolViolation, got \(error)")
            }
        }

        for malformedSuccess in [
            #"{"type":"heartbeat"}"#,
            #"{"type":"unknownResponse","number":42}"#,
            #"{"type":42,"number":42}"#,
        ] {
            XCTAssertThrowsError(try QVACClient.decodeOrThrowStatic(
                QVACResponse.self,
                from: Data(malformedSuccess.utf8)
            )) { error in
                guard case QVACError.encoding = error else {
                    return XCTFail("expected malformed non-error encoding failure, got \(error)")
                }
            }
        }
    }

    func test_public_error_mapping_distinguishes_arguments_protocol_and_ndjson() {
        guard case QVACError.invalidArgument = QVACClient.publicRPCError(
            BareRPCInvalidArgument("bad option"),
            operation: "test"
        ) else { return XCTFail("local option must map to invalidArgument") }

        guard case QVACError.protocolViolation = QVACClient.publicRPCError(
            BareRPCProtocolError("bad peer state"),
            operation: "test"
        ) else { return XCTFail("peer state must map to protocolViolation") }

        guard case QVACError.protocolViolation = QVACClient.publicRPCError(
            BareRPCCodecError.truncated,
            operation: "test"
        ) else { return XCTFail("wire codec failure must map to protocolViolation") }

        guard case QVACError.encoding = QVACClient.publicRPCError(
            QVACNDJSONError.recordTooLarge(limit: 1_024),
            operation: "test"
        ) else { return XCTFail("NDJSON framing failure must map to encoding") }
    }

    func test_public_pull_mapped_stream_second_iterator_surfaces_qvac_error() async throws {
        let source = QVACResponseStream<Int>(unfolding: { 1 }, onTermination: {})
        let mapped: QVACResponseStream<Int> = QVACClient.pullMap(source) {
            .emit($0)
        }
        var firstIterator = mapped.makeAsyncIterator()
        var secondIterator = mapped.makeAsyncIterator()
        let first = try await firstIterator.next()
        XCTAssertEqual(first, 1)

        do {
            _ = try await secondIterator.next()
            XCTFail("expected second-iterator failure")
        } catch let error as QVACError {
            guard case .protocolViolation = error else {
                return XCTFail("expected protocolViolation, got \(error)")
            }
        }
        mapped.cancel()
    }

    private static func object(for request: QVACRequest) throws -> [String: Any] {
        let data = try JSONEncoder.qvac.encode(request)
        return try jsonObject(data)
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private final class ProfilingCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [QVACProfilingMetadata] = []

    func append(_ value: QVACProfilingMetadata) {
        lock.withLock { storage.append(value) }
    }

    func values() -> [QVACProfilingMetadata] {
        lock.withLock { storage }
    }
}
