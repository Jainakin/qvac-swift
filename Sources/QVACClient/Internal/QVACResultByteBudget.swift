import Foundation

/// Validate strict, padded RFC 4648 base64 and derive its exact decoded byte
/// count without allocating decoded storage.
///
/// This deliberately accepts the same standard alphabet and terminal padding
/// shapes as the pinned SDK's anchored base64 schema. Callers can therefore
/// enforce decoded-byte limits before `Data(base64Encoded:)` allocates a
/// worker-controlled payload.
func qvacStrictBase64DecodedByteCount(_ value: String) -> Int? {
    var byteCount = 0
    var firstPaddingIndex: Int?
    var paddingCount = 0

    for byte in value.utf8 {
        let isAlphabet = (byte >= 65 && byte <= 90)
            || (byte >= 97 && byte <= 122)
            || (byte >= 48 && byte <= 57)
            || byte == 43
            || byte == 47
        if isAlphabet {
            guard firstPaddingIndex == nil else { return nil }
        } else if byte == 61 {
            if firstPaddingIndex == nil { firstPaddingIndex = byteCount }
            paddingCount += 1
            guard paddingCount <= 2 else { return nil }
        } else {
            return nil
        }
        let (nextByteCount, overflow) = byteCount.addingReportingOverflow(1)
        guard !overflow else { return nil }
        byteCount = nextByteCount
    }

    guard byteCount > 0, byteCount.isMultiple(of: 4) else { return nil }
    switch (firstPaddingIndex, paddingCount) {
    case (nil, 0):
        break
    case (.some(let index), 1):
        guard index % 4 == 3 else { return nil }
    case (.some(let index), 2):
        guard index % 4 == 2 else { return nil }
    default:
        return nil
    }

    // Division first keeps this below Int.max. Padding is at most two.
    return (byteCount / 4) * 3 - paddingCount
}

enum QVACBase64OutputRetention {
    case binaryArrayElement
    case contiguousDataAppend
}

extension QVACClient {
    /// Conservative retained-memory charge for appending text to an eager
    /// aggregate. Swift strings use UTF-8 storage and may grow capacity
    /// geometrically; charging twice the incoming UTF-8 bytes bounds that spare
    /// capacity without depending on runtime-private allocation details.
    static func retainedStringAggregateAppendBytes(_ value: String) -> Int {
        let (bytes, overflow) = value.utf8.count.multipliedReportingOverflow(by: 2)
        return overflow ? Int.max : bytes
    }

    /// Strictly preflight and charge a worker-controlled base64 result before
    /// allocating its decoded `Data`. The decoded value is returned only after
    /// its complete retained-memory charge succeeds.
    static func decodeRetainedBase64Output(
        _ encoded: String,
        invalidMessage: String,
        retention: QVACBase64OutputRetention,
        resultBudget: inout QVACResultByteBudget
    ) throws -> Data {
        guard let decodedByteCount = qvacStrictBase64DecodedByteCount(encoded),
              decodedByteCount > 0 else {
            throw QVACError.protocolViolation(invalidMessage)
        }

        let retainedByteCount = switch retention {
        case .binaryArrayElement:
            retainedBinaryArrayElementBytes(decodedByteCount)
        case .contiguousDataAppend:
            retainedContiguousDataAppendBytes(decodedByteCount)
        }
        try resultBudget.consume(retainedByteCount)

        // The strict preflight above guarantees validity and exact size. Keep
        // this defensive check so a platform decoder divergence still fails
        // closed rather than publishing a differently sized payload.
        guard let decoded = Data(base64Encoded: encoded),
              decoded.count == decodedByteCount else {
            throw QVACError.protocolViolation(invalidMessage)
        }
        return decoded
    }
}

/// Checked accounting for data retained by a high-level aggregate result.
///
/// Wire-record limits bound each frame independently. Aggregate helpers often
/// retain data from many valid records, so they need a separate cumulative
/// ceiling to prevent an otherwise valid stream from growing memory without
/// bound. The value type is intentionally local to one operation/task.
struct QVACResultByteBudget: Sendable {
    let operation: String
    let resource: String
    let maximumBytes: Int
    private(set) var consumedBytes = 0

    init(
        operation: String,
        resource: String = "accumulated result bytes",
        maximumBytes: Int
    ) {
        precondition(maximumBytes > 0)
        self.operation = operation
        self.resource = resource
        self.maximumBytes = maximumBytes
    }

    /// Charge bytes before allocating or appending them to the aggregate.
    mutating func consume(_ byteCount: Int) throws {
        guard byteCount >= 0 else {
            throw QVACError.invalidArgument(
                "\(operation) result byte count must not be negative"
            )
        }
        let (attemptedBytes, overflow) = consumedBytes.addingReportingOverflow(byteCount)
        guard !overflow, attemptedBytes <= maximumBytes else {
            throw QVACError.resourceLimitExceeded(
                operation: operation,
                resource: resource,
                maximumBytes: maximumBytes,
                attemptedBytes: overflow ? Int.max : attemptedBytes
            )
        }
        consumedBytes = attemptedBytes
    }

    mutating func consumeRetainedString(_ value: String) throws {
        try consume(QVACClient.retainedStringAggregateAppendBytes(value))
    }

    /// Replace the charge for a retained value that is overwritten rather than
    /// accumulated. The update is atomic: a rejected replacement leaves the
    /// previous charge in place.
    mutating func replace(_ previousByteCount: Int, with newByteCount: Int) throws {
        guard previousByteCount >= 0, newByteCount >= 0,
              previousByteCount <= consumedBytes else {
            throw QVACError.invalidArgument(
                "\(operation) replacement byte counts must describe retained result bytes"
            )
        }
        let retainedBytes = consumedBytes - previousByteCount
        let (attemptedBytes, overflow) = retainedBytes.addingReportingOverflow(newByteCount)
        guard !overflow, attemptedBytes <= maximumBytes else {
            throw QVACError.resourceLimitExceeded(
                operation: operation,
                resource: resource,
                maximumBytes: maximumBytes,
                attemptedBytes: overflow ? Int.max : attemptedBytes
            )
        }
        consumedBytes = attemptedBytes
    }
}
