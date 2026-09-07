// Text-to-speech synthesis.
//
// Synthesizes speech audio from text. QVAC 0.17 emits native signed 16-bit PCM sample
// values as JSON numbers, which the generated wire contract decodes to Swift `Double`.
// The sample rate is engine-specific: current upstream engines use 24 kHz (Chatterbox),
// 44.1 kHz (Supertonic/Parler), or 48 kHz for enhanced output; supported configurations
// range from 8–192 kHz.
//
// Three views are exposed:
//   • `bufferStream`: live sample stream for low-latency playback
//   • `buffer`: full concatenated samples in non-streaming mode
//   • `chunkUpdates`: per-sentence updates (only when `sentenceStream: true`)

import Foundation

internal enum QVACTextToSpeechValidation {
    private static let parlerEmotions: Set<String> = [
        "command", "anger", "narration", "conversation", "disgust", "fear",
        "happy", "neutral", "proper noun", "news", "sad", "surprise",
    ]

    private static let sentenceDelimiterPresets: Set<String> = [
        "latin", "cjk", "multilingual",
    ]

    static func validateOptions(
        operation: String,
        sentenceDelimiterPreset: String? = nil,
        description: String?,
        voiceDescription: String?,
        voice: String?,
        emotion: String?,
        pitch: String?,
        pace: String?,
        expressivity: String?,
        noise: String?,
        reverb: String?,
        quality: String?
    ) throws {
        let nonEmptyFields: [(name: String, value: String?)] = [
            ("description", description),
            ("voiceDescription", voiceDescription),
            ("voice", voice),
            ("pitch", pitch),
            ("pace", pace),
            ("expressivity", expressivity),
            ("noise", noise),
            ("reverb", reverb),
            ("quality", quality),
        ]
        if let emptyField = nonEmptyFields.first(where: { $0.value?.isEmpty == true }) {
            throw QVACError.invalidArgument(
                "\(operation) \(emptyField.name) must not be empty"
            )
        }
        if let emotion, !parlerEmotions.contains(emotion) {
            throw QVACError.invalidArgument(
                "\(operation) emotion must be one of: \(parlerEmotions.sorted().joined(separator: ", "))"
            )
        }
        if let sentenceDelimiterPreset,
           !sentenceDelimiterPresets.contains(sentenceDelimiterPreset) {
            throw QVACError.invalidArgument(
                "\(operation) sentenceDelimiterPreset must be one of: latin, cjk, multilingual"
            )
        }
        if description != nil, voiceDescription != nil {
            throw QVACError.invalidArgument(
                "\(operation) description and voiceDescription are mutually exclusive"
            )
        }
        let hasDescription = description != nil || voiceDescription != nil
        if hasDescription,
           [voice, emotion, pitch, pace, expressivity, noise, reverb, quality]
            .contains(where: { $0 != nil }) {
            throw QVACError.invalidArgument(
                "\(operation) description fields and voice-template fields are mutually exclusive"
            )
        }
    }
}

public extension QVACClient {
    /// Per-sentence update emitted when `sentenceStream: true` is requested.
    /// Contains the chunk index and the text being synthesized in that chunk.
    struct TtsSentenceChunkUpdate: Sendable, Equatable {
        public let buffer: [Double]
        public let chunkIndex: Int?
        public let sentenceChunk: String?
    }

    /// Outcome of a `textToSpeech(…)` call.
    final class TextToSpeechRun: @unchecked Sendable {
        /// A sample-by-sample view that retains bounded whole wire chunks and
        /// flattens each chunk lazily as it is consumed.
        public let bufferStream: QVACBufferedStream<Double>
        /// Byte-bounded sentence updates, one atomic batch per worker frame.
        public let chunkUpdates: QVACBufferedStream<TtsSentenceChunkUpdate>?
        /// Full non-streaming sample aggregation. Array capacity is conservatively
        /// charged against `maximumAccumulatedResultBytes` before each append.
        public let buffer: Task<[Double], Error>
        public let done: Task<Bool, Error>
        private let processing: Task<Bool, Error>

        init(
            bufferStream: QVACBufferedStream<Double>,
            chunkUpdates: QVACBufferedStream<TtsSentenceChunkUpdate>?,
            buffer: Task<[Double], Error>,
            done: Task<Bool, Error>,
            processing: Task<Bool, Error>
        ) {
            self.bufferStream = bufferStream
            self.chunkUpdates = chunkUpdates
            self.buffer = buffer
            self.done = done
            self.processing = processing
        }

        /// Cancel the underlying synthesis RPC and every public view of this run.
        ///
        /// Releasing the run wrapper does not cancel automatically: callers may
        /// safely retain an extracted task or stream and consume it independently.
        public func cancel() {
            processing.cancel()
        }
    }

    /// Synthesize speech for `text` using the loaded TTS model.
    ///
    /// `sentenceStream: true` emits sentence-boundary updates and lets the worker chunk
    /// long input into manageable pieces. `inputType` (default `"text"`) can be `"phonemes"`
    /// to bypass G2P. `emotion`, when provided, must be one of the exact Parler values
    /// defined by QVAC SDK 0.17: `command`, `anger`, `narration`, `conversation`,
    /// `disgust`, `fear`, `happy`, `neutral`, `proper noun`, `news`, `sad`, or `surprise`.
    func textToSpeech(
        modelId: String,
        text: String,
        stream: Bool = true,
        sentenceStream: Bool = false,
        sentenceStreamLocale: String? = nil,
        sentenceStreamMaxChunkScalars: Double? = nil,
        inputType: String? = nil,
        description: String? = nil,
        voiceDescription: String? = nil,
        voice: String? = nil,
        emotion: String? = nil,
        pitch: String? = nil,
        pace: String? = nil,
        expressivity: String? = nil,
        noise: String? = nil,
        reverb: String? = nil,
        quality: String? = nil,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> TextToSpeechRun {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw QVACError.invalidArgument("textToSpeech text must not be empty")
        }
        if sentenceStream, !stream {
            throw QVACError.invalidArgument(
                "textToSpeech sentenceStream requires stream"
            )
        }
        if let maximum = sentenceStreamMaxChunkScalars,
           !maximum.isFinite || maximum <= 0 {
            throw QVACError.invalidArgument(
                "textToSpeech sentenceStreamMaxChunkScalars must be a finite positive number"
            )
        }
        try QVACTextToSpeechValidation.validateOptions(
            operation: "textToSpeech",
            description: description,
            voiceDescription: voiceDescription,
            voice: voice,
            emotion: emotion,
            pitch: pitch,
            pace: pace,
            expressivity: expressivity,
            noise: noise,
            reverb: reverb,
            quality: quality
        )
        var req = TextToSpeechRequest(modelId: modelId, text: text)
        req.stream = stream
        req.sentenceStream = sentenceStream
        if sentenceStream {
            req.sentenceStreamLocale = sentenceStreamLocale
            req.sentenceStreamMaxChunkScalars = sentenceStreamMaxChunkScalars
        }
        req.inputType = inputType ?? "text"
        req.description = description
        req.voiceDescription = voiceDescription
        req.voice = voice
        req.emotion = emotion
        req.pitch = pitch
        req.pace = pace
        req.expressivity = expressivity
        req.noise = noise
        req.reverb = reverb
        req.quality = quality

        let responseStream: QVACResponseStream<QVACResponse> = try await streamTyped(
            .textToSpeech(req),
            rpcOptions: rpcOptions
        )
        let maximumBufferedStreamBytes = self.maximumBufferedStreamBytes
        let (bufferStream, bufferSink) = Self.makeBufferedStream(
            of: Double.self,
            name: "textToSpeech.bufferStream",
            maximumBufferedBytes: maximumBufferedStreamBytes
        )
        if !stream { bufferSink.finish() }
        let chunkUpdates: QVACBufferedStream<TtsSentenceChunkUpdate>?
        let chunkSink: QVACBufferedStreamSink<TtsSentenceChunkUpdate>?
        if sentenceStream {
            let pair = Self.makeBufferedStream(
                of: TtsSentenceChunkUpdate.self,
                name: "textToSpeech.chunkUpdates",
                maximumBufferedBytes: maximumBufferedStreamBytes
            )
            chunkUpdates = pair.0
            chunkSink = pair.1
        } else {
            chunkUpdates = nil
            chunkSink = nil
        }
        let collectedBuffer = ResultBox<[Double]>()
        let initialResultBudget = makeResultByteBudget(operation: "textToSpeech")

        let done = Task<Bool, Error> {
            var resultBudget = initialResultBudget
            var full: [Double] = []
            do {
                let responses = QVACResponseStreamIteratorBox(responseStream)
                while let response = try await responses.next() {
                    if case .error(let error) = response {
                        return try await Self.resolveResponseStreamTerminal(
                            responses,
                            operation: "textToSpeech"
                        ) { () throws -> Bool in
                            throw QVACError.fromWire(
                                code: try Self.checkedWireErrorCode(error.code),
                                message: error.message
                            )
                        }
                    }
                    guard case .textToSpeech(let r) = response else {
                        try Self.rejectUnexpectedResponse(response, expected: "textToSpeech")
                    }
                    let isTerminal = r.done == true
                    let hasChunkUpdate = !r.buffer.isEmpty
                        || r.chunkIndex != nil
                        || r.sentenceChunk?.isEmpty == false
                    if !r.buffer.isEmpty {
                        if stream {
                            if !isTerminal {
                                bufferSink.yield(
                                    contentsOf: r.buffer,
                                    estimatedBytes: Self.retainedTtsBufferedBatchBytes(
                                        r.buffer.count
                                    )
                                )
                            }
                        } else {
                            try resultBudget.consume(
                                Self.retainedTtsAggregateAppendBytes(r.buffer.count)
                            )
                            full.append(contentsOf: r.buffer)
                        }
                    }
                    if sentenceStream, hasChunkUpdate, !isTerminal {
                        chunkSink?.yield(
                            contentsOf: [.init(
                                buffer: r.buffer,
                                chunkIndex: r.chunkIndex,
                                sentenceChunk: r.sentenceChunk
                            )],
                            estimatedBytes: max(
                                Self.retainedTtsSampleBytes(r.buffer.count),
                                Self.conservativeBufferedJSONBytes(
                                    r,
                                    elementCount: 1,
                                    fallback: maximumBufferedStreamBytes
                                )
                            )
                        )
                    }
                    if isTerminal {
                        // Treat the logical terminal record as provisional until
                        // profiling metadata and transport EOF have been consumed.
                        // Otherwise a following domain record could fail the task
                        // after terminal audio had already escaped through a public
                        // stream.
                        try await Self.drainResponseStreamAfterTerminal(
                            responses,
                            operation: "textToSpeech"
                        )
                        if stream, !r.buffer.isEmpty {
                            bufferSink.yield(
                                contentsOf: r.buffer,
                                estimatedBytes: Self.retainedTtsBufferedBatchBytes(
                                    r.buffer.count
                                )
                            )
                        }
                        if sentenceStream, hasChunkUpdate {
                            chunkSink?.yield(
                                contentsOf: [.init(
                                    buffer: r.buffer,
                                    chunkIndex: r.chunkIndex,
                                    sentenceChunk: r.sentenceChunk
                                )],
                                estimatedBytes: max(
                                    Self.retainedTtsSampleBytes(r.buffer.count),
                                    Self.conservativeBufferedJSONBytes(
                                        r,
                                        elementCount: 1,
                                        fallback: maximumBufferedStreamBytes
                                    )
                                )
                            )
                        }
                        collectedBuffer.set(stream ? [] : full)
                        bufferSink.finish()
                        chunkSink?.finish()
                        return true
                    }
                }
                try Task.checkCancellation()
                throw QVACError.client(
                    .streamEndedWithoutResponse,
                    message: "textToSpeech ended without a terminal done frame"
                )
            } catch {
                bufferSink.finish(throwing: error)
                chunkSink?.finish(throwing: error)
                throw error
            }
        }
        let buffer = Task<[Double], Error> {
            _ = try await done.value
            return collectedBuffer.get() ?? []
        }
        return TextToSpeechRun(
            bufferStream: bufferStream,
            chunkUpdates: chunkUpdates,
            buffer: buffer,
            done: done,
            processing: done
        )
    }

    private static func retainedTtsSampleBytes(_ sampleCount: Int) -> Int {
        let (bytes, overflowed) = sampleCount.multipliedReportingOverflow(
            by: MemoryLayout<Double>.stride
        )
        return overflowed ? Int.max : bytes
    }

    /// Conservative allocation-free charge for one public PCM batch. The doubled
    /// payload covers ordinary geometric spare capacity in `[Double]`; the fixed
    /// charge covers the array value, channel entry, lease, and allocator metadata.
    internal static func retainedTtsBufferedBatchBytes(_ sampleCount: Int) -> Int {
        let capacityBytes = QVACBufferedJSONRetainedSizeEstimator.saturatingMultiply(
            retainedTtsSampleBytes(sampleCount),
            2
        )
        return QVACBufferedJSONRetainedSizeEstimator.saturatingAdd(capacityBytes, 512)
    }

    /// A growing Swift array can retain spare capacity after an append. Charging
    /// twice the fixed-width sample bytes conservatively bounds that allocation.
    private static func retainedTtsAggregateAppendBytes(_ sampleCount: Int) -> Int {
        let exactBytes = retainedTtsSampleBytes(sampleCount)
        return QVACBufferedJSONRetainedSizeEstimator.saturatingMultiply(exactBytes, 2)
    }
}
