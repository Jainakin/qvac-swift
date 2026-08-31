import Foundation

extension QVACClient {
    /// Convert an untrusted JSON number to `Int` without invoking Swift's trapping
    /// floating-point conversion. Wire integer schemas still arrive as `Double`
    /// through `JSONValue`, so every rich wrapper uses this boundary check.
    internal static func checkedWireInteger(
        _ value: Double,
        field: String
    ) throws -> Int {
        let upperExclusive = -Double(Int.min)
        guard value.isFinite,
              value.rounded(.towardZero) == value,
              value >= Double(Int.min),
              value < upperExclusive else {
            throw QVACError.protocolViolation(
                "\(field) must be a finite in-range integer"
            )
        }
        return Int(value)
    }

    /// QVAC's generic error envelope permits an absent code; `0` is the existing
    /// unknown-error fallback. A present but malformed code is a protocol violation.
    internal static func checkedWireErrorCode(
        _ value: Double?,
        field: String = "error.code"
    ) throws -> Int {
        guard let value else { return 0 }
        return try checkedWireInteger(value, field: field)
    }

    /// Reject a response union member that does not belong to the active operation.
    /// Generic worker error envelopes keep their typed SDK mapping; every other
    /// discriminator mismatch is a protocol violation rather than ignorable noise.
    internal static func rejectUnexpectedResponse(
        _ response: QVACResponse,
        expected: String
    ) throws -> Never {
        if case .error(let error) = response {
            throw QVACError.fromWire(
                code: try checkedWireErrorCode(error.code),
                message: error.message
            )
        }
        throw QVACError.protocolViolation(
            "expected \(expected) response, got \(response.discriminator)"
        )
    }
}
