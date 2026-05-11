// QVAC-207 — transcribeStream (bidirectional)
//
// Opens a long-lived session: client writes audio chunks (raw PCM bytes the worker's
// model expects — usually 16 kHz mono int16), server streams back transcription as VAD
// detects speech boundaries.
//
// The session is single-use. Call `write(_:)` repeatedly; call `end()` when the input
// audio is exhausted. Iterate `events` for transcripts.

import Foundation

public extension QVACClient {

    /// One transcription event from a `transcribeStream` session.
    enum TranscribeStreamEvent: Sendable, Equatable {
        /// Free-form text token / fragment.
        case text(String)
        /// Whole transcribed segment with timing (when `metadata: true` requested).
        case segment(TranscribeSegment)
        /// Stream finished.
        case done
    }

    /// Open a bidirectional transcription session.
    /// Single-use: iterating the session's `events` more than once throws.
    func transcribeStream(
        modelId: String,
        prompt: String? = nil,
        metadata: Bool = false
    ) async throws -> TranscribeStreamSession {
        let req = TranscribeStreamRequest(modelId: modelId, metadata: metadata, prompt: prompt)
        let raw: QVACDuplexSession<TranscribeStreamResponse> = try await duplexTyped(.transcribeStream(req))
        return TranscribeStreamSession(raw: raw)
    }

    /// Session handle. Write audio via `write(_:)`; iterate `events` for transcripts;
    /// call `end()` to signal you're done sending audio.
    final class TranscribeStreamSession: @unchecked Sendable {
        private let raw: QVACDuplexSession<TranscribeStreamResponse>
        init(raw: QVACDuplexSession<TranscribeStreamResponse>) { self.raw = raw }

        /// Send a chunk of audio bytes. Format depends on the loaded model (Whisper expects
        /// 16 kHz mono int16 PCM).
        public func write(_ audio: Data) async { await raw.write(audio) }

        /// Signal end-of-audio. The server will still emit any pending segments.
        public func end() async { await raw.end() }

        /// Hard-terminate the session.
        public func destroy() { raw.destroy() }

        /// Async sequence of transcription events. Single-use.
        public var events: AsyncThrowingStream<TranscribeStreamEvent, Error> {
            let inner = raw.responses
            return AsyncThrowingStream<TranscribeStreamEvent, Error> { continuation in
                let task = Task<Void, Never> {
                    do {
                        for try await response in inner {
                            if let err = response.error {
                                continuation.finish(throwing: QVACError.server(.transcriptionFailed, message: err))
                                return
                            }
                            if let seg = response.segment, let parsed = TranscribeSegment(from: seg) {
                                continuation.yield(.segment(parsed))
                            }
                            if let t = response.text, !t.isEmpty {
                                continuation.yield(.text(t))
                            }
                            if response.done == true {
                                continuation.yield(.done)
                                break
                            }
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
