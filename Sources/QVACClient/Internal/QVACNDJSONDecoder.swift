import Foundation
import CoreFoundation

enum QVACNDJSONError: Error, Sendable, Equatable, CustomStringConvertible {
    case recordTooLarge(limit: Int)

    var description: String {
        switch self {
        case .recordTooLarge(let limit):
            return "NDJSON record exceeds the \(limit)-byte limit"
        }
    }
}

/// Incremental newline-delimited JSON framing shared by every QVAC streaming path.
///
/// Transport frames and JSON records have no 1:1 relationship: one transport DATA
/// frame may contain many lines and one line may span many DATA frames. This type
/// retains only the unfinished suffix and periodically compacts consumed storage, so
/// token-heavy streams do not exhibit quadratic prefix removal behavior.
struct QVACNDJSONDecoder: Sendable {
    static let defaultMaximumRecordBytes = QVACClient.defaultMaximumWireMessageBytes

    private var bytes: [UInt8] = []
    private var recordStart = 0
    private var scanIndex = 0
    private let maximumRecordBytes: Int

    init(maximumRecordBytes: Int = Self.defaultMaximumRecordBytes) {
        precondition(maximumRecordBytes > 0)
        self.maximumRecordBytes = maximumRecordBytes
    }

    mutating func append(_ chunk: Data) throws -> [Data] {
        receive(chunk)
        var records: [Data] = []
        while let record = try nextRecord() {
            records.append(record)
        }
        return records
    }

    /// Retain a transport chunk without eagerly materializing every line it contains.
    /// Demand-driven consumers pair this with `nextRecord()` so one coalesced wire frame
    /// cannot expand into an unbounded array of decoded Swift response values.
    mutating func receive(_ chunk: Data) {
        bytes.append(contentsOf: chunk)
    }

    /// Return at most one non-blank record. With `finalizing` set, an unterminated
    /// residual record is returned and the decoder is reset after all complete lines.
    mutating func nextRecord(finalizing: Bool = false) throws -> Data? {
        while scanIndex < bytes.count {
            if bytes[scanIndex] == 0x0A {
                guard scanIndex - recordStart <= maximumRecordBytes else {
                    throw QVACNDJSONError.recordTooLarge(limit: maximumRecordBytes)
                }
                let record = Self.trimmedRecord(bytes[recordStart..<scanIndex])
                scanIndex += 1
                recordStart = scanIndex
                compactIfNeeded()
                if let record { return record }
            } else {
                scanIndex += 1
                if scanIndex - recordStart > maximumRecordBytes {
                    throw QVACNDJSONError.recordTooLarge(limit: maximumRecordBytes)
                }
            }
        }

        try enforceRecordLimit()
        guard finalizing else { return nil }
        let record = Self.trimmedRecord(bytes[recordStart..<bytes.count])
        reset()
        return record
    }

    mutating func finish() throws -> [Data] {
        var records: [Data] = []
        while let record = try nextRecord() {
            records.append(record)
        }
        if let residual = try nextRecord(finalizing: true) {
            records.append(residual)
        }
        return records
    }

    private mutating func reset() {
        bytes.removeAll(keepingCapacity: false)
        recordStart = 0
        scanIndex = 0
    }

    /// Profiling-enabled workers may append a metadata-only record that is not a
    /// domain `QVACResponse`. The marker is recognized only at the top level and only
    /// when its JSON value is the Boolean `true`; malformed or lookalike records still
    /// flow into normal response decoding and fail loudly.
    static func isProfilingTrailer(_ record: Data) -> Bool {
        let marker = Data("\"__profilingTrailer\"".utf8)
        guard record.range(of: marker) != nil,
              let object = try? JSONSerialization.jsonObject(with: record) as? [String: Any],
              object["type"] == nil,
              Set(object.keys).isSubset(of: ["__profilingTrailer", "__profiling"]),
              let value = object["__profilingTrailer"],
              CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID(),
              (value as? NSNumber)?.boolValue == true
        else {
            return false
        }
        return true
    }

    private mutating func enforceRecordLimit() throws {
        if bytes.count - recordStart > maximumRecordBytes {
            throw QVACNDJSONError.recordTooLarge(limit: maximumRecordBytes)
        }
    }

    private mutating func compactIfNeeded() {
        guard recordStart > 64 * 1024, recordStart >= bytes.count / 2 else { return }
        bytes.removeFirst(recordStart)
        scanIndex -= recordStart
        recordStart = 0
    }

    private static func trimmedRecord(_ slice: ArraySlice<UInt8>) -> Data? {
        var lower = slice.startIndex
        var upper = slice.endIndex
        while lower < upper, isJSONWhitespace(slice[lower]) {
            lower += 1
        }
        while upper > lower {
            let candidate = slice.index(before: upper)
            guard isJSONWhitespace(slice[candidate]) else { break }
            upper = candidate
        }
        guard lower < upper else { return nil }
        return Data(slice[lower..<upper])
    }

    private static func isJSONWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }
}
