// Bidirectional text-to-speech streaming.
//
// Opens a long-lived session: client writes text fragments (UTF-8 bytes), server streams
// back audio chunks as they're synthesized. QVAC 0.17 represents native signed 16-bit PCM
// sample values as JSON numbers, which the generated contract decodes to Swift `Double`.
// The sample rate is engine-specific: current upstream engines use 24 kHz (Chatterbox),
// 44.1 kHz (Supertonic/Parler), or 48 kHz for enhanced output; supported configurations
// range from 8–192 kHz.

import Foundation

public extension QVACClient {

    /// Performance statistics carried by a duplex TTS response, normally on its
    /// terminal frame.
    struct TtsStreamStats: Codable, Sendable, Equatable {
        public let audioDuration: Double?
        public let totalSamples: Double?
        public let enhancerBackendDevice: Double?
        public let enhancerBackendId: Double?
    }

    /// One response frame emitted by a `textToSpeechStream` session.
    ///
    /// `buffer` contains native signed 16-bit PCM sample values represented as
    /// Swift `Double`. A terminal frame can have an empty buffer and carry only
    /// `done` and `stats`; it is still emitted so no 0.17 response fields are lost.
    struct TtsStreamChunk: Sendable, Equatable {
        public let buffer: [Double]
        public let chunkIndex: Int?
        public let sentenceChunk: String?
        public let done: Bool
        public let stats: TtsStreamStats?
    }

    /// Open a bidirectional TTS session.
    func textToSpeechStream(
        modelId: String,
        accumulateSentences: Bool? = nil,
        sentenceDelimiterPreset: String? = nil,
        maxBufferScalars: Double? = nil,
        flushAfterMs: Double? = nil,
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
    ) async throws -> TextToSpeechStreamSession {
        let req = TextToSpeechStreamRequest(
            modelId: modelId,
            accumulateSentences: accumulateSentences,
            description: description,
            emotion: emotion,
            expressivity: expressivity,
            flushAfterMs: flushAfterMs,
            inputType: inputType,
            maxBufferScalars: maxBufferScalars,
            noise: noise,
            pace: pace,
            pitch: pitch,
            quality: quality,
            reverb: reverb,
            sentenceDelimiterPreset: sentenceDelimiterPreset,
            voice: voice,
            voiceDescription: voiceDescription
        )
        let raw: QVACDuplexSession<TextToSpeechStreamResponse> = try await duplexTyped(
            .textToSpeechStream(req),
            rpcOptions: rpcOptions
        )
        return TextToSpeechStreamSession(raw: raw)
    }

    final class TextToSpeechStreamSession: @unchecked Sendable {
        private let raw: QVACDuplexSession<TextToSpeechStreamResponse>
        init(raw: QVACDuplexSession<TextToSpeechStreamResponse>) { self.raw = raw }

        /// Send a UTF-8 text fragment. The session will synthesize audio for it incrementally.
        public func write(text: String) async throws { try await raw.write(Data(text.utf8)) }

        /// Send an already UTF-8-encoded text fragment, matching the 0.17
        /// JavaScript session's `Uint8Array` input form.
        public func write(_ utf8Fragment: Data) async throws {
            try await raw.write(utf8Fragment)
        }

        /// Signal end-of-input. The session emits final audio chunks then closes.
        public func end() async throws { try await raw.end() }

        /// Hard-terminate the session.
        public func destroy() { raw.destroy() }

        /// Async sequence of response frames. Single-use.
        ///
        /// The terminal frame is included even when it has no audio so callers can
        /// observe its `done` flag and performance `stats` before iteration ends.
        public var chunks: QVACResponseStream<TtsStreamChunk> {
            let inner = raw.responses
            let rawSession = raw
            return QVACClient.pullMap(
                inner,
                operation: "textToSpeechStream",
                onTermination: { rawSession.destroy() },
                endOfSourceError: {
                    QVACError.client(
                        .streamEndedWithoutResponse,
                        message: "textToSpeechStream ended without a terminal done frame"
                    )
                }
            ) { response in
                let chunk = TtsStreamChunk(
                    buffer: response.buffer,
                    chunkIndex: response.chunkIndex,
                    sentenceChunk: response.sentenceChunk,
                    done: response.done,
                    stats: try response.stats.map {
                        try QVACClient.decodeFromJSONValue($0, as: TtsStreamStats.self)
                    }
                )
                if response.done == true {
                    return .emitThenDrain([chunk])
                }
                return .emit(chunk)
            }
        }
    }
}
