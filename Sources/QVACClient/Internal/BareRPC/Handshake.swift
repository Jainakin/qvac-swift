// Handshake — the QVAC-specific `__init_config` and `__shutdown__` RPC calls
// that bracket a QVAC session.
//
// Both ride on top of BareRPCClient as normal `send`/RPC calls with `command=1`.
// The wire shape was reverse-engineered from `client/init-hooks.ts:29-55` and
// observed live in Spike-A (see docs/spike-validations.md).

import Foundation

// MARK: - Wire-level Codable shapes for the handshake messages
//
// These are the ONLY hand-written wire types in the codebase. Everything else
// is generated from Zod schemas by tools/codegen.
// They live here (next to the only code that uses them) rather than in Generated/
// because the handshake protocol itself is part of the bare-rpc client contract,
// not part of the QVAC SDK's data model.

public struct QVACRuntimeContext: Codable, Equatable, Sendable {
    public var runtime: String
    public var platform: String
    public var deviceModel: String?
    public var deviceBrand: String?

    public init(runtime: String, platform: String, deviceModel: String? = nil, deviceBrand: String? = nil) {
        self.runtime = runtime
        self.platform = platform
        self.deviceModel = deviceModel
        self.deviceBrand = deviceBrand
    }

    /// Sensible defaults for the runtime the calling Swift code is on.
    public static var current: QVACRuntimeContext {
        #if os(iOS)
        return QVACRuntimeContext(runtime: "bare", platform: "ios", deviceModel: nil, deviceBrand: "Apple")
        #elseif os(macOS)
        return QVACRuntimeContext(runtime: "node", platform: "darwin")
        #elseif os(Linux)
        return QVACRuntimeContext(runtime: "node", platform: "linux")
        #else
        return QVACRuntimeContext(runtime: "node", platform: "unknown")
        #endif
    }
}

/// Body of the first message the client sends on a new connection.
/// `config` is intentionally `[String: AnyCodable]?` rather than a typed struct here —
/// QvacConfig is generated from the Zod schemas alongside the rest of the wire model
/// and lives in `Sources/QVACClient/Generated/`. The client can either pass it pre-
/// encoded (typical) or pass `nil` to use the worker's defaults.
struct InitConfigEnvelope: Encodable {
    let type: String
    let config: JSONValue?
    let runtimeContext: QVACRuntimeContext?
    init(config: JSONValue?, runtimeContext: QVACRuntimeContext?) {
        self.type = "__init_config"
        self.config = config
        self.runtimeContext = runtimeContext
    }
}

struct InitConfigReply: Decodable {
    let success: Bool
    let error: String?
}

public struct QVACInitConfigFailed: Error, Sendable, CustomStringConvertible {
    public let message: String
    public var description: String { "init_config rejected by worker: \(message)" }
}

// MARK: - Public handshake helpers

public enum QVACHandshake {

    /// First message on a new connection. Sends `__init_config` and blocks for the worker's reply.
    /// Per the JS reference, the command id MUST be 1 (`init-hooks.ts:41 — rpc.request(1)`).
    public static func sendInitConfig(
        on rpc: BareRPCClient,
        config: JSONValue? = nil,
        runtimeContext: QVACRuntimeContext? = .current
    ) async throws {
        let envelope = InitConfigEnvelope(config: config, runtimeContext: runtimeContext)
        let payload = try JSONEncoder.qvac.encode(envelope)
        guard let respData = try await rpc.send(command: 1, data: payload) else {
            throw QVACInitConfigFailed(message: "empty reply")
        }
        let reply = try JSONDecoder().decode(InitConfigReply.self, from: respData)
        guard reply.success else {
            throw QVACInitConfigFailed(message: reply.error ?? "unknown error")
        }
    }

    /// Optional clean-shutdown hint. The worker uses this on Expo paths to torn down
    /// the V8 isolate gracefully (see `client/rpc/expo-rpc-client.ts:145-160`). On macOS
    /// the JS SDK skips it and simply lets the parent terminate the subprocess; we mirror
    /// that and expose `sendShutdown` as opt-in.
    public static func sendShutdown(on rpc: BareRPCClient) async throws {
        let envelope: [String: String] = ["type": "__shutdown__"]
        let payload = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        _ = try await rpc.send(command: 1, data: payload)
    }
}

// MARK: - JSON shape helpers
//
// `JSONValue` lets the handshake carry an opaque `config` blob without coupling this file
// to the generated QvacConfig type. Codable's `AnyCodable` pattern.

public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self)            { self = .bool(b); return }
        if let n = try? c.decode(Double.self)          { self = .number(n); return }
        if let s = try? c.decode(String.self)          { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self)     { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "invalid JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:        try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a):  try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

// MARK: - Shared JSON coders

extension JSONEncoder {
    /// QVAC's preferred JSON encoder: sorted keys for deterministic wire output.
    /// Sorted keys matter for fixture-based testing (the JS encoder also sorts).
    static let qvac: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
}
