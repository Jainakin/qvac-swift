// CompactEncoding — Swift port of Holepunch's `compact-encoding` JS library.
// https://github.com/compact-encoding/compact-encoding
//
// Wire-compatible byte-for-byte with the JS reference (validated by fixtures generated
// from the JS impl; see Tests/Fixtures/compact-encoding.json).
//
// This is an INTERNAL implementation detail of QVACClient. It is not part of the
// public API. Public consumers should not import or depend on it directly.

import Foundation

// MARK: - Errors

public enum CompactEncodingError: Error, Equatable, Sendable {
    case outOfBounds
    case negativeUInt
    case invalidUTF8
    case incorrectFixedSize(expected: Int, got: Int)
}

// MARK: - Encoder state

/// Mirrors `compact-encoding`'s state object: `{ start, end, buffer }`.
/// `preencode` walks the value to compute the byte length (advancing `end`);
/// `encode` writes the bytes (advancing `start`); `decode` reads them.
public struct EncoderState: Sendable {
    public var start: Int
    public var end: Int
    public var buffer: Data

    public init(buffer: Data = Data()) {
        self.start = 0
        self.end = buffer.count
        self.buffer = buffer
    }
}

// MARK: - Codec protocol

public protocol CompactCodec: Sendable {
    associatedtype Value: Sendable
    func preencode(_ state: inout EncoderState, _ value: Value)
    func encode(_ state: inout EncoderState, _ value: Value)
    func decode(_ state: inout EncoderState) throws -> Value
}

public extension CompactCodec {
    /// Encode `value` to a fresh `Data` buffer.
    func encode(_ value: Value) -> Data {
        var state = EncoderState()
        preencode(&state, value)
        state.buffer = Data(count: state.end)
        state.start = 0
        encode(&state, value)
        return state.buffer
    }

    /// Decode `value` from a complete `Data` buffer (must contain exactly one encoded value).
    func decode(_ data: Data) throws -> Value {
        var state = EncoderState(buffer: data)
        return try decode(&state)
    }
}

// MARK: - Fixed-width uints

public struct UInt8Codec: CompactCodec {
    public init() {}
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
    public init() {}
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

public struct UInt24Codec: CompactCodec {
    public init() {}
    public func preencode(_ state: inout EncoderState, _ value: UInt64) { state.end += 3 }
    public func encode(_ state: inout EncoderState, _ value: UInt64) {
        for i in 0..<3 { state.buffer[state.start + i] = UInt8((value >> (8 * i)) & 0xff) }
        state.start += 3
    }
    public func decode(_ state: inout EncoderState) throws -> UInt64 {
        guard state.end - state.start >= 3 else { throw CompactEncodingError.outOfBounds }
        var v: UInt64 = 0
        for i in 0..<3 { v |= UInt64(state.buffer[state.start + i]) << (8 * i) }
        state.start += 3
        return v
    }
}

public struct UInt32Codec: CompactCodec {
    public init() {}
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
    public init() {}
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

// MARK: - Varints

/// Holepunch compact-encoding's `uint` varint:
/// `0..0xfc` → 1 byte raw;
/// `0xfd <uint16>` (3 bytes total);
/// `0xfe <uint32>` (5 bytes total);
/// `0xff <uint64>` (9 bytes total).
/// All multi-byte values are little-endian.
public struct UIntVarintCodec: CompactCodec {
    public init() {}
    public func preencode(_ state: inout EncoderState, _ value: UInt64) {
        if      value <= 0xfc       { state.end += 1 }
        else if value <= 0xffff     { state.end += 3 }
        else if value <= 0xffffffff { state.end += 5 }
        else                        { state.end += 9 }
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

/// ZigZag-encoded signed varint built on `UIntVarintCodec`.
/// Maps signed integers to unsigned via the standard zigzag scheme:
/// `0, -1, 1, -2, 2, ...` → `0, 1, 2, 3, 4, ...`.
public struct IntVarintCodec: CompactCodec {
    private let inner = UIntVarintCodec()
    public init() {}
    public func preencode(_ state: inout EncoderState, _ value: Int64) { inner.preencode(&state, zigzag(value)) }
    public func encode(_ state: inout EncoderState, _ value: Int64)    { inner.encode(&state, zigzag(value)) }
    public func decode(_ state: inout EncoderState) throws -> Int64    { unzigzag(try inner.decode(&state)) }

    /// ZigZag encoding maps Int64 → UInt64 without overflow at the boundaries.
    /// Standard bit-twiddle form: `(n << 1) ^ (n >> 63)`. Works for the full domain
    /// including `Int64.min` (which would trap under the arithmetic form).
    @inline(__always)
    private func zigzag(_ n: Int64) -> UInt64 {
        let shifted = UInt64(bitPattern: n &<< 1)
        let sign = UInt64(bitPattern: n &>> 63)
        return shifted ^ sign
    }
    @inline(__always)
    private func unzigzag(_ n: UInt64) -> Int64 {
        let raw = Int64(bitPattern: n &>> 1)
        let mask = Int64(bitPattern: 0 &- (n & 1))
        return raw ^ mask
    }
}

// MARK: - Primitives

public struct BoolCodec: CompactCodec {
    public init() {}
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

/// `utf8`: uint-prefixed UTF-8 string bytes.
public struct UTF8Codec: CompactCodec {
    private let uvar = UIntVarintCodec()
    public init() {}
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

/// `buffer`: uint-prefixed raw bytes.
public struct BufferCodec: CompactCodec {
    private let uvar = UIntVarintCodec()
    public init() {}
    public func preencode(_ state: inout EncoderState, _ value: Data) {
        uvar.preencode(&state, UInt64(value.count))
        state.end += value.count
    }
    public func encode(_ state: inout EncoderState, _ value: Data) {
        uvar.encode(&state, UInt64(value.count))
        value.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            state.buffer.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                let s = src.bindMemory(to: UInt8.self)
                for i in 0..<value.count { dst[state.start + i] = s[i] }
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

/// `optionalBuffer`: like `buffer` but a length of 0 decodes to `nil`.
/// Encoding `nil` (or empty `Data`) writes a single 0 byte.
public struct OptionalBufferCodec: CompactCodec {
    private let uvar = UIntVarintCodec()
    public init() {}
    public func preencode(_ state: inout EncoderState, _ value: Data?) {
        if let v = value, !v.isEmpty {
            uvar.preencode(&state, UInt64(v.count))
            state.end += v.count
        } else {
            state.end += 1
        }
    }
    public func encode(_ state: inout EncoderState, _ value: Data?) {
        if let v = value, !v.isEmpty {
            uvar.encode(&state, UInt64(v.count))
            v.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                state.buffer.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                    let s = src.bindMemory(to: UInt8.self)
                    for i in 0..<v.count { dst[state.start + i] = s[i] }
                }
            }
            state.start += v.count
        } else {
            state.buffer[state.start] = 0
            state.start += 1
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

/// Fixed-width raw bytes. The size is part of the codec, not the wire (so encoding a Data
/// whose length ≠ `size` is an error).
public struct FixedBytesCodec: CompactCodec {
    public let size: Int
    public init(size: Int) { self.size = size }
    public func preencode(_ state: inout EncoderState, _ value: Data) { state.end += size }
    public func encode(_ state: inout EncoderState, _ value: Data) {
        // We intentionally don't throw on size mismatch from encode (mirrors JS which throws
        // synchronously); we trap with a precondition for fail-fast bugs.
        precondition(value.count == size, "FixedBytesCodec(\(size)).encode: got \(value.count) bytes")
        value.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            state.buffer.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                let s = src.bindMemory(to: UInt8.self)
                for i in 0..<size { dst[state.start + i] = s[i] }
            }
        }
        state.start += size
    }
    public func decode(_ state: inout EncoderState) throws -> Data {
        guard state.end - state.start >= size else { throw CompactEncodingError.outOfBounds }
        let slice = state.buffer.subdata(in: state.start..<(state.start + size))
        state.start += size
        return slice
    }
}

// MARK: - Float

public struct Float32Codec: CompactCodec {
    public init() {}
    public func preencode(_ state: inout EncoderState, _ value: Float) { state.end += 4 }
    public func encode(_ state: inout EncoderState, _ value: Float) {
        var bits = value.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { src in
            state.buffer.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                let s = src.bindMemory(to: UInt8.self)
                for i in 0..<4 { dst[state.start + i] = s[i] }
            }
        }
        state.start += 4
    }
    public func decode(_ state: inout EncoderState) throws -> Float {
        guard state.end - state.start >= 4 else { throw CompactEncodingError.outOfBounds }
        var bits: UInt32 = 0
        for i in 0..<4 { bits |= UInt32(state.buffer[state.start + i]) << (8 * i) }
        state.start += 4
        return Float(bitPattern: bits)
    }
}

public struct Float64Codec: CompactCodec {
    public init() {}
    public func preencode(_ state: inout EncoderState, _ value: Double) { state.end += 8 }
    public func encode(_ state: inout EncoderState, _ value: Double) {
        var bits = value.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { src in
            state.buffer.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                let s = src.bindMemory(to: UInt8.self)
                for i in 0..<8 { dst[state.start + i] = s[i] }
            }
        }
        state.start += 8
    }
    public func decode(_ state: inout EncoderState) throws -> Double {
        guard state.end - state.start >= 8 else { throw CompactEncodingError.outOfBounds }
        var bits: UInt64 = 0
        for i in 0..<8 { bits |= UInt64(state.buffer[state.start + i]) << (8 * i) }
        state.start += 8
        return Double(bitPattern: bits)
    }
}

// MARK: - Higher-order

/// `array(Codec)`: uint-length-prefixed homogeneous list.
public struct ArrayCodec<E: CompactCodec>: CompactCodec {
    private let element: E
    private let uvar = UIntVarintCodec()
    /// JS reference enforces a hard cap to defend against pathological inputs.
    /// We mirror the same 0x100000 (≈1M elements) limit.
    public static var maxLength: Int { 0x100000 }
    public init(_ element: E) { self.element = element }
    public func preencode(_ state: inout EncoderState, _ value: [E.Value]) {
        uvar.preencode(&state, UInt64(value.count))
        for v in value { element.preencode(&state, v) }
    }
    public func encode(_ state: inout EncoderState, _ value: [E.Value]) {
        uvar.encode(&state, UInt64(value.count))
        for v in value { element.encode(&state, v) }
    }
    public func decode(_ state: inout EncoderState) throws -> [E.Value] {
        let n = Int(try uvar.decode(&state))
        if n > Self.maxLength { throw CompactEncodingError.outOfBounds }
        var out: [E.Value] = []
        out.reserveCapacity(n)
        for _ in 0..<n { out.append(try element.decode(&state)) }
        return out
    }
}

/// `frame(Codec)`: uint-prefixed by the SIZE of the encoded inner value.
/// Useful when the inner is variable-width and the consumer wants to skip ahead.
public struct FrameCodec<Inner: CompactCodec>: CompactCodec {
    private let inner: Inner
    private let uvar = UIntVarintCodec()
    public init(_ inner: Inner) { self.inner = inner }
    public func preencode(_ state: inout EncoderState, _ value: Inner.Value) {
        // Measure inner size first, then add its uint-length prefix.
        var probe = EncoderState()
        inner.preencode(&probe, value)
        let innerLen = probe.end
        uvar.preencode(&state, UInt64(innerLen))
        state.end += innerLen
    }
    public func encode(_ state: inout EncoderState, _ value: Inner.Value) {
        var probe = EncoderState()
        inner.preencode(&probe, value)
        let innerLen = probe.end
        uvar.encode(&state, UInt64(innerLen))
        inner.encode(&state, value)
    }
    public func decode(_ state: inout EncoderState) throws -> Inner.Value {
        let claimedLen = Int(try uvar.decode(&state))
        let originalEnd = state.end
        guard originalEnd - state.start >= claimedLen else { throw CompactEncodingError.outOfBounds }
        state.end = state.start + claimedLen
        let v = try inner.decode(&state)
        state.start = state.end
        state.end = originalEnd
        return v
    }
}

// MARK: - Singletons (mirrors JS `c.uint`, `c.utf8`, etc.)

public enum c {
    public static let uint8           = UInt8Codec()
    public static let uint16          = UInt16Codec()
    public static let uint24          = UInt24Codec()
    public static let uint32          = UInt32Codec()
    public static let uint64          = UInt64Codec()
    public static let uint            = UIntVarintCodec()
    public static let int             = IntVarintCodec()
    public static let bool            = BoolCodec()
    public static let utf8            = UTF8Codec()
    public static let buffer          = BufferCodec()
    public static let optionalBuffer  = OptionalBufferCodec()
    public static let float32         = Float32Codec()
    public static let float64         = Float64Codec()
    public static func fixed(_ n: Int) -> FixedBytesCodec { FixedBytesCodec(size: n) }
    public static func array<E: CompactCodec>(_ e: E) -> ArrayCodec<E> { ArrayCodec(e) }
    public static func frame<I: CompactCodec>(_ i: I) -> FrameCodec<I> { FrameCodec(i) }
}
