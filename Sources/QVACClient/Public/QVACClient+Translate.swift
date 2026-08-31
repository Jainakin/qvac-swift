// QVAC-210 — translate
//
// Streams the translated text token-by-token. The worker supports both LLM-based
// (`modelType: "llamacpp-completion"`) and NMT-based (`modelType: "nmtcpp-translation"`)
// translation; the caller picks via `modelType`.

import Foundation

public extension QVACClient {

    struct TranslationStats: Codable, Sendable, Equatable {
        public let totalTime: Double?
        public let totalTokens: Double?
        public let tokensPerSecond: Double?
        public let timeToFirstToken: Double?
        public let decodeTime: Double?
        public let encodeTime: Double?
        public let cacheTokens: Double?
    }

    /// Result of a `translate(…)` call, matching the QVAC 0.17 result modes.
    /// When `stream` is `true`, consume `tokenStream` and `text` resolves to an empty
    /// string. When `stream` is `false`, `tokenStream` is empty and `text` resolves to
    /// the complete translation.
    final class TranslationRun: @unchecked Sendable {
        public let tokenStream: AsyncThrowingStream<String, Error>
        public let text: Task<String, Error>
        public let stats: Task<TranslationStats?, Error>
        private let processing: Task<String, Error>

        init(
            tokenStream: AsyncThrowingStream<String, Error>,
            text: Task<String, Error>,
            stats: Task<TranslationStats?, Error>,
            processing: Task<String, Error>
        ) {
            self.tokenStream = tokenStream
            self.text = text
            self.stats = stats
            self.processing = processing
        }

        deinit { processing.cancel() }
    }

    /// Translate text, returning either streamed tokens or an aggregated result according
    /// to `stream`.
    func translate(
        modelId: String,
        modelType: String,
        text: String,
        from: String? = nil,
        to: String? = nil,
        context: String? = nil,
        stream: Bool = true,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> TranslationRun {
        let req = TranslateRequest(
            modelId: modelId, modelType: modelType, stream: stream, text: text,
            context: context, from: from, to: to
        )
        let responseStream: QVACResponseStream<QVACResponse> = try await streamTyped(
            .translate(req),
            rpcOptions: rpcOptions
        )
        let (tokens, tokensCont) = Self.makeStream(
            of: String.self,
            name: "translate.tokenStream"
        )
        if !stream { tokensCont.finish() }
        let statsBox = ResultBox<TranslationStats?>()
        let processing = Task<String, Error> {
            var full = ""
            var receivedTerminalFrame = false
            do {
                for try await response in responseStream {
                    guard case .translate(let r) = response else {
                        try Self.rejectUnexpectedResponse(response, expected: "translate")
                    }
                    if let e = r.error { throw QVACError.server(.translationFailed, message: e) }
                    if r.done == true {
                        if !stream { full += r.token }
                        if let wireStats = r.stats {
                            do {
                                statsBox.set(try Self.decodeFromJSONValue(
                                    wireStats,
                                    as: TranslationStats.self
                                ))
                            } catch {
                                throw QVACError.protocolViolation(
                                    "translate returned malformed stats: \(error)"
                                )
                            }
                        } else {
                            statsBox.set(nil)
                        }
                        receivedTerminalFrame = true
                        break
                    }
                    if stream { tokensCont.yield(r.token) }
                    if !stream { full += r.token }
                }
                guard receivedTerminalFrame else {
                    throw QVACError.client(
                        .streamEndedWithoutResponse,
                        message: "translate ended without a terminal done frame"
                    )
                }
                tokensCont.finish()
                return full
            } catch {
                tokensCont.finish(throwing: error)
                throw error
            }
        }
        let textTask = stream ? Task<String, Error> { "" } : processing
        let statsTask = Task<TranslationStats?, Error> {
            _ = try await processing.value
            return statsBox.get() ?? nil
        }
        return TranslationRun(
            tokenStream: tokens,
            text: textTask,
            stats: statsTask,
            processing: processing
        )
    }
}
