import Foundation

public extension QVACClient {
    // MARK: - Standalone image upscaling

    enum GenerationBackendDevice: String, Codable, Sendable, Equatable {
        case cpu
        case gpu
    }

    struct UpscaleStats: Codable, Sendable, Equatable {
        public let modelLoadMs: Double?
        public let upscaleMs: Double?
        public let totalUpscaleMs: Double?
        public let totalWallMs: Double?
        public let totalUpscales: Double?
        public let totalImages: Double?
        public let totalPixels: Double?
        public let width: Double?
        public let height: Double?
        public let repeats: Double?
        public let backendDevice: GenerationBackendDevice?
    }

    final class UpscaleRun: @unchecked Sendable {
        public let outputs: Task<[Data], Error>
        public let stats: Task<UpscaleStats?, Error>

        init(outputs: Task<[Data], Error>, stats: Task<UpscaleStats?, Error>) {
            self.outputs = outputs
            self.stats = stats
        }
    }

    /// Run standalone ESRGAN upscaling. `image` is encoded as base64 on the wire;
    /// returned output values are decoded PNG bytes.
    func upscale(
        modelId: String,
        image: Data,
        repeats: Int? = nil,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> UpscaleRun {
        if let repeats, repeats <= 0 {
            throw QVACError.invalidArgument("upscale repeats must be greater than zero")
        }
        let request = UpscaleStreamRequest(
            image: image.base64EncodedString(),
            modelId: modelId,
            repeats: repeats
        )
        let source: QVACResponseStream<QVACResponse> = try await streamTyped(
            .upscaleStream(request), rpcOptions: rpcOptions
        )
        let statsBox = ResultBox<UpscaleStats?>()
        let outputs = Task<[Data], Error> {
            var outputs: [Data] = []
            let iterator = QVACResponseStreamIteratorBox(source)
            while let response = try await iterator.next() {
                if case .error(let error) = response {
                    return try await Self.resolveResponseStreamTerminal(
                        iterator,
                        operation: "upscaleStream"
                    ) { () throws -> [Data] in
                        throw QVACError.fromWire(
                            code: try Self.checkedWireErrorCode(error.code),
                            message: error.message
                        )
                    }
                }
                guard case .upscaleStream(let frame) = response else {
                    try Self.rejectUnexpectedResponse(response, expected: "upscaleStream")
                }
                if frame.done == true {
                    let terminal = try await Self.resolveResponseStreamTerminal(
                        iterator,
                        operation: "upscaleStream"
                    ) { () throws -> (outputs: [Data], stats: UpscaleStats?) in
                        var terminalOutputs = outputs
                        if let encoded = frame.data, !encoded.isEmpty {
                            guard let decoded = Data(base64Encoded: encoded), !decoded.isEmpty else {
                                throw QVACError.protocolViolation(
                                    "upscaleStream returned empty or invalid base64 image data"
                                )
                            }
                            terminalOutputs.append(decoded)
                        }
                        let stats = try frame.stats.map {
                            try Self.decodeInferenceStats(
                                $0,
                                as: UpscaleStats.self,
                                operation: "upscale"
                            )
                        }
                        return (terminalOutputs, stats)
                    }
                    statsBox.set(terminal.stats)
                    return terminal.outputs
                }
                if let encoded = frame.data, !encoded.isEmpty {
                    guard let decoded = Data(base64Encoded: encoded), !decoded.isEmpty else {
                        throw QVACError.protocolViolation(
                            "upscaleStream returned empty or invalid base64 image data"
                        )
                    }
                    outputs.append(decoded)
                }
            }
            throw QVACError.client(
                .streamEndedWithoutResponse,
                message: "upscaleStream ended without a terminal done frame"
            )
        }
        let stats = Task<UpscaleStats?, Error> {
            _ = try await outputs.value
            return statsBox.get() ?? nil
        }
        return UpscaleRun(outputs: outputs, stats: stats)
    }

    // MARK: - Video diffusion

    struct VideoProgressTick: Codable, Sendable, Equatable {
        public let step: Double
        public let totalSteps: Double
        public let elapsedMs: Double
    }

    struct VideoStats: Codable, Sendable, Equatable {
        public let seed: Double?
        public let width: Double?
        public let height: Double?
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
        public let totalVideos: Double?
        public let totalVideoFrames: Double?
        public let videoFrames: Double?
        public let fps: Double?
        public let hasAudio: Bool?
        public let audioSampleRate: Double?
    }

    final class VideoRun: @unchecked Sendable {
        /// Stable cancellation target carried in `VideoStreamRequest.requestId`.
        public let requestId: String
        /// Observational snapshots in a count- and byte-bounded coalescing window.
        /// A lagging observer never fails `outputs` or `stats`.
        public let progressStream: QVACBufferedStream<VideoProgressTick>
        public let outputs: Task<[Data], Error>
        public let stats: Task<VideoStats?, Error>

        init(
            requestId: String,
            progressStream: QVACBufferedStream<VideoProgressTick>,
            outputs: Task<[Data], Error>,
            stats: Task<VideoStats?, Error>
        ) {
            self.requestId = requestId
            self.progressStream = progressStream
            self.outputs = outputs
            self.stats = stats
        }
    }

    /// Generate video from an exact wire-level 0.17 request. For ergonomic binary
    /// conversion use the overload taking `initImage` and `controlFrames`.
    func video(
        _ input: VideoStreamRequest,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> VideoRun {
        var request = input
        let requestId = request.requestId ?? UUID().uuidString
        request.requestId = requestId
        let source: QVACResponseStream<QVACResponse> = try await streamTyped(
            .videoStream(request), rpcOptions: rpcOptions
        )
        let maximumBufferedStreamBytes = self.maximumBufferedStreamBytes
        let (progressStream, continuation) = Self.makeCoalescingProgressStream(
            of: VideoProgressTick.self,
            name: "video.progressStream",
            maximumBufferedBytes: maximumBufferedStreamBytes
        )
        let statsBox = ResultBox<VideoStats?>()
        let outputs = Task<[Data], Error> {
            var outputs: [Data] = []
            let iterator = QVACResponseStreamIteratorBox(source)
            do {
                while let response = try await iterator.next() {
                    if case .error(let error) = response {
                        return try await Self.resolveResponseStreamTerminal(
                            iterator,
                            operation: "videoStream"
                        ) { () throws -> [Data] in
                            throw QVACError.fromWire(
                                code: try Self.checkedWireErrorCode(error.code),
                                message: error.message
                            )
                        }
                    }
                    guard case .videoStream(let frame) = response else {
                        try Self.rejectUnexpectedResponse(response, expected: "videoStream")
                    }
                    if frame.done == true {
                        let terminal = try await Self.resolveResponseStreamTerminal(
                            iterator,
                            operation: "videoStream"
                        ) { () throws -> (
                            outputs: [Data],
                            progress: VideoProgressTick?,
                            stats: VideoStats?
                        ) in
                            var terminalOutputs = outputs
                            if let output = try Self.decodeVideoOutput(frame.data) {
                                terminalOutputs.append(output)
                            }
                            return (
                                terminalOutputs,
                                Self.decodeVideoProgress(frame),
                                try frame.stats.map {
                                    try Self.decodeInferenceStats(
                                        $0,
                                        as: VideoStats.self,
                                        operation: "video"
                                    )
                                }
                            )
                        }
                        if let tick = terminal.progress {
                            continuation.yield(
                                contentsOf: [tick],
                                estimatedBytes: Self.conservativeBufferedJSONBytes(
                                    tick,
                                    elementCount: 1,
                                    fallback: maximumBufferedStreamBytes
                                )
                            )
                        }
                        statsBox.set(terminal.stats)
                        continuation.finish()
                        return terminal.outputs
                    }
                    if let tick = Self.decodeVideoProgress(frame) {
                        continuation.yield(
                            contentsOf: [tick],
                            estimatedBytes: Self.conservativeBufferedJSONBytes(
                                tick,
                                elementCount: 1,
                                fallback: maximumBufferedStreamBytes
                            )
                        )
                    }
                    if let output = try Self.decodeVideoOutput(frame.data) {
                        outputs.append(output)
                    }
                }
                let error = QVACError.client(
                    .streamEndedWithoutResponse,
                    message: "videoStream ended without a terminal done frame"
                )
                continuation.finish(throwing: error)
                throw error
            } catch {
                continuation.finish(throwing: error)
                throw error
            }
        }
        let stats = Task<VideoStats?, Error> {
            _ = try await outputs.value
            return statsBox.get() ?? nil
        }
        return VideoRun(
            requestId: requestId,
            progressStream: progressStream,
            outputs: outputs,
            stats: stats
        )
    }

    /// Generate text-to-video or image-to-video while converting binary image inputs
    /// to the required base64 wire form. `configure` exposes every optional 0.17 field
    /// without duplicating the generated request type.
    func video(
        modelId: String,
        mode: String,
        prompt: String,
        initImage: Data? = nil,
        controlFrames: [Data]? = nil,
        configure: @Sendable (inout VideoStreamRequest) -> Void = { _ in },
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> VideoRun {
        guard mode == "txt2vid" || mode == "img2vid" else {
            throw QVACError.invalidArgument("video mode must be txt2vid or img2vid")
        }
        if mode == "img2vid", initImage == nil {
            throw QVACError.invalidArgument("img2vid requires initImage")
        }
        if mode == "txt2vid", initImage != nil {
            throw QVACError.invalidArgument("txt2vid does not accept initImage")
        }
        var request = VideoStreamRequest(mode: mode, modelId: modelId, prompt: prompt)
        request.initImage = initImage?.base64EncodedString()
        request.controlFrames = controlFrames?.map { $0.base64EncodedString() }
        configure(&request)
        return try await video(request, rpcOptions: rpcOptions)
    }

    private static func decodeVideoProgress(
        _ frame: VideoStreamResponse
    ) -> VideoProgressTick? {
        guard let step = frame.step,
              let totalSteps = frame.totalSteps,
              let elapsedMs = frame.elapsedMs else { return nil }
        return VideoProgressTick(
            step: step,
            totalSteps: totalSteps,
            elapsedMs: elapsedMs
        )
    }

    private static func decodeVideoOutput(_ encoded: String?) throws -> Data? {
        guard let encoded else { return nil }
        guard !encoded.isEmpty else { return nil }
        guard let decoded = Data(base64Encoded: encoded), !decoded.isEmpty else {
            throw QVACError.protocolViolation(
                "videoStream returned empty or invalid base64 video data"
            )
        }
        return decoded
    }

    // MARK: - Image classification

    struct ClassificationResult: Sendable, Equatable {
        public let label: String
        public let confidence: Double

        init?(wire: JSONValue) {
            guard case .object(let object) = wire,
                  case .string(let label) = object["label"] ?? .null,
                  case .number(let confidence) = object["confidence"] ?? .null else {
                return nil
            }
            self.label = label
            self.confidence = confidence
        }
    }

    /// Classify encoded JPEG/PNG bytes, or raw RGB bytes when dimensions and three
    /// channels are provided. The stream is aggregated until its terminal done frame.
    func classify(
        modelId: String,
        image: Data,
        topK: Int? = nil,
        width: Int? = nil,
        height: Int? = nil,
        channels: Int? = nil,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> [ClassificationResult] {
        if let channels, channels != 3 {
            throw QVACError.invalidArgument("classify raw RGB channels must equal 3")
        }
        var request = ClassifyRequest(image: image.base64EncodedString(), modelId: modelId)
        request.topK = topK
        request.width = width
        request.height = height
        request.channels = channels.map(Double.init)
        let source: QVACResponseStream<QVACResponse> = try await streamTyped(
            .classify(request), rpcOptions: rpcOptions
        )
        let iterator = QVACResponseStreamIteratorBox(source)
        while let response = try await iterator.next() {
            if case .error(let error) = response {
                return try await Self.resolveResponseStreamTerminal(
                    iterator,
                    operation: "classify"
                ) { () throws -> [ClassificationResult] in
                    throw QVACError.fromWire(
                        code: try Self.checkedWireErrorCode(error.code),
                        message: error.message
                    )
                }
            }
            guard case .classify(let frame) = response else {
                try Self.rejectUnexpectedResponse(response, expected: "classify")
            }
            guard frame.done == true else { continue }
            return try await Self.resolveResponseStreamTerminal(
                iterator,
                operation: "classify"
            ) {
                let results = frame.results.compactMap(ClassificationResult.init(wire:))
                guard results.count == frame.results.count else {
                    throw QVACError.protocolViolation("classify returned a malformed result")
                }
                return results
            }
        }
        throw QVACError.client(
            .streamEndedWithoutResponse,
            message: "classify ended without a terminal done frame"
        )
    }

    // MARK: - Audio generation

    struct AudioGenProgress: Codable, Sendable, Equatable {
        public let stage: String
        public let step: Int
        public let total: Int

        init(wire: JSONValue) throws {
            guard case .object(let object) = wire,
                  case .string(let stage) = object["stage"] ?? .null,
                  case .number(let step) = object["step"] ?? .null,
                  case .number(let total) = object["total"] ?? .null else {
                throw QVACError.protocolViolation("audioGenStream progress has an invalid shape")
            }
            self.stage = stage
            self.step = try QVACClient.checkedWireInteger(
                step, field: "audioGenStream progress.step"
            )
            self.total = try QVACClient.checkedWireInteger(
                total, field: "audioGenStream progress.total"
            )
            guard self.step >= 0, self.total >= 0 else {
                throw QVACError.protocolViolation(
                    "audioGenStream progress.step and progress.total must be nonnegative"
                )
            }
        }
    }

    struct AudioGenAudio: Sendable, Equatable {
        public let pcm: Data
        public let sampleRate: Int
        public let channels: Int
        public let bitsPerSample: Int
    }

    struct AudioGenStats: Sendable, Equatable {
        public let audioDurationMs: Double?
        public let totalTimeMs: Double?
        public let realTimeFactor: Double?
        public let backendDevice: Double?
        public let backendId: Double?

        init(wire: JSONValue) throws {
            guard case .object(let object) = wire else {
                throw QVACError.protocolViolation("audioGenStream stats must be an object")
            }
            func number(_ key: String) throws -> Double? {
                guard let value = object[key] else { return nil }
                guard case .number(let number) = value, number.isFinite else {
                    throw QVACError.protocolViolation(
                        "audioGenStream stats.\(key) must be a finite number"
                    )
                }
                return number
            }
            audioDurationMs = try number("audioDurationMs")
            totalTimeMs = try number("totalTimeMs")
            realTimeFactor = try number("realTimeFactor")
            backendDevice = try number("backendDevice")
            backendId = try number("backendId")
        }
    }

    private struct AudioGenPCMMetadata: Sendable {
        let sampleRate: Int?
        let channels: Int?
        let bitsPerSample: Int?
    }

    private struct AudioGenTerminalResolution: Sendable {
        let audio: AudioGenAudio
        let stats: AudioGenStats?
        let progress: AudioGenProgress?
    }

    final class AudioGenRun: @unchecked Sendable {
        public let requestId: String
        /// Observational snapshots in a count- and byte-bounded coalescing window.
        /// A lagging observer never fails `audio` or `stats`.
        public let progressStream: QVACBufferedStream<AudioGenProgress>
        public let audio: Task<AudioGenAudio, Error>
        public let stats: Task<AudioGenStats?, Error>

        init(
            requestId: String,
            progressStream: QVACBufferedStream<AudioGenProgress>,
            audio: Task<AudioGenAudio, Error>,
            stats: Task<AudioGenStats?, Error>
        ) {
            self.requestId = requestId
            self.progressStream = progressStream
            self.audio = audio
            self.stats = stats
        }
    }

    /// Generate PCM audio with the 0.17 AudioGen backend.
    func audioGen(
        modelId: String,
        caption: String,
        lyrics: String? = nil,
        seed: Int? = nil,
        vocalLanguage: String? = nil,
        bpm: Int? = nil,
        keyscale: String? = nil,
        timesignature: String? = nil,
        duration: Double? = nil,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> AudioGenRun {
        guard !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw QVACError.invalidArgument("audioGen caption must not be empty")
        }
        if let bpm, bpm <= 0 { throw QVACError.invalidArgument("audioGen bpm must be positive") }
        if let duration, duration <= 0 {
            throw QVACError.invalidArgument("audioGen duration must be positive")
        }
        let requestId = UUID().uuidString
        let request = AudioGenStreamRequest(
            caption: caption,
            modelId: modelId,
            bpm: bpm,
            duration: duration,
            keyscale: keyscale,
            lyrics: lyrics,
            requestId: requestId,
            seed: seed,
            timesignature: timesignature,
            vocalLanguage: vocalLanguage
        )
        let source: QVACResponseStream<QVACResponse> = try await streamTyped(
            .audioGenStream(request), rpcOptions: rpcOptions
        )
        let maximumBufferedStreamBytes = self.maximumBufferedStreamBytes
        let (progressStream, continuation) = Self.makeCoalescingProgressStream(
            of: AudioGenProgress.self,
            name: "audioGen.progressStream",
            maximumBufferedBytes: maximumBufferedStreamBytes
        )
        let statsBox = ResultBox<AudioGenStats?>()
        let audio = Task<AudioGenAudio, Error> {
            var pcm = Data()
            var metadata: AudioGenPCMMetadata?
            let iterator = QVACResponseStreamIteratorBox(source)
            do {
                while let response = try await iterator.next() {
                    if case .error(let error) = response {
                        return try await Self.resolveResponseStreamTerminal(
                            iterator,
                            operation: "audioGenStream"
                        ) { () throws -> AudioGenAudio in
                            throw QVACError.fromWire(
                                code: try Self.checkedWireErrorCode(error.code),
                                message: error.message
                            )
                        }
                    }
                    guard case .audioGenStream(let frame) = response else {
                        try Self.rejectUnexpectedResponse(response, expected: "audioGenStream")
                    }

                    if frame.done == true {
                        let terminal = try await Self.resolveResponseStreamTerminal(
                            iterator,
                            operation: "audioGenStream"
                        ) {
                            try Self.resolveAudioGenTerminal(
                                frame,
                                accumulatedPCM: pcm,
                                metadata: metadata,
                                requestId: requestId
                            )
                        }
                        if let progress = terminal.progress {
                            continuation.yield(
                                contentsOf: [progress],
                                estimatedBytes: Self.conservativeBufferedJSONBytes(
                                    progress,
                                    elementCount: 1,
                                    fallback: maximumBufferedStreamBytes
                                )
                            )
                        }
                        statsBox.set(terminal.stats)
                        continuation.finish()
                        return terminal.audio
                    }

                    if let raw = frame.progress {
                        continuation.yield(
                            contentsOf: [try AudioGenProgress(wire: raw)],
                            estimatedBytes: Self.conservativeBufferedJSONBytes(
                                raw,
                                elementCount: 1,
                                fallback: maximumBufferedStreamBytes
                            )
                        )
                    }
                    if let decoded = try Self.decodeAudioGenPCMFrame(frame) {
                        pcm.append(decoded.chunk)
                        metadata = decoded.metadata
                    }
                }
                let error = QVACError.client(
                    .streamEndedWithoutResponse,
                    message: "audioGenStream ended without a terminal done frame"
                )
                continuation.finish(throwing: error)
                throw error
            } catch {
                continuation.finish(throwing: error)
                throw error
            }
        }
        let stats = Task<AudioGenStats?, Error> {
            _ = try await audio.value
            return statsBox.get() ?? nil
        }
        return AudioGenRun(
            requestId: requestId,
            progressStream: progressStream,
            audio: audio,
            stats: stats
        )
    }

    private static func decodeAudioGenPCMFrame(
        _ frame: AudioGenStreamResponse
    ) throws -> (chunk: Data, metadata: AudioGenPCMMetadata)? {
        for (field, value) in [
            ("sampleRate", frame.sampleRate),
            ("channels", frame.channels),
            ("bitsPerSample", frame.bitsPerSample),
        ] {
            if let value, value <= 0 {
                throw QVACError.protocolViolation(
                    "audioGenStream.\(field) must be positive"
                )
            }
        }

        guard let encoded = frame.data else { return nil }
        guard !encoded.isEmpty,
              let chunk = Data(base64Encoded: encoded),
              !chunk.isEmpty else {
            throw QVACError.protocolViolation(
                "audioGenStream returned empty or invalid base64 PCM data"
            )
        }
        let metadata = AudioGenPCMMetadata(
            sampleRate: frame.sampleRate,
            channels: frame.channels,
            bitsPerSample: frame.bitsPerSample
        )
        return (chunk, metadata)
    }

    private static func resolveAudioGenTerminal(
        _ frame: AudioGenStreamResponse,
        accumulatedPCM: Data,
        metadata: AudioGenPCMMetadata?,
        requestId: String
    ) throws -> AudioGenTerminalResolution {
        let progress = try frame.progress.map(AudioGenProgress.init(wire:))
        var pcm = accumulatedPCM
        var resolvedMetadata = metadata
        if let decoded = try decodeAudioGenPCMFrame(frame) {
            pcm.append(decoded.chunk)
            resolvedMetadata = decoded.metadata
        }

        switch frame.stopReason {
        case "cancelled":
            throw QVACError.server(
                .inferenceCancelled,
                message: "audio generation \(requestId) was cancelled"
            )
        case nil, "completed":
            break
        case .some(let value):
            throw QVACError.protocolViolation(
                "audioGenStream.stopReason is not a QVAC 0.17 value: \(value)"
            )
        }

        guard let resolvedMetadata,
              let sampleRate = resolvedMetadata.sampleRate,
              let channels = resolvedMetadata.channels,
              let bitsPerSample = resolvedMetadata.bitsPerSample else {
            throw QVACError.protocolViolation(
                "audioGenStream completed without PCM sampleRate, channels, and bitsPerSample"
            )
        }
        return AudioGenTerminalResolution(
            audio: AudioGenAudio(
                pcm: pcm,
                sampleRate: sampleRate,
                channels: channels,
                bitsPerSample: bitsPerSample
            ),
            stats: try frame.stats.map(AudioGenStats.init(wire:)),
            progress: progress
        )
    }

    // MARK: - Batch completion

    struct BatchPrompt: Sendable, Equatable {
        public var id: String?
        public var history: [ChatMessage]
        public var generationParams: JSONValue?
        public var responseFormat: JSONValue?
        public var tools: [JSONValue]?

        public init(
            id: String? = nil,
            history: [ChatMessage],
            generationParams: JSONValue? = nil,
            responseFormat: JSONValue? = nil,
            tools: [JSONValue]? = nil
        ) {
            self.id = id
            self.history = history
            self.generationParams = generationParams
            self.responseFormat = responseFormat
            self.tools = tools
        }

        var wireValue: JSONValue {
            var object: [String: JSONValue] = [
                "history": .array(history.map(\.wireValue)),
            ]
            if let id { object["id"] = .string(id) }
            if let generationParams { object["generationParams"] = generationParams }
            if let responseFormat { object["responseFormat"] = responseFormat }
            if let tools { object["tools"] = .array(tools) }
            return .object(object)
        }
    }

    struct BatchCompletionEvent: Sendable, Equatable {
        public let id: String
        public let event: CompletionEvent

        init(wire: JSONValue) throws {
            guard case .object(let object) = wire,
                  case .string(let id) = object["id"] ?? .null,
                  let event = object["event"] else {
                throw QVACError.protocolViolation(
                    "batchCompletionStream event requires an id and event"
                )
            }
            self.id = id
            self.event = try CompletionEvent(wire: event)
        }
    }

    struct BatchCompletionResult: Sendable, Equatable {
        public let id: String
        public let final: CompletionFinal
    }

    final class BatchCompletionByIDRun: @unchecked Sendable {
        /// Lossless events flattened lazily from bounded per-wire-record batches.
        public let events: QVACBufferedStream<CompletionEvent>
        public let final: Task<CompletionFinal, Error>

        fileprivate init(
            events: QVACBufferedStream<CompletionEvent>,
            final: Task<CompletionFinal, Error>
        ) {
            self.events = events
            self.final = final
        }
    }

    final class BatchCompletionRun: @unchecked Sendable {
        public let requestId: String
        public let ids: Task<[String], Error>
        /// Lossless events flattened lazily from bounded per-wire-record batches.
        public let events: QVACBufferedStream<BatchCompletionEvent>
        public let results: Task<[BatchCompletionResult], Error>
        public let stats: Task<CompletionStats?, Error>

        private let coordinator: BatchCompletionCoordinator
        // Retaining the drain task is essential: all public views are observational,
        // while this task owns the raw stream through its terminal frame.
        private let processing: Task<Void, Never>

        fileprivate init(
            requestId: String,
            ids: Task<[String], Error>,
            events: QVACBufferedStream<BatchCompletionEvent>,
            results: Task<[BatchCompletionResult], Error>,
            stats: Task<CompletionStats?, Error>,
            coordinator: BatchCompletionCoordinator,
            processing: Task<Void, Never>
        ) {
            self.requestId = requestId
            self.ids = ids
            self.events = events
            self.results = results
            self.stats = stats
            self.coordinator = coordinator
            self.processing = processing
        }

        /// Return the typed event stream and final result for one prompt identifier.
        /// Event views are bounded to 64 producer batches and the client's configured
        /// byte budget. A lagging view fails explicitly without aborting batch
        /// aggregation or the other prompt results.
        public func byId(_ id: String) -> BatchCompletionByIDRun {
            coordinator.byId(id)
        }

        internal func __testPerIDStateCount() -> Int {
            coordinator.stateCount()
        }
    }

    /// Submit multiple completion histories to one addon run and correlate streamed
    /// events by prompt id.
    func batchCompletion(
        modelId: String,
        prompts: [BatchPrompt],
        stream: Bool = true,
        captureThinking: Bool? = nil,
        emitRawDeltas: Bool? = nil,
        toolDialect: CompletionToolDialect? = nil,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> BatchCompletionRun {
        guard !prompts.isEmpty else {
            throw QVACError.invalidArgument("batchCompletion requires at least one prompt")
        }
        let callerIds = prompts.compactMap(\.id)
        guard callerIds.allSatisfy({ !$0.isEmpty }) else {
            throw QVACError.invalidArgument("batchCompletion prompt ids must not be empty")
        }
        guard Set(callerIds).count == callerIds.count else {
            throw QVACError.invalidArgument("batchCompletion prompt ids must be unique")
        }
        for (index, prompt) in prompts.enumerated() {
            try Self.validateCompletionResponseFormat(
                prompt.responseFormat,
                hasTools: prompt.tools?.isEmpty == false,
                context: "batchCompletion prompt \(prompt.id ?? String(index))"
            )
        }
        let requestId = UUID().uuidString
        let request = BatchCompletionStreamRequest(
            modelId: modelId,
            prompts: prompts.map(\.wireValue),
            captureThinking: captureThinking,
            emitRawDeltas: emitRawDeltas,
            requestId: requestId,
            stream: stream,
            toolDialect: toolDialect?.rawValue
        )
        let source: QVACResponseStream<QVACResponse> = try await streamTyped(
            .batchCompletionStream(request), rpcOptions: rpcOptions
        )
        let (events, eventSink) = Self.makeBufferedStream(
            of: BatchCompletionEvent.self,
            name: "batchCompletion.events",
            maximumBufferedBytes: maximumBufferedStreamBytes
        )
        let fallbackIds = prompts.enumerated().map { index, prompt in
            prompt.id ?? String(index)
        }
        let coordinator = BatchCompletionCoordinator(
            requestId: requestId,
            fallbackIds: fallbackIds,
            initialKnownIds: Set(callerIds),
            eventSink: eventSink,
            maximumBufferedStreamBytes: maximumBufferedStreamBytes
        )
        let processing = Task<Void, Never> {
            let iterator = QVACResponseStreamIteratorBox(source)
            do {
                while let response = try await iterator.next() {
                    if case .error(let error) = response {
                        _ = try await Self.resolveResponseStreamTerminal(
                            iterator,
                            operation: "batchCompletionStream"
                        ) { () throws -> Void in
                            throw QVACError.fromWire(
                                code: try Self.checkedWireErrorCode(error.code),
                                message: error.message
                            )
                        }
                        throw QVACError.protocolViolation(
                            "batchCompletionStream terminal error unexpectedly resolved"
                        )
                    }
                    guard case .batchCompletionStream(let frame) = response else {
                        throw QVACError.protocolViolation(
                            "batchCompletionStream returned \(response.discriminator)"
                        )
                    }
                    if frame.done == true {
                        _ = try await Self.resolveResponseStreamTerminal(
                            iterator,
                            operation: "batchCompletionStream"
                        ) {
                            try coordinator.validateTerminalFrame(frame)
                        }
                    }
                    if try coordinator.consume(frame) { return }
                }
                coordinator.fail(QVACError.client(
                    .streamEndedWithoutResponse,
                    message: "batchCompletionStream ended without a terminal done frame"
                ))
            } catch {
                coordinator.fail(error)
            }
        }
        coordinator.registerProcessingCancellation { processing.cancel() }
        return BatchCompletionRun(
            requestId: requestId,
            ids: coordinator.ids,
            events: events,
            results: coordinator.results,
            stats: coordinator.stats,
            coordinator: coordinator,
            processing: processing
        )
    }

    internal static func decodeInferenceStats<T: Decodable>(
        _ wire: JSONValue,
        as type: T.Type,
        operation: String
    ) throws -> T {
        do {
            return try decodeFromJSONValue(wire, as: type)
        } catch {
            throw QVACError.protocolViolation("\(operation) returned malformed stats: \(error)")
        }
    }
}

private final class BatchPromise<Value: Sendable>: @unchecked Sendable {
    let task: Task<Value, Error>

    private let continuation: AsyncThrowingStream<Value, Error>.Continuation
    private let lock = NSLock()
    private var settled = false

    init(onCancel: @escaping @Sendable () -> Void = {}) {
        var captured: AsyncThrowingStream<Value, Error>.Continuation!
        let stream = AsyncThrowingStream<Value, Error>(bufferingPolicy: .bufferingNewest(1)) {
            captured = $0
        }
        continuation = captured
        task = Task {
            try await withTaskCancellationHandler {
                var iterator = stream.makeAsyncIterator()
                let value = try await iterator.next()
                try Task.checkCancellation()
                guard let value else {
                    throw QVACError.protocolViolation(
                        "batch completion promise ended without a value"
                    )
                }
                return value
            } onCancel: {
                onCancel()
            }
        }
    }

    func resolve(_ value: Value) {
        lock.lock()
        guard !settled else { lock.unlock(); return }
        settled = true
        lock.unlock()
        continuation.yield(value)
        continuation.finish()
    }

    func reject(_ error: Error) {
        lock.lock()
        guard !settled else { lock.unlock(); return }
        settled = true
        lock.unlock()
        continuation.finish(throwing: error)
    }
}

private final class BatchProcessingCancellationRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable () -> Void)?
    private var cancellationRequested = false

    func register(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        if cancellationRequested {
            lock.unlock()
            handler()
            return
        }
        self.handler = handler
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        guard !cancellationRequested else { lock.unlock(); return }
        cancellationRequested = true
        let handler = handler
        self.handler = nil
        lock.unlock()
        handler?()
    }
}

private struct BatchCompletionAccumulator: Sendable {
    var contentText = ""
    var thinkingText = ""
    var toolCalls: [QVACClient.CompletionToolCall] = []
    var stats: QVACClient.CompletionStats?
    var stopReason: QVACClient.CompletionStopReason?
    var rawFullText: String?
    var failureMessage: String?

    mutating func consume(_ event: QVACClient.CompletionEvent) {
        switch event {
        case .contentDelta(_, let text):
            contentText += text
        case .thinkingDelta(_, let text):
            thinkingText += text
        case .toolCall(_, let call):
            toolCalls.append(call)
        case .stats(_, let value):
            stats = value
        case .done(_, let reason, let raw):
            stopReason = reason
            if let raw { rawFullText = raw }
        case .failure(_, let message, let raw):
            failureMessage = message
            if let raw { rawFullText = raw }
        case .rawDelta, .toolError:
            break
        }
    }

    func result(requestId: String) -> Result<QVACClient.CompletionFinal, Error> {
        if let failureMessage {
            return .failure(QVACError.server(.completionFailed, message: failureMessage))
        }
        if stopReason == .cancelled {
            return .failure(QVACError.inferenceCancelled(
                requestId: requestId,
                partial: .init(
                    text: contentText,
                    toolCalls: toolCalls,
                    stats: stats
                )
            ))
        }
        let fullText = rawFullText ?? contentText
        return .success(.init(
            contentText: contentText,
            thinkingText: thinkingText.isEmpty ? nil : thinkingText,
            toolCalls: toolCalls,
            stats: stats,
            stopReason: stopReason,
            raw: .init(fullText: fullText),
            cacheableAssistantContent: toolCalls.isEmpty
                ? QVACClient.normalizeAssistantCacheContent(fullText)
                : nil
        ))
    }
}

private final class BatchCompletionPerIDState: @unchecked Sendable {
    let id: String
    let events: QVACBufferedStream<QVACClient.CompletionEvent>
    let eventSink: QVACBufferedStreamSink<QVACClient.CompletionEvent>
    let finalPromise: BatchPromise<QVACClient.CompletionFinal>
    var accumulator = BatchCompletionAccumulator()

    init(
        id: String,
        cancellationRelay: BatchProcessingCancellationRelay,
        maximumBufferedStreamBytes: Int
    ) {
        self.id = id
        finalPromise = BatchPromise { cancellationRelay.cancel() }
        let pair = QVACClient.makeBufferedStream(
            of: QVACClient.CompletionEvent.self,
            name: "batchCompletion.byId(\(id)).events",
            maximumBufferedBytes: maximumBufferedStreamBytes
        )
        events = pair.0
        eventSink = pair.1
    }

    var run: QVACClient.BatchCompletionByIDRun {
        .init(events: events, final: finalPromise.task)
    }
}

private final class BatchCompletionCoordinator: @unchecked Sendable {
    let ids: Task<[String], Error>
    let results: Task<[QVACClient.BatchCompletionResult], Error>
    let stats: Task<QVACClient.CompletionStats?, Error>

    private let requestId: String
    private let fallbackIds: [String]
    private let eventSink: QVACBufferedStreamSink<QVACClient.BatchCompletionEvent>
    private let maximumBufferedStreamBytes: Int
    private let cancellationRelay: BatchProcessingCancellationRelay
    private let idsPromise: BatchPromise<[String]>
    private let resultsPromise: BatchPromise<[QVACClient.BatchCompletionResult]>
    private let statsPromise: BatchPromise<QVACClient.CompletionStats?>
    private let lock = NSLock()
    private var orderedIds: [String] = []
    private var knownIds: Set<String>
    private var idsResolved = false
    private var terminal = false
    private var terminalError: Error?
    private var settledIds: Set<String> = []
    private var states: [String: BatchCompletionPerIDState] = [:]

    init(
        requestId: String,
        fallbackIds: [String],
        initialKnownIds: Set<String>,
        eventSink: QVACBufferedStreamSink<QVACClient.BatchCompletionEvent>,
        maximumBufferedStreamBytes: Int
    ) {
        self.requestId = requestId
        self.fallbackIds = fallbackIds
        knownIds = initialKnownIds
        self.eventSink = eventSink
        self.maximumBufferedStreamBytes = maximumBufferedStreamBytes
        let cancellationRelay = BatchProcessingCancellationRelay()
        self.cancellationRelay = cancellationRelay
        idsPromise = BatchPromise { cancellationRelay.cancel() }
        resultsPromise = BatchPromise { cancellationRelay.cancel() }
        statsPromise = BatchPromise { cancellationRelay.cancel() }
        ids = idsPromise.task
        results = resultsPromise.task
        stats = statsPromise.task
    }

    func registerProcessingCancellation(_ handler: @escaping @Sendable () -> Void) {
        cancellationRelay.register(handler)
    }

    func byId(_ id: String) -> QVACClient.BatchCompletionByIDRun {
        let rejection: Error?
        lock.lock()
        if let existing = states[id] {
            lock.unlock()
            return existing.run
        }
        if let terminalError {
            rejection = terminalError
        } else if terminal || !knownIds.contains(id) {
            rejection = QVACError.server(
                .completionFailed,
                message: "Unknown batch prompt id \"\(id)\". Await ids before requesting an addon-minted id."
            )
        } else {
            let state = BatchCompletionPerIDState(
                id: id,
                cancellationRelay: cancellationRelay,
                maximumBufferedStreamBytes: maximumBufferedStreamBytes
            )
            states[id] = state
            lock.unlock()
            return state.run
        }
        lock.unlock()

        // Unknown and terminal-failure lookups are intentionally ephemeral. Keeping
        // them out of `states` prevents unbounded growth from arbitrary caller ids.
        let state = BatchCompletionPerIDState(
            id: id,
            cancellationRelay: cancellationRelay,
            maximumBufferedStreamBytes: maximumBufferedStreamBytes
        )
        let error = rejection ?? QVACError.protocolViolation(
            "batchCompletion byId rejection was not initialized"
        )
        state.finalPromise.reject(error)
        state.eventSink.finish(throwing: error)
        return state.run
    }

    func stateCount() -> Int {
        lock.withLock { states.count }
    }

    /// Validate a logical terminal frame before the transport is drained. The
    /// terminal is consumed only after EOF so a trailer/drain failure can still
    /// reject every aggregate and observer with the authoritative stream error.
    func validateTerminalFrame(_ frame: BatchCompletionStreamResponse) throws {
        guard frame.done == true else {
            throw QVACError.protocolViolation(
                "batchCompletion terminal validation requires done: true"
            )
        }
        _ = try frame.events.map(QVACClient.BatchCompletionEvent.init(wire:))
        _ = try frame.stats.map { try QVACClient.CompletionStats(wire: $0) }
        if let ids = frame.ids {
            guard ids.count == fallbackIds.count, Set(ids).count == ids.count else {
                throw QVACError.protocolViolation(
                    "batchCompletionStream ids must contain exactly one unique id per prompt"
                )
            }
        }
    }

    /// Returns true when this is the terminal response frame.
    func consume(_ frame: BatchCompletionStreamResponse) throws -> Bool {
        let parsedEvents = try frame.events.map(QVACClient.BatchCompletionEvent.init(wire:))
        let parsedStats = try frame.stats.map { try QVACClient.CompletionStats(wire: $0) }

        if let ids = frame.ids {
            guard ids.count == fallbackIds.count, Set(ids).count == ids.count else {
                throw QVACError.protocolViolation(
                    "batchCompletionStream ids must contain exactly one unique id per prompt"
                )
            }
        }

        // Group only after every event in the frame has parsed successfully. This
        // makes frame handling atomic: malformed trailing events cannot leave
        // earlier values partially aggregated or published.
        var groupOrder: [String] = []
        var parsedEventsByID: [String: [QVACClient.CompletionEvent]] = [:]
        var wireEventsByID: [String: [JSONValue]] = [:]
        for (wireEvent, parsedEvent) in zip(frame.events, parsedEvents) {
            if parsedEventsByID[parsedEvent.id] == nil {
                groupOrder.append(parsedEvent.id)
            }
            parsedEventsByID[parsedEvent.id, default: []].append(parsedEvent.event)
            // Keeping the id wrapper in the estimate intentionally overestimates
            // what the per-id stream retains after parsing.
            wireEventsByID[parsedEvent.id, default: []].append(wireEvent)
        }
        let globalEstimatedBytes = conservativeBatchCompletionEventBytes(
            frame.events,
            fallback: maximumBufferedStreamBytes
        )
        var estimatedBytesByID: [String: Int] = [:]
        for id in groupOrder {
            estimatedBytesByID[id] = conservativeBatchCompletionEventBytes(
                wireEventsByID[id] ?? [],
                fallback: maximumBufferedStreamBytes
            )
        }

        var resolvedIDs: [String]?
        var perIDEmissions: [(
            sink: QVACBufferedStreamSink<QVACClient.CompletionEvent>,
            events: [QVACClient.CompletionEvent],
            estimatedBytes: Int
        )] = []
        var perIDSettlements: [(
            state: BatchCompletionPerIDState,
            result: Result<QVACClient.CompletionFinal, Error>
        )] = []
        var unknownStates: [BatchCompletionPerIDState] = []
        var completed: [QVACClient.BatchCompletionResult] = []
        var firstError: Error?

        lock.lock()
        guard !terminal else {
            lock.unlock()
            return true
        }

        var prospectiveKnownIds = knownIds
        if let ids = frame.ids { prospectiveKnownIds.formUnion(ids) }
        prospectiveKnownIds.formUnion(groupOrder)
        guard prospectiveKnownIds.count <= fallbackIds.count else {
            lock.unlock()
            throw QVACError.protocolViolation(
                "batchCompletionStream introduced more ids than requested prompts"
            )
        }
        for id in (frame.ids ?? []) + groupOrder where !knownIds.contains(id) {
            knownIds.insert(id)
        }

        if let ids = frame.ids, !idsResolved {
            orderedIds = ids
            resolvedIDs = resolveIdsLocked(ids)
        }
        for event in parsedEvents {
            let state = stateLocked(for: event.id)
            state.accumulator.consume(event.event)
        }
        for id in groupOrder {
            guard let events = parsedEventsByID[id], !events.isEmpty else { continue }
            perIDEmissions.append((
                sink: stateLocked(for: id).eventSink,
                events: events,
                estimatedBytes: estimatedBytesByID[id] ?? maximumBufferedStreamBytes
            ))
        }

        let isTerminalFrame = frame.done == true
        if isTerminalFrame {
            // Match the pinned 0.17 client: when the optional wire `ids` field is
            // absent, results remain in original prompt order regardless of event
            // arrival order.
            let ids = orderedIds.isEmpty ? fallbackIds : orderedIds
            if !idsResolved { resolvedIDs = resolveIdsLocked(ids) }
            settledIds = Set(ids)

            for id in ids {
                let state = stateLocked(for: id)
                let result = state.accumulator.result(requestId: requestId)
                perIDSettlements.append((state, result))
                switch result {
                case .success(let final):
                    completed.append(.init(id: id, final: final))
                case .failure(let error):
                    if firstError == nil { firstError = error }
                }
            }
            unknownStates = states.compactMap { id, state in
                settledIds.contains(id) ? nil : state
            }
            terminal = true
        }
        lock.unlock()

        // Never call a stream sink or settle a promise while holding the
        // coordinator lock. Delivery resumes arbitrary consumer tasks.
        if let resolvedIDs { idsPromise.resolve(resolvedIDs) }
        eventSink.yield(contentsOf: parsedEvents, estimatedBytes: globalEstimatedBytes)
        for emission in perIDEmissions {
            emission.sink.yield(
                contentsOf: emission.events,
                estimatedBytes: emission.estimatedBytes
            )
        }

        guard isTerminalFrame else { return false }

        for settlement in perIDSettlements {
            switch settlement.result {
            case .success(let final):
                settlement.state.finalPromise.resolve(final)
            case .failure(let error):
                settlement.state.finalPromise.reject(error)
            }
            settlement.state.eventSink.finish()
        }
        for state in unknownStates {
            state.finalPromise.reject(QVACError.server(
                .completionFailed,
                message: "Unknown batch prompt id \"\(state.id)\"."
            ))
            state.eventSink.finish()
        }
        eventSink.finish()
        if let firstError {
            resultsPromise.reject(firstError)
            statsPromise.reject(firstError)
        } else {
            resultsPromise.resolve(completed)
            statsPromise.resolve(parsedStats)
        }
        return true
    }

    func fail(_ error: Error) {
        let rejectIDs: Bool
        let statesToFail: [BatchCompletionPerIDState]
        lock.lock()
        guard !terminal else { lock.unlock(); return }
        terminal = true
        terminalError = error
        rejectIDs = !idsResolved
        statesToFail = Array(states.values)
        lock.unlock()

        if rejectIDs { idsPromise.reject(error) }
        resultsPromise.reject(error)
        statsPromise.reject(error)
        eventSink.finish(throwing: error)
        for state in statesToFail {
            state.finalPromise.reject(error)
            state.eventSink.finish(throwing: error)
        }
    }

    /// Marks ids resolved under the coordinator lock and returns the value that
    /// must be delivered after unlocking.
    private func resolveIdsLocked(_ ids: [String]) -> [String]? {
        guard !idsResolved else { return nil }
        idsResolved = true
        orderedIds = ids
        knownIds.formUnion(ids)
        for id in ids { _ = stateLocked(for: id) }
        return ids
    }

    private func stateLocked(for id: String) -> BatchCompletionPerIDState {
        if let state = states[id] { return state }
        knownIds.insert(id)
        let state = BatchCompletionPerIDState(
            id: id,
            cancellationRelay: cancellationRelay,
            maximumBufferedStreamBytes: maximumBufferedStreamBytes
        )
        states[id] = state
        return state
    }
}

/// Estimates the retained decoded event batch from its JSON wire representation.
///
/// Two times the encoded UTF-8 size plus fixed per-event storage is deliberately
/// conservative for Swift enum/array/dictionary overhead. Encoding JSONValue is
/// expected to be infallible for decoded wire data; reserving the entire configured
/// budget on an encoder failure keeps estimation best-effort and cannot fail the
/// batch operation itself.
private func conservativeBatchCompletionEventBytes(
    _ wireEvents: [JSONValue],
    fallback: Int
) -> Int {
    QVACClient.conservativeBufferedJSONBytes(
        wireEvents,
        elementCount: wireEvents.count,
        fallback: fallback
    )
}
