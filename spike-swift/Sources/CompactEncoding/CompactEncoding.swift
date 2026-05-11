import Foundation

public enum CompactEncodingError: Error, Equatable {
    case outOfBounds
    case negativeUInt
    case invalidUTF8
}

public struct EncoderState {
    public var start: Int
    public var end: Int
    public var buffer: Data

    public init(buffer: Data = Data()) {
        self.start = 0
        self.end = buffer.count
        self.buffer = buffer
    }
}

public protocol CompactCodec {
    associatedtype Value
    func preencode(_ state: inout EncoderState, _ value: Value)
    func encode(_ state: inout EncoderState, _ value: Value)
    func decode(_ state: inout EncoderState) throws -> Value
}

public extension CompactCodec {
    func encode(_ value: Value) -> Data {
        var state = EncoderState()
        preencode(&state, value)
        state.buffer = Data(count: state.end)
        state.start = 0
        encode(&state, value)
        return state.buffer
    }

    func decode(_ data: Data) throws -> Value {
        var state = EncoderState(buffer: data)
        state.start = 0
        state.end = data.count
        return try decode(&state)
    }
}

// MARK: - Primitives

public struct UInt8Codec: CompactCodec {
    public func preencode(_ state: inout EncoderState, _ value: UInt64) { state.end += 1 }
    public func encode(_ state: inout EncoderState, _ value: UInt64) {
        state.buffer[state.start] = UInt8(value & 0xff)
        state.start += 1
    }
    public func decode(_ state: inout EncoderState) throws -> UInt64 {
        guard state.start < state.end else { throw CompactEncodingError.outOfBounds }
        let b = state.buffer[state.start]
        state.start += 1
        return UInt64(b)
    }
}

public struct UInt16Codec: CompactCodec {
    public func preencode(_ state: inout EncoderState, _ value: UInt64) { state.end += 2 }
    public func encode(_ state: inout EncoderState, _ value: UInt64) {
        state.buffer[state.start]     = UInt8(value        & 0xff)
        state.buffer[state.start + 1] = UInt8((value >> 8) & 0xff)
        state.start += 2
    }
    public func decode(_ state: inout EncoderState) throws -> UInt64 {
        guard state.end - state.start >= 2 else { throw CompactEncodingError.outOfBounds }
        let v = UInt64(state.buffer[state.start]) | (UInt64(state.buffer[state.start + 1]) << 8)
        state.start += 2
        return v
    }
}

public struct UInt32Codec: CompactCodec {
    public func preencode(_ state: inout EncoderState, _ value: UInt64) { state.end += 4 }
    public func encode(_ state: inout EncoderState, _ value: UInt64) {
        for i in 0..<4 { state.buffer[state.start + i] = UInt8((value >> (8 * i)) & 0xff) }
        state.start += 4
    }
    public func decode(_ state: inout EncoderState) throws -> UInt64 {
        guard state.end - state.start >= 4 else { throw CompactEncodingError.outOfBounds }
        var v: UInt64 = 0
        for i in 0..<4 { v |= UInt64(state.buffer[state.start + i]) << (8 * i) }
        state.start += 4
        return v
    }
}

public struct UInt64Codec: CompactCodec {
    public func preencode(_ state: inout EncoderState, _ value: UInt64) { state.end += 8 }
    public func encode(_ state: inout EncoderState, _ value: UInt64) {
        for i in 0..<8 { state.buffer[state.start + i] = UInt8((value >> (8 * i)) & 0xff) }
        state.start += 8
    }
    public func decode(_ state: inout EncoderState) throws -> UInt64 {
        guard state.end - state.start >= 8 else { throw CompactEncodingError.outOfBounds }
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(state.buffer[state.start + i]) << (8 * i) }
        state.start += 8
        return v
    }
}

/// Holepunch compact-encoding's `uint` varint:
/// `0..0xfc` → 1 byte raw; `0xfd <uint16>`; `0xfe <uint32>`; `0xff <uint64>`. All little-endian.
public struct UIntVarintCodec: CompactCodec {
    public func preencode(_ state: inout EncoderState, _ value: UInt64) {
        if value <= 0xfc      { state.end += 1 }
        else if value <= 0xffff      { state.end += 3 }
        else if value <= 0xffffffff  { state.end += 5 }
        else                         { state.end += 9 }
    }
    public func encode(_ state: inout EncoderState, _ value: UInt64) {
        if value <= 0xfc {
            state.buffer[state.start] = UInt8(value); state.start += 1
        } else if value <= 0xffff {
            state.buffer[state.start] = 0xfd; state.start += 1
            UInt16Codec().encode(&state, value)
        } else if value <= 0xffffffff {
            state.buffer[state.start] = 0xfe; state.start += 1
            UInt32Codec().encode(&state, value)
        } else {
            state.buffer[state.start] = 0xff; state.start += 1
            UInt64Codec().encode(&state, value)
        }
    }
    public func decode(_ state: inout EncoderState) throws -> UInt64 {
        guard state.start < state.end else { throw CompactEncodingError.outOfBounds }
        let tag = state.buffer[state.start]
        if tag <= 0xfc { state.start += 1; return UInt64(tag) }
        state.start += 1
        switch tag {
        case 0xfd: return try UInt16Codec().decode(&state)
        case 0xfe: return try UInt32Codec().decode(&state)
        default:   return try UInt64Codec().decode(&state)
        }
    }
}

/// ZigZag-encoded int: 0, -1, 1, -2, 2, ... → 0, 1, 2, 3, 4, ...
public struct IntVarintCodec: CompactCodec {
    private let inner = UIntVarintCodec()
    public func preencode(_ state: inout EncoderState, _ value: Int64) { inner.preencode(&state, zigzag(value)) }
    public func encode(_ state: inout EncoderState, _ value: Int64) { inner.encode(&state, zigzag(value)) }
    public func decode(_ state: inout EncoderState) throws -> Int64 { unzigzag(try inner.decode(&state)) }

    private func zigzag(_ n: Int64) -> UInt64 {
        if n < 0 { return UInt64(bitPattern: 2 * -n - 1) }
        if n == 0 { return 0 }
        return UInt64(2 * n)
    }
    private func unzigzag(_ n: UInt64) -> Int64 {
        if n == 0 { return 0 }
        if (n & 1) == 0 { return Int64(n / 2) }
        return -Int64((n + 1) / 2)
    }
}

public struct BoolCodec: CompactCodec {
    public func preencode(_ state: inout EncoderState, _ value: Bool) { state.end += 1 }
    public func encode(_ state: inout EncoderState, _ value: Bool) {
        state.buffer[state.start] = value ? 1 : 0
        state.start += 1
    }
    public func decode(_ state: inout EncoderState) throws -> Bool {
        guard state.start < state.end else { throw CompactEncodingError.outOfBounds }
        let b = state.buffer[state.start] == 1
        state.start += 1
        return b
    }
}

/// `utf8` = uint-prefixed UTF-8 bytes.
public struct UTF8Codec: CompactCodec {
    private let uvar = UIntVarintCodec()
    public func preencode(_ state: inout EncoderState, _ value: String) {
        let len = value.utf8.count
        uvar.preencode(&state, UInt64(len))
        state.end += len
    }
    public func encode(_ state: inout EncoderState, _ value: String) {
        let bytes = Array(value.utf8)
        uvar.encode(&state, UInt64(bytes.count))
        for i in 0..<bytes.count { state.buffer[state.start + i] = bytes[i] }
        state.start += bytes.count
    }
    public func decode(_ state: inout EncoderState) throws -> String {
        let len = Int(try uvar.decode(&state))
        guard state.end - state.start >= len else { throw CompactEncodingError.outOfBounds }
        let slice = state.buffer.subdata(in: state.start..<(state.start + len))
        state.start += len
        guard let s = String(data: slice, encoding: .utf8) else { throw CompactEncodingError.invalidUTF8 }
        return s
    }
}

/// `buffer` = uint-prefixed raw bytes.
public struct BufferCodec: CompactCodec {
    private let uvar = UIntVarintCodec()
    public func preencode(_ state: inout EncoderState, _ value: Data) {
        uvar.preencode(&state, UInt64(value.count))
        state.end += value.count
    }
    public func encode(_ state: inout EncoderState, _ value: Data) {
        uvar.encode(&state, UInt64(value.count))
        value.withUnsafeBytes { raw in
            for i in 0..<value.count {
                state.buffer[state.start + i] = raw.bindMemory(to: UInt8.self)[i]
            }
        }
        state.start += value.count
    }
    public func decode(_ state: inout EncoderState) throws -> Data {
        let len = Int(try uvar.decode(&state))
        guard state.end - state.start >= len else { throw CompactEncodingError.outOfBounds }
        let slice = state.buffer.subdata(in: state.start..<(state.start + len))
        state.start += len
        return slice
    }
}

/// `optionalBuffer` = like buffer, but a length of 0 decodes to nil. Encoding nil writes a single 0 byte.
public struct OptionalBufferCodec: CompactCodec {
    private let uvar = UIntVarintCodec()
    public func preencode(_ state: inout EncoderState, _ value: Data?) {
        if let v = value { uvar.preencode(&state, UInt64(v.count)); state.end += v.count }
        else             { state.end += 1 }
    }
    public func encode(_ state: inout EncoderState, _ value: Data?) {
        if let v = value, !v.isEmpty {
            uvar.encode(&state, UInt64(v.count))
            v.withUnsafeBytes { raw in
                for i in 0..<v.count {
                    state.buffer[state.start + i] = raw.bindMemory(to: UInt8.self)[i]
                }
            }
            state.start += v.count
        } else {
            state.buffer[state.start] = 0; state.start += 1
        }
    }
    public func decode(_ state: inout EncoderState) throws -> Data? {
        let len = Int(try uvar.decode(&state))
        if len == 0 { return nil }
        guard state.end - state.start >= len else { throw CompactEncodingError.outOfBounds }
        let slice = state.buffer.subdata(in: state.start..<(state.start + len))
        state.start += len
        return slice
    }
}

// MARK: - Singleton accessors

public enum c {
    public static let uint8 = UInt8Codec()
    public static let uint16 = UInt16Codec()
    public static let uint32 = UInt32Codec()
    public static let uint64 = UInt64Codec()
    public static let uint = UIntVarintCodec()
    public static let int = IntVarintCodec()
    public static let bool = BoolCodec()
    public static let utf8 = UTF8Codec()
    public static let buffer = BufferCodec()
    public static let optionalBuffer = OptionalBufferCodec()
}
