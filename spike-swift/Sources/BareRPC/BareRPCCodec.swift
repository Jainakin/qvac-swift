import Foundation
import CompactEncoding

/// Wire-level codec for bare-rpc messages.
/// Mirrors holepunchto/bare-rpc `lib/messages.js`.
///
/// Frame on the wire:
/// ```
/// [uint32 LE frame_len]                  // length of body in bytes (excludes these 4)
/// [varuint type]                         // 1=REQUEST, 2=RESPONSE, 3=STREAM
/// [varuint id]                           // message id (auto-allocated, for correlation)
/// [per-type fields]
/// [varuint dataLen][raw data bytes]      // present only when this frame carries data
/// ```
public enum BareRPCMessageType: UInt64 {
    case request = 1
    case response = 2
    case stream = 3
}

public struct BareRPCStreamFlags: OptionSet, Sendable {
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
}

public struct BareRPCError: Error, CustomStringConvertible, Sendable {
    public let message: String
    public let code: String
    public let errno: Int64
    public var description: String { "\(code) \(message) (errno=\(errno))" }
}

public enum BareRPCFrame: Sendable {
    case request(id: UInt64, command: UInt64, stream: BareRPCStreamFlags, data: Data?)
    case response(id: UInt64, stream: BareRPCStreamFlags, payload: Result<Data?, BareRPCError>)
    case stream(id: UInt64, flags: BareRPCStreamFlags, payload: StreamPayload)

    public enum StreamPayload: Sendable {
        case data(Data)
        case error(BareRPCError)
        case control          // OPEN/CLOSE/PAUSE/RESUME/END/DESTROY with no data
    }
}

public enum BareRPCCodecError: Error {
    case truncated
    case unknownType(UInt64)
}

public enum BareRPCCodec {

    // MARK: - Encode

    /// Encodes the body of a REQUEST frame WITHOUT the outer uint32 length prefix.
    /// Mirrors `header.encode` for type=REQUEST in bare-rpc.
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
            payload.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                state.buffer.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                    let raw = src.bindMemory(to: UInt8.self)
                    for i in 0..<payload.count {
                        dst[state.start + i] = raw[i]
                    }
                }
            }
            state.start += payload.count
        }
        return state.buffer
    }

    /// Encodes a full REQUEST frame including the uint32 LE length prefix. Ready to write to the wire.
    public static func encodeRequestFrame(
        id: UInt64,
        command: UInt64,
        stream: BareRPCStreamFlags = [],
        data: Data?
    ) -> Data {
        let body = encodeRequestBody(id: id, command: command, stream: stream, data: data)
        return prefixWithLength(body)
    }

    /// Encodes a STREAM frame (`type=3`). Optional `data` is only included when `.data` flag is set.
    public static func encodeStreamFrame(
        id: UInt64,
        flags: BareRPCStreamFlags,
        data: Data? = nil
    ) -> Data {
        var state = EncoderState()
        c.uint.preencode(&state, BareRPCMessageType.stream.rawValue)
        c.uint.preencode(&state, id)
        c.uint.preencode(&state, flags.rawValue)
        let hasData = flags.contains(.data)
        let payload = data ?? Data()
        if hasData { c.uint.preencode(&state, UInt64(payload.count)) }
        let headerLen = state.end
        let totalLen = headerLen + (hasData ? payload.count : 0)
        state.buffer = Data(count: totalLen)
        state.start = 0
        c.uint.encode(&state, BareRPCMessageType.stream.rawValue)
        c.uint.encode(&state, id)
        c.uint.encode(&state, flags.rawValue)
        if hasData {
            c.uint.encode(&state, UInt64(payload.count))
            payload.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                state.buffer.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                    let raw = src.bindMemory(to: UInt8.self)
                    for i in 0..<payload.count {
                        dst[state.start + i] = raw[i]
                    }
                }
            }
            state.start += payload.count
        }
        return prefixWithLength(state.buffer)
    }

    private static func prefixWithLength(_ body: Data) -> Data {
        var out = Data(count: 4 + body.count)
        let bodyLen = UInt32(body.count)
        for i in 0..<4 { out[i] = UInt8((bodyLen >> (8 * i)) & 0xff) }
        body.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                let raw = src.bindMemory(to: UInt8.self)
                for i in 0..<body.count { dst[4 + i] = raw[i] }
            }
        }
        return out
    }

    // MARK: - Decode

    /// Decodes a full frame body (everything AFTER the uint32 LE length prefix).
    public static func decodeFrameBody(_ body: Data) throws -> BareRPCFrame {
        var state = EncoderState(buffer: body)
        state.start = 0
        state.end = body.count

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

    // MARK: - Helpers

    private static func readDataField(_ state: inout EncoderState) throws -> Data? {
        let len = Int(try c.uint.decode(&state))
        if len == 0 { return nil }
        guard state.end - state.start >= len else { throw BareRPCCodecError.truncated }
        let d = state.buffer.subdata(in: state.start..<(state.start + len))
        state.start += len
        return d
    }

    private static func readError(_ state: inout EncoderState) throws -> BareRPCError {
        let message = try c.utf8.decode(&state)
        let code = try c.utf8.decode(&state)
        let errno = try c.int.decode(&state)
        return BareRPCError(message: message, code: code, errno: errno)
    }
}

/// Streaming reader: feed bytes via `append`, get back fully-decoded frames as they complete.
/// Mirrors bare-rpc's `_onbeforeframe → _onframe` state machine.
///
/// Implementation note: uses an explicit `consumed` offset rather than `Data.removeFirst()` because
/// Data subscripting uses absolute (non-zero-resetting) indices, and `removeFirst` only advances the
/// internal startIndex — subsequent `buffer[i]` reads with literal `0..<n` indices then trap.
public final class BareRPCFrameReader {
    private enum State {
        case awaitingLength
        case awaitingBody(needed: Int)
    }

    private var buffer = Data()
    private var consumed: Int = 0  // bytes already drained from the front
    private var state: State = .awaitingLength
    private var pending: [BareRPCFrame] = []

    public init() {}

    public func append(_ data: Data) throws {
        // Periodically compact to keep memory bounded.
        if consumed > 64 * 1024 {
            buffer = Data(buffer.suffix(from: buffer.startIndex + consumed))
            consumed = 0
        }
        buffer.append(data)
        try drain()
    }

    public func nextFrame() -> BareRPCFrame? {
        guard !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }

    private var remaining: Int { buffer.count - consumed }

    private func byte(_ relativeOffset: Int) -> UInt8 {
        return buffer[buffer.startIndex + consumed + relativeOffset]
    }

    private func slice(_ length: Int) -> Data {
        let start = buffer.startIndex + consumed
        return buffer.subdata(in: start..<(start + length))
    }

    private func drain() throws {
        while true {
            switch state {
            case .awaitingLength:
                guard remaining >= 4 else { return }
                var n: UInt32 = 0
                for i in 0..<4 { n |= UInt32(byte(i)) << (8 * i) }
                consumed += 4
                state = .awaitingBody(needed: Int(n))
            case .awaitingBody(let needed):
                guard remaining >= needed else { return }
                let body = slice(needed)
                consumed += needed
                let frame = try BareRPCCodec.decodeFrameBody(body)
                pending.append(frame)
                state = .awaitingLength
            }
        }
    }
}
