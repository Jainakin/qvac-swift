// Completion operations.

import Foundation

public extension QVACClient {
    /// File attachment supplied to a multimodal completion message.
    struct ChatAttachment: Codable, Sendable, Equatable {
        /// Absolute or SDK-resolvable path understood by the worker.
        public var path: String

        public init(path: String) {
            self.path = path
        }
    }

    struct ChatMessage: Codable, Sendable, Equatable {
        public var role: String
        public var content: String
        public var attachments: [ChatAttachment]?

        public init(
            role: String,
            content: String,
            attachments: [ChatAttachment]? = nil
        ) {
            self.role = role
            self.content = content
            self.attachments = attachments
        }

        public static func user(
            _ value: String,
            attachments: [ChatAttachment]? = nil
        ) -> Self {
            .init(role: "user", content: value, attachments: attachments)
        }

        public static func assistant(
            _ value: String,
            attachments: [ChatAttachment]? = nil
        ) -> Self {
            .init(role: "assistant", content: value, attachments: attachments)
        }

        public static func system(
            _ value: String,
            attachments: [ChatAttachment]? = nil
        ) -> Self {
            .init(role: "system", content: value, attachments: attachments)
        }

        var wireValue: JSONValue {
            var object: [String: JSONValue] = [
                "role": .string(role),
                "content": .string(content),
            ]
            if let attachments {
                object["attachments"] = .array(attachments.map { attachment in
                    .object(["path": .string(attachment.path)])
                })
            }
            return .object(object)
        }
    }

    enum CompletionToolDialect: String, Codable, Sendable, Equatable, CaseIterable {
        case hermes
        case pythonic
        case json
        case harmony
        case qwen35
        case gemma4
        case dsml
    }

    enum CompletionBackendDevice: String, Codable, Sendable, Equatable {
        case cpu
        case gpu
    }

    struct CompletionStats: Sendable, Equatable {
        public let timeToFirstToken: Double?
        public let tokensPerSecond: Double?
        public let cacheTokens: Double?
        public let promptTokens: Double?
        public let generatedTokens: Double?
        public let emittedTokens: Double?
        public let avgConcurrentSeq: Double?
        public let backendDevice: CompletionBackendDevice?

        init(wire: JSONValue) throws {
            guard case .object(let object) = wire else {
                throw QVACError.protocolViolation("completionStats must be an object")
            }
            func number(_ key: String) throws -> Double? {
                guard let value = object[key] else { return nil }
                guard case .number(let number) = value else {
                    throw QVACError.protocolViolation("completionStats.\(key) must be a number")
                }
                return number
            }
            timeToFirstToken = try number("timeToFirstToken")
            tokensPerSecond = try number("tokensPerSecond")
            cacheTokens = try number("cacheTokens")
            promptTokens = try number("promptTokens")
            generatedTokens = try number("generatedTokens")
            emittedTokens = try number("emittedTokens")
            avgConcurrentSeq = try number("avgConcurrentSeq")
            if let value = object["backendDevice"] {
                guard case .string(let raw) = value,
                      let device = CompletionBackendDevice(rawValue: raw) else {
                    throw QVACError.protocolViolation(
                        "completionStats.backendDevice must be cpu or gpu"
                    )
                }
                backendDevice = device
            } else {
                backendDevice = nil
            }
        }
    }

    struct CompletionToolCall: Sendable, Equatable {
        public let id: String
        public let name: String
        public let arguments: [String: JSONValue]
        public let raw: String?

        init(wire: JSONValue) throws {
            guard case .object(let object) = wire,
                  case .string(let id) = object["id"] ?? .null,
                  case .string(let name) = object["name"] ?? .null,
                  case .object(let arguments) = object["arguments"] ?? .null else {
                throw QVACError.protocolViolation("completion toolCall has an invalid shape")
            }
            if let rawValue = object["raw"] {
                guard case .string(let raw) = rawValue else {
                    throw QVACError.protocolViolation("completion toolCall.raw must be a string")
                }
                self.raw = raw
            } else {
                self.raw = nil
            }
            self.id = id
            self.name = name
            self.arguments = arguments
        }
    }

    struct CompletionToolError: Sendable, Equatable {
        public enum Code: String, Sendable, Equatable {
            case parseError = "PARSE_ERROR"
            case validationError = "VALIDATION_ERROR"
            case unknownTool = "UNKNOWN_TOOL"
        }

        public let code: Code
        public let message: String
        public let raw: String?

        init(wire: JSONValue) throws {
            guard case .object(let object) = wire,
                  case .string(let rawCode) = object["code"] ?? .null,
                  let code = Code(rawValue: rawCode),
                  case .string(let message) = object["message"] ?? .null else {
                throw QVACError.protocolViolation("completion toolError has an invalid shape")
            }
            if let rawValue = object["raw"] {
                guard case .string(let raw) = rawValue else {
                    throw QVACError.protocolViolation("completion toolError.raw must be a string")
                }
                self.raw = raw
            } else {
                self.raw = nil
            }
            self.code = code
            self.message = message
        }
    }

    enum CompletionStopReason: String, Sendable, Equatable {
        case eos
        case length
        case stopSequence
        case cancelled
    }

    enum CompletionEvent: Sendable, Equatable {
        case contentDelta(seq: Int, text: String)
        case rawDelta(seq: Int, text: String)
        case thinkingDelta(seq: Int, text: String)
        case toolCall(seq: Int, call: CompletionToolCall)
        case toolError(seq: Int, error: CompletionToolError)
        case stats(seq: Int, stats: CompletionStats)
        case done(seq: Int, stopReason: CompletionStopReason?, rawFullText: String?)
        case failure(seq: Int, message: String, rawFullText: String?)

        init(wire: JSONValue) throws {
            guard case .object(let object) = wire,
                  case .string(let type) = object["type"] ?? .null,
                  case .number(let sequence) = object["seq"] ?? .null else {
                throw QVACError.protocolViolation(
                    "completion event requires a non-negative integer seq and type"
                )
            }
            let seq = try QVACClient.checkedWireInteger(sequence, field: "completion event.seq")
            guard seq >= 0 else {
                throw QVACError.protocolViolation(
                    "completion event requires a non-negative integer seq and type"
                )
            }
            switch type {
            case "contentDelta":
                guard case .string(let text) = object["text"] ?? .null else {
                    throw QVACError.protocolViolation("contentDelta.text must be a string")
                }
                self = .contentDelta(seq: seq, text: text)
            case "rawDelta":
                guard case .string(let text) = object["text"] ?? .null else {
                    throw QVACError.protocolViolation("rawDelta.text must be a string")
                }
                self = .rawDelta(seq: seq, text: text)
            case "thinkingDelta":
                guard case .string(let text) = object["text"] ?? .null else {
                    throw QVACError.protocolViolation("thinkingDelta.text must be a string")
                }
                self = .thinkingDelta(seq: seq, text: text)
            case "toolCall":
                self = .toolCall(
                    seq: seq,
                    call: try CompletionToolCall(wire: object["call"] ?? .null)
                )
            case "toolError":
                self = .toolError(
                    seq: seq,
                    error: try CompletionToolError(wire: object["error"] ?? .null)
                )
            case "completionStats":
                self = .stats(
                    seq: seq,
                    stats: try CompletionStats(wire: object["stats"] ?? .null)
                )
            case "completionDone":
                let rawFullText = try Self.rawFullText(from: object["raw"])
                if case .string("error") = object["stopReason"] ?? .null {
                    guard case .object(let error) = object["error"] ?? .null,
                          case .string(let message) = error["message"] ?? .null else {
                        throw QVACError.protocolViolation(
                            "error completionDone requires error.message"
                        )
                    }
                    self = .failure(seq: seq, message: message, rawFullText: rawFullText)
                    return
                }
                var reason: CompletionStopReason?
                if let value = object["stopReason"] {
                    guard case .string(let raw) = value,
                          let parsed = CompletionStopReason(rawValue: raw) else {
                        throw QVACError.protocolViolation(
                            "completionDone.stopReason is not a 0.17 value"
                        )
                    }
                    reason = parsed
                }
                self = .done(seq: seq, stopReason: reason, rawFullText: rawFullText)
            default:
                throw QVACError.protocolViolation("unknown 0.17 completion event \(type)")
            }
        }

        private static func rawFullText(from wire: JSONValue?) throws -> String? {
            guard let wire else { return nil }
            guard case .object(let object) = wire,
                  case .string(let fullText) = object["fullText"] ?? .null else {
                throw QVACError.protocolViolation("completionDone.raw.fullText must be a string")
            }
            return fullText
        }
    }

    /// Raw terminal text reported by the 0.17 completion response.
    struct CompletionRawOutput: Sendable, Equatable {
        /// Full worker-assembled output, including any protocol-level markup.
        public let fullText: String
    }

    /// Aggregated terminal state for one completion invocation.
    struct CompletionFinal: Sendable, Equatable {
        /// Normalized assistant content, excluding captured reasoning text.
        public let contentText: String
        /// Captured reasoning text when `captureThinking` was enabled.
        public let thinkingText: String?
        /// Completed tool calls emitted by the model.
        public let toolCalls: [CompletionToolCall]
        /// Worker timing/token statistics, when supplied by the backend.
        public let stats: CompletionStats?
        /// Why generation ended, including `.cancelled` and `.length`.
        public let stopReason: CompletionStopReason?
        /// Raw output preserved from the worker's terminal event.
        public let raw: CompletionRawOutput
        /// Assistant content suitable for a subsequent cached conversation turn.
        public let cacheableAssistantContent: String?
    }

    /// Aggregate state retained when a completion is cancelled before success.
    ///
    /// Every field is optional because cancellation may win before the first
    /// event. A later cancellation normally includes accumulated text and tool
    /// calls, plus statistics when the worker emitted them before its terminal
    /// cancelled event.
    struct InferenceCancelledPartial: Sendable, Equatable {
        public let text: String?
        public let toolCalls: [CompletionToolCall]?
        public let stats: CompletionStats?

        public init(
            text: String? = nil,
            toolCalls: [CompletionToolCall]? = nil,
            stats: CompletionStats? = nil
        ) {
            self.text = text
            self.toolCalls = toolCalls
            self.stats = stats
        }
    }

    /// Live and aggregated views of a single completion request.
    ///
    /// `requestId` can be passed to ``cancel(_:rpcOptions:)``. The event stream ends
    /// normally with a cancelled terminal event, while aggregate tasks reject with
    /// ``QVACError/inferenceCancelled(requestId:partial:)``, which retains the
    /// request id and partial aggregate. Event/token/tool fan-outs are bounded
    /// observational views; ``final`` remains the authoritative result.
    final class CompletionRun: @unchecked Sendable {
        /// Stable client-generated identifier carried on the wire.
        public let requestId: String
        /// Normalized completion events in worker order.
        public let events: QVACBufferedStream<CompletionEvent>
        /// Authoritative aggregated terminal result.
        public let final: Task<CompletionFinal, Error>
        /// Convenience stream containing only assistant-content deltas.
        public let tokenStream: QVACBufferedStream<String>
        /// Convenience stream containing completed tool calls.
        public let toolCallStream: QVACBufferedStream<CompletionToolCall>
        /// Convenience task resolving to normalized assistant text.
        public let text: Task<String, Error>
        /// Convenience task resolving to all completed tool calls.
        public let toolCalls: Task<[CompletionToolCall], Error>
        /// Convenience task resolving to terminal worker statistics.
        public let stats: Task<CompletionStats?, Error>

        init(
            requestId: String,
            events: QVACBufferedStream<CompletionEvent>,
            final: Task<CompletionFinal, Error>,
            tokenStream: QVACBufferedStream<String>,
            toolCallStream: QVACBufferedStream<CompletionToolCall>,
            text: Task<String, Error>,
            toolCalls: Task<[CompletionToolCall], Error>,
            stats: Task<CompletionStats?, Error>
        ) {
            self.requestId = requestId
            self.events = events
            self.final = final
            self.tokenStream = tokenStream
            self.toolCallStream = toolCallStream
            self.text = text
            self.toolCalls = toolCalls
            self.stats = stats
        }
    }

    /// Run a QVAC 0.17 completion and expose live events plus aggregate tasks.
    ///
    /// The request id is available as soon as this method returns, so callers can
    /// issue targeted cancellation without waiting for a decoded token. Supply an
    /// explicit `rpcOptions.timeout` to override the 60-second default inactivity
    /// deadline, or pass `nil` when another watchdog bounds the operation.
    func completion(
        modelId: String,
        history: [ChatMessage],
        stream: Bool = true,
        generationParams: JSONValue? = nil,
        tools: [JSONValue]? = nil,
        kvCache: JSONValue? = nil,
        captureThinking: Bool = false,
        emitRawDeltas: Bool = false,
        toolDialect: CompletionToolDialect? = nil,
        responseFormat: JSONValue? = nil,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> CompletionRun {
        try Self.validateCompletionResponseFormat(
            responseFormat,
            hasTools: tools?.isEmpty == false,
            context: "completion"
        )
        let historyWire = history.map(\.wireValue)
        let requestId = UUID().uuidString
        var request = CompletionStreamRequest(
            history: historyWire,
            modelId: modelId,
            stream: stream
        )
        request.requestId = requestId
        request.generationParams = generationParams
        request.tools = tools?.isEmpty == true ? nil : tools
        request.kvCache = kvCache
        request.captureThinking = captureThinking ? true : nil
        request.emitRawDeltas = emitRawDeltas ? true : nil
        request.toolDialect = toolDialect?.rawValue
        request.responseFormat = responseFormat

        let source: QVACResponseStream<QVACResponse> = try await streamTyped(
            .completionStream(request),
            rpcOptions: rpcOptions
        )
        let maximumBufferedStreamBytes = self.maximumBufferedStreamBytes
        let (events, eventSink) = Self.makeBufferedStream(
            of: CompletionEvent.self,
            name: "completion.events",
            maximumBufferedBytes: maximumBufferedStreamBytes
        )
        let (tokens, tokenSink) = Self.makeBufferedStream(
            of: String.self,
            name: "completion.tokenStream",
            maximumBufferedBytes: maximumBufferedStreamBytes
        )
        let (toolStream, toolSink) = Self.makeBufferedStream(
            of: CompletionToolCall.self,
            name: "completion.toolCallStream",
            maximumBufferedBytes: maximumBufferedStreamBytes
        )

        let final = Task<CompletionFinal, Error> {
            var contentText = ""
            var thinkingText = ""
            var toolCalls: [CompletionToolCall] = []
            var stats: CompletionStats?
            var stopReason: CompletionStopReason?
            var rawFullText: String?
            var terminalError: String?
            var receivedTerminalFrame = false
            do {
                let responses = QVACResponseStreamIteratorBox(source)
                while let response = try await responses.next() {
                    if case .error(let error) = response {
                        return try await Self.resolveResponseStreamTerminal(
                            responses,
                            operation: "completionStream"
                        ) { () throws -> CompletionFinal in
                            throw QVACError.fromWire(
                                code: try Self.checkedWireErrorCode(error.code),
                                message: error.message
                            )
                        }
                    }
                    guard case .completionStream(let frame) = response else {
                        throw QVACError.protocolViolation(
                            "completionStream returned \(response.discriminator)"
                        )
                    }
                    let parsedEvents: [CompletionEvent]
                    let terminalValidation: Result<[CompletionEvent], Error>?
                    if frame.done == true {
                        let validation = Result<[CompletionEvent], Error> {
                            try frame.events.map(CompletionEvent.init(wire:))
                        }
                        terminalValidation = validation
                        parsedEvents = (try? validation.get()) ?? []
                    } else {
                        terminalValidation = nil
                        parsedEvents = try frame.events.map(CompletionEvent.init(wire:))
                    }
                    let estimatedFrameBytes = Self.conservativeBufferedJSONBytes(
                        frame.events,
                        elementCount: frame.events.count,
                        fallback: maximumBufferedStreamBytes
                    )
                    var frameTokens: [String] = []
                    var frameToolCalls: [CompletionToolCall] = []
                    for event in parsedEvents {
                        switch event {
                        case .contentDelta(_, let text):
                            contentText += text
                            if stream { frameTokens.append(text) }
                        case .thinkingDelta(_, let text):
                            thinkingText += text
                        case .toolCall(_, let call):
                            toolCalls.append(call)
                            if stream { frameToolCalls.append(call) }
                        case .stats(_, let value):
                            stats = value
                        case .done(_, let reason, let raw):
                            stopReason = reason
                            if let raw { rawFullText = raw }
                        case .failure(_, let message, let raw):
                            terminalError = message
                            if let raw { rawFullText = raw }
                        case .rawDelta, .toolError:
                            break
                        }
                    }
                    eventSink.yield(
                        contentsOf: parsedEvents,
                        estimatedBytes: estimatedFrameBytes
                    )
                    if stream {
                        tokenSink.yield(
                            contentsOf: frameTokens,
                            estimatedBytes: estimatedFrameBytes
                        )
                        toolSink.yield(
                            contentsOf: frameToolCalls,
                            estimatedBytes: estimatedFrameBytes
                        )
                    }
                    if frame.done == true {
                        let validation = terminalValidation ?? .failure(
                            QVACError.protocolViolation(
                                "completionStream terminal validation was not captured"
                            )
                        )
                        _ = try await Self.resolveResponseStreamTerminal(
                            responses,
                            operation: "completionStream"
                        ) {
                            try validation.get()
                        }
                        receivedTerminalFrame = true
                        break
                    }
                }
                guard receivedTerminalFrame else {
                    throw QVACError.client(
                        .streamEndedWithoutResponse,
                        message: "completionStream ended without a terminal done frame"
                    )
                }
                eventSink.finish()
                tokenSink.finish()
                toolSink.finish()
                let fullText = rawFullText ?? contentText
                let result = CompletionFinal(
                    contentText: contentText,
                    thinkingText: thinkingText.isEmpty ? nil : thinkingText,
                    toolCalls: toolCalls,
                    stats: stats,
                    stopReason: stopReason,
                    raw: .init(fullText: fullText),
                    cacheableAssistantContent: toolCalls.isEmpty
                        ? Self.normalizeAssistantCacheContent(fullText)
                        : nil
                )
                if let terminalError {
                    throw QVACError.server(.completionFailed, message: terminalError)
                }
                if stopReason == .cancelled {
                    throw QVACError.inferenceCancelled(
                        requestId: requestId,
                        partial: .init(
                            text: result.contentText,
                            toolCalls: result.toolCalls,
                            stats: result.stats
                        )
                    )
                }
                return result
            } catch {
                eventSink.finish(throwing: error)
                tokenSink.finish(throwing: error)
                toolSink.finish(throwing: error)
                throw error
            }
        }
        let text = Task<String, Error> { try await final.value.contentText }
        let finalToolCalls = Task<[CompletionToolCall], Error> { try await final.value.toolCalls }
        let finalStats = Task<CompletionStats?, Error> { try await final.value.stats }
        return CompletionRun(
            requestId: requestId,
            events: events,
            final: final,
            tokenStream: tokens,
            toolCallStream: toolStream,
            text: text,
            toolCalls: finalToolCalls,
            stats: finalStats
        )
    }

    internal static func normalizeAssistantCacheContent(_ content: String) -> String {
        let paired = content.replacingOccurrences(
            of: "(?is)<think>.*?</think>",
            with: "",
            options: .regularExpression
        )
        let unclosed = paired.replacingOccurrences(
            of: "(?is)<think>.*$",
            with: "",
            options: .regularExpression
        )
        return unclosed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Validate the executable 0.17 response-format schema at the rich API
    /// boundary. Free-form text may be combined with tools; structured JSON
    /// formats may not, because tool schemas already constrain model output.
    internal static func validateCompletionResponseFormat(
        _ responseFormat: JSONValue?,
        hasTools: Bool,
        context: String
    ) throws {
        guard let responseFormat else { return }
        guard case .object(let object) = responseFormat,
              case .string(let type) = object["type"] ?? .null else {
            throw QVACError.invalidArgument(
                "\(context) responseFormat must be an object with a string type"
            )
        }

        switch type {
        case "text", "json_object":
            guard Set(object.keys) == ["type"] else {
                throw QVACError.invalidArgument(
                    "\(context) responseFormat type \(type) does not accept extra fields"
                )
            }
        case "json_schema":
            guard Set(object.keys) == ["type", "json_schema"],
                  case .object(let schemaObject) = object["json_schema"] ?? .null,
                  case .string(let name) = schemaObject["name"] ?? .null,
                  !name.isEmpty,
                  case .object = schemaObject["schema"] ?? .null,
                  Set(schemaObject.keys).isSubset(of: [
                      "name", "description", "schema", "strict",
                  ]) else {
                throw QVACError.invalidArgument(
                    "\(context) json_schema responseFormat has an invalid shape"
                )
            }
            if let description = schemaObject["description"],
               case .string = description {
                // Valid optional description.
            } else if schemaObject["description"] != nil {
                throw QVACError.invalidArgument(
                    "\(context) responseFormat json_schema.description must be a string"
                )
            }
            if let strict = schemaObject["strict"], case .bool = strict {
                // Valid optional strict marker.
            } else if schemaObject["strict"] != nil {
                throw QVACError.invalidArgument(
                    "\(context) responseFormat json_schema.strict must be a boolean"
                )
            }
        default:
            throw QVACError.invalidArgument(
                "\(context) responseFormat.type must be text, json_object, or json_schema"
            )
        }

        if hasTools, type != "text" {
            throw QVACError.invalidArgument(
                "\(context) structured responseFormat cannot be combined with tools"
            )
        }
    }
}
