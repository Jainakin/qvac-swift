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
        inputType: String? = nil
    ) async throws -> TextToSpeechStreamSession {
        let req = TextToSpeechStreamRequest(
            modelId: modelId,
            accumulateSentences: accumulateSentences,
            flushAfterMs: flushAfterMs,
            inputType: inputType,
            maxBufferScalars: maxBufferScalars,
            sentenceDelimiterPreset: sentenceDelimiterPreset
        )
        let raw: QVACDuplexSession<TextToSpeechStreamResponse> = try await duplexTyped(.textToSpeechStream(req))
        return TextToSpeechStreamSession(raw: raw)
    }

    final class TextToSpeechStreamSession: @unchecked Sendable {
        private let raw: QVACDuplexSession<TextToSpeechStreamResponse>
        init(raw: QVACDuplexSession<TextToSpeechStreamResponse>) { self.raw = raw }

        /// Send a UTF-8 text fragment. The session will synthesize audio for it incrementally.
        public func write(text: String) async { await raw.write(Data(text.utf8)) }

        /// Signal end-of-input. The session emits final audio chunks then closes.
        public func end() async { await raw.end() }

        /// Hard-terminate the session.
        public func destroy() { raw.destroy() }

        /// Async sequence of audio chunks. Single-use.
        public var chunks: AsyncThrowingStream<TtsStreamChunk, Error> {
            let inner = raw.responses
            return AsyncThrowingStream<TtsStreamChunk, Error> { continuation in
                let task = Task<Void, Never> {
                    do {
                        for try await response in inner {
                            if !response.buffer.isEmpty || response.sentenceChunk != nil {
                                continuation.yield(TtsStreamChunk(
                                    buffer: response.buffer,
                                    chunkIndex: response.chunkIndex,
                                    sentenceChunk: response.sentenceChunk
                                ))
                            }
                            if response.done == true { break }
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }
}
