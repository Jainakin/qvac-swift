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
        /// Voice-activity update emitted when `emitVadEvents` is enabled.
        case vad(JSONValue)
        /// Conversation boundary emitted by Whisper or Parakeet streaming modes.
        case endOfTurn(JSONValue)
        /// Stream finished.
        case done
    }

    /// Open a bidirectional transcription session.
    /// Single-use: iterating the session's `events` more than once throws.
    func transcribeStream(
        modelId: String,
        prompt: String? = nil,
        metadata: Bool = false,
        emitVadEvents: Bool = false,
        endOfTurnSilenceMs: Int? = nil,
        vadRunIntervalMs: Int? = nil,
        parakeetStreamingConfig: JSONValue? = nil,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> TranscribeStreamSession {
        if let endOfTurnSilenceMs, endOfTurnSilenceMs < 0 {
            throw QVACError.invalidArgument("endOfTurnSilenceMs must not be negative")
        }
        if let vadRunIntervalMs, vadRunIntervalMs <= 0 {
            throw QVACError.invalidArgument("vadRunIntervalMs must be positive")
        }
        let requestId = UUID().uuidString
        let req = TranscribeStreamRequest(
            modelId: modelId,
            emitVadEvents: emitVadEvents ? true : nil,
            endOfTurnSilenceMs: endOfTurnSilenceMs,
            metadata: metadata ? true : nil,
            parakeetStreamingConfig: parakeetStreamingConfig,
            prompt: prompt,
            requestId: requestId,
            vadRunIntervalMs: vadRunIntervalMs
        )
        let raw: QVACDuplexSession<TranscribeStreamResponse> = try await duplexTyped(
            .transcribeStream(req),
            rpcOptions: rpcOptions
        )
        return TranscribeStreamSession(requestId: requestId, raw: raw)
    }

    /// Session handle. Write audio via `write(_:)`; iterate `events` for transcripts;
    /// call `end()` to signal you're done sending audio.
    final class TranscribeStreamSession: @unchecked Sendable {
        public let requestId: String
        private let raw: QVACDuplexSession<TranscribeStreamResponse>
        init(requestId: String, raw: QVACDuplexSession<TranscribeStreamResponse>) {
            self.requestId = requestId
            self.raw = raw
        }

        /// Send a chunk of audio bytes. Format depends on the loaded model (Whisper expects
        /// 16 kHz mono int16 PCM).
        public func write(_ audio: Data) async throws { try await raw.write(audio) }

        /// Signal end-of-audio. The server will still emit any pending segments.
        public func end() async throws { try await raw.end() }

        /// Hard-terminate the session.
        public func destroy() { raw.destroy() }

        /// Async sequence of transcription events. Single-use.
        public var events: QVACResponseStream<TranscribeStreamEvent> {
            let inner = raw.responses
            let rawSession = raw
            return QVACClient.pullMap(
                inner,
                operation: "transcribeStream",
                onTermination: { rawSession.destroy() },
                endOfSourceError: {
                    QVACError.client(
                        .streamEndedWithoutResponse,
                        message: "transcribeStream ended without a terminal done frame"
                    )
                }
            ) { response in
                if let error = response.error {
                    throw QVACError.server(.transcriptionFailed, message: error)
                }
                var events: [TranscribeStreamEvent] = []
                if let rawSegment = response.segment {
                    events.append(.segment(try TranscribeSegment(from: rawSegment)))
                }
                if let text = response.text, !text.isEmpty { events.append(.text(text)) }
                if let vad = response.vad { events.append(.vad(vad)) }
                if let endOfTurn = response.endOfTurn { events.append(.endOfTurn(endOfTurn)) }
                if response.done == true {
                    events.append(.done)
                    return .emitThenDrain(events)
                }
                return .emitMany(events)
            }
        }
    }
}
