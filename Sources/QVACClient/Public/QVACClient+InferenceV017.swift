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
            for try await response in source {
                guard case .upscaleStream(let frame) = response else {
                    try Self.rejectUnexpectedResponse(response, expected: "upscaleStream")
                }
                if let encoded = frame.data {
                    guard let decoded = Data(base64Encoded: encoded) else {
                        throw QVACError.protocolViolation(
                            "upscaleStream returned invalid base64 image data"
                        )
                    }
                    outputs.append(decoded)
                }
                if frame.done == true {
                    statsBox.set(try frame.stats.map {
                        try Self.decodeInferenceStats($0, as: UpscaleStats.self, operation: "upscale")
                    })
                    return outputs
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

    struct VideoProgressTick: Sendable, Equatable {
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
        public let progressStream: AsyncThrowingStream<VideoProgressTick, Error>
        public let outputs: Task<[Data], Error>
        public let stats: Task<VideoStats?, Error>

        init(
            requestId: String,
            progressStream: AsyncThrowingStream<VideoProgressTick, Error>,
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
        let (progressStream, continuation) = Self.makeStream(
            of: VideoProgressTick.self,
            name: "video.progressStream"
        )
        let statsBox = ResultBox<VideoStats?>()
        let outputs = Task<[Data], Error> {
            var outputs: [Data] = []
            do {
                for try await response in source {
                    guard case .videoStream(let frame) = response else {
                        try Self.rejectUnexpectedResponse(response, expected: "videoStream")
                    }
                    if let step = frame.step,
                       let totalSteps = frame.totalSteps,
                       let elapsedMs = frame.elapsedMs {
                        continuation.yield(.init(
                            step: step, totalSteps: totalSteps, elapsedMs: elapsedMs
                        ))
                    }
                    if let encoded = frame.data {
                        guard let decoded = Data(base64Encoded: encoded) else {
                            throw QVACError.protocolViolation(
                                "videoStream returned invalid base64 video data"
                            )
                        }
                        outputs.append(decoded)
                    }
                    if frame.done == true {
                        statsBox.set(try frame.stats.map {
                            try Self.decodeInferenceStats($0, as: VideoStats.self, operation: "video")
                        })
                        continuation.finish()
                        return outputs
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
        for try await response in source {
            guard case .classify(let frame) = response else {
                try Self.rejectUnexpectedResponse(response, expected: "classify")
            }
            guard frame.done == true else { continue }
            let results = frame.results.compactMap(ClassificationResult.init(wire:))
            guard results.count == frame.results.count else {
                throw QVACError.protocolViolation("classify returned a malformed result")
            }
            return results
        }
        throw QVACError.client(
            .streamEndedWithoutResponse,
            message: "classify ended without a terminal done frame"
        )
    }

    // MARK: - Audio generation

    struct AudioGenProgress: Sendable, Equatable {
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

    final class AudioGenRun: @unchecked Sendable {
        public let requestId: String
        public let progressStream: AsyncThrowingStream<AudioGenProgress, Error>
        public let audio: Task<AudioGenAudio, Error>
        public let stats: Task<AudioGenStats?, Error>

        init(
            requestId: String,
            progressStream: AsyncThrowingStream<AudioGenProgress, Error>,
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
        let (progressStream, continuation) = Self.makeStream(
            of: AudioGenProgress.self,
            name: "audioGen.progressStream"
        )
        let statsBox = ResultBox<AudioGenStats?>()
        let audio = Task<AudioGenAudio, Error> {
            var pcm = Data()
            var sampleRate: Int?
            var channels: Int?
            var bitsPerSample: Int?
            do {
                for try await response in source {
                    guard case .audioGenStream(let frame) = response else {
                        try Self.rejectUnexpectedResponse(response, expected: "audioGenStream")
                    }
                    if let raw = frame.progress {
                        let event = try AudioGenProgress(wire: raw)
                        continuation.yield(event)
                    }
                    if let encoded = frame.data {
                        guard let chunk = Data(base64Encoded: encoded) else {
                            throw QVACError.protocolViolation(
                                "audioGenStream returned invalid base64 PCM data"
                            )
                        }
                        pcm.append(chunk)
                        sampleRate = frame.sampleRate
                        channels = frame.channels
                        bitsPerSample = frame.bitsPerSample
                    }
                    if frame.done == true {
                        if frame.stopReason == "cancelled" {
                            throw QVACError.server(
                                .inferenceCancelled,
                                message: "audio generation \(requestId) was cancelled"
                            )
                        }
                        guard let sampleRate, let channels, let bitsPerSample else {
                            throw QVACError.protocolViolation(
                                "audioGenStream terminal response omitted audio metadata"
                            )
                        }
                        let parsedStats = try frame.stats.map(AudioGenStats.init(wire:))
                        statsBox.set(parsedStats)
                        continuation.finish()
                        return AudioGenAudio(
                            pcm: pcm,
                            sampleRate: sampleRate,
                            channels: channels,
                            bitsPerSample: bitsPerSample
                        )
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
                "history": .array(history.map { message in
                    .object([
                        "role": .string(message.role),
                        "content": .string(message.content),
                    ])
                }),
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
        public let events: AsyncThrowingStream<CompletionEvent, Error>
        public let final: Task<CompletionFinal, Error>

        fileprivate init(
            events: AsyncThrowingStream<CompletionEvent, Error>,
            final: Task<CompletionFinal, Error>
        ) {
            self.events = events
            self.final = final
        }
    }

    final class BatchCompletionRun: @unchecked Sendable {
        public let requestId: String
        public let ids: Task<[String], Error>
        public let events: AsyncThrowingStream<BatchCompletionEvent, Error>
        public let results: Task<[BatchCompletionResult], Error>
        public let stats: Task<CompletionStats?, Error>

        private let coordinator: BatchCompletionCoordinator
        // Retaining the drain task is essential: all public views are observational,
        // while this task owns the raw stream through its terminal frame.
        private let processing: Task<Void, Never>

        fileprivate init(
            requestId: String,
            ids: Task<[String], Error>,
            events: AsyncThrowingStream<BatchCompletionEvent, Error>,
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
        /// Event views are bounded to 64 elements; a lagging view fails explicitly
        /// without aborting batch aggregation or the other prompt results.
        public func byId(_ id: String) -> BatchCompletionByIDRun {
            coordinator.byId(id)
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
        let (events, eventSink) = Self.makeStream(
            of: BatchCompletionEvent.self,
            name: "batchCompletion.events"
        )
        let fallbackIds = prompts.enumerated().map { index, prompt in
            prompt.id ?? String(index)
        }
        let coordinator = BatchCompletionCoordinator(
            requestId: requestId,
            fallbackIds: fallbackIds,
            eventSink: eventSink
        )
        let processing = Task<Void, Never> {
            do {
                for try await response in source {
                    guard case .batchCompletionStream(let frame) = response else {
                        if case .error(let error) = response {
                            throw QVACError.fromWire(
                                code: try Self.checkedWireErrorCode(error.code),
                                message: error.message
                            )
                        }
                        throw QVACError.protocolViolation(
                            "batchCompletionStream returned \(response.discriminator)"
                        )
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

    private static func decodeInferenceStats<T: Decodable>(
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
                guard let value = try await iterator.next() else {
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
            return .failure(QVACError.server(
                .inferenceCancelled,
                message: "batch completion \(requestId) was cancelled"
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
    let events: AsyncThrowingStream<QVACClient.CompletionEvent, Error>
    let eventSink: QVACStreamSink<QVACClient.CompletionEvent>
    let finalPromise: BatchPromise<QVACClient.CompletionFinal>
    var accumulator = BatchCompletionAccumulator()

    init(id: String, cancellationRelay: BatchProcessingCancellationRelay) {
        self.id = id
        finalPromise = BatchPromise { cancellationRelay.cancel() }
        let pair = QVACClient.makeStream(
            of: QVACClient.CompletionEvent.self,
            name: "batchCompletion.byId(\(id)).events"
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
    private let eventSink: QVACStreamSink<QVACClient.BatchCompletionEvent>
    private let cancellationRelay: BatchProcessingCancellationRelay
    private let idsPromise: BatchPromise<[String]>
    private let resultsPromise: BatchPromise<[QVACClient.BatchCompletionResult]>
    private let statsPromise: BatchPromise<QVACClient.CompletionStats?>
    private let lock = NSLock()
    private var orderedIds: [String] = []
    private var idsResolved = false
    private var terminal = false
    private var settledIds: Set<String> = []
    private var states: [String: BatchCompletionPerIDState] = [:]

    init(
        requestId: String,
        fallbackIds: [String],
        eventSink: QVACStreamSink<QVACClient.BatchCompletionEvent>
    ) {
        self.requestId = requestId
        self.fallbackIds = fallbackIds
        self.eventSink = eventSink
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
        lock.lock()
        if let state = states[id] {
            lock.unlock()
            return state.run
        }
        let state = BatchCompletionPerIDState(
            id: id,
            cancellationRelay: cancellationRelay
        )
        states[id] = state
        if terminal {
            state.eventSink.finish()
            state.finalPromise.reject(QVACError.server(
                .completionFailed,
                message: "Unknown batch prompt id \"\(id)\"."
            ))
        }
        lock.unlock()
        return state.run
    }

    /// Returns true when this is the terminal response frame.
    func consume(_ frame: BatchCompletionStreamResponse) throws -> Bool {
        let parsedEvents = try frame.events.map(QVACClient.BatchCompletionEvent.init(wire:))
        let parsedStats = try frame.stats.map { try QVACClient.CompletionStats(wire: $0) }

        lock.lock()
        defer { lock.unlock() }
        guard !terminal else { return true }

        if let ids = frame.ids, !idsResolved {
            orderedIds = ids
            resolveIdsLocked(ids)
        }
        for event in parsedEvents {
            let state = stateLocked(for: event.id)
            state.accumulator.consume(event.event)
            eventSink.yield(event)
            state.eventSink.yield(event.event)
        }
        guard frame.done == true else { return false }

        let ids = orderedIds.isEmpty ? fallbackIds : orderedIds
        if !idsResolved { resolveIdsLocked(ids) }
        settledIds = Set(ids)

        var completed: [QVACClient.BatchCompletionResult] = []
        var firstError: Error?
        for id in ids {
            let state = stateLocked(for: id)
            switch state.accumulator.result(requestId: requestId) {
            case .success(let final):
                state.finalPromise.resolve(final)
                completed.append(.init(id: id, final: final))
            case .failure(let error):
                state.finalPromise.reject(error)
                if firstError == nil { firstError = error }
            }
            state.eventSink.finish()
        }
        for (id, state) in states where !settledIds.contains(id) {
            let error = QVACError.server(
                .completionFailed,
                message: "Unknown batch prompt id \"\(id)\"."
            )
            state.finalPromise.reject(error)
            state.eventSink.finish()
        }

        terminal = true
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
        lock.lock()
        guard !terminal else { lock.unlock(); return }
        terminal = true
        if !idsResolved { idsPromise.reject(error) }
        resultsPromise.reject(error)
        statsPromise.reject(error)
        eventSink.finish(throwing: error)
        for state in states.values {
            state.finalPromise.reject(error)
            state.eventSink.finish(throwing: error)
        }
        lock.unlock()
    }

    private func resolveIdsLocked(_ ids: [String]) {
        guard !idsResolved else { return }
        idsResolved = true
        orderedIds = ids
        for id in ids { _ = stateLocked(for: id) }
        idsPromise.resolve(ids)
    }

    private func stateLocked(for id: String) -> BatchCompletionPerIDState {
        if let state = states[id] { return state }
        let state = BatchCompletionPerIDState(
            id: id,
            cancellationRelay: cancellationRelay
        )
        states[id] = state
        return state
    }
}
