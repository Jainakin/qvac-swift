// QVACSDKContract.generated.swift
//
// AUTO-GENERATED from @qvac/sdk@0.17.0 contract/manifest.json
// gitHead: e8b440665a053a9efe852f04c3601da44f0d55d8
// DO NOT EDIT BY HAND. Re-run `tools/codegen/run.sh` to update.

import Foundation

/// Immutable provenance and routing inventory for the exact QVAC wire contract.
public enum QVACSDKContract {
    public static let sdkVersion = "0.17.0"
    public static let upstreamCommit = "e8b440665a053a9efe852f04c3601da44f0d55d8"
    public static let methodCount = 39

    public enum CallShape: String, Sendable, Equatable, Codable {
        case requestReply = "request-reply"
        case serverStream = "server-stream"
        case duplex
    }

    public struct Method: Sendable, Equatable, Codable {
        public struct Progress: Sendable, Equatable, Codable {
            public let condition: String
            public let responseSchema: String
            public let operations: [String]?
            public let allowsMissingOperation: Bool

            public init(
                condition: String,
                responseSchema: String,
                operations: [String]?,
                allowsMissingOperation: Bool
            ) {
                self.condition = condition
                self.responseSchema = responseSchema
                self.operations = operations
                self.allowsMissingOperation = allowsMissingOperation
            }
        }

        public let name: String
        public let callShape: CallShape
        public let requestSchema: String
        public let responseSchema: String
        public let progress: Progress?

        public init(
            name: String,
            callShape: CallShape,
            requestSchema: String,
            responseSchema: String,
            progress: Progress? = nil
        ) {
            self.name = name
            self.callShape = callShape
            self.requestSchema = requestSchema
            self.responseSchema = responseSchema
            self.progress = progress
        }
    }

    /// Exact method order exported by the pinned source contract.
    public static let methods: [Method] = [
        .init(name: "audioGenStream", callShape: .serverStream, requestSchema: "schema.json#/$defs/audioGenStream.request", responseSchema: "schema.json#/$defs/audioGenStream.response"),
        .init(name: "batchCompletionStream", callShape: .serverStream, requestSchema: "schema.json#/$defs/batchCompletionStream.request", responseSchema: "schema.json#/$defs/batchCompletionStream.response"),
        .init(name: "bciTranscribe", callShape: .serverStream, requestSchema: "schema.json#/$defs/bciTranscribe.request", responseSchema: "schema.json#/$defs/bciTranscribe.response"),
        .init(name: "bciTranscribeStream", callShape: .duplex, requestSchema: "schema.json#/$defs/bciTranscribeStream.request", responseSchema: "schema.json#/$defs/bciTranscribeStream.response"),
        .init(name: "cancel", callShape: .requestReply, requestSchema: "schema.json#/$defs/cancel.request", responseSchema: "schema.json#/$defs/cancel.response"),
        .init(name: "classify", callShape: .serverStream, requestSchema: "schema.json#/$defs/classify.request", responseSchema: "schema.json#/$defs/classify.response"),
        .init(name: "completionOrchestrate", callShape: .duplex, requestSchema: "schema.json#/$defs/completionOrchestrate.request", responseSchema: "schema.json#/$defs/completionOrchestrate.response"),
        .init(name: "completionStream", callShape: .serverStream, requestSchema: "schema.json#/$defs/completionStream.request", responseSchema: "schema.json#/$defs/completionStream.response"),
        .init(name: "deleteCache", callShape: .requestReply, requestSchema: "schema.json#/$defs/deleteCache.request", responseSchema: "schema.json#/$defs/deleteCache.response"),
        .init(name: "diffusionStream", callShape: .serverStream, requestSchema: "schema.json#/$defs/diffusionStream.request", responseSchema: "schema.json#/$defs/diffusionStream.response"),
        .init(name: "downloadAsset", callShape: .requestReply, requestSchema: "schema.json#/$defs/downloadAsset.request", responseSchema: "schema.json#/$defs/downloadAsset.response", progress: .init(condition: "request.withProgress === true", responseSchema: "schema.json#/$defs/modelProgress.response", operations: nil, allowsMissingOperation: true)),
        .init(name: "embed", callShape: .requestReply, requestSchema: "schema.json#/$defs/embed.request", responseSchema: "schema.json#/$defs/embed.response"),
        .init(name: "finetune", callShape: .requestReply, requestSchema: "schema.json#/$defs/finetune.request", responseSchema: "schema.json#/$defs/finetune.response", progress: .init(condition: "request.withProgress === true && ['start', 'resume', undefined].includes(request.operation)", responseSchema: "schema.json#/$defs/finetune:progress.response", operations: ["start", "resume"], allowsMissingOperation: true)),
        .init(name: "getLoadedModelInfo", callShape: .requestReply, requestSchema: "schema.json#/$defs/getLoadedModelInfo.request", responseSchema: "schema.json#/$defs/getLoadedModelInfo.response"),
        .init(name: "getModelInfo", callShape: .requestReply, requestSchema: "schema.json#/$defs/getModelInfo.request", responseSchema: "schema.json#/$defs/getModelInfo.response"),
        .init(name: "getSystemResources", callShape: .requestReply, requestSchema: "schema.json#/$defs/getSystemResources.request", responseSchema: "schema.json#/$defs/getSystemResources.response"),
        .init(name: "heartbeat", callShape: .requestReply, requestSchema: "schema.json#/$defs/heartbeat.request", responseSchema: "schema.json#/$defs/heartbeat.response"),
        .init(name: "loadModel", callShape: .requestReply, requestSchema: "schema.json#/$defs/loadModel.request", responseSchema: "schema.json#/$defs/loadModel.response", progress: .init(condition: "request.withProgress === true", responseSchema: "schema.json#/$defs/modelProgress.response", operations: nil, allowsMissingOperation: true)),
        .init(name: "loggingStream", callShape: .serverStream, requestSchema: "schema.json#/$defs/loggingStream.request", responseSchema: "schema.json#/$defs/loggingStream.response"),
        .init(name: "modelRegistryGetModel", callShape: .requestReply, requestSchema: "schema.json#/$defs/modelRegistryGetModel.request", responseSchema: "schema.json#/$defs/modelRegistryGetModel.response"),
        .init(name: "modelRegistryList", callShape: .requestReply, requestSchema: "schema.json#/$defs/modelRegistryList.request", responseSchema: "schema.json#/$defs/modelRegistryList.response"),
        .init(name: "modelRegistrySearch", callShape: .requestReply, requestSchema: "schema.json#/$defs/modelRegistrySearch.request", responseSchema: "schema.json#/$defs/modelRegistrySearch.response"),
        .init(name: "ocrStream", callShape: .serverStream, requestSchema: "schema.json#/$defs/ocrStream.request", responseSchema: "schema.json#/$defs/ocrStream.response"),
        .init(name: "pluginInvoke", callShape: .requestReply, requestSchema: "schema.json#/$defs/pluginInvoke.request", responseSchema: "schema.json#/$defs/pluginInvoke.response"),
        .init(name: "pluginInvokeStream", callShape: .serverStream, requestSchema: "schema.json#/$defs/pluginInvokeStream.request", responseSchema: "schema.json#/$defs/pluginInvokeStream.response"),
        .init(name: "provide", callShape: .requestReply, requestSchema: "schema.json#/$defs/provide.request", responseSchema: "schema.json#/$defs/provide.response"),
        .init(name: "rag", callShape: .requestReply, requestSchema: "schema.json#/$defs/rag.request", responseSchema: "schema.json#/$defs/rag.response", progress: .init(condition: "request.withProgress === true && ['ingest', 'saveEmbeddings', 'reindex'].includes(request.operation)", responseSchema: "schema.json#/$defs/rag:progress.response", operations: ["ingest", "saveEmbeddings", "reindex"], allowsMissingOperation: false)),
        .init(name: "resume", callShape: .requestReply, requestSchema: "schema.json#/$defs/resume.request", responseSchema: "schema.json#/$defs/resume.response"),
        .init(name: "state", callShape: .requestReply, requestSchema: "schema.json#/$defs/state.request", responseSchema: "schema.json#/$defs/state.response"),
        .init(name: "stopProvide", callShape: .requestReply, requestSchema: "schema.json#/$defs/stopProvide.request", responseSchema: "schema.json#/$defs/stopProvide.response"),
        .init(name: "suspend", callShape: .requestReply, requestSchema: "schema.json#/$defs/suspend.request", responseSchema: "schema.json#/$defs/suspend.response"),
        .init(name: "textToSpeech", callShape: .serverStream, requestSchema: "schema.json#/$defs/textToSpeech.request", responseSchema: "schema.json#/$defs/textToSpeech.response"),
        .init(name: "textToSpeechStream", callShape: .duplex, requestSchema: "schema.json#/$defs/textToSpeechStream.request", responseSchema: "schema.json#/$defs/textToSpeechStream.response"),
        .init(name: "transcribe", callShape: .serverStream, requestSchema: "schema.json#/$defs/transcribe.request", responseSchema: "schema.json#/$defs/transcribe.response"),
        .init(name: "transcribeStream", callShape: .duplex, requestSchema: "schema.json#/$defs/transcribeStream.request", responseSchema: "schema.json#/$defs/transcribeStream.response"),
        .init(name: "translate", callShape: .serverStream, requestSchema: "schema.json#/$defs/translate.request", responseSchema: "schema.json#/$defs/translate.response"),
        .init(name: "unloadModel", callShape: .requestReply, requestSchema: "schema.json#/$defs/unloadModel.request", responseSchema: "schema.json#/$defs/unloadModel.response"),
        .init(name: "upscaleStream", callShape: .serverStream, requestSchema: "schema.json#/$defs/upscaleStream.request", responseSchema: "schema.json#/$defs/upscaleStream.response"),
        .init(name: "videoStream", callShape: .serverStream, requestSchema: "schema.json#/$defs/videoStream.request", responseSchema: "schema.json#/$defs/videoStream.response")
    ]

    private static let methodsByName = Dictionary(uniqueKeysWithValues: methods.map { ($0.name, $0) })

    public static func method(named name: String) -> Method? {
        methodsByName[name]
    }
}

public extension QVACClient {
    /// Invoke any contract method declared as request/reply. Prefer a typed convenience
    /// API when one exists; this surface guarantees newly generated methods are callable.
    func wireRequestReply(
        _ request: QVACRequest,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> QVACResponse {
        let method = try Self.requireCallShape(.requestReply, for: request)
        if try Self.usesConditionalProgressTransport(method, request: request) {
            throw QVACError.invalidArgument(
                "\(request.discriminator) requested progress; use wireProgressStream"
            )
        }
        return try await sendTyped(request, rpcOptions: rpcOptions)
    }

    /// Invoke the conditional progress transport of a request/reply method. This is
    /// available only when the manifest declares progress and the request satisfies
    /// its exact `withProgress`/operation condition.
    ///
    /// This low-level wire-union API yields `QVACResponse.error` as a domain
    /// element. Continue iteration to EOF to consume a following profiling trailer.
    /// Higher-level progress-run APIs perform that drain and then throw `QVACError`.
    func wireProgressStream(
        _ request: QVACRequest,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> QVACResponseStream<QVACResponse> {
        let method = try Self.requireCallShape(.requestReply, for: request)
        guard method.progress != nil else {
            throw QVACError.invalidArgument(
                "\(request.discriminator) has no conditional progress transport"
            )
        }
        guard try Self.usesConditionalProgressTransport(method, request: request) else {
            throw QVACError.invalidArgument(
                "\(request.discriminator) request does not satisfy \(method.progress!.condition)"
            )
        }
        return try await streamTyped(request, rpcOptions: rpcOptions)
    }

    /// Invoke any contract method declared as a server stream.
    ///
    /// This low-level wire-union API yields `QVACResponse.error` as a domain
    /// element. Continue iteration to EOF to consume a following profiling trailer.
    /// Concrete generated and high-level APIs perform that drain and then throw
    /// `QVACError`.
    func wireServerStream(
        _ request: QVACRequest,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> QVACResponseStream<QVACResponse> {
        _ = try Self.requireCallShape(.serverStream, for: request)
        return try await streamTyped(request, rpcOptions: rpcOptions)
    }

    /// Open any contract method declared as a duplex stream.
    ///
    /// The returned low-level response union yields `QVACResponse.error` as a
    /// domain element. Continue its response iterator to EOF to consume a following
    /// profiling trailer. Concrete generated APIs drain that trailer and throw
    /// `QVACError`.
    func wireDuplex(
        _ request: QVACRequest,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> QVACDuplexSession<QVACResponse> {
        _ = try Self.requireCallShape(.duplex, for: request)
        return try await duplexTyped(request, rpcOptions: rpcOptions)
    }

    private static func requireCallShape(
        _ expected: QVACSDKContract.CallShape,
        for request: QVACRequest
    ) throws -> QVACSDKContract.Method {
        guard let method = QVACSDKContract.method(named: request.discriminator) else {
            throw QVACError.invalidArgument(
                "request discriminator \(request.discriminator) is not in the pinned SDK contract"
            )
        }
        guard method.callShape == expected else {
            throw QVACError.invalidArgument(
                "\(request.discriminator) is \(method.callShape.rawValue), not \(expected.rawValue)"
            )
        }
        return method
    }

    private static func usesConditionalProgressTransport(
        _ method: QVACSDKContract.Method,
        request: QVACRequest
    ) throws -> Bool {
        guard let progress = method.progress else { return false }
        let data: Data
        do {
            data = try JSONEncoder.qvac.encode(request)
        } catch {
            throw QVACError.encoding("could not inspect progress request: \(error)")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QVACError.encoding("progress request did not encode as an object")
        }
        guard object["withProgress"] as? Bool == true else { return false }
        guard let operations = progress.operations else { return true }
        guard let operation = object["operation"] as? String else {
            return progress.allowsMissingOperation
        }
        return operations.contains(operation)
    }

    /// Exact generated server-stream entry point for `audioGenStream`.
    func wireAudioGenStream(
        _ request: AudioGenStreamRequest,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> QVACResponseStream<AudioGenStreamResponse> {
        let source = try await wireServerStream(.audioGenStream(request), rpcOptions: rpcOptions)
        return Self.pullMap(source, operation: "audioGenStream") { response in
            switch response {
            case .audioGenStream(let value):
                return .emit(value)
            case .error(let error):
                return .failThenDrain(Self.retainedWireError(error))
            default:
                try Self.rejectUnexpectedResponse(response, expected: "audioGenStream")
            }
        }
    }

    /// Exact generated server-stream entry point for `batchCompletionStream`.
    func wireBatchCompletionStream(
        _ request: BatchCompletionStreamRequest,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> QVACResponseStream<BatchCompletionStreamResponse> {
        let source = try await wireServerStream(.batchCompletionStream(request), rpcOptions: rpcOptions)
        return Self.pullMap(source, operation: "batchCompletionStream") { response in
            switch response {
            case .batchCompletionStream(let value):
                return .emit(value)
            case .error(let error):
                return .failThenDrain(Self.retainedWireError(error))
            default:
                try Self.rejectUnexpectedResponse(response, expected: "batchCompletionStream")
            }
        }
    }

    /// Exact generated server-stream entry point for `bciTranscribe`.
    func wireBciTranscribe(
        _ request: BciTranscribeRequest,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> QVACResponseStream<BciTranscribeResponse> {
        let source = try await wireServerStream(.bciTranscribe(request), rpcOptions: rpcOptions)
        return Self.pullMap(source, operation: "bciTranscribe") { response in
            switch response {
            case .bciTranscribe(let value):
                return .emit(value)
            case .error(let error):
                return .failThenDrain(Self.retainedWireError(error))
            default:
                try Self.rejectUnexpectedResponse(response, expected: "bciTranscribe")
            }
        }
    }

    /// Exact generated duplex entry point for `bciTranscribeStream`.
    func wireBciTranscribeStream(
        _ request: BciTranscribeStreamRequest,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> QVACDuplexSession<BciTranscribeStreamResponse> {
        let envelope = QVACRequest.bciTranscribeStream(request)
        _ = try Self.requireCallShape(.duplex, for: envelope)
        return try await duplexTyped(envelope, decoding: BciTranscribeStreamResponse.self, rpcOptions: rpcOptions)
    }

    /// Exact generated request/reply entry point for `cancel`.
    func wireCancel(
        _ request: CancelRequest,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> CancelResponse {
        let response = try await wireRequestReply(.cancel(request), rpcOptions: rpcOptions)
        guard case .cancel(let value) = response else {
            throw QVACError.protocolViolation(
                "expected cancel response, got \(response.discriminator)"
            )
        }
        return value
    }

    /// Exact generated server-stream entry point for `classify`.
    func wireClassify(
        _ request: ClassifyRequest,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> QVACResponseStream<ClassifyResponse> {
        let source = try await wireServerStream(.classify(request), rpcOptions: rpcOptions)
        return Self.pullMap(source, operation: "classify") { response in
            switch response {
            case .classify(let value):
                return .emit(value)
            case .error(let error):
                return .failThenDrain(Self.retainedWireError(error))
            default:
                try Self.rejectUnexpectedResponse(response, expected: "classify")
            }
        }
    }

    /// Exact generated duplex entry point for `completionOrchestrate`.
    func wireCompletionOrchestrate(
        _ request: CompletionOrchestrateRequest,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> QVACDuplexSession<CompletionOrchestrateResponse> {
        let envelope = QVACRequest.completionOrchestrate(request)
        _ = try Self.requireCallShape(.duplex, for: envelope)
        return try await duplexTyped(envelope, decoding: CompletionOrchestrateResponse.self, rpcOptions: rpcOptions)
    }

    /// Exact generated server-stream entry point for `completionStream`.
    func wireCompletionStream(
        _ request: CompletionStreamRequest,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> QVACResponseStream<CompletionStreamResponse> {
        let source = try await wireServerStream(.completionStream(request), rpcOptions: rpcOptions)
        return Self.pullMap(source, operation: "completionStream") { response in
            switch response {
            case .completionStream(let value):
                return .emit(value)
            case .error(let error):
                return .failThenDrain(Self.retainedWireError(error))
            default:
                try Self.rejectUnexpectedResponse(response, expected: "completionStream")
            }
        }
    }

    /// Exact generated request/reply entry point for `deleteCache`.
    func wireDeleteCache(
        _ request: DeleteCacheRequest,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> DeleteCacheResponse {
        let response = try await wireRequestReply(.deleteCache(request), rpcOptions: rpcOptions)
        guard case .deleteCache(let value) = response else {
            throw QVACError.protocolViolation(
                "expected deleteCache response, got \(response.discriminator)"
            )
        }
        return value
    }

    /// Exact generated server-stream entry point for `diffusionStream`.
    func wireDiffusionStream(
        _ request: DiffusionStreamRequest,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> QVACResponseStream<DiffusionStreamResponse> {
        let source = try await wireServerStream(.diffusionStream(request), rpcOptions: rpcOptions)
        return Self.pullMap(source, operation: "diffusionStream") { response in
            switch response {
            case .diffusionStream(let value):
                return .emit(value)
            case .error(let error):
                return .failThenDrain(Self.retainedWireError(error))
            default:
                try Self.rejectUnexpectedResponse(response, expected: "diffusionStream")
            }
        }
    }

    /// Exact generated request/reply entry point for `downloadAsset`.
    func wireDownloadAsset(
        _ request: DownloadAssetRequest,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> DownloadAssetResponse {
        let response = try await wireRequestReply(.downloadAsset(request), rpcOptions: rpcOptions)
        guard case .downloadAsset(let value) = response else {
            throw QVACError.protocolViolation(
                "expected downloadAsset response, got \(response.discriminator)"
            )
        }
        return value
    }

    /// Invoke the conditional progress transport declared for `downloadAsset`.
    /// This wire-union stream preserves `QVACResponse.error`; continue the same
    /// iterator to EOF to consume a following profiling trailer.
    func wireDownloadAssetProgress(
        _ request: DownloadAssetRequest,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> QVACResponseStream<QVACResponse> {
        try await wireProgressStream(.downloadAsset(request), rpcOptions: rpcOptions)
    }

    /// Exact generated request/reply entry point for `embed`.
    func wireEmbed(
        _ request: EmbedRequest,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> EmbedResponse {
        let response = try await wireRequestReply(.embed(request), rpcOptions: rpcOptions)
        guard case .embed(let value) = response else {
            throw QVACError.protocolViolation(
                "expected embed response, got \(response.discriminator)"
            )
        }
        return value
    }

    /// Exact generated request/reply entry point for `finetune`.
    func wireFinetune(
        _ request: FinetuneRequest,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> FinetuneResponse {
        let response = try await wireRequestReply(.finetune(request), rpcOptions: rpcOptions)
        guard case .finetune(let value) = response else {
            throw QVACError.protocolViolation(
                "expected finetune response, got \(response.discriminator)"
            )
        }
        return value
    }

    /// Invoke the conditional progress transport declared for `finetune`.
    /// This wire-union stream preserves `QVACResponse.error`; continue the same
    /// iterator to EOF to consume a following profiling trailer.
    func wireFinetuneProgress(
        _ request: FinetuneRequest,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> QVACResponseStream<QVACResponse> {
        try await wireProgressStream(.finetune(request), rpcOptions: rpcOptions)
    }

    /// Exact generated request/reply entry point for `getLoadedModelInfo`.
    func wireGetLoadedModelInfo(
        _ request: GetLoadedModelInfoRequest,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> GetLoadedModelInfoResponse {
        let response = try await wireRequestReply(.getLoadedModelInfo(request), rpcOptions: rpcOptions)
        guard case .getLoadedModelInfo(let value) = response else {
            throw QVACError.protocolViolation(
                "expected getLoadedModelInfo response, got \(response.discriminator)"
            )
        }
        return value
    }

    /// Exact generated request/reply entry point for `getModelInfo`.
    func wireGetModelInfo(
        _ request: GetModelInfoRequest,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> GetModelInfoResponse {
        let response = try await wireRequestReply(.getModelInfo(request), rpcOptions: rpcOptions)
        guard case .getModelInfo(let value) = response else {
            throw QVACError.protocolViolation(
                "expected getModelInfo response, got \(response.discriminator)"
            )
        }
        return value
    }

    /// Exact generated request/reply entry point for `getSystemResources`.
    func wireGetSystemResources(
        _ request: GetSystemResourcesRequest,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> GetSystemResourcesResponse {
        let response = try await wireRequestReply(.getSystemResources(request), rpcOptions: rpcOptions)
        guard case .getSystemResources(let value) = response else {
            throw QVACError.protocolViolation(
                "expected getSystemResources response, got \(response.discriminator)"
            )
        }
        return value
    }

    /// Exact generated request/reply entry point for `heartbeat`.
    func wireHeartbeat(
        _ request: HeartbeatRequest,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> HeartbeatResponse {
        let response = try await wireRequestReply(.heartbeat(request), rpcOptions: rpcOptions)
        guard case .heartbeat(let value) = response else {
            throw QVACError.protocolViolation(
                "expected heartbeat response, got \(response.discriminator)"
            )
        }
        return value
    }

    /// Exact generated request/reply entry point for `loadModel`.
    func wireLoadModel(
        _ request: LoadModelRequest,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> LoadModelResponse {
        let response = try await wireRequestReply(.loadModel(request), rpcOptions: rpcOptions)
        guard case .loadModel(let value) = response else {
            throw QVACError.protocolViolation(
                "expected loadModel response, got \(response.discriminator)"
            )
        }
        return value
    }

    /// Invoke the conditional progress transport declared for `loadModel`.
    /// This wire-union stream preserves `QVACResponse.error`; continue the same
    /// iterator to EOF to consume a following profiling trailer.
    func wireLoadModelProgress(
        _ request: LoadModelRequest,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> QVACResponseStream<QVACResponse> {
        try await wireProgressStream(.loadModel(request), rpcOptions: rpcOptions)
    }

    /// Exact generated server-stream entry point for `loggingStream`.
    func wireLoggingStream(
        _ request: LoggingStreamRequest,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> QVACResponseStream<LoggingStreamResponse> {
        let source = try await wireServerStream(.loggingStream(request), rpcOptions: rpcOptions)
        return Self.pullMap(source, operation: "loggingStream") { response in
            switch response {
            case .loggingStream(let value):
                return .emit(value)
            case .error(let error):
                return .failThenDrain(Self.retainedWireError(error))
            default:
                try Self.rejectUnexpectedResponse(response, expected: "loggingStream")
            }
        }
    }

    /// Exact generated request/reply entry point for `modelRegistryGetModel`.
    func wireModelRegistryGetModel(
        _ request: ModelRegistryGetModelRequest,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> ModelRegistryGetModelResponse {
        let response = try await wireRequestReply(.modelRegistryGetModel(request), rpcOptions: rpcOptions)
        guard case .modelRegistryGetModel(let value) = response else {
            throw QVACError.protocolViolation(
                "expected modelRegistryGetModel response, got \(response.discriminator)"
            )
        }
        return value
    }

    /// Exact generated request/reply entry point for `modelRegistryList`.
    func wireModelRegistryList(
        _ request: ModelRegistryListRequest,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> ModelRegistryListResponse {
        let response = try await wireRequestReply(.modelRegistryList(request), rpcOptions: rpcOptions)
        guard case .modelRegistryList(let value) = response else {
            throw QVACError.protocolViolation(
                "expected modelRegistryList response, got \(response.discriminator)"
            )
        }
        return value
    }

    /// Exact generated request/reply entry point for `modelRegistrySearch`.
    func wireModelRegistrySearch(
        _ request: ModelRegistrySearchRequest,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> ModelRegistrySearchResponse {
        let response = try await wireRequestReply(.modelRegistrySearch(request), rpcOptions: rpcOptions)
        guard case .modelRegistrySearch(let value) = response else {
            throw QVACError.protocolViolation(
                "expected modelRegistrySearch response, got \(response.discriminator)"
            )
        }
        return value
    }

    /// Exact generated server-stream entry point for `ocrStream`.
    func wireOcrStream(
        _ request: OcrStreamRequest,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> QVACResponseStream<OcrStreamResponse> {
        let source = try await wireServerStream(.ocrStream(request), rpcOptions: rpcOptions)
        return Self.pullMap(source, operation: "ocrStream") { response in
            switch response {
            case .ocrStream(let value):
                return .emit(value)
            case .error(let error):
                return .failThenDrain(Self.retainedWireError(error))
            default:
                try Self.rejectUnexpectedResponse(response, expected: "ocrStream")
            }
        }
    }

    /// Exact generated request/reply entry point for `pluginInvoke`.
    func wirePluginInvoke(
        _ request: PluginInvokeRequest,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> PluginInvokeResponse {
        let response = try await wireRequestReply(.pluginInvoke(request), rpcOptions: rpcOptions)
        guard case .pluginInvoke(let value) = response else {
            throw QVACError.protocolViolation(
                "expected pluginInvoke response, got \(response.discriminator)"
            )
        }
        return value
    }

    /// Exact generated server-stream entry point for `pluginInvokeStream`.
    func wirePluginInvokeStream(
        _ request: PluginInvokeStreamRequest,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> QVACResponseStream<PluginInvokeStreamResponse> {
        let source = try await wireServerStream(.pluginInvokeStream(request), rpcOptions: rpcOptions)
        return Self.pullMap(source, operation: "pluginInvokeStream") { response in
            switch response {
            case .pluginInvokeStream(let value):
                return .emit(value)
            case .error(let error):
                return .failThenDrain(Self.retainedWireError(error))
            default:
                try Self.rejectUnexpectedResponse(response, expected: "pluginInvokeStream")
            }
        }
    }

    /// Exact generated request/reply entry point for `provide`.
    func wireProvide(
        _ request: ProvideRequest,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> ProvideResponse {
        let response = try await wireRequestReply(.provide(request), rpcOptions: rpcOptions)
        guard case .provide(let value) = response else {
            throw QVACError.protocolViolation(
                "expected provide response, got \(response.discriminator)"
            )
        }
        return value
    }

    /// Exact generated request/reply entry point for `rag`.
    func wireRag(
        _ request: RagRequest,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> RagResponse {
        let response = try await wireRequestReply(.rag(request), rpcOptions: rpcOptions)
        guard case .rag(let value) = response else {
            throw QVACError.protocolViolation(
                "expected rag response, got \(response.discriminator)"
            )
        }
        return value
    }

    /// Invoke the conditional progress transport declared for `rag`.
    /// This wire-union stream preserves `QVACResponse.error`; continue the same
    /// iterator to EOF to consume a following profiling trailer.
    func wireRagProgress(
        _ request: RagRequest,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> QVACResponseStream<QVACResponse> {
        try await wireProgressStream(.rag(request), rpcOptions: rpcOptions)
    }

    /// Exact generated request/reply entry point for `resume`.
    func wireResume(
        _ request: ResumeRequest,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> ResumeResponse {
        let response = try await wireRequestReply(.resume(request), rpcOptions: rpcOptions)
        guard case .resume(let value) = response else {
            throw QVACError.protocolViolation(
                "expected resume response, got \(response.discriminator)"
            )
        }
        return value
    }

    /// Exact generated request/reply entry point for `state`.
    func wireState(
        _ request: StateRequest,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> StateResponse {
        let response = try await wireRequestReply(.state(request), rpcOptions: rpcOptions)
        guard case .state(let value) = response else {
            throw QVACError.protocolViolation(
                "expected state response, got \(response.discriminator)"
            )
        }
        return value
    }

    /// Exact generated request/reply entry point for `stopProvide`.
    func wireStopProvide(
        _ request: StopProvideRequest,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> StopProvideResponse {
        let response = try await wireRequestReply(.stopProvide(request), rpcOptions: rpcOptions)
        guard case .stopProvide(let value) = response else {
            throw QVACError.protocolViolation(
                "expected stopProvide response, got \(response.discriminator)"
            )
        }
        return value
    }

    /// Exact generated request/reply entry point for `suspend`.
    func wireSuspend(
        _ request: SuspendRequest,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> SuspendResponse {
        let response = try await wireRequestReply(.suspend(request), rpcOptions: rpcOptions)
        guard case .suspend(let value) = response else {
            throw QVACError.protocolViolation(
                "expected suspend response, got \(response.discriminator)"
            )
        }
        return value
    }

    /// Exact generated server-stream entry point for `textToSpeech`.
    func wireTextToSpeech(
        _ request: TextToSpeechRequest,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> QVACResponseStream<TextToSpeechResponse> {
        let source = try await wireServerStream(.textToSpeech(request), rpcOptions: rpcOptions)
        return Self.pullMap(source, operation: "textToSpeech") { response in
            switch response {
            case .textToSpeech(let value):
                return .emit(value)
            case .error(let error):
                return .failThenDrain(Self.retainedWireError(error))
            default:
                try Self.rejectUnexpectedResponse(response, expected: "textToSpeech")
            }
        }
    }

    /// Exact generated duplex entry point for `textToSpeechStream`.
    func wireTextToSpeechStream(
        _ request: TextToSpeechStreamRequest,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> QVACDuplexSession<TextToSpeechStreamResponse> {
        let envelope = QVACRequest.textToSpeechStream(request)
        _ = try Self.requireCallShape(.duplex, for: envelope)
        return try await duplexTyped(envelope, decoding: TextToSpeechStreamResponse.self, rpcOptions: rpcOptions)
    }

    /// Exact generated server-stream entry point for `transcribe`.
    func wireTranscribe(
        _ request: TranscribeRequest,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> QVACResponseStream<TranscribeResponse> {
        let source = try await wireServerStream(.transcribe(request), rpcOptions: rpcOptions)
        return Self.pullMap(source, operation: "transcribe") { response in
            switch response {
            case .transcribe(let value):
                return .emit(value)
            case .error(let error):
                return .failThenDrain(Self.retainedWireError(error))
            default:
                try Self.rejectUnexpectedResponse(response, expected: "transcribe")
            }
        }
    }

    /// Exact generated duplex entry point for `transcribeStream`.
    func wireTranscribeStream(
        _ request: TranscribeStreamRequest,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> QVACDuplexSession<TranscribeStreamResponse> {
        let envelope = QVACRequest.transcribeStream(request)
        _ = try Self.requireCallShape(.duplex, for: envelope)
        return try await duplexTyped(envelope, decoding: TranscribeStreamResponse.self, rpcOptions: rpcOptions)
    }

    /// Exact generated server-stream entry point for `translate`.
    func wireTranslate(
        _ request: TranslateRequest,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> QVACResponseStream<TranslateResponse> {
        let source = try await wireServerStream(.translate(request), rpcOptions: rpcOptions)
        return Self.pullMap(source, operation: "translate") { response in
            switch response {
            case .translate(let value):
                return .emit(value)
            case .error(let error):
                return .failThenDrain(Self.retainedWireError(error))
            default:
                try Self.rejectUnexpectedResponse(response, expected: "translate")
            }
        }
    }

    /// Exact generated request/reply entry point for `unloadModel`.
    func wireUnloadModel(
        _ request: UnloadModelRequest,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> UnloadModelResponse {
        let response = try await wireRequestReply(.unloadModel(request), rpcOptions: rpcOptions)
        guard case .unloadModel(let value) = response else {
            throw QVACError.protocolViolation(
                "expected unloadModel response, got \(response.discriminator)"
            )
        }
        return value
    }

    /// Exact generated server-stream entry point for `upscaleStream`.
    func wireUpscaleStream(
        _ request: UpscaleStreamRequest,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> QVACResponseStream<UpscaleStreamResponse> {
        let source = try await wireServerStream(.upscaleStream(request), rpcOptions: rpcOptions)
        return Self.pullMap(source, operation: "upscaleStream") { response in
            switch response {
            case .upscaleStream(let value):
                return .emit(value)
            case .error(let error):
                return .failThenDrain(Self.retainedWireError(error))
            default:
                try Self.rejectUnexpectedResponse(response, expected: "upscaleStream")
            }
        }
    }

    /// Exact generated server-stream entry point for `videoStream`.
    func wireVideoStream(
        _ request: VideoStreamRequest,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> QVACResponseStream<VideoStreamResponse> {
        let source = try await wireServerStream(.videoStream(request), rpcOptions: rpcOptions)
        return Self.pullMap(source, operation: "videoStream") { response in
            switch response {
            case .videoStream(let value):
                return .emit(value)
            case .error(let error):
                return .failThenDrain(Self.retainedWireError(error))
            default:
                try Self.rejectUnexpectedResponse(response, expected: "videoStream")
            }
        }
    }
}
