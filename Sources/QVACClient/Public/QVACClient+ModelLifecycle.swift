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

    /// Outcome of a streaming `loadModel(_:progress:)` call.
    struct ModelLoadOutcome: Sendable {
        /// The id the worker registered for this model. Use it for subsequent
        /// `completion`, `embed`, `unloadModel`, etc.
        public let modelId: String
    }

    /// Load a model with a single-shot RPC (no progress events).
    /// The simplest entry point — good when the model is already cached locally.
    func loadModel(
        modelSrc: String,
        modelType: String,
        modelConfig: JSONValue? = nil,
        modelName: String? = nil
    ) async throws -> String {
        var req = LoadModelRequest(modelType: modelType)
        req.modelSrc = .string(modelSrc)
        req.modelConfig = modelConfig
        req.modelName = modelName
        let response: QVACResponse = try await sendTyped(.loadModel(req))
        guard case .loadModel(let r) = response else {
            throw QVACError.protocolViolation("expected loadModel response, got \(response.discriminator)")
        }
        if r.success != true {
            throw QVACError.server(.modelLoadFailed, message: r.error)
        }
        guard let id = r.modelId else {
            throw QVACError.protocolViolation("loadModel succeeded but returned no modelId")
        }
        return id
    }

    /// Load a model with a streaming progress feed. Caller iterates the `progress` stream
    /// while awaiting the returned `modelId`.
    ///
    /// Returns a pair: `(progress: AsyncThrowingStream<ModelLoadProgress, Error>,
    /// modelId: Task<String, Error>)`. Iterate the progress stream and then `await modelId`
    /// for the resolved id. Both terminate together.
    func loadModelStreaming(
        modelSrc: String,
        modelType: String,
        modelConfig: JSONValue? = nil,
        modelName: String? = nil
    ) async throws -> (progress: AsyncThrowingStream<ModelLoadProgress, Error>, modelId: Task<String, Error>) {
        var req = LoadModelRequest(modelType: modelType)
        req.modelSrc = .string(modelSrc)
        req.modelConfig = modelConfig
        req.modelName = modelName
        req.withProgress = .bool(true)
        let payload = try JSONEncoder.qvac.encode(QVACRequest.loadModel(req))
        let cmd = nextCommand()
        let rawStream = try await sendStreamRaw(payload: payload, command: cmd)

        // We can't have two consumers of one stream, so we'll split the response into
        // (progress events, terminal loadModel event) at the source.
        let (progressStream, progressContinuation) = Self.makeStream(of: ModelLoadProgress.self)
        let modelIdTask = Task<String, Error> {
            do {
                var buffer = Data()
                for try await chunk in rawStream {
                    buffer.append(chunk)
                    while let nl = buffer.firstIndex(of: 0x0A) {
                        let lineData = buffer[buffer.startIndex..<nl]
                        buffer.removeSubrange(buffer.startIndex...nl)
                        if lineData.isEmpty { continue }
                        let response = try Self.decodeOrThrowStatic(QVACResponse.self, from: Data(lineData))
                        switch response {
                        case .modelProgress(let p):
                            progressContinuation.yield(ModelLoadProgress(p))
                        case .loadModel(let r):
                            progressContinuation.finish()
                            if r.success != true {
                                throw QVACError.server(.modelLoadFailed, message: r.error)
                            }
                            guard let id = r.modelId else {
                                throw QVACError.protocolViolation("loadModel: missing modelId")
                            }
                            return id
                        case .error:
                            throw QVACError.protocolViolation("error frame in loadModel stream")
                        default:
                            // Unknown response types are forward-compatible — skip.
                            continue
                        }
                    }
                }
                progressContinuation.finish()
                throw QVACError.protocolViolation("loadModel stream ended without resolution")
            } catch {
                progressContinuation.finish(throwing: error)
                throw error
            }
        }
        return (progressStream, modelIdTask)
    }

    // MARK: - Unload

    /// Unload a previously-loaded model.
    /// Mirrors JS behavior: when the worker reports `hasActiveModels == false && hasActiveProviders == false`
    /// after this call, the client connection is auto-closed (Phase-1 RPC layer + transport torn down).
    @discardableResult
    func unloadModel(modelId: String, clearStorage: Bool = false) async throws -> UnloadModelResponse {
        let req = UnloadModelRequest(modelId: modelId, clearStorage: clearStorage)
        let response: QVACResponse = try await sendTyped(.unloadModel(req))
        guard case .unloadModel(let r) = response else {
            throw QVACError.protocolViolation("expected unloadModel response, got \(response.discriminator)")
        }
        if r.success != true {
            throw QVACError.server(.modelUnloadFailed, message: r.error)
        }
        if r.hasActiveModels == false && r.hasActiveProviders == false {
            await close()
        }
        return r
    }

    // MARK: - Internal helpers (not in QVACClient.swift because it would couple it to this file)

    /// Like `sendTyped` but for raw byte streams (used when we need pre-injected request fields
    /// that don't survive `QVACRequest` round-trip — e.g. `withProgress` on loadModel).
    internal func sendStreamRaw(payload: Data, command: UInt64) async throws -> AsyncThrowingStream<Data, Error> {
        let raw = try await rpc.stream(command: command, data: payload)
        return raw.chunks
    }

    internal static func makeStream<T>(of: T.Type) -> (AsyncThrowingStream<T, Error>, AsyncThrowingStream<T, Error>.Continuation) {
        var continuation: AsyncThrowingStream<T, Error>.Continuation!
        let stream = AsyncThrowingStream<T, Error> { c in continuation = c }
        return (stream, continuation)
    }
}
