// BareRPCWire — wire-level types and codec for the `bare-rpc` protocol.
// https://github.com/holepunchto/bare-rpc
//
// The wire model is a length-prefixed frame:
//
//     [uint32 LE frame_length]                       <- not counted in itself
//     [varuint type]                                 <- 1=REQUEST, 2=RESPONSE, 3=STREAM
//     [varuint id]                                   <- message id (auto-allocated)
//     [per-type fields]
//     [varuint dataLen?][raw data bytes?]            <- present when the frame carries data
//
// Stream lifecycle is encoded via a bitmask in the `stream` field; see `BareRPCStreamFlags`.
// The codec is symmetric with the JS reference implementation. We validate this via
// Tests/Fixtures/bare-rpc-frames/*.bin, which is produced by running the JS encoder
// over a known set of messages.
//
// This module is INTERNAL. Public consumers use `QVACClient` which composes this codec
// inside a higher-level Request/Response abstraction.

import Foundation

// MARK: - Message type tag (header position 1)

public enum BareRPCMessageType: UInt64, Sendable {
    case request  = 1
    case response = 2
    case stream   = 3
}

// MARK: - Stream flag bitmask (carries lifecycle + direction)
//
// Mirrors `bare-rpc/lib/constants.js` exactly.
// Direction bits 0x100 / 0x200 distinguish the OUTGOING request-stream from the
// INCOMING response-stream when a single message id has both.

public struct BareRPCStreamFlags: OptionSet, Sendable, Hashable, CustomStringConvertible {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static let open     = BareRPCStreamFlags(rawValue: 0x1)
    public static let close    = BareRPCStreamFlags(rawValue: 0x2)
    public static let pause    = BareRPCStreamFlags(rawValue: 0x4)
    public static let resume   = BareRPCStreamFlags(rawValue: 0x8)
    public static let data     = BareRPCStreamFlags(rawValue: 0x10)
    public static let end      = BareRPCStreamFlags(rawValue: 0x20)
    public static let destroy  = BareRPCStreamFlags(rawValue: 0x40)
    public static let error    = BareRPCStreamFlags(rawValue: 0x80)
    public static let request  = BareRPCStreamFlags(rawValue: 0x100)
    public static let response = BareRPCStreamFlags(rawValue: 0x200)

    public var description: String {
        if rawValue == 0 { return "[]" }
        var parts: [String] = []
        if contains(.open)     { parts.append("OPEN") }
        if contains(.close)    { parts.append("CLOSE") }
        if contains(.pause)    { parts.append("PAUSE") }
        if contains(.resume)   { parts.append("RESUME") }
        if contains(.data)     { parts.append("DATA") }
        if contains(.end)      { parts.append("END") }
        if contains(.destroy)  { parts.append("DESTROY") }
        if contains(.error)    { parts.append("ERROR") }
        if contains(.request)  { parts.append("REQUEST") }
        if contains(.response) { parts.append("RESPONSE") }
        return "[" + parts.joined(separator: "|") + "]"
    }
}

// MARK: - Errors

/// Wire-level error payload carried inside a `RESPONSE` or `STREAM(ERROR)` frame.
/// Mirrors the JS `error = { message: utf8, code: utf8, errno: int }`.
public struct BareRPCError: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String
    public let code: String
    public let errno: Int64
    public init(message: String, code: String, errno: Int64) {
        self.message = message
        self.code = code
        self.errno = errno
    }
    public var description: String { "\(code) \(message) (errno=\(errno))" }
}

public enum BareRPCCodecError: Error, Equatable, Sendable {
    case truncated
    case unknownType(UInt64)
}

// MARK: - Decoded frame

public enum BareRPCFrame: Sendable, Equatable {
    case request(id: UInt64, command: UInt64, stream: BareRPCStreamFlags, data: Data?)
    case response(id: UInt64, stream: BareRPCStreamFlags, payload: BareRPCResponsePayload)
    case stream(id: UInt64, flags: BareRPCStreamFlags, payload: BareRPCStreamPayload)

    public var id: UInt64 {
        switch self {
        case .request(let id, _, _, _),
             .response(let id, _, _),
             .stream(let id, _, _):
            return id
        }
    }
}

public enum BareRPCResponsePayload: Sendable, Equatable {
    case success(Data?)
    case failure(BareRPCError)
}

public enum BareRPCStreamPayload: Sendable, Equatable {
    /// `DATA` flag — chunk of bytes inside the stream.
    case data(Data)
    /// `ERROR` flag — error carried inline.
    case error(BareRPCError)
    /// `OPEN`, `CLOSE`, `PAUSE`, `RESUME`, `END`, `DESTROY` — lifecycle frames with no data.
    case control
}

// MARK: - Codec

public enum BareRPCCodec {

    // MARK: Encode

    /// Encode the body of a REQUEST (without the outer uint32 length prefix).
    public static func encodeRequestBody(
        id: UInt64,
        command: UInt64,
        stream: BareRPCStreamFlags = [],
        data: Data?
    ) -> Data {
        var state = EncoderState()
        c.uint.preencode(&state, BareRPCMessageType.request.rawValue)
        c.uint.preencode(&state, id)
        c.uint.preencode(&state, command)
        c.uint.preencode(&state, stream.rawValue)
        let hasData = stream.rawValue == 0
        let payload = data ?? Data()
        if hasData { c.uint.preencode(&state, UInt64(payload.count)) }

        let headerLen = state.end
        let totalLen = headerLen + (hasData ? payload.count : 0)
        state.buffer = Data(count: totalLen)
        state.start = 0
        c.uint.encode(&state, BareRPCMessageType.request.rawValue)
        c.uint.encode(&state, id)
        c.uint.encode(&state, command)
        c.uint.encode(&state, stream.rawValue)
        if hasData {
            c.uint.encode(&state, UInt64(payload.count))
            appendPayload(into: &state, payload: payload)
        }
        return state.buffer
    }

    /// Encode the body of a RESPONSE (without the outer uint32 length prefix).
    public static func encodeResponseBody(
        id: UInt64,
        stream: BareRPCStreamFlags,
        payload: BareRPCResponsePayload
    ) -> Data {
        var state = EncoderState()
        c.uint.preencode(&state, BareRPCMessageType.response.rawValue)
        c.uint.preencode(&state, id)
        let hasError: Bool
        let data: Data
        switch payload {
        case .failure(let err):
            hasError = true; data = Data()
            c.bool.preencode(&state, true)
            c.uint.preencode(&state, stream.rawValue)
            preencodeError(&state, err)
        case .success(let d):
            hasError = false; data = d ?? Data()
            c.bool.preencode(&state, false)
            c.uint.preencode(&state, stream.rawValue)
            if stream.rawValue == 0 {
                c.uint.preencode(&state, UInt64(data.count))
            }
        }
        let headerLen = state.end
        let totalLen = headerLen + ((!hasError && stream.rawValue == 0) ? data.count : 0)
        state.buffer = Data(count: totalLen)
        state.start = 0
        c.uint.encode(&state, BareRPCMessageType.response.rawValue)
        c.uint.encode(&state, id)
        switch payload {
        case .failure(let err):
            c.bool.encode(&state, true)
            c.uint.encode(&state, stream.rawValue)
            encodeError(&state, err)
        case .success:
            c.bool.encode(&state, false)
            c.uint.encode(&state, stream.rawValue)
            if stream.rawValue == 0 {
                c.uint.encode(&state, UInt64(data.count))
                appendPayload(into: &state, payload: data)
            }
        }
        return state.buffer
    }

    /// Encode the body of a STREAM frame (without the outer uint32 length prefix).
    public static func encodeStreamBody(
        id: UInt64,
        flags: BareRPCStreamFlags,
        payload: BareRPCStreamPayload = .control
    ) -> Data {
        var state = EncoderState()
        c.uint.preencode(&state, BareRPCMessageType.stream.rawValue)
        c.uint.preencode(&state, id)
        c.uint.preencode(&state, flags.rawValue)
        var dataBytes: Data = Data()
        switch payload {
        case .error(let e):
            preencodeError(&state, e)
        case .data(let d):
            dataBytes = d
            c.uint.preencode(&state, UInt64(d.count))
        case .control:
            break
        }
        let headerLen = state.end
        let totalLen = headerLen + dataBytes.count
        state.buffer = Data(count: totalLen)
        state.start = 0
        c.uint.encode(&state, BareRPCMessageType.stream.rawValue)
        c.uint.encode(&state, id)
        c.uint.encode(&state, flags.rawValue)
        switch payload {
        case .error(let e):
            encodeError(&state, e)
        case .data(let d):
            c.uint.encode(&state, UInt64(d.count))
            appendPayload(into: &state, payload: d)
        case .control:
            break
        }
        return state.buffer
    }

    // MARK: Frame wrappers (prepend uint32 LE length)

    public static func encodeRequestFrame(
        id: UInt64, command: UInt64, stream: BareRPCStreamFlags = [], data: Data?
    ) -> Data {
        return prefixWithLength(encodeRequestBody(id: id, command: command, stream: stream, data: data))
    }
    public static func encodeResponseFrame(
        id: UInt64, stream: BareRPCStreamFlags, payload: BareRPCResponsePayload
    ) -> Data {
        return prefixWithLength(encodeResponseBody(id: id, stream: stream, payload: payload))
    }
    public static func encodeStreamFrame(
        id: UInt64, flags: BareRPCStreamFlags, payload: BareRPCStreamPayload = .control
    ) -> Data {
        return prefixWithLength(encodeStreamBody(id: id, flags: flags, payload: payload))
    }

    // MARK: Decode

    /// Decode a complete frame body (everything after the uint32 LE length prefix).
    public static func decodeFrameBody(_ body: Data) throws -> BareRPCFrame {
        var state = EncoderState(buffer: body)
        let type = try c.uint.decode(&state)
        let id = try c.uint.decode(&state)
        switch type {
        case BareRPCMessageType.request.rawValue:
            let command = try c.uint.decode(&state)
            let streamRaw = try c.uint.decode(&state)
            let flags = BareRPCStreamFlags(rawValue: streamRaw)
            let data: Data? = streamRaw == 0 ? try readDataField(&state) : nil
            return .request(id: id, command: command, stream: flags, data: data)

        case BareRPCMessageType.response.rawValue:
            let hasError = try c.bool.decode(&state)
            let streamRaw = try c.uint.decode(&state)
            let flags = BareRPCStreamFlags(rawValue: streamRaw)
            if hasError {
                let err = try readError(&state)
                return .response(id: id, stream: flags, payload: .failure(err))
            }
            if streamRaw == 0 {
                let data = try readDataField(&state)
                return .response(id: id, stream: flags, payload: .success(data))
            }
            return .response(id: id, stream: flags, payload: .success(nil))

        case BareRPCMessageType.stream.rawValue:
            let streamRaw = try c.uint.decode(&state)
            let flags = BareRPCStreamFlags(rawValue: streamRaw)
            if flags.contains(.error) {
                let err = try readError(&state)
                return .stream(id: id, flags: flags, payload: .error(err))
            }
            if flags.contains(.data) {
                let data = try readDataField(&state) ?? Data()
                return .stream(id: id, flags: flags, payload: .data(data))
            }
            return .stream(id: id, flags: flags, payload: .control)

        default:
            throw BareRPCCodecError.unknownType(type)
        }
    }

    // MARK: Helpers

    private static func prefixWithLength(_ body: Data) -> Data {
        var out = Data(count: 4 + body.count)
        let bodyLen = UInt32(body.count)
        for i in 0..<4 { out[i] = UInt8((bodyLen >> (8 * i)) & 0xff) }
        body.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                let s = src.bindMemory(to: UInt8.self)
                for i in 0..<body.count { dst[4 + i] = s[i] }
            }
        }
        return out
    }

    private static func appendPayload(into state: inout EncoderState, payload: Data) {
        payload.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            state.buffer.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                let s = src.bindMemory(to: UInt8.self)
                for i in 0..<payload.count { dst[state.start + i] = s[i] }
            }
        }
        state.start += payload.count
    }

    private static func readDataField(_ state: inout EncoderState) throws -> Data? {
        let len = Int(try c.uint.decode(&state))
        if len == 0 { return nil }
        guard state.end - state.start >= len else { throw BareRPCCodecError.truncated }
        let d = state.buffer.subdata(in: state.start..<(state.start + len))
        state.start += len
        return d
    }

    private static func preencodeError(_ state: inout EncoderState, _ e: BareRPCError) {
        c.utf8.preencode(&state, e.message)
        c.utf8.preencode(&state, e.code)
        c.int.preencode(&state, e.errno)
    }

    private static func encodeError(_ state: inout EncoderState, _ e: BareRPCError) {
        c.utf8.encode(&state, e.message)
        c.utf8.encode(&state, e.code)
        c.int.encode(&state, e.errno)
    }

    private static func readError(_ state: inout EncoderState) throws -> BareRPCError {
        let message = try c.utf8.decode(&state)
        let code = try c.utf8.decode(&state)
        let errno = try c.int.decode(&state)
        return BareRPCError(message: message, code: code, errno: errno)
    }
}

// MARK: - Streaming frame reader

/// A push-style decoder: feed bytes via `append(_:)`, pull complete frames via `next()`.
/// Implements the two-state machine `awaitingLength → awaitingBody → awaitingLength`
/// mirroring `bare-rpc/index.js:_onbeforeframe → _onafterframe`.
///
/// Uses an explicit `consumed` offset instead of `Data.removeFirst()` because Data's
/// subscript can be index-absolute after removeFirst, which silently crashes on
/// multi-frame inputs. The buffer compacts when consumed > 64KB.
public final class BareRPCFrameReader {
    public init() {}

    private enum State { case awaitingLength; case awaitingBody(needed: Int) }

    private var buffer = Data()
    private var consumed = 0
    private var state: State = .awaitingLength
    private var pending: [BareRPCFrame] = []
    private static let compactThreshold = 64 * 1024

    /// Feed bytes from the wire. Throws on protocol-level decode failures (truncation
    /// is NOT an error — the reader simply waits for more bytes).
    public func append(_ data: Data) throws {
        if consumed > Self.compactThreshold {
            buffer = Data(buffer.suffix(from: buffer.startIndex + consumed))
            consumed = 0
        }
        buffer.append(data)
        try drain()
    }

    /// Pull the next fully-decoded frame, or `nil` if none ready yet.
    public func next() -> BareRPCFrame? {
        guard !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }

    /// Number of bytes buffered but not yet decoded (after consumed bytes).
    public var bufferedBytes: Int { buffer.count - consumed }

    private func drain() throws {
        while true {
            switch state {
            case .awaitingLength:
                guard remaining >= 4 else { return }
                var n: UInt32 = 0
                for i in 0..<4 { n |= UInt32(byte(at: i)) << (8 * i) }
                consumed += 4
                state = .awaitingBody(needed: Int(n))
            case .awaitingBody(let needed):
                guard remaining >= needed else { return }
                let body = sliceBytes(needed)
                consumed += needed
                let frame = try BareRPCCodec.decodeFrameBody(body)
                pending.append(frame)
                state = .awaitingLength
            }
        }
    }

    private var remaining: Int { buffer.count - consumed }
    private func byte(at relative: Int) -> UInt8 {
        return buffer[buffer.startIndex + consumed + relative]
    }
    private func sliceBytes(_ length: Int) -> Data {
        let start = buffer.startIndex + consumed
        return buffer.subdata(in: start..<(start + length))
    }
}
