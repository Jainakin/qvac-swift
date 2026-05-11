// QVAC-204 — completion
//
// Streaming LLM completion. The worker emits an NDJSON stream of `completionStream`
// frames, each carrying a list of `events`. Event shapes (delta, toolCall, stats, done)
// are heterogeneous — we keep them as `JSONValue` in the generated type and unpack on
// demand.
//
// Public API:
//   completion(modelId:history:…) returns `CompletionRun` with:
//     – `events`: full event stream (every delta, tool call, stats frame)
//     – `tokenStream`: ergonomic sugar — text-only deltas yielded as Swift Strings
//     – `final`: the terminal frame (carrying stats + finish reason)

import Foundation

public extension QVACClient {

    /// A single message in a chat history. Wire shape: `{role: "user"|"assistant"|"system", content: "…"}`.
    struct ChatMessage: Codable, Sendable, Equatable {
        public var role: String
        public var content: String
        public init(role: String, content: String) {
            self.role = role; self.content = content
        }
        public static func user(_ s: String)      -> Self { .init(role: "user", content: s) }
        public static func assistant(_ s: String) -> Self { .init(role: "assistant", content: s) }
        public static func system(_ s: String)    -> Self { .init(role: "system", content: s) }
    }

    /// An event yielded by `CompletionRun.events`.
    enum CompletionEvent: Sendable, Equatable {
        case contentDelta(String)
        case thinkingDelta(String)
        case toolCall(JSONValue)
        case stats(JSONValue)
        case done(JSONValue)
        /// Forward-compatibility for event shapes we don't know about yet.
        case unknown(type: String, raw: JSONValue)

        init?(from raw: JSONValue) {
            guard case .object(let obj) = raw,
                  case .string(let type) = obj["type"] ?? .null else { return nil }
            switch type {
            case "contentDelta":
                if case .string(let s) = obj["text"] ?? .null { self = .contentDelta(s); return }
                if case .string(let s) = obj["delta"] ?? .null { self = .contentDelta(s); return }
                self = .unknown(type: type, raw: raw)
            case "thinkingDelta":
                if case .string(let s) = obj["text"] ?? .null { self = .thinkingDelta(s); return }
                if case .string(let s) = obj["delta"] ?? .null { self = .thinkingDelta(s); return }
                self = .unknown(type: type, raw: raw)
            case "toolCall":          self = .toolCall(raw)
            case "completionStats":   self = .stats(raw)
            case "completionDone":    self = .done(raw)
            default:                  self = .unknown(type: type, raw: raw)
            }
        }
    }

    /// Result of a `completion(…)` call. Consume `events` (or the sugar `tokenStream`)
    /// to receive incremental output. The `final` task resolves once the stream completes.
    final class CompletionRun: @unchecked Sendable {
        public let events: AsyncThrowingStream<CompletionEvent, Error>
        public let tokenStream: AsyncThrowingStream<String, Error>
        public let final: Task<JSONValue?, Error>

        init(
            events: AsyncThrowingStream<CompletionEvent, Error>,
            tokenStream: AsyncThrowingStream<String, Error>,
            final: Task<JSONValue?, Error>
        ) {
            self.events = events
            self.tokenStream = tokenStream
            self.final = final
        }
    }

    /// Run a streaming completion. The returned `CompletionRun` gives you three views:
    /// raw events, just-the-text sugar, and a final stats payload.
    func completion(
        modelId: String,
        history: [ChatMessage],
        generationParams: JSONValue? = nil,
        captureThinking: Bool = false
    ) async throws -> CompletionRun {
        let historyJSON: [JSONValue] = history.map { msg in
            .object([
                "role": .string(msg.role),
                "content": .string(msg.content),
            ])
        }
        var req = CompletionStreamRequest(history: historyJSON, modelId: modelId, stream: true)
        req.generationParams = generationParams
        if captureThinking { req.captureThinking = true }

        let typedStream: AsyncThrowingStream<QVACResponse, Error> = try await streamTyped(.completionStream(req))

        let (events, eventsCont) = Self.makeStream(of: CompletionEvent.self)
        let (tokens, tokensCont) = Self.makeStream(of: String.self)
        let finalTask = Task<JSONValue?, Error> {
            var lastDone: JSONValue?
            do {
                for try await response in typedStream {
                    guard case .completionStream(let frame) = response else {
                        if case .error(let e) = response {
                            throw QVACError.fromWire(code: Int(e.code ?? 0), message: e.message)
                        }
                        continue // forward-compat: ignore unknown response types in the stream
                    }
                    for rawEvent in frame.events {
                        guard let ev = CompletionEvent(from: rawEvent) else { continue }
                        eventsCont.yield(ev)
                        switch ev {
                        case .contentDelta(let s): tokensCont.yield(s)
                        case .done(let v):         lastDone = v
                        default: break
                        }
                    }
                    if frame.done == true { break }
                }
                eventsCont.finish()
                tokensCont.finish()
                return lastDone
            } catch {
                eventsCont.finish(throwing: error)
                tokensCont.finish(throwing: error)
                throw error
            }
        }

        return CompletionRun(events: events, tokenStream: tokens, final: finalTask)
    }
}
