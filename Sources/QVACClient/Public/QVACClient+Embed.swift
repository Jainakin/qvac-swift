// QVAC-205 — embed
//
// Returns a vector embedding for the given text. Supports single (string) and batch
// (array of strings) inputs. The JS API overloads on input type; in Swift we use
// two methods to keep the return types tight.

import Foundation

public extension QVACClient {

    /// Embed a single text. Returns the vector as `[Double]`.
    func embed(modelId: String, text: String) async throws -> [Double] {
        let req = EmbedRequest(modelId: modelId, text: .string(text))
        let response: QVACResponse = try await sendTyped(.embed(req))
        guard case .embed(let r) = response else {
            throw QVACError.protocolViolation("expected embed response, got \(response.discriminator)")
        }
        return try Self.extractSingleEmbedding(from: r)
    }

    /// Embed a batch of texts. Returns one vector per input, in input order.
    func embed(modelId: String, texts: [String]) async throws -> [[Double]] {
        let textsJSON: JSONValue = .array(texts.map(JSONValue.string))
        let req = EmbedRequest(modelId: modelId, text: textsJSON)
        let response: QVACResponse = try await sendTyped(.embed(req))
        guard case .embed(let r) = response else {
            throw QVACError.protocolViolation("expected embed response, got \(response.discriminator)")
        }
        return try Self.extractBatchEmbedding(from: r)
    }

    private static func extractSingleEmbedding(from response: EmbedResponse) throws -> [Double] {
        if response.success != true {
            throw QVACError.server(.embedFailed, message: response.error)
        }
        guard let value = response.embedding, case .array(let arr) = value else {
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
        guard let value = response.embedding, case .array(let outer) = value else {
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
