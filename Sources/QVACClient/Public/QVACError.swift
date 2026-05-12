// QVACError — typed Swift errors matching the QVAC SDK's numeric error-code surface.
//
// THIS FILE IS PARTIALLY GENERATED. The `enum QVACErrorCode` and `category` accessor
// live in `Sources/QVACClient/Generated/QVACErrorCodes.generated.swift` — produced by
// `tools/codegen/run.sh` from:
//   • packages/sdk/schemas/sdk-errors-client.ts (codes 50001–52000)
//   • packages/sdk/schemas/sdk-errors-server.ts (codes 52001–54000)
//
// This file contains the hand-written wrapper that maps an Int code from the wire onto
// a typed Swift case, plus the throwing surface consumers see.

import Foundation

/// The single error type thrown by all `QVACClient` methods on a server-side failure.
///
/// Two flavors:
///   • `.client(code, message?)`  — error originated in the SDK's client layer (codes 50001–52000)
///   • `.server(code, message?)`  — error originated in the worker (codes 52001–54000)
///   • `.transport(_)`            — connection/transport failure
///   • `.protocolViolation(_)`    — server returned an unexpected shape
///   • `.encoding(_)`             — wire-level decode failed
public enum QVACError: Error, CustomStringConvertible, Sendable {
    case client(QVACErrorCode, message: String?)
    case server(QVACErrorCode, message: String?)
    /// The worker returned a numeric error code outside the SDK's documented client
    /// (50001–52000) and server (52001–54000) ranges. These typically originate from
    /// installed addons (rag/embed/diffusion/etc.) which define their own code spaces.
    /// The wire format parsed cleanly — the error is a legitimate server response we
    /// just don't have a typed Swift enum case for.
    case serverUntyped(code: Int, message: String?)
    case transport(reason: String, underlying: Error? = nil)
    case protocolViolation(String)
    case encoding(String)

    public var description: String {
        switch self {
        case .client(let code, let m):
            return "QVAC client error \(code.rawValue) (\(code)): \(m ?? "no message")"
        case .server(let code, let m):
            return "QVAC server error \(code.rawValue) (\(code)): \(m ?? "no message")"
        case .serverUntyped(let code, let m):
            return "QVAC server error \(code) (addon-defined): \(m ?? "no message")"
        case .transport(let reason, _):
            return "QVAC transport error: \(reason)"
        case .protocolViolation(let r):
            return "QVAC protocol violation: \(r)"
        case .encoding(let r):
            return "QVAC encoding error: \(r)"
        }
    }

    /// Convenience constructor: map a numeric code from the wire into a typed error.
    /// Returns:
    /// - `.client(...)`        for codes 50001–52000 we have a typed enum case for
    /// - `.server(...)`        for codes 52001–54000 we have a typed enum case for
    /// - `.serverUntyped(...)` for any other numeric code (addon-defined / newer SDK)
    /// Never returns `.protocolViolation` for a numeric code — an unrecognized code is
    /// a known-shape error envelope from an addon, not a wire-format violation.
    public static func fromWire(code: Int, message: String?) -> QVACError {
        if let typed = QVACErrorCode(rawValue: code) {
            if (50001...52000).contains(code) { return .client(typed, message: message) }
            return .server(typed, message: message)
        }
        return .serverUntyped(code: code, message: message)
    }
}

/// Categories that group related error codes — useful for matching in `switch` statements
/// without enumerating every individual case.
public enum QVACErrorCategory: Sendable {
    case responseValidation
    case rpcCommunication
    case providerDelegation
    case buildBundle
    case profiler
    case modelRegistry
    case modelLoading
    case modelOperation
    case rag
    case download
    case cache
    case config
    case systemRuntime
    case lifecycle
    case serverRpcDelegation
    case plugin
    case security
    case other
}
