import Foundation

public extension QVACClient {
    enum BciNeuralInput: Sendable, Equatable {
        /// Provider-local path to a neural `.bin` recording.
        case filePath(String)
        /// Raw neural-signal bytes, base64-encoded by the client. Empty data is
        /// forwarded as an empty base64 string, matching QVAC 0.17.
        case data(Data)

        var wireValue: JSONValue {
            switch self {
            case .filePath(let path):
                return .object(["type": .string("filePath"), "value": .string(path)])
            case .data(let data):
                return .object([
                    "type": .string("base64"),
                    "value": .string(data.base64EncodedString()),
                ])
            }
        }
    }

    struct BciTranscriptionOutcome: Sendable, Equatable {
        public let text: String
        public let segments: [TranscribeSegment]
        public let stats: JSONValue?
    }

    final class BciTranscriptionRun: @unchecked Sendable {
        /// Stable cancellation target carried in the wire request.
        public let requestId: String
        public let result: Task<BciTranscriptionOutcome, Error>

        init(requestId: String, result: Task<BciTranscriptionOutcome, Error>) {
            self.requestId = requestId
            self.result = result
        }
    }

    /// Transcribe a complete neural-signal recording. The run object exposes its
    /// request id before transcription completes, allowing targeted cancellation.
    func bciTranscribe(
        modelId: String,
        neuralData: BciNeuralInput,
        metadata: Bool = false,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> BciTranscriptionRun {
        if case .data(let data) = neuralData {
            try validateBase64InputSizes([data.count], operation: "bciTranscribe")
        }
        let requestId = UUID().uuidString
        let request = BciTranscribeRequest(
            modelId: modelId,
            neuralData: neuralData.wireValue,
            metadata: metadata ? true : nil,
            requestId: requestId
        )
        let source: QVACResponseStream<QVACResponse> = try await streamTyped(
            .bciTranscribe(request), rpcOptions: rpcOptions
        )
        let maximumAccumulatedResultBytes = self.maximumAccumulatedResultBytes
        let initialResultBudget = makeResultByteBudget(operation: "bciTranscribe")
        let result = Task<BciTranscriptionOutcome, Error> {
            var resultBudget = initialResultBudget
            var text = ""
            var segments: [TranscribeSegment] = []
            var stats: JSONValue?
            var retainedStatsBytes = 0
            let responses = QVACResponseStreamIteratorBox(source)
            while let response = try await responses.next() {
                if case .error(let error) = response {
                    return try await Self.resolveResponseStreamTerminal(
                        responses,
                        operation: "bciTranscribe"
                    ) { () throws -> BciTranscriptionOutcome in
                        throw QVACError.fromWire(
                            code: try Self.checkedWireErrorCode(error.code),
                            message: error.message
                        )
                    }
                }
                guard case .bciTranscribe(let frame) = response else {
                    try Self.rejectUnexpectedResponse(response, expected: "bciTranscribe")
                }
                if let error = frame.error {
                    return try await Self.resolveResponseStreamTerminal(
                        responses,
                        operation: "bciTranscribe"
                    ) { () throws -> BciTranscriptionOutcome in
                        throw QVACError.server(.transcriptionFailed, message: error)
                    }
                }
                if frame.done == true {
                    let terminalSegment = Result {
                        try frame.segment.map(TranscribeSegment.init(from:))
                    }
                    if let responseStats = frame.stats {
                        let nextStatsBytes = Self.conservativeBufferedJSONBytes(
                            responseStats,
                            elementCount: 1,
                            fallback: maximumAccumulatedResultBytes
                        )
                        try resultBudget.replace(
                            retainedStatsBytes,
                            with: nextStatsBytes
                        )
                        retainedStatsBytes = nextStatsBytes
                    }
                    if let fragment = frame.text {
                        try resultBudget.consumeRetainedString(fragment)
                    }
                    if let raw = frame.segment {
                        try resultBudget.consume(Self.conservativeBufferedJSONBytes(
                            raw,
                            elementCount: 1,
                            fallback: maximumAccumulatedResultBytes
                        ))
                    }
                    return try await Self.resolveResponseStreamTerminal(
                        responses,
                        operation: "bciTranscribe"
                    ) {
                        var terminalText = text
                        var terminalSegments = segments
                        var terminalStats = stats
                        if let fragment = frame.text {
                            terminalText += fragment
                        }
                        if let parsed = try terminalSegment.get() {
                            terminalSegments.append(parsed)
                        }
                        if let responseStats = frame.stats {
                            terminalStats = responseStats
                        }
                        return BciTranscriptionOutcome(
                            text: terminalText,
                            segments: terminalSegments,
                            stats: terminalStats
                        )
                    }
                }
                if let responseStats = frame.stats {
                    let nextStatsBytes = Self.conservativeBufferedJSONBytes(
                        responseStats,
                        elementCount: 1,
                        fallback: maximumAccumulatedResultBytes
                    )
                    try resultBudget.replace(retainedStatsBytes, with: nextStatsBytes)
                    retainedStatsBytes = nextStatsBytes
                    stats = responseStats
                }
                if let fragment = frame.text {
                    try resultBudget.consumeRetainedString(fragment)
                    text += fragment
                }
                if let raw = frame.segment {
                    let parsed = try TranscribeSegment(from: raw)
                    try resultBudget.consume(Self.conservativeBufferedJSONBytes(
                        raw,
                        elementCount: 1,
                        fallback: maximumAccumulatedResultBytes
                    ))
                    segments.append(parsed)
                }
            }
            throw QVACError.client(
                .streamEndedWithoutResponse,
                message: "bciTranscribe ended without a terminal done frame"
            )
        }
        return BciTranscriptionRun(requestId: requestId, result: result)
    }

    enum BciTranscribeStreamEvent: Sendable, Equatable {
        case text(String)
        case segment(TranscribeSegment)
        case done(stats: JSONValue?)
    }

    /// Bidirectional BCI session. Neural chunks are written verbatim; response records
    /// are NDJSON-decoded by the shared duplex layer.
    final class BciTranscribeStreamSession: @unchecked Sendable {
        public let requestId: String
        private let raw: QVACDuplexSession<BciTranscribeStreamResponse>

        init(requestId: String, raw: QVACDuplexSession<BciTranscribeStreamResponse>) {
            self.requestId = requestId
            self.raw = raw
        }

        public func write(_ neuralChunk: Data) async throws { try await raw.write(neuralChunk) }
        public func end() async throws { try await raw.end() }
        public func destroy() { raw.destroy() }

        /// Single-use response event sequence. Ending without `done` is a protocol error.
        public var events: QVACResponseStream<BciTranscribeStreamEvent> {
            let responses = raw.responses
            let rawSession = raw
            return QVACClient.pullMap(
                responses,
                operation: "bciTranscribeStream",
                onTermination: { rawSession.destroy() },
                endOfSourceError: {
                    QVACError.client(
                        .streamEndedWithoutResponse,
                        message: "bciTranscribeStream ended without a terminal done frame"
                    )
                }
            ) { frame in
                if let error = frame.error {
                    return .failThenDrain(
                        QVACError.server(.transcriptionFailed, message: error)
                    )
                }
                if frame.done == true {
                    do {
                        var terminalEvents: [BciTranscribeStreamEvent] = []
                        if let raw = frame.segment {
                            terminalEvents.append(.segment(try TranscribeSegment(from: raw)))
                        }
                        if let text = frame.text, !text.isEmpty {
                            terminalEvents.append(.text(text))
                        }
                        terminalEvents.append(.done(stats: frame.stats))
                        return .emitThenDrain(terminalEvents)
                    } catch let error as QVACError {
                        return .failThenDrain(error)
                    } catch {
                        return .failThenDrain(.protocolViolation(
                            "bciTranscribeStream returned a malformed terminal frame: \(error)"
                        ))
                    }
                }
                var events: [BciTranscribeStreamEvent] = []
                if let raw = frame.segment {
                    events.append(.segment(try TranscribeSegment(from: raw)))
                }
                if let text = frame.text, !text.isEmpty {
                    events.append(.text(text))
                }
                return .emitMany(events)
            }
        }
    }

    /// Open a sliding-window BCI transcription session.
    ///
    /// Timestep counts are encoded as JSON numbers and therefore must not exceed
    /// 2^53 - 1, the largest integer that the 0.17 JavaScript worker can represent
    /// exactly.
    func bciTranscribeStream(
        modelId: String,
        metadata: Bool = false,
        windowTimesteps: Int? = nil,
        hopTimesteps: Int? = nil,
        emit: String? = nil,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> BciTranscribeStreamSession {
        let maximumExactWireInteger = 9_007_199_254_740_991
        if let windowTimesteps, windowTimesteps <= 0 {
            throw QVACError.invalidArgument("windowTimesteps must be positive")
        }
        if let windowTimesteps, windowTimesteps > maximumExactWireInteger {
            throw QVACError.invalidArgument(
                "windowTimesteps must not exceed 9007199254740991, "
                    + "the largest exactly representable JSON integer"
            )
        }
        if let hopTimesteps, hopTimesteps <= 0 {
            throw QVACError.invalidArgument("hopTimesteps must be positive")
        }
        if let hopTimesteps, hopTimesteps > maximumExactWireInteger {
            throw QVACError.invalidArgument(
                "hopTimesteps must not exceed 9007199254740991, "
                    + "the largest exactly representable JSON integer"
            )
        }
        if let windowTimesteps, let hopTimesteps, hopTimesteps >= windowTimesteps {
            throw QVACError.invalidArgument("hopTimesteps must be less than windowTimesteps")
        }
        if let emit, emit != "delta" && emit != "full" {
            throw QVACError.invalidArgument("BCI emit must be delta or full")
        }

        var streamOptions: [String: JSONValue] = [:]
        if let windowTimesteps { streamOptions["windowTimesteps"] = .number(Double(windowTimesteps)) }
        if let hopTimesteps { streamOptions["hopTimesteps"] = .number(Double(hopTimesteps)) }
        if let emit { streamOptions["emit"] = .string(emit) }
        let requestId = UUID().uuidString
        let request = BciTranscribeStreamRequest(
            modelId: modelId,
            metadata: metadata ? true : nil,
            requestId: requestId,
            streamOpts: streamOptions.isEmpty ? nil : .object(streamOptions)
        )
        let raw: QVACDuplexSession<BciTranscribeStreamResponse> = try await duplexTyped(
            .bciTranscribeStream(request), rpcOptions: rpcOptions
        )
        return BciTranscribeStreamSession(requestId: requestId, raw: raw)
    }
}
