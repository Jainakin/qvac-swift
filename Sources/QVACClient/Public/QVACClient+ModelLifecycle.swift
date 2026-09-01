// QVAC-202 / QVAC-203 — loadModel + unloadModel

import Foundation

public extension QVACClient {

    // MARK: - Load

    /// QVAC 0.17 progress metadata for a model split across multiple weight shards.
    struct ModelShardProgress: Sendable, Equatable {
        public let currentShard: Double
        public let totalShards: Double
        public let shardName: String
        public let overallDownloaded: Double
        public let overallTotal: Double
        public let overallPercentage: Double

        init(wire: JSONValue) throws {
            let object = try Self.checkedObject(wire, context: "modelProgress.shardInfo")
            currentShard = try Self.checkedNumber(
                object["currentShard"], field: "modelProgress.shardInfo.currentShard"
            )
            totalShards = try Self.checkedNumber(
                object["totalShards"], field: "modelProgress.shardInfo.totalShards"
            )
            shardName = try Self.checkedString(
                object["shardName"], field: "modelProgress.shardInfo.shardName"
            )
            overallDownloaded = try Self.checkedNumber(
                object["overallDownloaded"],
                field: "modelProgress.shardInfo.overallDownloaded"
            )
            overallTotal = try Self.checkedNumber(
                object["overallTotal"], field: "modelProgress.shardInfo.overallTotal"
            )
            overallPercentage = try Self.checkedNumber(
                object["overallPercentage"],
                field: "modelProgress.shardInfo.overallPercentage"
            )
        }

        private static func checkedObject(
            _ value: JSONValue,
            context: String
        ) throws -> [String: JSONValue] {
            guard case .object(let object) = value else {
                throw QVACError.protocolViolation("\(context) must be an object")
            }
            return object
        }

        private static func checkedNumber(_ value: JSONValue?, field: String) throws -> Double {
            guard case .number(let number) = value, number.isFinite else {
                throw QVACError.protocolViolation("\(field) must be a finite number")
            }
            return number
        }

        private static func checkedString(_ value: JSONValue?, field: String) throws -> String {
            guard case .string(let string) = value else {
                throw QVACError.protocolViolation("\(field) must be a string")
            }
            return string
        }
    }

    /// QVAC 0.17 progress metadata for a model accompanied by multiple files.
    struct ModelFileSetProgress: Sendable, Equatable {
        public let setKey: String
        public let currentFile: String
        public let fileIndex: Double
        public let totalFiles: Double
        public let overallDownloaded: Double
        public let overallTotal: Double
        public let overallPercentage: Double

        init(wire: JSONValue) throws {
            guard case .object(let object) = wire else {
                throw QVACError.protocolViolation("modelProgress.fileSetInfo must be an object")
            }

            func number(_ key: String) throws -> Double {
                guard case .number(let value) = object[key], value.isFinite else {
                    throw QVACError.protocolViolation(
                        "modelProgress.fileSetInfo.\(key) must be a finite number"
                    )
                }
                return value
            }

            func string(_ key: String) throws -> String {
                guard case .string(let value) = object[key] else {
                    throw QVACError.protocolViolation(
                        "modelProgress.fileSetInfo.\(key) must be a string"
                    )
                }
                return value
            }

            setKey = try string("setKey")
            currentFile = try string("currentFile")
            fileIndex = try number("fileIndex")
            totalFiles = try number("totalFiles")
            overallDownloaded = try number("overallDownloaded")
            overallTotal = try number("overallTotal")
            overallPercentage = try number("overallPercentage")
        }
    }

    /// Progress event emitted during a streaming model load.
    /// Mirrors the JS client's `modelProgress` event.
    struct ModelLoadProgress: Sendable, Equatable {
        public var downloadKey: String
        public var downloaded: Double
        public var total: Double
        public var percentage: Double
        /// Optional 0.17 sharded-model progress metadata.
        public var shardInfo: ModelShardProgress?
        /// Optional 0.17 companion-file-set progress metadata.
        public var fileSetInfo: ModelFileSetProgress?
        init(_ wire: ModelProgressResponse) throws {
            self.downloadKey = wire.downloadKey
            self.downloaded = wire.downloaded
            self.total = wire.total
            self.percentage = wire.percentage
            self.shardInfo = try wire.shardInfo.map(ModelShardProgress.init(wire:))
            self.fileSetInfo = try wire.fileSetInfo.map(ModelFileSetProgress.init(wire:))
        }
    }

    /// Descriptor form accepted by the 0.17 JavaScript client for model and asset
    /// sources. Only `src` and optional `name` are placed on the wire; `engine` or
    /// `addon` can be used to infer the canonical model type before the request.
    struct ModelDescriptor: Codable, Sendable, Equatable {
        public var src: String
        public var name: String?
        public var modelId: String?
        public var registryPath: String?
        public var registrySource: String?
        public var blobCoreKey: String?
        public var blobIndex: Double?
        public var engine: String?
        public var expectedSize: Double?
        public var sha256Checksum: String?
        public var addon: String?

        public init(
            src: String,
            name: String? = nil,
            modelId: String? = nil,
            registryPath: String? = nil,
            registrySource: String? = nil,
            blobCoreKey: String? = nil,
            blobIndex: Double? = nil,
            engine: String? = nil,
            expectedSize: Double? = nil,
            sha256Checksum: String? = nil,
            addon: String? = nil
        ) {
            self.src = src
            self.name = name
            self.modelId = modelId
            self.registryPath = registryPath
            self.registrySource = registrySource
            self.blobCoreKey = blobCoreKey
            self.blobIndex = blobIndex
            self.engine = engine
            self.expectedSize = expectedSize
            self.sha256Checksum = sha256Checksum
            self.addon = addon
        }
    }

    /// A cancellable model-load operation matching the decorated promise returned by
    /// the published 0.17 JavaScript client.
    final class ModelLoadRun: @unchecked Sendable {
        /// Stable targeted-cancellation key carried on the wire request.
        public let requestId: String
        /// Download/load progress. This is empty for the non-streaming overload.
        ///
        /// Progress is observational state: the stream retains the newest bounded
        /// window when its consumer falls behind rather than failing the model load.
        public let progress: QVACBufferedStream<ModelLoadProgress>
        /// Resolves to the worker-registered model id.
        public let result: Task<String, Error>

        init(
            requestId: String,
            progress: QVACBufferedStream<ModelLoadProgress>,
            result: Task<String, Error>
        ) {
            self.requestId = requestId
            self.progress = progress
            self.result = result
        }
    }

    /// Load a model with a single-shot RPC (no progress events).
    /// The simplest entry point — good when the model is already cached locally.
    func loadModel(
        modelSrc: String,
        modelType: String,
        modelConfig: JSONValue? = nil,
        modelName: String? = nil,
        seed: Bool = false,
        delegate: JSONValue? = nil,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> ModelLoadRun {
        let requestId = UUID().uuidString
        let req = Self.makeLoadModelRequest(
            modelSrc: modelSrc,
            modelType: modelType,
            modelConfig: modelConfig,
            modelName: modelName,
            requestId: requestId,
            withProgress: false,
            seed: seed,
            delegate: delegate
        )
        return try await loadModel(req, rpcOptions: rpcOptions)
    }

    /// Load a descriptor source and infer its canonical 0.17 model type from
    /// `engine` or `addon` when `modelType` is omitted.
    func loadModel(
        modelSrc: ModelDescriptor,
        modelType: String? = nil,
        modelConfig: JSONValue? = nil,
        seed: Bool = false,
        delegate: JSONValue? = nil,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> ModelLoadRun {
        let resolvedType = try Self.resolveModelType(modelType, descriptor: modelSrc)
        return try await loadModel(
            modelSrc: modelSrc.src,
            modelType: resolvedType,
            modelConfig: modelConfig,
            modelName: modelSrc.name,
            seed: seed,
            delegate: delegate,
            rpcOptions: rpcOptions
        )
    }

    /// Load a model with a streaming progress feed. Caller iterates the `progress` stream
    /// while awaiting the returned `modelId`.
    ///
    /// Returns a request-id-bearing run. Iterate ``ModelLoadRun/progress`` and await
    /// ``ModelLoadRun/result`` for the resolved id. Cancelling `result` tears down the
    /// underlying server stream.
    func loadModelStreaming(
        modelSrc: String,
        modelType: String,
        modelConfig: JSONValue? = nil,
        modelName: String? = nil,
        seed: Bool = false,
        delegate: JSONValue? = nil,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> ModelLoadRun {
        let requestId = UUID().uuidString
        let req = Self.makeLoadModelRequest(
            modelSrc: modelSrc,
            modelType: modelType,
            modelConfig: modelConfig,
            modelName: modelName,
            requestId: requestId,
            withProgress: true,
            seed: seed,
            delegate: delegate
        )
        return try await loadModel(req, rpcOptions: rpcOptions)
    }

    /// Stream a descriptor-based model load with the same 0.17 type inference as
    /// ``loadModel(modelSrc:modelType:modelConfig:seed:delegate:rpcOptions:)``.
    func loadModelStreaming(
        modelSrc: ModelDescriptor,
        modelType: String? = nil,
        modelConfig: JSONValue? = nil,
        seed: Bool = false,
        delegate: JSONValue? = nil,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> ModelLoadRun {
        let resolvedType = try Self.resolveModelType(modelType, descriptor: modelSrc)
        let requestId = UUID().uuidString
        let request = Self.makeLoadModelRequest(
            modelSrc: modelSrc.src,
            modelType: resolvedType,
            modelConfig: modelConfig,
            modelName: modelSrc.name,
            requestId: requestId,
            withProgress: true,
            seed: seed,
            delegate: delegate
        )
        return try await loadModel(request, rpcOptions: rpcOptions)
    }

    /// Execute an exact generated 0.17 load/reload request while retaining the
    /// request-id-bearing rich result. `withProgress == true` selects the streaming
    /// transport declared by the pinned contract.
    func loadModel(
        _ input: LoadModelRequest,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> ModelLoadRun {
        var request = input
        let isReloadConfig = request.modelId != nil && request.modelSrc == nil
        let requestId = request.requestId ?? UUID().uuidString
        request.modelType = QVACModelTypeContract.normalize(request.modelType)
        if isReloadConfig {
            guard let modelId = request.modelId,
                  modelId.range(of: #"^[0-9a-f]{16}$"#, options: .regularExpression) != nil else {
                throw QVACError.invalidArgument(
                    "reloadModelConfig modelId must be exactly 16 lowercase hexadecimal characters"
                )
            }
            guard request.modelType == "whispercpp-transcription" else {
                throw QVACError.invalidArgument(
                    "reloadModelConfig only supports whispercpp-transcription in QVAC SDK 0.17"
                )
            }
            guard case .object = request.modelConfig else {
                throw QVACError.invalidArgument(
                    "reloadModelConfig modelConfig must be an object"
                )
            }
            request.requestId = nil
            request.withProgress = nil
            request.seed = nil
            request.delegate = nil
            request.modelName = nil
        } else {
            guard let modelSrc = request.modelSrc, !modelSrc.isEmpty else {
                throw QVACError.invalidArgument("loadModel modelSrc must not be empty")
            }
            request.modelId = nil
            request.requestId = requestId
            request.modelConfig = request.modelConfig ?? .object([:])
            request.seed = request.seed ?? false
        }

        guard request.withProgress == true else {
            let (progress, progressContinuation) = Self.makeCoalescingProgressStream(
                of: ModelLoadProgress.self,
                name: "loadModel.progress",
                maximumBufferedBytes: maximumBufferedStreamBytes
            )
            progressContinuation.finish()
            let result = Task<String, Error> {
                let response: QVACResponse = try await self.sendTyped(
                    .loadModel(request), rpcOptions: rpcOptions
                )
                guard case .loadModel(let terminal) = response else {
                    throw QVACError.protocolViolation(
                        "expected loadModel response, got \(response.discriminator)"
                    )
                }
                return try Self.extractLoadedModelId(terminal)
            }
            return ModelLoadRun(requestId: requestId, progress: progress, result: result)
        }

        let source: QVACResponseStream<QVACResponse> = try await streamTyped(
            .loadModel(request),
            rpcOptions: rpcOptions
        )

        // We can't have two consumers of one stream, so we'll split the response into
        // (progress events, terminal loadModel event) at the source.
        let maximumBufferedStreamBytes = self.maximumBufferedStreamBytes
        let (progressStream, progressContinuation) = Self.makeCoalescingProgressStream(
            of: ModelLoadProgress.self,
            name: "loadModel.progress",
            maximumBufferedBytes: maximumBufferedStreamBytes
        )
        let modelIdTask = Task<String, Error> {
            do {
                let responses = QVACResponseStreamIteratorBox(source)
                while let response = try await responses.next() {
                    if let terminal = try Self.handleModelLoadResponse(
                        response,
                        progress: progressContinuation,
                        maximumBufferedStreamBytes: maximumBufferedStreamBytes
                    ) {
                        let id = try await Self.resolveResponseStreamTerminal(
                            responses,
                            operation: "loadModel"
                        ) {
                            try terminal.get()
                        }
                        progressContinuation.finish()
                        return id
                    }
                }
                throw QVACError.protocolViolation("loadModel stream ended without resolution")
            } catch {
                let publicError = Self.publicRPCError(error, operation: "loadModel")
                progressContinuation.finish(throwing: publicError)
                throw publicError
            }
        }
        return ModelLoadRun(
            requestId: requestId,
            progress: progressStream,
            result: modelIdTask
        )
    }

    /// Hot-reload the runtime configuration of an already-loaded Whisper model.
    /// QVAC SDK 0.17 supports config reload only for 16-character lowercase-hex
    /// Whisper model identifiers and never sends load-only fields on this request.
    func reloadModelConfig(
        modelId: String,
        modelType: String = "whispercpp-transcription",
        modelConfig: JSONValue,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> ModelLoadRun {
        try await loadModel(
            LoadModelRequest(
                modelType: modelType,
                modelConfig: modelConfig,
                modelId: modelId
            ),
            rpcOptions: rpcOptions
        )
    }

    // MARK: - Unload

    /// Unload a previously-loaded model.
    ///
    /// By default, the 0.17 client keeps the worker connection open after the last
    /// model unloads. Set `autoClose` to close it when the worker reports no active
    /// models or providers, or call ``QVACClient/close()`` explicitly when finished.
    @discardableResult
    func unloadModel(
        modelId: String,
        clearStorage: Bool = false,
        autoClose: Bool = false,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> UnloadModelResponse {
        let req = UnloadModelRequest(modelId: modelId, clearStorage: clearStorage)
        let response: QVACResponse = try await sendTyped(.unloadModel(req), rpcOptions: rpcOptions)
        guard case .unloadModel(let r) = response else {
            throw QVACError.protocolViolation("expected unloadModel response, got \(response.discriminator)")
        }
        if r.success != true {
            throw QVACError.server(.modelUnloadFailed, message: r.error)
        }
        if autoClose,
           r.hasActiveModels == false,
           r.hasActiveProviders == false {
            await close()
        }
        return r
    }

    // MARK: - Internal helpers (not in QVACClient.swift because it would couple it to this file)

    internal static func makeLoadModelRequest(
        modelSrc: String,
        modelType: String,
        modelConfig: JSONValue?,
        modelName: String?,
        requestId: String,
        withProgress: Bool,
        seed: Bool = false,
        delegate: JSONValue? = nil
    ) -> LoadModelRequest {
        var request = LoadModelRequest(modelType: QVACModelTypeContract.normalize(modelType))
        request.modelSrc = modelSrc
        request.modelConfig = modelConfig ?? .object([:])
        request.modelName = modelName
        request.requestId = requestId
        request.seed = seed
        request.delegate = delegate
        if withProgress { request.withProgress = true }
        return request
    }

    private static func resolveModelType(
        _ explicit: String?,
        descriptor: ModelDescriptor
    ) throws -> String {
        if let explicit { return QVACModelTypeContract.normalize(explicit) }
        for candidate in [descriptor.engine, descriptor.addon].compactMap({ $0 }) {
            if let legacy = QVACModelTypeContract.legacyEngineToCanonical[candidate] {
                return legacy == "onnx-tts" ? "tts-ggml" : legacy
            }
            if QVACModelTypeContract.engineToAddon[candidate] != nil {
                return candidate == "onnx-tts" ? "tts-ggml" : candidate
            }
            if let alias = QVACModelTypeContract.aliasToCanonical[candidate] {
                return alias
            }
        }
        throw QVACError.invalidArgument(
            "modelType is required when a model descriptor has no recognized engine or addon"
        )
    }

    private static func handleModelLoadResponse(
        _ response: QVACResponse,
        progress: QVACBufferedStreamSink<ModelLoadProgress>,
        maximumBufferedStreamBytes: Int
    ) throws -> Result<String, Error>? {
        switch response {
        case .modelProgress(let event):
            // Progress is observational and keeps the newest bounded window. Continue
            // draining the worker stream so the authoritative result can resolve even
            // when an observer is temporarily slower than per-network-chunk updates.
            progress.yield(
                contentsOf: [try ModelLoadProgress(event)],
                estimatedBytes: conservativeBufferedJSONBytes(
                    event,
                    elementCount: 1,
                    fallback: maximumBufferedStreamBytes
                )
            )
            return nil
        case .loadModel(let result):
            return Result { try extractLoadedModelId(result) }
        case .error(let error):
            return .failure(retainedWireError(error))
        default:
            try rejectUnexpectedResponse(
                response,
                expected: "loadModel or modelProgress"
            )
        }
    }

    private static func extractLoadedModelId(_ result: LoadModelResponse) throws -> String {
        guard result.success == true else {
            throw QVACError.server(.modelLoadFailed, message: result.error)
        }
        guard let id = result.modelId else {
            throw QVACError.protocolViolation("loadModel: missing modelId")
        }
        return id
    }

    internal static let publicStreamBufferCapacity = 64
    internal static let publicProgressBufferCapacity = 64
}
