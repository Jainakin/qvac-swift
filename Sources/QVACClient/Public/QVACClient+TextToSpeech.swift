// QVAC-208 — textToSpeech (single-shot synthesis)
//
// Synthesizes speech audio from text. The worker emits a stream of audio chunks; each
// chunk is a `[Float64]` of mono samples at the model's sample rate (usually 22050 Hz
// or 24000 Hz — call `client.getLoadedModelInfo(…)` to confirm).
//
// Three views are exposed:
//   • `audioStream`: live AsyncThrowingStream of `[Double]` chunks for low-latency playback
//   • `audio`:       Task that resolves with the full concatenated audio when done
//   • `sentenceChunks`: per-sentence boundary updates (only emitted if `sentenceStream: true`)

import Foundation

public extension QVACClient {

    /// Per-sentence update emitted when `sentenceStream: true` is requested.
    /// Contains the chunk index and the text being synthesized in that chunk.
    struct TtsSentenceChunkUpdate: Sendable, Equatable {
        public let chunkIndex: Int
        public let sentence: String
    }

    /// Outcome of a `textToSpeech(…)` call.
    final class TextToSpeechRun: @unchecked Sendable {
        public let audioStream: AsyncThrowingStream<[Double], Error>
        public let sentenceChunks: AsyncThrowingStream<TtsSentenceChunkUpdate, Error>
        public let audio: Task<[Double], Error>
        public let stats: Task<JSONValue?, Error>
        init(
            audioStream: AsyncThrowingStream<[Double], Error>,
            sentenceChunks: AsyncThrowingStream<TtsSentenceChunkUpdate, Error>,
            audio: Task<[Double], Error>,
            stats: Task<JSONValue?, Error>
        ) {
            self.audioStream = audioStream
            self.sentenceChunks = sentenceChunks
            self.audio = audio
            self.stats = stats
        }
    }

    /// Synthesize speech for `text` using the loaded TTS model.
    ///
    /// `sentenceStream: true` emits sentence-boundary updates and lets the worker chunk
    /// long input into manageable pieces. `inputType` (default `"text"`) can be `"phonemes"`
    /// to bypass G2P.
    func textToSpeech(
        modelId: String,
        text: String,
        sentenceStream: Bool = false,
        sentenceStreamLocale: String? = nil,
        sentenceStreamMaxChunkScalars: Double? = nil,
        inputType: String? = nil
    ) async throws -> TextToSpeechRun {
        var req = TextToSpeechRequest(modelId: modelId, text: text)
        req.stream = true
        if sentenceStream {
            req.sentenceStream = true
            req.sentenceStreamLocale = sentenceStreamLocale
            req.sentenceStreamMaxChunkScalars = sentenceStreamMaxChunkScalars
        }
        req.inputType = inputType

        let stream: AsyncThrowingStream<QVACResponse, Error> = try await streamTyped(.textToSpeech(req))
        let (audio, audioCont) = Self.makeStream(of: [Double].self)
        let (sentences, sentencesCont) = Self.makeStream(of: TtsSentenceChunkUpdate.self)
        let statsBox = ResultBox<JSONValue?>()

        let audioTask = Task<[Double], Error> {
            var full: [Double] = []
            do {
                for try await response in stream {
                    guard case .textToSpeech(let r) = response else {
                        if case .error(let e) = response {
                            throw QVACError.fromWire(code: Int(e.code ?? 0), message: e.message)
                        }
                        continue
                    }
                    if !r.buffer.isEmpty {
                        full.append(contentsOf: r.buffer)
                        audioCont.yield(r.buffer)
                    }
                    if let chunk = r.sentenceChunk, let idx = r.chunkIndex {
                        sentencesCont.yield(TtsSentenceChunkUpdate(chunkIndex: idx, sentence: chunk))
                    }
                    if let s = r.stats { statsBox.set(s) }
                    if r.done == true { break }
                }
                audioCont.finish()
                sentencesCont.finish()
                return full
            } catch {
                audioCont.finish(throwing: error)
                sentencesCont.finish(throwing: error)
                throw error
            }
        }
        let statsTask = Task<JSONValue?, Error> { _ = try await audioTask.value; return statsBox.get() ?? nil }
        return TextToSpeechRun(audioStream: audio, sentenceChunks: sentences, audio: audioTask, stats: statsTask)
    }
}
