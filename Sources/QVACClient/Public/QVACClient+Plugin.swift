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
        as resultType: Result.Type = Result.self
    ) async throws -> Result {
        let paramsJSON = try Self.encodeAsJSONValue(params)
        let req = PluginInvokeRequest(handler: handler, modelId: modelId, params: paramsJSON)
        let response: QVACResponse = try await sendTyped(.pluginInvoke(req))
        guard case .pluginInvoke(let r) = response else {
            throw QVACError.protocolViolation("expected pluginInvoke response, got \(response.discriminator)")
        }
        return try Self.decodeFromJSONValue(r.result, as: Result.self)
    }

    /// Untyped variant — returns the raw `JSONValue` so callers can extract bits ad-hoc.
    func invokePlugin<Params: Encodable & Sendable>(
        modelId: String,
        handler: String,
        params: Params
    ) async throws -> JSONValue {
        let paramsJSON = try Self.encodeAsJSONValue(params)
        let req = PluginInvokeRequest(handler: handler, modelId: modelId, params: paramsJSON)
        let response: QVACResponse = try await sendTyped(.pluginInvoke(req))
        guard case .pluginInvoke(let r) = response else {
            throw QVACError.protocolViolation("expected pluginInvoke response, got \(response.discriminator)")
        }
        return r.result
    }

    /// Invoke a streaming plugin handler. Returns an `AsyncThrowingStream` of decoded chunks.
    /// The stream terminates when the worker emits `done: true`.
    func invokePluginStream<Params: Encodable & Sendable, Chunk: Decodable & Sendable>(
        modelId: String,
        handler: String,
        params: Params,
        as chunkType: Chunk.Type = Chunk.self
    ) async throws -> AsyncThrowingStream<Chunk, Error> {
        let paramsJSON = try Self.encodeAsJSONValue(params)
        let req = PluginInvokeStreamRequest(handler: handler, modelId: modelId, params: paramsJSON)
        let rawStream: AsyncThrowingStream<QVACResponse, Error> = try await streamTyped(.pluginInvokeStream(req))

        return AsyncThrowingStream<Chunk, Error> { continuation in
            let task = Task<Void, Never> {
                do {
                    for try await response in rawStream {
                        switch response {
                        case .pluginInvokeStream(let r):
                            if r.done == true { continuation.finish(); return }
                            let chunk = try QVACClient.decodeFromJSONValue(r.result, as: Chunk.self)
                            continuation.yield(chunk)
                        case .error(let e):
                            throw QVACError.fromWire(code: Int(e.code ?? 0), message: e.message)
                        default:
                            continue   // forward-compat
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
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
