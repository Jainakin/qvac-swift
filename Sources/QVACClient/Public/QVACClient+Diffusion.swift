// QVAC-211 — diffusion
//
// Image generation via Stable Diffusion / FLUX. The worker streams two kinds of frames:
//   • `step` events with progress (current step / total steps)
//   • output frames with base64-encoded image bytes (one per `batchCount` image)
//
// We expose three views:
//   • `progress`: AsyncThrowingStream<DiffusionProgressTick>
//   • `outputs`:  Task<[Data], Error>  (the rendered images)
//   • `stats`:    Task<JSONValue?, Error>

import Foundation

public extension QVACClient {

    /// Progress tick during diffusion sampling.
    struct DiffusionProgressTick: Sendable, Equatable {
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

    /// Streaming diffusion result. Iterate `progress` for progress events, await
    /// `outputs` for the rendered images (PNG-encoded `Data`).
    final class DiffusionRun: @unchecked Sendable {
        public let progressStream: AsyncThrowingStream<DiffusionProgressTick, Error>
        public let outputs: Task<[Data], Error>
        public let stats: Task<DiffusionStats?, Error>
        init(progressStream: AsyncThrowingStream<DiffusionProgressTick, Error>, outputs: Task<[Data], Error>, stats: Task<DiffusionStats?, Error>) {
            self.progressStream = progressStream; self.outputs = outputs; self.stats = stats
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
        initImage: Data? = nil,
        strength: Double? = nil,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> DiffusionRun {
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
        req.initImage = initImage?.base64EncodedString()
        req.strength = strength

        let stream: QVACResponseStream<QVACResponse> = try await streamTyped(
            .diffusionStream(req),
            rpcOptions: rpcOptions
        )
        let (progressStream, progressCont) = Self.makeStream(
            of: DiffusionProgressTick.self,
            name: "diffusion.progressStream"
        )
        let statsBox = ResultBox<DiffusionStats?>()

        let outputsTask = Task<[Data], Error> {
            var imgs: [Data] = []
            var receivedTerminalFrame = false
            do {
                for try await response in stream {
                    guard case .diffusionStream(let r) = response else {
                        try Self.rejectUnexpectedResponse(response, expected: "diffusionStream")
                    }
                    if let step = r.step,
                       let totalSteps = r.totalSteps,
                       let elapsedMs = r.elapsedMs {
                        progressCont.yield(DiffusionProgressTick(
                            step: step,
                            totalSteps: totalSteps,
                            elapsedMs: elapsedMs
                        ))
                    }
                    if let encoded = r.data {
                        guard let bytes = Data(base64Encoded: encoded) else {
                            throw QVACError.protocolViolation(
                                "diffusionStream returned invalid base64 image data"
                            )
                        }
                        imgs.append(bytes)
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
                    if r.done == true {
                        receivedTerminalFrame = true
                        break
                    }
                }
                guard receivedTerminalFrame else {
                    throw QVACError.client(
                        .streamEndedWithoutResponse,
                        message: "diffusionStream ended without a terminal done frame"
                    )
                }
                progressCont.finish()
                return imgs
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
}
