import Foundation

// Public wrappers for the 0.17 contract methods that previously existed only as
// generated enum cases. Rich inference/media APIs live in their operation-specific
// files; these methods intentionally expose JSONValue where the upstream contract is
// open-ended or backend-specific.

public extension QVACClient {
    /// Delete cached model data or a completion KV cache.
    ///
    /// The request must select a target using `all`, `modelId`, or `kvCacheKey` as
    /// required by the worker. Invalid combinations are rejected by the worker with
    /// `INVALID_DELETE_CACHE_PARAMS`.
    @discardableResult
    func deleteCache(
        _ request: DeleteCacheRequest,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> DeleteCacheResponse {
        let response: QVACResponse = try await sendTyped(
            .deleteCache(request), rpcOptions: rpcOptions
        )
        guard case .deleteCache(let result) = response else {
            throw QVACError.protocolViolation(
                "expected deleteCache response, got \(response.discriminator)"
            )
        }
        guard result.success else {
            throw QVACError.server(.deleteCacheFailed, message: result.error)
        }
        return result
    }

    /// Execute a non-progress finetuning operation.
    ///
    /// Use ``finetuneStreaming(_:rpcOptions:)`` when `withProgress` is desired.
    func finetune(
        _ request: FinetuneRequest,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> FinetuneResponse {
        guard request.withProgress != true else {
            throw QVACError.invalidArgument(
                "finetune(withProgress: true) must use finetuneStreaming"
            )
        }
        let response: QVACResponse = try await sendTyped(
            .finetune(request), rpcOptions: rpcOptions
        )
        guard case .finetune(let result) = response else {
            throw QVACError.protocolViolation(
                "expected finetune response, got \(response.discriminator)"
            )
        }
        return try Self.validateFinetuneResponse(result)
    }

    /// Progress and terminal result for a finetuning start/resume operation.
    final class FinetuneRun: @unchecked Sendable {
        public let requestId: String
        /// Lossless per-step metrics retained as byte-bounded worker-frame batches.
        public let progress: QVACBufferedStream<FinetuneProgressResponse>
        public let result: Task<FinetuneResponse, Error>

        init(
            requestId: String,
            progress: QVACBufferedStream<FinetuneProgressResponse>,
            result: Task<FinetuneResponse, Error>
        ) {
            self.requestId = requestId
            self.progress = progress
            self.result = result
        }
    }

    /// Start or resume finetuning and consume the conditional progress response stream.
    /// The result task fails if the stream closes without a terminal `finetune` frame.
    func finetuneStreaming(
        _ input: FinetuneRequest,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> FinetuneRun {
        var request = input
        request.withProgress = true
        let requestId = request.requestId ?? UUID().uuidString
        request.requestId = requestId

        // The 0.17 contract only enables this conditional progress transport for
        // start, resume, or an omitted operation. Route through the generated
        // contract guard so cancel/status-style unary operations fail locally
        // instead of opening a stream that can never receive their unary reply.
        let source = try await wireFinetuneProgress(request, rpcOptions: rpcOptions)
        let maximumBufferedStreamBytes = self.maximumBufferedStreamBytes
        let (progress, continuation) = Self.makeBufferedStream(
            of: FinetuneProgressResponse.self,
            name: "finetune.progress",
            maximumBufferedBytes: maximumBufferedStreamBytes
        )
        let result = Task<FinetuneResponse, Error> {
            do {
                let responses = QVACResponseStreamIteratorBox(source)
                while let response = try await responses.next() {
                    switch response {
                    case .finetuneProgress(let event):
                        let validated = try Self.validateFinetuneProgress(event)
                        continuation.yield(
                            contentsOf: [validated],
                            estimatedBytes: Self.conservativeBufferedJSONBytes(
                                event,
                                elementCount: 1,
                                fallback: maximumBufferedStreamBytes
                            )
                        )
                    case .finetune(let terminal):
                        let validated = try await Self.resolveResponseStreamTerminal(
                            responses,
                            operation: "finetune"
                        ) {
                            try Self.validateFinetuneResponse(terminal)
                        }
                        continuation.finish()
                        return validated
                    case .error(let error):
                        return try await Self.resolveResponseStreamTerminal(
                            responses,
                            operation: "finetune"
                        ) { () throws -> FinetuneResponse in
                            throw QVACError.fromWire(
                                code: try Self.checkedWireErrorCode(error.code),
                                message: error.message
                            )
                        }
                    default:
                        try Self.rejectUnexpectedResponse(
                            response,
                            expected: "finetune or finetune:progress"
                        )
                    }
                }
                let error = QVACError.client(
                    .streamEndedWithoutResponse,
                    message: "finetune stream ended without a terminal response"
                )
                continuation.finish(throwing: error)
                throw error
            } catch {
                continuation.finish(throwing: error)
                throw error
            }
        }
        return FinetuneRun(requestId: requestId, progress: progress, result: result)
    }

    private static func validateFinetuneResponse(
        _ response: FinetuneResponse
    ) throws -> FinetuneResponse {
        switch response.status {
        case "IDLE", "RUNNING", "PAUSED", "CANCELLED", "COMPLETED":
            break
        default:
            throw QVACError.protocolViolation(
                "finetune.status is not a QVAC 0.17 value: \(response.status)"
            )
        }
        if let stats = response.stats {
            try validateFinetuneStats(stats)
        }
        return response
    }

    private static func validateFinetuneProgress(
        _ response: FinetuneProgressResponse
    ) throws -> FinetuneProgressResponse {
        let counters: [(String, Int)] = [
            ("global_steps", response.globalSteps),
            ("current_epoch", response.currentEpoch),
            ("current_batch", response.currentBatch),
            ("total_batches", response.totalBatches),
        ]
        for (field, value) in counters where value < 0 {
            throw QVACError.protocolViolation(
                "finetune:progress.\(field) must be nonnegative"
            )
        }
        let durations: [(String, Double)] = [
            ("elapsed_ms", response.elapsedMs),
            ("eta_ms", response.etaMs),
        ]
        for (field, value) in durations where !value.isFinite || value < 0 {
            throw QVACError.protocolViolation(
                "finetune:progress.\(field) must be a finite nonnegative number"
            )
        }
        try validateFinetuneMetric(response.loss, field: "finetune:progress.loss")
        try validateFinetuneMetric(
            response.lossUncertainty,
            field: "finetune:progress.loss_uncertainty"
        )
        try validateFinetuneMetric(response.accuracy, field: "finetune:progress.accuracy")
        try validateFinetuneMetric(
            response.accuracyUncertainty,
            field: "finetune:progress.accuracy_uncertainty"
        )
        return response
    }

    private static func validateFinetuneStats(_ value: JSONValue) throws {
        guard case .object(let stats) = value else {
            throw QVACError.protocolViolation("finetune.stats must be an object")
        }
        let required: Set<String> = ["global_steps", "epochs_completed"]
        let numeric: Set<String> = [
            "train_loss", "val_loss", "train_accuracy", "val_accuracy", "learning_rate",
        ]
        let nullableNumeric: Set<String> = [
            "train_loss_uncertainty", "val_loss_uncertainty",
            "train_accuracy_uncertainty", "val_accuracy_uncertainty",
        ]
        let allowed = required.union(numeric).union(nullableNumeric)
        guard required.isSubset(of: Set(stats.keys)),
              Set(stats.keys).isSubset(of: allowed) else {
            throw QVACError.protocolViolation(
                "finetune.stats must contain global_steps and epochs_completed "
                    + "and no fields outside the QVAC 0.17 contract"
            )
        }
        for field in required {
            guard case .number(let raw) = stats[field] else {
                throw QVACError.protocolViolation("finetune.stats.\(field) must be an integer")
            }
            let integer = try checkedWireInteger(raw, field: "finetune.stats.\(field)")
            guard integer >= 0 else {
                throw QVACError.protocolViolation(
                    "finetune.stats.\(field) must be nonnegative"
                )
            }
        }
        for field in numeric where stats[field] != nil {
            guard case .number(let number) = stats[field], number.isFinite else {
                throw QVACError.protocolViolation(
                    "finetune.stats.\(field) must be a finite number"
                )
            }
        }
        for field in nullableNumeric {
            guard let metric = stats[field] else { continue }
            try validateFinetuneMetric(metric, field: "finetune.stats.\(field)")
        }
    }

    private static func validateFinetuneMetric(
        _ value: JSONValue,
        field: String
    ) throws {
        switch value {
        case .null:
            return
        case .number(let number) where number.isFinite:
            return
        default:
            throw QVACError.protocolViolation("\(field) must be a finite number or null")
        }
    }

    /// Return metadata for a model that is currently loaded in the worker.
    func getLoadedModelInfo(
        modelId: String,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> JSONValue {
        let response: QVACResponse = try await sendTyped(
            .getLoadedModelInfo(GetLoadedModelInfoRequest(modelId: modelId)),
            rpcOptions: rpcOptions
        )
        guard case .getLoadedModelInfo(let result) = response else {
            throw QVACError.protocolViolation(
                "expected getLoadedModelInfo response, got \(response.discriminator)"
            )
        }
        return result.info
    }

    /// Return static model metadata by registered model name.
    func getModelInfo(
        name: String,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> JSONValue {
        let response: QVACResponse = try await sendTyped(
            .getModelInfo(GetModelInfoRequest(name: name)), rpcOptions: rpcOptions
        )
        guard case .getModelInfo(let result) = response else {
            throw QVACError.protocolViolation(
                "expected getModelInfo response, got \(response.discriminator)"
            )
        }
        return result.modelInfo
    }

    /// Describe system-resource capabilities and optionally take a live sample.
    func getSystemResources(
        sample: Bool? = nil,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> GetSystemResourcesResponse {
        let response: QVACResponse = try await sendTyped(
            .getSystemResources(GetSystemResourcesRequest(sample: sample)),
            rpcOptions: rpcOptions
        )
        guard case .getSystemResources(let result) = response else {
            throw QVACError.protocolViolation(
                "expected getSystemResources response, got \(response.discriminator)"
            )
        }
        return result
    }

    /// Subscribe to a worker-side logging channel. This is intentionally an open-ended
    /// stream; cancelling iteration closes the underlying RPC stream.
    func loggingStream(
        id: String,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> QVACResponseStream<LoggingStreamResponse> {
        let source: QVACResponseStream<QVACResponse> = try await streamTyped(
            .loggingStream(LoggingStreamRequest(id: id)), rpcOptions: rpcOptions
        )
        return Self.pullMap(source, operation: "loggingStream") { response in
            switch response {
            case .loggingStream(let event):
                return .emit(event)
            case .error(let error):
                return .failThenDrain(Self.retainedWireError(error))
            default:
                try Self.rejectUnexpectedResponse(response, expected: "loggingStream")
            }
        }
    }

    /// List every entry in the distributed model registry.
    func modelRegistryList(
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> [JSONValue] {
        let response: QVACResponse = try await sendTyped(
            .modelRegistryList(ModelRegistryListRequest()), rpcOptions: rpcOptions
        )
        guard case .modelRegistryList(let result) = response else {
            throw QVACError.protocolViolation(
                "expected modelRegistryList response, got \(response.discriminator)"
            )
        }
        guard result.success, let models = result.models else {
            throw QVACError.server(.qvacModelRegistryQueryFailed, message: result.error)
        }
        return models
    }

    /// Search the distributed model registry using the exact 0.17 wire filters.
    func modelRegistrySearch(
        filter: String? = nil,
        engine: String? = nil,
        quantization: String? = nil,
        addon: String? = nil,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> [JSONValue] {
        let request = ModelRegistrySearchRequest(
            addon: addon,
            engine: engine,
            filter: filter,
            quantization: quantization
        )
        let response: QVACResponse = try await sendTyped(
            .modelRegistrySearch(request), rpcOptions: rpcOptions
        )
        guard case .modelRegistrySearch(let result) = response else {
            throw QVACError.protocolViolation(
                "expected modelRegistrySearch response, got \(response.discriminator)"
            )
        }
        guard result.success, let models = result.models else {
            throw QVACError.server(.qvacModelRegistryQueryFailed, message: result.error)
        }
        return models
    }

    /// Fetch one distributed-registry entry by path and source.
    func modelRegistryGetModel(
        registryPath: String,
        registrySource: String,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> JSONValue {
        let request = ModelRegistryGetModelRequest(
            registryPath: registryPath,
            registrySource: registrySource
        )
        let response: QVACResponse = try await sendTyped(
            .modelRegistryGetModel(request), rpcOptions: rpcOptions
        )
        guard case .modelRegistryGetModel(let result) = response else {
            throw QVACError.protocolViolation(
                "expected modelRegistryGetModel response, got \(response.discriminator)"
            )
        }
        guard result.success, let model = result.model else {
            throw QVACError.server(.qvacModelRegistryQueryFailed, message: result.error)
        }
        return model
    }

    /// Start the QVAC peer provider. Repeated calls are idempotent upstream.
    func startQVACProvider(
        firewall: JSONValue? = nil,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> ProvideResponse {
        let response: QVACResponse = try await sendTyped(
            .provide(ProvideRequest(firewall: firewall)), rpcOptions: rpcOptions
        )
        guard case .provide(let result) = response else {
            throw QVACError.protocolViolation(
                "expected provide response, got \(response.discriminator)"
            )
        }
        guard result.success else {
            throw QVACError.client(.providerStartFailed, message: result.error)
        }
        return result
    }

    /// Stop the active QVAC peer provider.
    @discardableResult
    func stopQVACProvider(
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> StopProvideResponse {
        let response: QVACResponse = try await sendTyped(
            .stopProvide(StopProvideRequest()), rpcOptions: rpcOptions
        )
        guard case .stopProvide(let result) = response else {
            throw QVACError.protocolViolation(
                "expected stopProvide response, got \(response.discriminator)"
            )
        }
        guard result.success else {
            throw QVACError.client(.providerStopFailed, message: result.error)
        }
        return result
    }

    /// Suspend network-backed runtime resources and engage the lifecycle gate.
    func suspend(rpcOptions: QVACRPCOptions = .init()) async throws {
        let response: QVACResponse = try await sendTyped(
            .suspend(SuspendRequest()), rpcOptions: rpcOptions
        )
        guard case .suspend = response else {
            throw QVACError.protocolViolation(
                "expected suspend response, got \(response.discriminator)"
            )
        }
    }

    /// Resume suspended runtime resources and release the lifecycle gate.
    func resume(rpcOptions: QVACRPCOptions = .init()) async throws {
        let response: QVACResponse = try await sendTyped(
            .resume(ResumeRequest()), rpcOptions: rpcOptions
        )
        guard case .resume = response else {
            throw QVACError.protocolViolation(
                "expected resume response, got \(response.discriminator)"
            )
        }
    }

    /// Return `active`, `suspending`, `suspended`, or `resuming`.
    func state(rpcOptions: QVACRPCOptions = .init()) async throws -> String {
        let response: QVACResponse = try await sendTyped(
            .state(StateRequest()), rpcOptions: rpcOptions
        )
        guard case .state(let result) = response else {
            throw QVACError.protocolViolation(
                "expected state response, got \(response.discriminator)"
            )
        }
        return result.state
    }
}
