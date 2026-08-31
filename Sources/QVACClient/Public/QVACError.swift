// QVACError — typed Swift errors matching the QVAC SDK's numeric error-code surface.
//
// THIS FILE IS PARTIALLY GENERATED. The `enum QVACErrorCode` and `category` accessor
// live in `Sources/QVACClient/Generated/QVACErrorCodes.generated.swift`, produced by
// `tools/codegen/run.sh` from the pinned @qvac/sdk 0.17.0
// `contract/error-codes.json` manifest. That manifest currently contains 136 codes:
// 3 registry, 38 client, and 95 server codes.
//
// This file contains the hand-written wrapper that maps an Int code from the wire onto
// a typed Swift case, plus the throwing surface consumers see.

import Foundation

/// The single error type thrown by all `QVACClient` methods on a server-side failure.
///
/// Public cases:
///   • `.client(code, message?)`  — error originated in the SDK's client layer (codes 50001–52000)
///   • `.server(code, message?)`  — error originated in the registry/worker
///                                  (codes 19001–19003 and 52001–54000)
///   • `.transport(_)`            — connection/transport failure
///   • `.requestTimedOut(...)`     — a local per-call RPC deadline elapsed
///   • `.invalidArgument(_)`       — the caller supplied an invalid local option
///   • `.protocolViolation(_)`    — server returned an unexpected shape
///   • `.encoding(_)`             — wire-level decode failed
public enum QVACError: Error, CustomStringConvertible, Sendable {
    case client(QVACErrorCode, message: String?)
    case server(QVACErrorCode, message: String?)
    /// The worker returned a numeric error code absent from the pinned 0.17
    /// `contract/error-codes.json` manifest. This can originate from an installed
    /// add-on with its own code space or a newer worker contract. The wire format
    /// parsed cleanly; Swift simply has no typed enum case for that code.
    case serverUntyped(code: Int, message: String?)
    case transport(reason: String, underlying: Error? = nil)
    case requestTimedOut(operation: String, after: Duration)
    case streamBufferOverflow(operation: String, maximumBytes: Int, attemptedBytes: Int)
    case invalidArgument(String)
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
        case .requestTimedOut(let operation, let timeout):
            return "QVAC request '\(operation)' timed out after \(timeout)"
        case .streamBufferOverflow(let operation, let maximumBytes, let attemptedBytes):
            return "QVAC stream '\(operation)' exceeded its \(maximumBytes)-byte buffer "
                + "(attempted \(attemptedBytes) bytes)"
        case .invalidArgument(let reason):
            return "QVAC invalid argument: \(reason)"
        case .protocolViolation(let r):
            return "QVAC protocol violation: \(r)"
        case .encoding(let r):
            return "QVAC encoding error: \(r)"
        }
    }

    /// Convenience constructor: map a numeric code from the wire into a typed error.
    /// Returns:
    /// - `.client(...)`        for codes 50001–52000 we have a typed enum case for
    /// - `.server(...)`        for typed registry (19001–19003) and worker
    ///                         (52001–54000) codes
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
    case registry
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
