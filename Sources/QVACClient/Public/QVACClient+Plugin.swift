// QVAC-310 / QVAC-311 — invokePlugin + invokePluginStream
//
// Generic plugin RPC. Each plugin registers handlers on the worker side with arbitrary
// request/response Zod schemas; we don't know them at compile time, so the public
// Swift API exposes them via `Encodable` (params) + `Decodable` (response) generics.
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
    /// from the worker's reply (also JSON).
    func invokePlugin<Params: Encodable & Sendable, Result: Decodable & Sendable>(
        modelId: String,
        handler: String,
        params: Params,
        as resultType: Result.Type = Result.self,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> Result {
        let paramsJSON = try Self.encodeAsJSONValue(params)
        let req = PluginInvokeRequest(handler: handler, modelId: modelId, params: paramsJSON)
        let response: QVACResponse = try await sendTyped(.pluginInvoke(req), rpcOptions: rpcOptions)
        guard case .pluginInvoke(let r) = response else {
            throw QVACError.protocolViolation("expected pluginInvoke response, got \(response.discriminator)")
        }
        return try Self.decodeFromJSONValue(r.result, as: Result.self)
    }

    /// Untyped variant — returns the raw `JSONValue` so callers can extract bits ad-hoc.
    func invokePlugin<Params: Encodable & Sendable>(
        modelId: String,
        handler: String,
        params: Params,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> JSONValue {
        let paramsJSON = try Self.encodeAsJSONValue(params)
        let req = PluginInvokeRequest(handler: handler, modelId: modelId, params: paramsJSON)
        let response: QVACResponse = try await sendTyped(.pluginInvoke(req), rpcOptions: rpcOptions)
        guard case .pluginInvoke(let r) = response else {
            throw QVACError.protocolViolation("expected pluginInvoke response, got \(response.discriminator)")
        }
        return r.result
    }

    /// Invoke a streaming plugin handler. Returns a single-consumer
    /// ``QVACResponseStream`` of decoded chunks. In 0.17, `done` is optional and
    /// merely suppresses that frame's payload; transport EOF is normal completion.
    /// Breaking iteration tears down the remote stream.
    func invokePluginStream<Params: Encodable & Sendable, Chunk: Decodable & Sendable>(
        modelId: String,
        handler: String,
        params: Params,
        as chunkType: Chunk.Type = Chunk.self,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> QVACResponseStream<Chunk> {
        let paramsJSON = try Self.encodeAsJSONValue(params)
        let req = PluginInvokeStreamRequest(handler: handler, modelId: modelId, params: paramsJSON)
        let rawStream: QVACResponseStream<QVACResponse> = try await streamTyped(
            .pluginInvokeStream(req),
            rpcOptions: rpcOptions
        )

        return Self.pullMap(rawStream, operation: "pluginInvokeStream") { response in
            switch response {
            case .pluginInvokeStream(let frame):
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
