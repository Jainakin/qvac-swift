import Foundation
@testable import QVACClient

/// Peer-frame construction lives in the test target so release library builds do not
/// ship unchecked framing entry points. Fixtures still call the production encoders
/// with the protocol's absolute UInt32 capacity and fail loudly if the fixture itself
/// is invalid.
extension BareRPCCodec {
    static func __testEncodeRequestFrame(
        id: UInt64,
        command: UInt64,
        stream: BareRPCStreamFlags = [],
        data: Data?
    ) -> Data {
        try! encodeRequestFrame(
            id: id,
            command: command,
            stream: stream,
            data: data,
            maximumBodyBytes: Int(UInt32.max)
        )
    }

    static func __testEncodeResponseFrame(
        id: UInt64,
        stream: BareRPCStreamFlags,
        payload: BareRPCResponsePayload
    ) -> Data {
        try! encodeResponseFrame(
            id: id,
            stream: stream,
            payload: payload,
            maximumBodyBytes: Int(UInt32.max)
        )
    }

    static func __testEncodeStreamFrame(
        id: UInt64,
        flags: BareRPCStreamFlags,
        payload: BareRPCStreamPayload = .control
    ) -> Data {
        try! encodeStreamFrame(
            id: id,
            flags: flags,
            payload: payload,
            maximumBodyBytes: Int(UInt32.max)
        )
    }
}
