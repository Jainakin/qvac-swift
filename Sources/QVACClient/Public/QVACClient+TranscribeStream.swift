// Bidirectional transcription streaming.
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
    ///
    /// `parakeetStreamingConfig` follows the exact QVAC 0.17 object schema.
    /// Positive integer fields are `chunkMs`, `historyMs`, `spkCacheLen`,
    /// `fifoLen`, and `spkCacheUpdatePeriod`. Nonnegative integer fields are
    /// `leftContextMs`, `rightLookaheadMs`, `chunkLeftContextMs`, and
    /// `chunkRightContextMs`. `emitPartials`, `emitEnergyVad`, and
    /// `spkCacheEnable` are Boolean.
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
        try Self.validateParakeetStreamingConfig(parakeetStreamingConfig)
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

    private static func validateParakeetStreamingConfig(_ config: JSONValue?) throws {
        guard let config else { return }
        guard case .object(let fields) = config else {
            throw QVACError.invalidArgument(
                "parakeetStreamingConfig must be an object"
            )
        }

        let positiveIntegerFields = [
            "chunkMs", "historyMs", "spkCacheLen", "fifoLen", "spkCacheUpdatePeriod",
        ]
        let nonnegativeIntegerFields = [
            "leftContextMs", "rightLookaheadMs", "chunkLeftContextMs",
            "chunkRightContextMs",
        ]
        let booleanFields = ["emitPartials", "emitEnergyVad", "spkCacheEnable"]

        for name in positiveIntegerFields {
            guard let value = fields[name] else { continue }
            guard case .number(let number) = value,
                  number.isFinite,
                  number.rounded(.towardZero) == number,
                  number > 0 else {
                throw QVACError.invalidArgument(
                    "parakeetStreamingConfig.\(name) must be a finite positive integer"
                )
            }
        }
        for name in nonnegativeIntegerFields {
            guard let value = fields[name] else { continue }
            guard case .number(let number) = value,
                  number.isFinite,
                  number.rounded(.towardZero) == number,
                  number >= 0 else {
                throw QVACError.invalidArgument(
                    "parakeetStreamingConfig.\(name) must be a finite nonnegative integer"
                )
            }
        }
        for name in booleanFields {
            guard let value = fields[name] else { continue }
            guard case .bool = value else {
                throw QVACError.invalidArgument(
                    "parakeetStreamingConfig.\(name) must be a Boolean"
                )
            }
        }
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
                    return .failThenDrain(
                        QVACError.server(.transcriptionFailed, message: error)
                    )
                }
                if response.done == true {
                    do {
                        var terminalEvents: [TranscribeStreamEvent] = []
                        if let rawSegment = response.segment {
                            terminalEvents.append(.segment(
                                try TranscribeSegment(from: rawSegment)
                            ))
                        }
                        if let text = response.text, !text.isEmpty {
                            terminalEvents.append(.text(text))
                        }
                        if let vad = response.vad {
                            terminalEvents.append(.vad(try QVACClient.validatedVadEvent(vad)))
                        }
                        if let endOfTurn = response.endOfTurn {
                            terminalEvents.append(.endOfTurn(
                                try QVACClient.validatedEndOfTurnEvent(endOfTurn)
                            ))
                        }
                        terminalEvents.append(.done)
                        return .emitThenDrain(terminalEvents)
                    } catch let error as QVACError {
                        return .failThenDrain(error)
                    } catch {
                        return .failThenDrain(.protocolViolation(
                            "transcribeStream returned a malformed terminal frame: \(error)"
                        ))
                    }
                }
                var events: [TranscribeStreamEvent] = []
                if let rawSegment = response.segment {
                    events.append(.segment(try TranscribeSegment(from: rawSegment)))
                }
                if let text = response.text, !text.isEmpty { events.append(.text(text)) }
                if let vad = response.vad {
                    events.append(.vad(try QVACClient.validatedVadEvent(vad)))
                }
                if let endOfTurn = response.endOfTurn {
                    events.append(.endOfTurn(
                        try QVACClient.validatedEndOfTurnEvent(endOfTurn)
                    ))
                }
                return .emitMany(events)
            }
        }
    }

    private static func validatedVadEvent(_ value: JSONValue) throws -> JSONValue {
        guard case .object(let fields) = value,
              case .bool(let speaking) = fields["speaking"] ?? .null,
              case .number(let probability) = fields["probability"] ?? .null,
              probability.isFinite else {
            throw QVACError.protocolViolation(
                "transcribeStream vad must contain Boolean speaking and finite numeric probability"
            )
        }
        return .object([
            "speaking": .bool(speaking),
            "probability": .number(probability),
        ])
    }

    private static func validatedEndOfTurnEvent(_ value: JSONValue) throws -> JSONValue {
        guard case .object(let fields) = value,
              case .string(let source) = fields["source"] ?? .null else {
            throw QVACError.protocolViolation(
                "transcribeStream endOfTurn must identify a canonical source"
            )
        }
        switch source {
        case "parakeet":
            return .object(["source": .string("parakeet")])
        case "whisper":
            guard case .number(let silenceDurationMs) =
                    fields["silenceDurationMs"] ?? .null,
                  silenceDurationMs.isFinite else {
                throw QVACError.protocolViolation(
                    "transcribeStream whisper endOfTurn requires finite silenceDurationMs"
                )
            }
            return .object([
                "source": .string("whisper"),
                "silenceDurationMs": .number(silenceDurationMs),
            ])
        default:
            throw QVACError.protocolViolation(
                "transcribeStream endOfTurn source must be whisper or parakeet"
            )
        }
    }
}
