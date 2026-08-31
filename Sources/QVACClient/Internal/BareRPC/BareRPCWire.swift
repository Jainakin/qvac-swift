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

enum BareRPCMessageType: UInt64, Sendable {
    case request  = 1
    case response = 2
    case stream   = 3
}

// MARK: - Stream flag bitmask (carries lifecycle + direction)
//
// Mirrors `bare-rpc/lib/constants.js` exactly.
// Direction bits 0x100 / 0x200 distinguish the OUTGOING request-stream from the
// INCOMING response-stream when a single message id has both.

struct BareRPCStreamFlags: OptionSet, Sendable, Hashable, CustomStringConvertible {
    let rawValue: UInt64
    init(rawValue: UInt64) { self.rawValue = rawValue }

    static let open     = BareRPCStreamFlags(rawValue: 0x1)
    static let close    = BareRPCStreamFlags(rawValue: 0x2)
    static let pause    = BareRPCStreamFlags(rawValue: 0x4)
    static let resume   = BareRPCStreamFlags(rawValue: 0x8)
    static let data     = BareRPCStreamFlags(rawValue: 0x10)
    static let end      = BareRPCStreamFlags(rawValue: 0x20)
    static let destroy  = BareRPCStreamFlags(rawValue: 0x40)
    static let error    = BareRPCStreamFlags(rawValue: 0x80)
    static let request  = BareRPCStreamFlags(rawValue: 0x100)
    static let response = BareRPCStreamFlags(rawValue: 0x200)

    var description: String {
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
struct BareRPCError: Error, Equatable, Sendable, CustomStringConvertible {
    let message: String
    let code: String
    let errno: Int64
    init(message: String, code: String, errno: Int64) {
        self.message = message
        self.code = code
        self.errno = errno
    }
    var description: String { "\(code) \(message) (errno=\(errno))" }
}

enum BareRPCCodecError: Error, Equatable, Sendable {
    case truncated
    case unknownType(UInt64)
    /// The length prefix on an incoming frame exceeds `BareRPCFrameReader.maxFrameSize`.
    /// Likely a malformed worker or a hostile peer attempting a DoS via oversize frames.
    case frameTooLarge(declared: UInt32, max: Int)
}

// MARK: - Decoded frame

enum BareRPCFrame: Sendable, Equatable {
    case request(id: UInt64, command: UInt64, stream: BareRPCStreamFlags, data: Data?)
    case response(id: UInt64, stream: BareRPCStreamFlags, payload: BareRPCResponsePayload)
    case stream(id: UInt64, flags: BareRPCStreamFlags, payload: BareRPCStreamPayload)

    var id: UInt64 {
        switch self {
        case .request(let id, _, _, _),
             .response(let id, _, _),
             .stream(let id, _, _):
            return id
        }
    }
}

enum BareRPCResponsePayload: Sendable, Equatable {
    case success(Data?)
    case failure(BareRPCError)
}

enum BareRPCStreamPayload: Sendable, Equatable {
    /// `DATA` flag — chunk of bytes inside the stream.
    case data(Data)
    /// `ERROR` flag — error carried inline.
    case error(BareRPCError)
    /// `OPEN`, `CLOSE`, `PAUSE`, `RESUME`, `END`, `DESTROY` — lifecycle frames with no data.
    case control
}

// MARK: - Codec

enum BareRPCCodec {

    // MARK: Encode

    /// Encode the body of a REQUEST (without the outer uint32 length prefix).
    static func encodeRequestBody(
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
        let hasInlinePayload = stream.rawValue == 0
        let payload = data ?? Data()
        if hasInlinePayload { c.uint.preencode(&state, UInt64(payload.count)) }

        let headerLen = state.end
        let totalLen = headerLen + (hasInlinePayload ? payload.count : 0)
        state.buffer = Data(count: totalLen)
        state.start = 0
        c.uint.encode(&state, BareRPCMessageType.request.rawValue)
        c.uint.encode(&state, id)
        c.uint.encode(&state, command)
        c.uint.encode(&state, stream.rawValue)
        if hasInlinePayload {
            c.uint.encode(&state, UInt64(payload.count))
            appendPayload(into: &state, payload: payload)
        }
        return state.buffer
    }

    /// Encode the body of a RESPONSE (without the outer uint32 length prefix).
    static func encodeResponseBody(
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
    static func encodeStreamBody(
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

    /// Every frame wrapper validates both the configured resource ceiling and the
    /// protocol's UInt32 length field before narrowing or allocating the outer frame.
    static func encodeRequestFrame(
        id: UInt64,
        command: UInt64,
        stream: BareRPCStreamFlags = [],
        data: Data?,
        maximumBodyBytes: Int
    ) throws -> Data {
        if let data, data.count > maximumBodyBytes {
            throw BareRPCInvalidArgument(
                "outbound request payload is \(data.count) bytes; maximumWireMessageBytes is \(maximumBodyBytes)"
            )
        }
        return try prefixWithLength(
            encodeRequestBody(id: id, command: command, stream: stream, data: data),
            maximumBodyBytes: maximumBodyBytes
        )
    }

    static func encodeStreamFrame(
        id: UInt64,
        flags: BareRPCStreamFlags,
        payload: BareRPCStreamPayload = .control,
        maximumBodyBytes: Int
    ) throws -> Data {
        if case .data(let data) = payload, data.count > maximumBodyBytes {
            throw BareRPCInvalidArgument(
                "outbound stream chunk is \(data.count) bytes; maximumWireMessageBytes is \(maximumBodyBytes)"
            )
        }
        return try prefixWithLength(
            encodeStreamBody(id: id, flags: flags, payload: payload),
            maximumBodyBytes: maximumBodyBytes
        )
    }

    static func encodeResponseFrame(
        id: UInt64,
        stream: BareRPCStreamFlags,
        payload: BareRPCResponsePayload,
        maximumBodyBytes: Int
    ) throws -> Data {
        return try prefixWithLength(
            encodeResponseBody(id: id, stream: stream, payload: payload),
            maximumBodyBytes: maximumBodyBytes
        )
    }

    // MARK: Decode

    /// Decode a complete frame body (everything after the uint32 LE length prefix).
    static func decodeFrameBody(_ body: Data) throws -> BareRPCFrame {
        var state = EncoderState(buffer: body)
        return try decodeFrame(from: &state)
    }

    /// Decode a body already resident in a larger receive buffer. Keeping the storage
    /// copy-on-write avoids duplicating an entire 0.17 video frame before extracting its
    /// payload.
    static func decodeFrameBody(_ storage: Data, in range: Range<Int>) throws -> BareRPCFrame {
        guard range.lowerBound >= storage.startIndex,
              range.upperBound <= storage.endIndex,
              range.lowerBound <= range.upperBound else {
            throw BareRPCCodecError.truncated
        }
        var state = EncoderState(buffer: storage)
        state.start = range.lowerBound
        state.end = range.upperBound
        return try decodeFrame(from: &state)
    }

    private static func decodeFrame(from state: inout EncoderState) throws -> BareRPCFrame {
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

    private static func prefixWithValidatedLength(_ body: Data) -> Data {
        var out = Data(count: 4 + body.count)
        let bodyLen = UInt32(body.count)
        for i in 0..<4 { out[i] = UInt8((bodyLen >> (8 * i)) & 0xff) }
        body.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                guard body.count > 0, let source = src.baseAddress, let destination = dst.baseAddress else {
                    return
                }
                destination.advanced(by: 4).copyMemory(from: source, byteCount: body.count)
            }
        }
        return out
    }

    private static func prefixWithLength(_ body: Data, maximumBodyBytes: Int) throws -> Data {
        guard body.count <= maximumBodyBytes else {
            throw BareRPCInvalidArgument(
                "outbound bare-rpc frame is \(body.count) bytes; maximumWireMessageBytes is \(maximumBodyBytes)"
            )
        }
        guard body.count <= Int(UInt32.max) else {
            throw BareRPCInvalidArgument("outbound bare-rpc frame exceeds the UInt32 wire capacity")
        }
        return prefixWithValidatedLength(body)
    }

    private static func appendPayload(into state: inout EncoderState, payload: Data) {
        payload.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            state.buffer.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                guard payload.count > 0,
                      let source = src.baseAddress,
                      let destination = dst.baseAddress else { return }
                destination.advanced(by: state.start).copyMemory(
                    from: source,
                    byteCount: payload.count
                )
            }
        }
        state.start += payload.count
    }

    private static func readDataField(_ state: inout EncoderState) throws -> Data? {
        let encodedLength = try c.uint.decode(&state)
        guard encodedLength <= UInt64(Int.max) else { throw BareRPCCodecError.truncated }
        let len = Int(encodedLength)
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
final class BareRPCFrameReader {
    /// Upper bound on a single frame's declared length (the 4-byte length prefix on the
    /// wire). Configurable per-instance and shared with the high-level NDJSON ceiling.
    /// The 256 MiB default accommodates 0.17 video/upscale responses while retaining a
    /// finite memory bound. Anything bigger is treated as a hostile or malformed peer and rejected as
    /// `BareRPCCodecError.frameTooLarge`.
    static let defaultMaxFrameSize: Int = 256 * 1024 * 1024

    convenience init() {
        self.init(validatedMaxFrameSize: Self.defaultMaxFrameSize)
    }

    convenience init(maxFrameSize: Int) throws {
        guard maxFrameSize > 0, maxFrameSize <= Int(UInt32.max) else {
            throw BareRPCInvalidArgument("maxFrameSize must be between 1 and UInt32.max")
        }
        self.init(validatedMaxFrameSize: maxFrameSize)
    }

    init(validatedMaxFrameSize maxFrameSize: Int) {
        self.maxFrameSize = maxFrameSize
    }

    let maxFrameSize: Int

    private enum State { case awaitingLength; case awaitingBody(needed: Int) }

    private var buffer = Data()
    private var consumed = 0
    private var state: State = .awaitingLength
    private var pending: [BareRPCFrame] = []
    private var pendingIndex = 0
    private static let compactThreshold = 64 * 1024

    /// Feed bytes from the wire. Throws on protocol-level decode failures (truncation
    /// is NOT an error — the reader simply waits for more bytes).
    func append(_ data: Data) throws {
        if consumed > Self.compactThreshold {
            buffer = Data(buffer.suffix(from: buffer.startIndex + consumed))
            consumed = 0
        }
        buffer.append(data)
        try drain()
        compactConsumedStorage()
    }

    /// Pull the next fully-decoded frame, or `nil` if none ready yet.
    func next() -> BareRPCFrame? {
        guard pendingIndex < pending.count else {
            if !pending.isEmpty {
                pending.removeAll(keepingCapacity: true)
                pendingIndex = 0
            }
            return nil
        }
        let frame = pending[pendingIndex]
        pendingIndex += 1
        if pendingIndex >= 256, pendingIndex >= pending.count / 2 {
            pending.removeFirst(pendingIndex)
            pendingIndex = 0
        }
        return frame
    }

    /// Number of bytes buffered but not yet decoded (after consumed bytes).
    var bufferedBytes: Int { buffer.count - consumed }

    private func drain() throws {
        while true {
            switch state {
            case .awaitingLength:
                guard remaining >= 4 else { return }
                var n: UInt32 = 0
                for i in 0..<4 { n |= UInt32(byte(at: i)) << (8 * i) }
                if Int(n) > maxFrameSize {
                    throw BareRPCCodecError.frameTooLarge(declared: n, max: maxFrameSize)
                }
                consumed += 4
                state = .awaitingBody(needed: Int(n))
            case .awaitingBody(let needed):
                guard remaining >= needed else { return }
                let start = buffer.startIndex + consumed
                let frame = try BareRPCCodec.decodeFrameBody(
                    buffer,
                    in: start..<(start + needed)
                )
                consumed += needed
                pending.append(frame)
                state = .awaitingLength
            }
        }
    }

    private var remaining: Int { buffer.count - consumed }
    private func byte(at relative: Int) -> UInt8 {
        return buffer[buffer.startIndex + consumed + relative]
    }

    private func compactConsumedStorage() {
        guard consumed > 0 else { return }
        if consumed == buffer.count {
            // A single large completed media frame must not leave its full receive
            // allocation retained until an unrelated future append.
            buffer.removeAll(keepingCapacity: false)
            consumed = 0
        } else if consumed > Self.compactThreshold {
            buffer = Data(buffer.suffix(from: buffer.startIndex + consumed))
            consumed = 0
        }
    }
}
