// QVAC-211 — diffusion
//
// Image generation via Stable Diffusion / FLUX. The worker streams two kinds of frames:
//   • `step` events with progress (current step / total steps)
//   • output frames with base64-encoded image bytes (one per `batchCount` image)
//
// We expose three views:
//   • `progressStream`: QVACBufferedStream<DiffusionProgressTick>
//   • `outputs`:  Task<[Data], Error>  (the rendered images)
//   • `stats`:    Task<DiffusionStats?, Error>

import Foundation

public extension QVACClient {

    /// Progress tick during diffusion sampling.
    struct DiffusionProgressTick: Codable, Sendable, Equatable {
        public let step: Double
        public let totalSteps: Double
        public let elapsedMs: Double
    }

    struct DiffusionStats: Codable, Sendable, Equatable {
        public let modelLoadMs: Double?
        public let generationMs: Double?
        public let conditionerMs: Double?
        public let denoiseMs: Double?
        public let vaeMs: Double?
        public let postProcessMs: Double?
        public let stepsPerSecond: Double?
        public let totalGenerationMs: Double?
        public let totalWallMs: Double?
        public let totalSteps: Double?
        public let totalGenerations: Double?
        public let totalImages: Double?
        public let totalPixels: Double?
        public let width: Double?
        public let height: Double?
        public let seed: Double?
    }

    /// Streaming diffusion result. Iterate `progressStream` for progress events, await
    /// `outputs` for the rendered images (PNG-encoded `Data`).
    final class DiffusionRun: @unchecked Sendable {
        /// Observational snapshots retaining the newest count- and byte-bounded
        /// window if the consumer lags. Coalescing never changes `outputs` or `stats`.
        public let progressStream: QVACBufferedStream<DiffusionProgressTick>
        public let outputs: Task<[Data], Error>
        public let stats: Task<DiffusionStats?, Error>

        init(
            progressStream: QVACBufferedStream<DiffusionProgressTick>,
            outputs: Task<[Data], Error>,
            stats: Task<DiffusionStats?, Error>
        ) {
            self.progressStream = progressStream
            self.outputs = outputs
            self.stats = stats
        }
    }

    /// Run a diffusion generation. Most parameters mirror sd.cpp / FLUX.cpp's CLI flags.
    func diffusion(
        modelId: String,
        prompt: String,
        negativePrompt: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        steps: Int? = nil,
        cfgScale: Double? = nil,
        guidance: Double? = nil,
        samplingMethod: String? = nil,
        scheduler: String? = nil,
        seed: Int? = nil,
        batchCount: Int? = nil,
        imgCfgScale: Double? = nil,
        vaeTiling: Bool? = nil,
        cachePreset: String? = nil,
        initImage: Data? = nil,
        initImages: [Data]? = nil,
        increaseRefIndex: Bool? = nil,
        autoResizeRefImage: Bool? = nil,
        lora: String? = nil,
        strength: Double? = nil,
        upscale: JSONValue? = nil,
        configure: @Sendable (inout DiffusionStreamRequest) -> Void = { _ in },
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> DiffusionRun {
        guard initImage == nil || initImages == nil else {
            throw QVACError.invalidArgument(
                "diffusion initImage and initImages are mutually exclusive"
            )
        }
        if let initImages, initImages.isEmpty {
            throw QVACError.invalidArgument("diffusion initImages must not be empty")
        }
        var req = DiffusionStreamRequest(modelId: modelId, prompt: prompt)
        req.negativePrompt = negativePrompt
        req.width = width
        req.height = height
        req.steps = steps
        req.cfgScale = cfgScale
        req.guidance = guidance
        req.samplingMethod = samplingMethod
        req.scheduler = scheduler
        req.seed = seed
        req.batchCount = batchCount
        req.imgCfgScale = imgCfgScale
        req.vaeTiling = vaeTiling
        req.cachePreset = cachePreset
        req.initImage = initImage?.base64EncodedString()
        req.initImages = initImages?.map { $0.base64EncodedString() }
        req.increaseRefIndex = increaseRefIndex
        req.autoResizeRefImage = autoResizeRefImage
        req.lora = lora
        req.strength = strength
        req.upscale = upscale
        configure(&req)
        guard req.initImage == nil || req.initImages == nil else {
            throw QVACError.invalidArgument(
                "diffusion initImage and initImages are mutually exclusive"
            )
        }
        return try await diffusion(req, rpcOptions: rpcOptions)
    }

    /// Generate images from an exact 0.17 request while retaining the rich progress,
    /// outputs, and stats views. This overload exposes every generated request field.
    func diffusion(
        _ req: DiffusionStreamRequest,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> DiffusionRun {
        let stream: QVACResponseStream<QVACResponse> = try await streamTyped(
            .diffusionStream(req),
            rpcOptions: rpcOptions
        )
        let maximumBufferedStreamBytes = self.maximumBufferedStreamBytes
        let (progressStream, progressCont) = Self.makeCoalescingProgressStream(
            of: DiffusionProgressTick.self,
            name: "diffusion.progressStream",
            maximumBufferedBytes: maximumBufferedStreamBytes
        )
        let statsBox = ResultBox<DiffusionStats?>()

        let outputsTask = Task<[Data], Error> {
            var imgs: [Data] = []
            do {
                let responses = QVACResponseStreamIteratorBox(stream)
                while let response = try await responses.next() {
                    if case .error(let error) = response {
                        return try await Self.resolveResponseStreamTerminal(
                            responses,
                            operation: "diffusionStream"
                        ) { () throws -> [Data] in
                            throw QVACError.fromWire(
                                code: try Self.checkedWireErrorCode(error.code),
                                message: error.message
                            )
                        }
                    }
                    guard case .diffusionStream(let r) = response else {
                        try Self.rejectUnexpectedResponse(response, expected: "diffusionStream")
                    }
                    if r.done == true {
                        let terminal = try await Self.resolveResponseStreamTerminal(
                            responses,
                            operation: "diffusionStream"
                        ) { () throws -> (
                            outputs: [Data],
                            progress: DiffusionProgressTick?,
                            stats: DiffusionStats?
                        ) in
                            var terminalOutputs = imgs
                            if let output = try Self.decodeDiffusionOutput(r.data) {
                                terminalOutputs.append(output)
                            }
                            return (
                                terminalOutputs,
                                Self.decodeDiffusionProgress(r),
                                try r.stats.map {
                                    try Self.decodeInferenceStats(
                                        $0,
                                        as: DiffusionStats.self,
                                        operation: "diffusion"
                                    )
                                }
                            )
                        }
                        if let tick = terminal.progress {
                            progressCont.yield(
                                contentsOf: [tick],
                                estimatedBytes: Self.conservativeBufferedJSONBytes(
                                    tick,
                                    elementCount: 1,
                                    fallback: maximumBufferedStreamBytes
                                )
                            )
                        }
                        statsBox.set(terminal.stats)
                        progressCont.finish()
                        return terminal.outputs
                    }
                    if let tick = Self.decodeDiffusionProgress(r) {
                        progressCont.yield(
                            contentsOf: [tick],
                            estimatedBytes: Self.conservativeBufferedJSONBytes(
                                tick,
                                elementCount: 1,
                                fallback: maximumBufferedStreamBytes
                            )
                        )
                    }
                    if let output = try Self.decodeDiffusionOutput(r.data) {
                        imgs.append(output)
                    }
                    if let wireStats = r.stats {
                        do {
                            statsBox.set(try Self.decodeFromJSONValue(
                                wireStats,
                                as: DiffusionStats.self
                            ))
                        } catch {
                            throw QVACError.protocolViolation(
                                "diffusion returned malformed stats: \(error)"
                            )
                        }
                    }
                }
                throw QVACError.client(
                    .streamEndedWithoutResponse,
                    message: "diffusionStream ended without a terminal done frame"
                )
            } catch {
                progressCont.finish(throwing: error)
                throw error
            }
        }
        let statsTask = Task<DiffusionStats?, Error> {
            _ = try await outputsTask.value
            return statsBox.get() ?? nil
        }
        return DiffusionRun(
            progressStream: progressStream,
            outputs: outputsTask,
            stats: statsTask
        )
    }

    private static func decodeDiffusionProgress(
        _ frame: DiffusionStreamResponse
    ) -> DiffusionProgressTick? {
        guard let step = frame.step,
              let totalSteps = frame.totalSteps,
              let elapsedMs = frame.elapsedMs else { return nil }
        return DiffusionProgressTick(
            step: step,
            totalSteps: totalSteps,
            elapsedMs: elapsedMs
        )
    }

    private static func decodeDiffusionOutput(_ encoded: String?) throws -> Data? {
        guard let encoded else { return nil }
        guard !encoded.isEmpty else { return nil }
        guard let decoded = Data(base64Encoded: encoded), !decoded.isEmpty else {
            throw QVACError.protocolViolation(
                "diffusionStream returned empty or invalid base64 image data"
            )
        }
        return decoded
    }
}
