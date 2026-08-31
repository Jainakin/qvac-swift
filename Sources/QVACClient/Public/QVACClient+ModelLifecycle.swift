// QVAC-202 / QVAC-203 — loadModel + unloadModel

import Foundation

public extension QVACClient {

    // MARK: - Load

    /// Progress event emitted during a streaming model load.
    /// Mirrors the JS client's `modelProgress` event.
    struct ModelLoadProgress: Sendable, Equatable {
        public var downloadKey: String
        public var downloaded: Double
        public var total: Double
        public var percentage: Double
        init(_ wire: ModelProgressResponse) {
            self.downloadKey = wire.downloadKey
            self.downloaded = wire.downloaded
            self.total = wire.total
            self.percentage = wire.percentage
        }
    }

    /// A cancellable model-load operation matching the decorated promise returned by
    /// the published 0.17 JavaScript client.
    final class ModelLoadRun: @unchecked Sendable {
        /// Stable targeted-cancellation key carried on the wire request.
        public let requestId: String
        /// Download/load progress. This is empty for the non-streaming overload.
        public let progress: AsyncThrowingStream<ModelLoadProgress, Error>
        /// Resolves to the worker-registered model id.
        public let result: Task<String, Error>

        init(
            requestId: String,
            progress: AsyncThrowingStream<ModelLoadProgress, Error>,
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
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> ModelLoadRun {
        let requestId = UUID().uuidString
        let req = Self.makeLoadModelRequest(
            modelSrc: modelSrc,
            modelType: modelType,
            modelConfig: modelConfig,
            modelName: modelName,
            requestId: requestId,
            withProgress: false
        )
        let (progress, progressContinuation) = Self.makeStream(of: ModelLoadProgress.self)
        progressContinuation.finish()
        let result = Task<String, Error> {
            let response: QVACResponse = try await self.sendTyped(
                .loadModel(req), rpcOptions: rpcOptions
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
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> ModelLoadRun {
        let requestId = UUID().uuidString
        let req = Self.makeLoadModelRequest(
            modelSrc: modelSrc,
            modelType: modelType,
            modelConfig: modelConfig,
            modelName: modelName,
            requestId: requestId,
            withProgress: true
        )
        let source: QVACResponseStream<QVACResponse> = try await streamTyped(
            .loadModel(req),
            rpcOptions: rpcOptions
        )

        // We can't have two consumers of one stream, so we'll split the response into
        // (progress events, terminal loadModel event) at the source.
        let (progressStream, progressContinuation) = Self.makeStream(of: ModelLoadProgress.self)
        let modelIdTask = Task<String, Error> {
            do {
                for try await response in source {
                    if let id = try Self.handleModelLoadResponse(response, progress: progressContinuation) {
                        return id
                    }
                }
                progressContinuation.finish()
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

    // MARK: - Unload

    /// Unload a previously-loaded model.
    ///
    /// The 0.17 client keeps the worker connection open after the last model unloads.
    /// Call ``QVACClient/close()`` explicitly when the client is no longer needed.
    @discardableResult
    func unloadModel(
        modelId: String,
        clearStorage: Bool = false,
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
        return r
    }

    // MARK: - Internal helpers (not in QVACClient.swift because it would couple it to this file)

    internal static func makeLoadModelRequest(
        modelSrc: String,
        modelType: String,
        modelConfig: JSONValue?,
        modelName: String?,
        requestId: String,
        withProgress: Bool
    ) -> LoadModelRequest {
        var request = LoadModelRequest(modelType: QVACModelTypeContract.normalize(modelType))
        request.modelSrc = modelSrc
        request.modelConfig = modelConfig ?? .object([:])
        request.modelName = modelName
        request.requestId = requestId
        if withProgress { request.withProgress = true }
        return request
    }

    private static func handleModelLoadResponse(
        _ response: QVACResponse,
        progress: QVACStreamSink<ModelLoadProgress>
    ) throws -> String? {
        switch response {
        case .modelProgress(let event):
            // The bounded progress view fails explicitly when it falls behind, but
            // progress is observational: continue draining the worker stream so the
            // independently awaited terminal result can still resolve.
            progress.yield(ModelLoadProgress(event))
            return nil
        case .loadModel(let result):
            progress.finish()
            return try extractLoadedModelId(result)
        case .error(let error):
            throw QVACError.fromWire(
                code: try checkedWireErrorCode(error.code),
                message: error.message
            )
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

    /// Build a bounded public event/progress view. If a consumer falls more than 64
    /// elements behind, its view terminates with ``QVACStreamBufferOverflow`` rather
    /// than retaining the entire operation or silently dropping data.
    internal static func makeStream<T: Sendable>(
        of: T.Type,
        name: String? = nil
    ) -> (AsyncThrowingStream<T, Error>, QVACStreamSink<T>) {
        let capacity = publicStreamBufferCapacity
        let terminationRelay = QVACStreamTerminationRelay()
        var continuation: AsyncThrowingStream<T, Error>.Continuation!
        let stream = AsyncThrowingStream<T, Error>(
            bufferingPolicy: .bufferingOldest(capacity)
        ) {
            continuation = $0
            $0.onTermination = { _ in terminationRelay.signal() }
        }
        return (
            stream,
            QVACStreamSink(
                continuation: continuation,
                terminationRelay: terminationRelay,
                streamName: name ?? String(describing: T.self),
                capacity: capacity
            )
        )
    }
}
