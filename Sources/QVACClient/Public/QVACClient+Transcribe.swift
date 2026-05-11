// QVAC-206 — transcribe (upfront audio)
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

        init?(from value: JSONValue) {
            guard case .object(let obj) = value else { return nil }
            guard case .string(let t) = obj["text"] ?? .null else { return nil }
            guard case .number(let s) = obj["startMs"] ?? .null else { return nil }
            guard case .number(let e) = obj["endMs"] ?? .null else { return nil }
            let segId: Int = {
                if case .number(let n) = obj["id"] ?? .null { return Int(n) }
                return 0
            }()
            let appendFlag: Bool = {
                if case .bool(let b) = obj["append"] ?? .null { return b }
                return false
            }()
            self.id = segId
            self.text = t
            self.startMs = Int(s)
            self.endMs = Int(e)
            self.append = appendFlag
        }
    }

    /// Plain-text transcribe. Returns the full concatenated transcript once the stream completes.
    func transcribe(modelId: String, audioPath: String, prompt: String? = nil) async throws -> String {
        let request = QVACRequest.transcribe(TranscribeRequest(
            audioChunk: .object(["type": .string("filePath"), "value": .string(audioPath)]),
            modelId: modelId,
            prompt: prompt
        ))
        let stream: AsyncThrowingStream<QVACResponse, Error> = try await streamTyped(request)
        var fullText = ""
        for try await response in stream {
            guard case .transcribe(let r) = response else { continue }
            if let e = r.error { throw QVACError.server(.transcriptionFailed, message: e) }
            if let t = r.text { fullText += t }
            if r.done == true { break }
        }
        return fullText
    }

    /// Metadata transcribe. Returns one `TranscribeSegment` per VAD-detected speech chunk.
    func transcribeWithMetadata(modelId: String, audioPath: String, prompt: String? = nil) async throws -> [TranscribeSegment] {
        var t = TranscribeRequest(
            audioChunk: .object(["type": .string("filePath"), "value": .string(audioPath)]),
            modelId: modelId,
            prompt: prompt
        )
        t.metadata = true
        let stream: AsyncThrowingStream<QVACResponse, Error> = try await streamTyped(.transcribe(t))
        var segments: [TranscribeSegment] = []
        for try await response in stream {
            guard case .transcribe(let r) = response else { continue }
            if let e = r.error { throw QVACError.server(.transcriptionFailed, message: e) }
            if let seg = r.segment, let parsed = TranscribeSegment(from: seg) {
                segments.append(parsed)
            }
            if r.done == true { break }
        }
        return segments
    }

    /// Bytes-form transcribe — base64-encodes the audio on the wire.
    func transcribe(modelId: String, audioBytes: Data, prompt: String? = nil) async throws -> String {
        let request = QVACRequest.transcribe(TranscribeRequest(
            audioChunk: .object(["type": .string("base64"), "value": .string(audioBytes.base64EncodedString())]),
            modelId: modelId,
            prompt: prompt
        ))
        let stream: AsyncThrowingStream<QVACResponse, Error> = try await streamTyped(request)
        var fullText = ""
        for try await response in stream {
            guard case .transcribe(let r) = response else { continue }
            if let e = r.error { throw QVACError.server(.transcriptionFailed, message: e) }
            if let t = r.text { fullText += t }
            if r.done == true { break }
        }
        return fullText
    }
}
