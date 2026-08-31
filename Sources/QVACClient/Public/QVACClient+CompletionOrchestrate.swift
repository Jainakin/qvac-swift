import Foundation

public extension QVACClient {
    struct CompletionToolCallback: Sendable, Equatable {
        public let callId: String
        public let name: String
        public let arguments: [String: JSONValue]

        init?(wire: JSONValue) {
            guard case .object(let object) = wire,
                  case .string(let callId) = object["callId"] ?? .null,
                  case .string(let name) = object["name"] ?? .null,
                  case .object(let arguments) = object["arguments"] ?? .null else {
                return nil
            }
            self.callId = callId
            self.name = name
            self.arguments = arguments
        }
    }

    enum CompletionOrchestrationEvent: Sendable, Equatable {
        case turnEvents(turn: Int, events: [JSONValue])
        case toolCallback(CompletionToolCallback)
        case done(stopReason: String?)
    }

    /// Worker-driven completion/tool loop. Tool callbacks execute in the Swift host;
    /// answer each callback using ``sendToolResult(callId:result:error:)``.
    final class CompletionOrchestrationSession: @unchecked Sendable {
        public let requestId: String
        private let raw: QVACDuplexSession<CompletionOrchestrateResponse>

        init(requestId: String, raw: QVACDuplexSession<CompletionOrchestrateResponse>) {
            self.requestId = requestId
            self.raw = raw
        }

        /// Write one newline-delimited tool result to the request side of the duplex.
        /// Supply either `result` or `error`; omitting both sends a JSON null result.
        public func sendToolResult(
            callId: String,
            result: JSONValue? = nil,
            error: String? = nil
        ) async throws {
            guard !callId.isEmpty else {
                throw QVACError.invalidArgument("tool callback callId must not be empty")
            }
            guard result == nil || error == nil else {
                throw QVACError.invalidArgument(
                    "tool callback result and error are mutually exclusive"
                )
            }
            var object: [String: JSONValue] = ["callId": .string(callId)]
            if let error {
                object["error"] = .string(error)
            } else {
                object["result"] = result ?? .null
            }
            var line = try JSONEncoder.qvac.encode(JSONValue.object(object))
            line.append(0x0A)
            try await raw.write(line)
        }

        public func end() async throws { try await raw.end() }
        public func destroy() { raw.destroy() }

        /// Single-use orchestration sequence. A stream close without `done` is surfaced
        /// as `STREAM_ENDED_WITHOUT_RESPONSE` instead of silently succeeding.
        public var events: QVACResponseStream<CompletionOrchestrationEvent> {
            let responses = raw.responses
            let rawSession = raw
            return QVACClient.pullMap(
                responses,
                onTermination: { rawSession.destroy() },
                endOfSourceError: {
                    QVACError.client(
                        .streamEndedWithoutResponse,
                        message: "completionOrchestrate ended without a terminal done frame"
                    )
                }
            ) { frame in
                var mapped: [CompletionOrchestrationEvent] = []
                if let events = frame.events {
                    mapped.append(.turnEvents(turn: frame.turn ?? 0, events: events))
                }
                if let rawCallback = frame.toolCallback {
                    guard let callback = CompletionToolCallback(wire: rawCallback) else {
                        throw QVACError.protocolViolation(
                            "completionOrchestrate returned malformed toolCallback"
                        )
                    }
                    mapped.append(.toolCallback(callback))
                }
                if frame.done == true {
                    mapped.append(.done(stopReason: frame.stopReason))
                    return .emitThenFinish(mapped)
                }
                return .emitMany(mapped)
            }
        }
    }

    /// Open the exact wire-level orchestration request.
    func completionOrchestrate(
        _ input: CompletionOrchestrateRequest,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> CompletionOrchestrationSession {
        var request = input
        if let maxToolTurns = request.maxToolTurns, !(1...32).contains(maxToolTurns) {
            throw QVACError.invalidArgument("maxToolTurns must be in 1...32")
        }
        let requestId = request.requestId ?? UUID().uuidString
        request.requestId = requestId
        let raw: QVACDuplexSession<CompletionOrchestrateResponse> = try await duplexTyped(
            .completionOrchestrate(request), rpcOptions: rpcOptions
        )
        return CompletionOrchestrationSession(requestId: requestId, raw: raw)
    }

    /// Open a worker-driven tool loop using the same chat/history wire representation as
    /// the `completion` API.
    func completionOrchestrate(
        modelId: String,
        history: [ChatMessage],
        tools: [JSONValue],
        generationParams: JSONValue? = nil,
        maxToolTurns: Int? = nil,
        captureThinking: Bool = false,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> CompletionOrchestrationSession {
        let historyValue: [JSONValue] = history.map { message in
            .object([
                "role": .string(message.role),
                "content": .string(message.content),
            ])
        }
        let request = CompletionOrchestrateRequest(
            history: historyValue,
            modelId: modelId,
            stream: true,
            captureThinking: captureThinking ? true : nil,
            generationParams: generationParams,
            maxToolTurns: maxToolTurns,
            tools: tools
        )
        return try await completionOrchestrate(request, rpcOptions: rpcOptions)
    }
}
