// Transcription from complete audio input.
//
// Streams transcription back as the worker processes the supplied audio. Two output
// styles match the JS API:
//   • plain — concatenated text
//   • metadata — segments with start/end timestamps
//
// Audio is supplied either as a file path the worker can read, or as in-memory bytes
// (encoded base64 on the wire).

import Foundation

public extension QVACClient {

    /// A transcribed segment with timing metadata. Matches the JS `TranscribeSegment` shape.
    struct TranscribeSegment: Sendable, Equatable {
        public var id: Int
        public var text: String
        public var startMs: Int
        public var endMs: Int
        public var append: Bool

        init(from value: JSONValue) throws {
            guard case .object(let obj) = value,
                  case .string(let t) = obj["text"] ?? .null,
                  case .number(let s) = obj["startMs"] ?? .null,
                  case .number(let e) = obj["endMs"] ?? .null else {
                throw QVACError.protocolViolation("transcribe segment has an invalid shape")
            }
            let segId: Int
            if case .number(let n) = obj["id"] ?? .null {
                segId = try QVACClient.checkedWireInteger(n, field: "transcribe segment.id")
            } else {
                segId = 0
            }
            let appendFlag: Bool = {
                if case .bool(let b) = obj["append"] ?? .null { return b }
                return false
            }()
            self.id = segId
            self.text = t
            self.startMs = try QVACClient.checkedWireInteger(
                s, field: "transcribe segment.startMs"
            )
            self.endMs = try QVACClient.checkedWireInteger(
                e, field: "transcribe segment.endMs"
            )
            self.append = appendFlag
        }
    }

    /// Aggregated result of an upfront-audio transcription.
    struct TranscriptionOutcome: Sendable, Equatable {
        public let text: String
        public let segments: [TranscribeSegment]
        public let stats: JSONValue?
    }

    /// A cancellable 0.17 transcription. The request id is available before the
    /// stream resolves, matching the published SDK's decorated-promise contract.
    final class TranscriptionRun: @unchecked Sendable {
        public let requestId: String
        public let result: Task<TranscriptionOutcome, Error>

        init(requestId: String, result: Task<TranscriptionOutcome, Error>) {
            self.requestId = requestId
            self.result = result
        }
    }

    /// Plain-text transcribe. Returns the full concatenated transcript once the stream completes.
    func transcribe(
        modelId: String,
        audioPath: String,
        prompt: String? = nil,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> TranscriptionRun {
        try await transcribeRun(
            modelId: modelId,
            audioChunk: .object(["type": .string("filePath"), "value": .string(audioPath)]),
            prompt: prompt,
            metadata: false,
            rpcOptions: rpcOptions
        )
    }

    /// Metadata transcribe. Returns one `TranscribeSegment` per VAD-detected speech chunk.
    func transcribeWithMetadata(
        modelId: String,
        audioPath: String,
        prompt: String? = nil,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> TranscriptionRun {
        try await transcribeRun(
            modelId: modelId,
            audioChunk: .object(["type": .string("filePath"), "value": .string(audioPath)]),
            prompt: prompt,
            metadata: true,
            rpcOptions: rpcOptions
        )
    }

    /// Bytes-form transcribe — base64-encodes the audio on the wire.
    func transcribe(
        modelId: String,
        audioBytes: Data,
        prompt: String? = nil,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> TranscriptionRun {
        try await transcribeRun(
            modelId: modelId,
            audioChunk: .object(["type": .string("base64"), "value": .string(audioBytes.base64EncodedString())]),
            prompt: prompt,
            metadata: false,
            rpcOptions: rpcOptions
        )
    }

    private func transcribeRun(
        modelId: String,
        audioChunk: JSONValue,
        prompt: String?,
        metadata: Bool,
        rpcOptions: QVACRPCOptions
    ) async throws -> TranscriptionRun {
        let requestId = UUID().uuidString
        let request = TranscribeRequest(
            audioChunk: audioChunk,
            modelId: modelId,
            metadata: metadata ? true : nil,
            prompt: prompt,
            requestId: requestId
        )
        let stream: QVACResponseStream<QVACResponse> = try await streamTyped(
            .transcribe(request),
            rpcOptions: rpcOptions
        )
        let result = Task<TranscriptionOutcome, Error> {
            var fullText = ""
            var segments: [TranscribeSegment] = []
            var stats: JSONValue?
            let responses = QVACResponseStreamIteratorBox(stream)
            while let response = try await responses.next() {
                if case .error(let error) = response {
                    return try await Self.resolveResponseStreamTerminal(
                        responses,
                        operation: "transcribe"
                    ) { () throws -> TranscriptionOutcome in
                        throw QVACError.fromWire(
                            code: try Self.checkedWireErrorCode(error.code),
                            message: error.message
                        )
                    }
                }
                guard case .transcribe(let frame) = response else {
                    try Self.rejectUnexpectedResponse(response, expected: "transcribe")
                }
                if frame.done == true || frame.error != nil {
                    return try await Self.resolveResponseStreamTerminal(
                        responses,
                        operation: "transcribe"
                    ) {
                        if let error = frame.error {
                            throw QVACError.server(.transcriptionFailed, message: error)
                        }
                        var terminalText = fullText
                        var terminalSegments = segments
                        var terminalStats = stats
                        if let text = frame.text { terminalText += text }
                        if let rawSegment = frame.segment {
                            terminalSegments.append(try TranscribeSegment(from: rawSegment))
                        }
                        if let responseStats = frame.stats { terminalStats = responseStats }
                        return TranscriptionOutcome(
                            text: terminalText,
                            segments: terminalSegments,
                            stats: terminalStats
                        )
                    }
                }
                if let text = frame.text { fullText += text }
                if let rawSegment = frame.segment {
                    segments.append(try TranscribeSegment(from: rawSegment))
                }
                if let responseStats = frame.stats { stats = responseStats }
            }
            throw QVACError.client(
                .streamEndedWithoutResponse,
                message: "transcribe ended without a terminal done frame"
            )
        }
        return TranscriptionRun(requestId: requestId, result: result)
    }
}
