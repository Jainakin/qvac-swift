// Text embedding operations.
//
// Returns a vector embedding for the given text. Supports single (string) and batch
// (array of strings) inputs. The JavaScript API overloads on input type; Swift
// exposes separate methods with concrete return types.

import Foundation

public extension QVACClient {

    /// Embedding payload and optional worker performance statistics.
    struct EmbeddingOutcome<Value: Sendable>: Sendable {
        public let embedding: Value
        public let stats: JSONValue?

        init(embedding: Value, stats: JSONValue?) {
            self.embedding = embedding
            self.stats = stats
        }
    }

    /// A cancellable embedding operation matching the decorated promise returned by
    /// the published 0.17 JavaScript client.
    final class EmbeddingRun<Value: Sendable>: @unchecked Sendable {
        public let requestId: String
        public let result: Task<EmbeddingOutcome<Value>, Error>

        init(requestId: String, result: Task<EmbeddingOutcome<Value>, Error>) {
            self.requestId = requestId
            self.result = result
        }
    }

    /// Start embedding one text. The request id is available before the worker replies.
    func embed(
        modelId: String,
        text: String,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> EmbeddingRun<[Double]> {
        let requestId = UUID().uuidString
        let req = EmbedRequest(
            modelId: modelId,
            text: .string(text),
            requestId: requestId
        )
        let result = Task<EmbeddingOutcome<[Double]>, Error> {
            let response: QVACResponse = try await self.sendTyped(
                .embed(req), rpcOptions: rpcOptions
            )
            guard case .embed(let terminal) = response else {
                throw QVACError.protocolViolation(
                    "expected embed response, got \(response.discriminator)"
                )
            }
            return .init(
                embedding: try Self.extractSingleEmbedding(from: terminal),
                stats: terminal.stats
            )
        }
        return EmbeddingRun(requestId: requestId, result: result)
    }

    /// Start embedding multiple texts. The result preserves input order.
    func embed(
        modelId: String,
        texts: [String],
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> EmbeddingRun<[[Double]]> {
        let requestId = UUID().uuidString
        let textsJSON: JSONValue = .array(texts.map(JSONValue.string))
        let req = EmbedRequest(modelId: modelId, text: textsJSON, requestId: requestId)
        let result = Task<EmbeddingOutcome<[[Double]]>, Error> {
            let response: QVACResponse = try await self.sendTyped(
                .embed(req), rpcOptions: rpcOptions
            )
            guard case .embed(let terminal) = response else {
                throw QVACError.protocolViolation(
                    "expected embed response, got \(response.discriminator)"
                )
            }
            return .init(
                embedding: try Self.extractBatchEmbedding(from: terminal),
                stats: terminal.stats
            )
        }
        return EmbeddingRun(requestId: requestId, result: result)
    }

    private static func extractSingleEmbedding(from response: EmbedResponse) throws -> [Double] {
        if response.success != true {
            throw QVACError.server(.embedFailed, message: response.error)
        }
        guard case .array(let arr) = response.embedding else {
            throw QVACError.protocolViolation("embed: unexpected embedding shape")
        }
        var out: [Double] = []
        out.reserveCapacity(arr.count)
        for v in arr {
            guard case .number(let d) = v else {
                throw QVACError.protocolViolation("embed: embedding element not a number")
            }
            out.append(d)
        }
        return out
    }

    private static func extractBatchEmbedding(from response: EmbedResponse) throws -> [[Double]] {
        if response.success != true {
            throw QVACError.server(.embedFailed, message: response.error)
        }
        guard case .array(let outer) = response.embedding else {
            throw QVACError.protocolViolation("embed: unexpected embedding shape")
        }
        var out: [[Double]] = []
        out.reserveCapacity(outer.count)
        for row in outer {
            guard case .array(let inner) = row else {
                throw QVACError.protocolViolation("embed: row not an array")
            }
            var vec: [Double] = []
            vec.reserveCapacity(inner.count)
            for v in inner {
                guard case .number(let d) = v else {
                    throw QVACError.protocolViolation("embed: element not a number")
                }
                vec.append(d)
            }
            out.append(vec)
        }
        return out
    }
}
