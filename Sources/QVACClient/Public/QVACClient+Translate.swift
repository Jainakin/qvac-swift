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

    /// Translate one non-empty text with an NMT or LLM model.
    ///
    /// NMT model types (`nmt`, `nmtcpp-translation`) accept only the text input.
    /// LLM model types (`llm`, `llamacpp-completion`) require a non-empty `to`
    /// language and may use `from` and `context`.
    ///
    /// - Parameters:
    ///   - modelId: Identifier of the loaded translation model.
    ///   - modelType: One of the four QVAC 0.17 translation model identifiers.
    ///   - text: A non-empty input to translate.
    ///   - from: Optional LLM source-language code; omit to auto-detect.
    ///   - to: Required target-language code for LLM translation.
    ///   - context: Optional LLM system hint.
    ///   - stream: Whether to expose worker output through `tokenStream`.
    ///   - rpcOptions: Per-request transport, timeout, and profiling options.
    /// - Throws: `QVACError.invalidArgument` when parameters do not match the
    ///   selected QVAC 0.17 NMT or LLM request branch.
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
        guard !text.isEmpty else {
            throw QVACError.invalidArgument("translate text must not be empty")
        }
        switch modelType {
        case "llm", "llamacpp-completion":
            guard let to, !to.isEmpty else {
                throw QVACError.invalidArgument(
                    "LLM translation requires a non-empty target language"
                )
            }
        case "nmt", "nmtcpp-translation":
            guard from == nil, to == nil, context == nil else {
                throw QVACError.invalidArgument(
                    "NMT translation does not accept from, to, or context"
                )
            }
        default:
            throw QVACError.invalidArgument(
                "translate modelType must be llm, llamacpp-completion, nmt, "
                    + "or nmtcpp-translation"
            )
        }
        return try await startTranslation(
            modelId: modelId,
            modelType: modelType,
            text: .one(text),
            from: from,
            to: to,
            context: context,
            stream: stream,
            rpcOptions: rpcOptions
        )
    }

    /// Translate a non-empty batch with an NMT model, preserving input order.
    ///
    /// QVAC 0.17 accepts array input only for the `nmt` and
    /// `nmtcpp-translation` model types. In non-streaming mode, `TranslationRun.text`
    /// contains the worker's newline-delimited translations; in streaming mode,
    /// consume `TranslationRun.tokenStream` (which includes the separators emitted
    /// by the worker).
    ///
    /// - Parameters:
    ///   - modelId: Identifier of the loaded NMT model.
    ///   - modelType: Either `nmt` or `nmtcpp-translation`.
    ///   - texts: One or more non-empty inputs to translate.
    ///   - stream: Whether to expose worker output through `tokenStream`.
    ///   - rpcOptions: Per-request transport, timeout, and profiling options.
    func translate(
        modelId: String,
        modelType: String,
        texts: [String],
        stream: Bool = true,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> TranslationRun {
        guard !texts.isEmpty else {
            throw QVACError.invalidArgument("translate texts must contain at least one value")
        }
        guard texts.allSatisfy({ !$0.isEmpty }) else {
            throw QVACError.invalidArgument("translate texts must not contain an empty value")
        }
        guard modelType == "nmt" || modelType == "nmtcpp-translation" else {
            throw QVACError.invalidArgument(
                "translate batch input requires modelType nmt or nmtcpp-translation"
            )
        }
        return try await startTranslation(
            modelId: modelId,
            modelType: modelType,
            text: .many(texts),
            from: nil,
            to: nil,
            context: nil,
            stream: stream,
            rpcOptions: rpcOptions
        )
    }

    private func startTranslation(
        modelId: String,
        modelType: String,
        text: QVACOneOrMany<String>,
        from: String?,
        to: String?,
        context: String?,
        stream: Bool,
        rpcOptions: QVACRPCOptions
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
