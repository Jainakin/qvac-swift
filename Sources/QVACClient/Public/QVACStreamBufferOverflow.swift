import Foundation

/// A bounded, lossless public event view could not keep up with its producer.
///
/// QVAC run results continue aggregating independently; only the lagging lossless
/// view is terminated. Observational progress streams use a separate sliding-window
/// policy because intermediate progress snapshots may be safely coalesced.
public struct QVACStreamBufferOverflow: Error, Sendable, Equatable, CustomStringConvertible {
    public let stream: String
    public let capacity: Int
    /// Byte budget for a batch-aware stream, or `nil` for an element-only stream.
    public let maximumBufferedBytes: Int?
    /// Retained bytes the rejected batch would have required, when known.
    public let attemptedBufferedBytes: Int?

    public init(stream: String, capacity: Int) {
        self.stream = stream
        self.capacity = capacity
        self.maximumBufferedBytes = nil
        self.attemptedBufferedBytes = nil
    }

    public init(
        stream: String,
        capacity: Int,
        maximumBufferedBytes: Int,
        attemptedBufferedBytes: Int
    ) {
        self.stream = stream
        self.capacity = capacity
        self.maximumBufferedBytes = maximumBufferedBytes
        self.attemptedBufferedBytes = attemptedBufferedBytes
    }

    public var description: String {
        if let maximumBufferedBytes, let attemptedBufferedBytes {
            return "QVAC stream '\(stream)' exceeded its \(capacity)-batch / "
                + "\(maximumBufferedBytes)-byte buffer (attempted \(attemptedBufferedBytes) bytes)"
        }
        return "QVAC stream '\(stream)' exceeded its \(capacity)-element buffer"
    }
}

enum QVACStreamDropBehavior: Sendable, Equatable {
    /// Every element is semantically significant. Terminate rather than lose data.
    case fail
    /// Elements are observational state snapshots. Retain the newest bounded window.
    case coalesceNewest
}
