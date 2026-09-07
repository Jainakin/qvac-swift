// Plugin invocation operations.
//
// Generic plugin RPC. Each plugin registers handlers on the worker side with arbitrary
// request and response Zod schemas. Because those schemas are known only at
// runtime, the Swift API uses `Encodable` parameters and `Decodable` responses.
// Callers define their own typed structs for the plugin they're calling.
//
// Example:
//   struct MyParams: Encodable { let prompt: String }
//   struct MyResult: Decodable { let text: String }
//   let result: MyResult = try await client.invokePlugin(
//       modelId: id, handler: "myHandler", params: MyParams(prompt: "hi")
//   )

import Foundation

public extension QVACClient {

    /// Invoke a plugin handler with a single-shot RPC.
    /// `Params` is encoded to JSON via the standard `Codable` machinery; the result is decoded
    /// from the worker's reply (also JSON). Before the caller-owned `Result` is materialized,
    /// the arbitrary plugin result is charged against `maximumAccumulatedResultBytes` using an
    /// allocation-free retained-memory estimate.
    func invokePlugin<Params: Encodable & Sendable, Result: Decodable & Sendable>(
        modelId: String,
        handler: String,
        params: Params,
        as resultType: Result.Type = Result.self,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> Result {
        let paramsJSON = try encodePluginParameters(params, operation: "pluginInvoke")
        let req = PluginInvokeRequest(handler: handler, modelId: modelId, params: paramsJSON)
        var resultBudget = makeResultByteBudget(operation: "pluginInvoke")
        let response: QVACResponse = try await sendTyped(.pluginInvoke(req), rpcOptions: rpcOptions)
        guard case .pluginInvoke(let r) = response else {
            throw QVACError.protocolViolation("expected pluginInvoke response, got \(response.discriminator)")
        }
        try Self.preflightPluginResultMaterialization(r.result, resultBudget: &resultBudget)
        return try Self.decodeFromJSONValue(r.result, as: Result.self)
    }

    /// Untyped variant that returns the raw `JSONValue` for caller-defined decoding.
    /// The worker-controlled tree is charged against `maximumAccumulatedResultBytes`
    /// before it is returned.
    func invokePlugin<Params: Encodable & Sendable>(
        modelId: String,
        handler: String,
        params: Params,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> JSONValue {
        let paramsJSON = try encodePluginParameters(params, operation: "pluginInvoke")
        let req = PluginInvokeRequest(handler: handler, modelId: modelId, params: paramsJSON)
        var resultBudget = makeResultByteBudget(operation: "pluginInvoke")
        let response: QVACResponse = try await sendTyped(.pluginInvoke(req), rpcOptions: rpcOptions)
        guard case .pluginInvoke(let r) = response else {
            throw QVACError.protocolViolation("expected pluginInvoke response, got \(response.discriminator)")
        }
        try Self.preflightPluginResultMaterialization(r.result, resultBudget: &resultBudget)
        return r.result
    }

    /// Internal bounded-response variant used by plugin wrappers whose response
    /// schema has a substantially smaller safe envelope than the client's
    /// general-purpose wire ceiling. The byte check happens before decoding the
    /// response into `JSONValue`, preventing JSON/base64 amplification.
    internal func invokePluginWithResponseLimit<Params: Encodable & Sendable>(
        modelId: String,
        handler: String,
        params: Params,
        rpcOptions: QVACRPCOptions,
        maximumResponseBytes: Int
    ) async throws -> JSONValue {
        let paramsJSON = try encodePluginParameters(params, operation: "pluginInvoke")
        let req = PluginInvokeRequest(handler: handler, modelId: modelId, params: paramsJSON)
        let response: QVACResponse = try await sendTyped(
            .pluginInvoke(req),
            rpcOptions: rpcOptions,
            maximumResponseBytes: maximumResponseBytes
        )
        guard case .pluginInvoke(let result) = response else {
            throw QVACError.protocolViolation(
                "expected pluginInvoke response, got \(response.discriminator)"
            )
        }
        return result.result
    }

    /// Invoke a streaming plugin handler. Returns a single-consumer
    /// ``QVACResponseStream`` of decoded chunks. In 0.17, `done` is optional and
    /// merely suppresses that frame's payload; transport EOF is normal completion.
    /// Each arbitrary result is independently charged against
    /// `maximumAccumulatedResultBytes` before its caller-owned `Chunk` is materialized.
    /// Breaking iteration tears down the remote stream.
    func invokePluginStream<Params: Encodable & Sendable, Chunk: Decodable & Sendable>(
        modelId: String,
        handler: String,
        params: Params,
        as chunkType: Chunk.Type = Chunk.self,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> QVACResponseStream<Chunk> {
        let paramsJSON = try encodePluginParameters(params, operation: "pluginInvokeStream")
        let req = PluginInvokeStreamRequest(handler: handler, modelId: modelId, params: paramsJSON)
        let rawStream: QVACResponseStream<QVACResponse> = try await streamTyped(
            .pluginInvokeStream(req),
            rpcOptions: rpcOptions
        )
        let initialResultBudget = makeResultByteBudget(operation: "pluginInvokeStream")

        return Self.pullMap(rawStream, operation: "pluginInvokeStream") { response in
            switch response {
            case .pluginInvokeStream(let frame):
                var resultBudget = initialResultBudget
                try Self.preflightPluginResultMaterialization(
                    frame.result,
                    resultBudget: &resultBudget
                )
                if frame.done == true { return .skip }
                return .emit(try Self.decodeFromJSONValue(frame.result, as: Chunk.self))
            case .error(let error):
                return .failThenDrain(Self.retainedWireError(error))
            default:
                try Self.rejectUnexpectedResponse(response, expected: "pluginInvokeStream")
            }
        }
    }

    // MARK: - JSONValue <-> Codable bridge

    private func encodePluginParameters<T: Encodable>(
        _ value: T,
        operation: String
    ) throws -> JSONValue {
        let data = try JSONEncoder.qvac.encode(value)
        try validateOutboundPayloadSize(data.count, operation: operation)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Bound the decoded worker tree and the transient Codable bridge without
    /// re-encoding untrusted JSON merely to measure it. The conservative estimator
    /// includes collection, key, string-capacity, and handoff overhead and saturates
    /// on hostile nesting or integer overflow.
    private static func preflightPluginResultMaterialization(
        _ value: JSONValue,
        resultBudget: inout QVACResultByteBudget
    ) throws {
        try resultBudget.consume(conservativeBufferedJSONBytes(
            value,
            elementCount: 1,
            fallback: resultBudget.maximumBytes
        ))
    }

    /// Encode a `Codable` value to our `JSONValue` for transport.
    /// Uses a round-trip through `Data` since `JSONValue` doesn't have a direct
    /// Codable bridge to arbitrary types.
    static func encodeAsJSONValue<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try JSONEncoder.qvac.encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Decode a `JSONValue` into a `Decodable` value.
    static func decodeFromJSONValue<T: Decodable>(_ value: JSONValue, as: T.Type = T.self) throws -> T {
        let data = try JSONEncoder.qvac.encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }
}
