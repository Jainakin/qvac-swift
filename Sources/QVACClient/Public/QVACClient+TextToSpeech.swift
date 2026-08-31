// QVAC-208 — textToSpeech (single-shot synthesis)
//
// Synthesizes speech audio from text. The worker emits a stream of audio chunks; each
// chunk is a `[Float64]` of mono samples at the model's sample rate (usually 22050 Hz
// or 24000 Hz — call `client.getLoadedModelInfo(…)` to confirm).
//
// Three views are exposed:
//   • `bufferStream`: live sample stream for low-latency playback
//   • `buffer`: full concatenated samples in non-streaming mode
//   • `chunkUpdates`: per-sentence updates (only when `sentenceStream: true`)

import Foundation

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
        public let bufferStream: AsyncThrowingStream<Double, Error>
        public let chunkUpdates: AsyncThrowingStream<TtsSentenceChunkUpdate, Error>?
        public let buffer: Task<[Double], Error>
        public let done: Task<Bool, Error>
        init(
            bufferStream: AsyncThrowingStream<Double, Error>,
            chunkUpdates: AsyncThrowingStream<TtsSentenceChunkUpdate, Error>?,
            buffer: Task<[Double], Error>,
            done: Task<Bool, Error>
        ) {
            self.bufferStream = bufferStream
            self.chunkUpdates = chunkUpdates
            self.buffer = buffer
            self.done = done
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
        if let maximum = sentenceStreamMaxChunkScalars, maximum <= 0 {
            throw QVACError.invalidArgument(
                "textToSpeech sentenceStreamMaxChunkScalars must be positive"
            )
        }
        if description != nil, voiceDescription != nil {
            throw QVACError.invalidArgument(
                "textToSpeech description and voiceDescription are mutually exclusive"
            )
        }
        let hasDescription = description != nil || voiceDescription != nil
        if hasDescription,
           [voice, emotion, pitch, pace, expressivity, noise, reverb, quality]
            .contains(where: { $0 != nil }) {
            throw QVACError.invalidArgument(
                "textToSpeech description fields and voice-template fields are mutually exclusive"
            )
        }
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
        let (bufferStream, bufferSink) = Self.makeStream(
            of: Double.self,
            name: "textToSpeech.bufferStream"
        )
        if !stream { bufferSink.finish() }
        let chunkUpdates: AsyncThrowingStream<TtsSentenceChunkUpdate, Error>?
        let chunkSink: QVACStreamSink<TtsSentenceChunkUpdate>?
        if sentenceStream {
            let pair = Self.makeStream(
                of: TtsSentenceChunkUpdate.self,
                name: "textToSpeech.chunkUpdates"
            )
            chunkUpdates = pair.0
            chunkSink = pair.1
        } else {
            chunkUpdates = nil
            chunkSink = nil
        }
        let collectedBuffer = ResultBox<[Double]>()

        let done = Task<Bool, Error> {
            var full: [Double] = []
            var receivedTerminalFrame = false
            do {
                for try await response in responseStream {
                    guard case .textToSpeech(let r) = response else {
                        try Self.rejectUnexpectedResponse(response, expected: "textToSpeech")
                    }
                    if !r.buffer.isEmpty {
                        if stream {
                            for sample in r.buffer { bufferSink.yield(sample) }
                        } else {
                            full.append(contentsOf: r.buffer)
                        }
                    }
                    if sentenceStream,
                       !r.buffer.isEmpty || r.chunkIndex != nil || r.sentenceChunk?.isEmpty == false {
                        chunkSink?.yield(.init(
                            buffer: r.buffer,
                            chunkIndex: r.chunkIndex,
                            sentenceChunk: r.sentenceChunk
                        ))
                    }
                    if r.done == true {
                        receivedTerminalFrame = true
                        break
                    }
                }
                guard receivedTerminalFrame else {
                    throw QVACError.client(
                        .streamEndedWithoutResponse,
                        message: "textToSpeech ended without a terminal done frame"
                    )
                }
                collectedBuffer.set(stream ? [] : full)
                bufferSink.finish()
                chunkSink?.finish()
                return true
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
            done: done
        )
    }
}
