// QVAC-210 — translate
//
// Streams the translated text token-by-token. The worker supports both LLM-based
// (`modelType: "llamacpp-completion"`) and NMT-based (`modelType: "nmtcpp-translation"`)
// translation; the caller picks via `modelType`.

import Foundation

public extension QVACClient {

    /// Result of a `translate(…)` call. Iterate `tokenStream` to receive the translation
    /// as it streams, or `await text` for the complete final string.
    final class TranslationRun: @unchecked Sendable {
        public let tokenStream: AsyncThrowingStream<String, Error>
        public let text: Task<String, Error>
        init(tokenStream: AsyncThrowingStream<String, Error>, text: Task<String, Error>) {
            self.tokenStream = tokenStream; self.text = text
        }
    }

    /// Run streaming translation.
    func translate(
        modelId: String,
        modelType: String,
        text: String,
        from: String? = nil,
        to: String? = nil,
        context: String? = nil
    ) async throws -> TranslationRun {
        let req = TranslateRequest(
            modelId: modelId, modelType: modelType, stream: true, text: text,
            context: context, from: from, to: to
        )
        let stream: AsyncThrowingStream<QVACResponse, Error> = try await streamTyped(.translate(req))
        let (tokens, tokensCont) = Self.makeStream(of: String.self)
        let textTask = Task<String, Error> {
            var full = ""
            do {
                for try await response in stream {
                    guard case .translate(let r) = response else {
                        if case .error(let e) = response {
                            throw QVACError.fromWire(code: Int(e.code ?? 0), message: e.message)
                        }
                        continue
                    }
                    if let e = r.error { throw QVACError.server(.translationFailed, message: e) }
                    tokensCont.yield(r.token)
                    full += r.token
                    if r.done == true { break }
                }
                tokensCont.finish()
                return full
            } catch {
                tokensCont.finish(throwing: error)
                throw error
            }
        }
        return TranslationRun(tokenStream: tokens, text: textTask)
    }
}
