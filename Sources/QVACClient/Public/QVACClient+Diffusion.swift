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
        public let step: Int
        public let totalSteps: Int?
        public let elapsedMs: Double?
        public let outputIndex: Int?
    }

    /// Streaming diffusion result. Iterate `progress` for progress events, await
    /// `outputs` for the rendered images (PNG-encoded `Data`).
    final class DiffusionRun: @unchecked Sendable {
        public let progress: AsyncThrowingStream<DiffusionProgressTick, Error>
        public let outputs: Task<[Data], Error>
        public let stats: Task<JSONValue?, Error>
        init(progress: AsyncThrowingStream<DiffusionProgressTick, Error>, outputs: Task<[Data], Error>, stats: Task<JSONValue?, Error>) {
            self.progress = progress; self.outputs = outputs; self.stats = stats
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
        strength: Double? = nil
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

        let stream: AsyncThrowingStream<QVACResponse, Error> = try await streamTyped(.diffusionStream(req))
        let (progress, progressCont) = Self.makeStream(of: DiffusionProgressTick.self)
        let statsBox = ResultBox<JSONValue?>()

        let outputsTask = Task<[Data], Error> {
            var imgs: [Data] = []
            do {
                for try await response in stream {
                    guard case .diffusionStream(let r) = response else {
                        if case .error(let e) = response {
                            throw QVACError.fromWire(code: Int(e.code ?? 0), message: e.message)
                        }
                        continue
                    }
                    if let stepNum = r.step {
                        progressCont.yield(DiffusionProgressTick(
                            step: Int(stepNum),
                            totalSteps: r.totalSteps.map { Int($0) },
                            elapsedMs: r.elapsedMs,
                            outputIndex: r.outputIndex.map { Int($0) }
                        ))
                    }
                    if let b64 = r.data, let bytes = Data(base64Encoded: b64) {
                        imgs.append(bytes)
                    }
                    if let s = r.stats { statsBox.set(s) }
                    if r.done == true { break }
                }
                progressCont.finish()
                return imgs
            } catch {
                progressCont.finish(throwing: error)
                throw error
            }
        }
        let statsTask = Task<JSONValue?, Error> {
            _ = try await outputsTask.value
            return statsBox.get() ?? nil
        }
        return DiffusionRun(progress: progress, outputs: outputsTask, stats: statsTask)
    }
}
