// QVAC-209 — textToSpeechStream (bidirectional)
//
// Opens a long-lived session: client writes text fragments (UTF-8 bytes), server streams
// back audio chunks as they're synthesized. Used for low-latency TTS where text arrives
// incrementally (e.g. piping an LLM's tokenStream straight into TTS).

import Foundation

public extension QVACClient {

    /// Audio chunk emitted by a `textToSpeechStream` session.
    /// `buffer` is mono float32 samples at the loaded TTS model's sample rate.
    struct TtsStreamChunk: Sendable, Equatable {
        public let buffer: [Double]
        public let chunkIndex: Int?
        public let sentenceChunk: String?
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

        /// Signal end-of-input. The session emits final audio chunks then closes.
        public func end() async throws { try await raw.end() }

        /// Hard-terminate the session.
        public func destroy() { raw.destroy() }

        /// Async sequence of audio chunks. Single-use.
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
                let chunk: TtsStreamChunk? =
                    !response.buffer.isEmpty || response.sentenceChunk != nil
                    ? TtsStreamChunk(
                        buffer: response.buffer,
                        chunkIndex: response.chunkIndex,
                        sentenceChunk: response.sentenceChunk
                    )
                    : nil
                if response.done == true {
                    return .emitThenDrain(chunk.map { [$0] } ?? [])
                }
                return chunk.map(QVACPullMapDecision.emit) ?? .skip
            }
        }
    }
}
