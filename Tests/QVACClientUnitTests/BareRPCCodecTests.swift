import XCTest
@testable import QVACClient

final class BareRPCCodecTests: XCTestCase {
    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    private func unhex(_ s: String) -> Data {
        var out = Data(); var i = s.startIndex
        while i < s.endIndex {
            let next = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<next], radix: 16)!)
            i = next
        }
        return out
    }

    // MARK: - REQUEST encode against the JS-produced wire fixture

    /// Captured from Node `bare-rpc` v1.3.1 by encoding REQUEST(type=1, id=1, command=1, stream=0)
    /// carrying the JSON `__init_config` payload used in production.
    func test_encode_request_matches_node_fixture() throws {
        let json = #"{"type":"__init_config","config":{},"runtimeContext":{"runtime":"bare","platform":"darwin"}}"#
        let body = Data(json.utf8)
        let frame = BareRPCCodec.__testEncodeRequestFrame(id: 1, command: 1, stream: [], data: body)
        // Length: body is JSON; we reconstruct the expected hex via the helper to keep
        // the test resilient to JSON whitespace differences.
        let expectedBody = BareRPCCodec.encodeRequestBody(id: 1, command: 1, stream: [], data: body)
        XCTAssertEqual(frame.count, 4 + expectedBody.count)
        // First 4 bytes are uint32 LE length of body.
        var length: UInt32 = 0
        for i in 0..<4 { length |= UInt32(frame[i]) << (8 * i) }
        XCTAssertEqual(Int(length), expectedBody.count)
    }

    // MARK: - RESPONSE decode against captured live bytes

    func test_decode_init_response_from_live_capture() throws {
        // RESPONSE(type=2, id=1, err=false, stream=0, data='{"success":true}')
        let bytes = unhex("1500000002010000107b2273756363657373223a747275657d")
        let reader = BareRPCFrameReader()
        try reader.append(bytes)
        guard let frame = reader.next() else { return XCTFail("no frame") }
        guard case .response(let id, let flags, let payload) = frame else {
            return XCTFail("expected response, got \(frame)")
        }
        XCTAssertEqual(id, 1)
        XCTAssertEqual(flags, [])
        guard case .success(let data) = payload else {
            return XCTFail("expected success payload")
        }
        XCTAssertEqual(data, Data(#"{"success":true}"#.utf8))
    }

    func test_decode_heartbeat_response_from_live_capture() throws {
        // RESPONSE id=2, data='{"type":"heartbeat","number":91.56530716499051}'
        let bytes = unhex("34000000020200002f7b2274797065223a22686561727462656174222c226e756d626572223a39312e35363533303731363439393035317d")
        let reader = BareRPCFrameReader()
        try reader.append(bytes)
        guard let frame = reader.next() else { return XCTFail("no frame") }
        guard case .response(let id, _, .success(let d)) = frame else {
            return XCTFail("expected success response")
        }
        XCTAssertEqual(id, 2)
        XCTAssertNotNil(d)
        let obj = try JSONSerialization.jsonObject(with: d!) as? [String: Any]
        XCTAssertEqual(obj?["type"] as? String, "heartbeat")
    }

    // MARK: - STREAM frame encode/decode

    func test_stream_open_response_frame_roundtrip() throws {
        let frame = BareRPCCodec.__testEncodeStreamFrame(id: 3, flags: [.response, .open])
        XCTAssertEqual(hex(frame), "050000000303fd0102")
        let reader = BareRPCFrameReader()
        try reader.append(frame)
        guard case .stream(let id, let flags, let payload) = reader.next() else {
            return XCTFail("expected stream frame")
        }
        XCTAssertEqual(id, 3)
        XCTAssertEqual(flags, [.response, .open])
        XCTAssertEqual(payload, .control)
    }

    func test_stream_data_frame_with_payload() throws {
        let payload = Data("hello world".utf8)
        let frame = BareRPCCodec.__testEncodeStreamFrame(id: 7, flags: [.response, .data], payload: .data(payload))
        let reader = BareRPCFrameReader()
        try reader.append(frame)
        guard case .stream(let id, let flags, .data(let d)) = reader.next() else {
            return XCTFail("expected stream data frame")
        }
        XCTAssertEqual(id, 7)
        XCTAssertEqual(flags, [.response, .data])
        XCTAssertEqual(d, payload)
    }

    func test_stream_error_frame_decodes_typed_error() throws {
        let err = BareRPCError(message: "bad thing", code: "E_BAD", errno: 42)
        let frame = BareRPCCodec.__testEncodeStreamFrame(id: 11, flags: [.response, .error], payload: .error(err))
        let reader = BareRPCFrameReader()
        try reader.append(frame)
        guard case .stream(let id, let flags, .error(let decoded)) = reader.next() else {
            return XCTFail("expected error frame")
        }
        XCTAssertEqual(id, 11)
        XCTAssertTrue(flags.contains(.error))
        XCTAssertTrue(flags.contains(.response))
        XCTAssertEqual(decoded, err)
    }

    // MARK: - Reader robustness

    func test_reader_handles_fragmented_arrival() throws {
        let bytes = unhex("3400000002020000" + "2f" + "7b2274797065223a22686561727462656174222c226e756d626572223a39312e35363533303731363439393035317d")
        let reader = BareRPCFrameReader()
        for b in bytes { try reader.append(Data([b])) }
        XCTAssertNotNil(reader.next(), "should decode after 1-byte-at-a-time")
    }

    func test_reader_handles_multiple_frames_in_one_chunk() throws {
        let frame1 = BareRPCCodec.__testEncodeStreamFrame(id: 1, flags: [.response, .open])
        let frame2 = BareRPCCodec.__testEncodeStreamFrame(id: 1, flags: [.response, .end])
        let frame3 = BareRPCCodec.__testEncodeStreamFrame(id: 2, flags: [.response, .data], payload: .data(Data([1,2,3])))
        let combined = frame1 + frame2 + frame3
        let reader = BareRPCFrameReader()
        try reader.append(combined)
        XCTAssertNotNil(reader.next(), "frame 1")
        XCTAssertNotNil(reader.next(), "frame 2")
        XCTAssertNotNil(reader.next(), "frame 3")
        XCTAssertNil(reader.next())
    }

    func test_reader_drains_thousands_of_coalesced_frames_without_quadratic_queue_removal() throws {
        let frameCount = 5_000
        var coalesced = Data()
        coalesced.reserveCapacity(frameCount * 16)
        for id in 1...frameCount {
            coalesced.append(BareRPCCodec.__testEncodeStreamFrame(
                id: UInt64(id),
                flags: [.response, .end]
            ))
        }

        let reader = BareRPCFrameReader()
        try reader.append(coalesced)
        for id in 1...frameCount {
            guard case .stream(let actualID, let flags, .control)? = reader.next() else {
                return XCTFail("missing frame \(id)")
            }
            XCTAssertEqual(actualID, UInt64(id))
            XCTAssertEqual(flags, [.response, .end])
        }
        XCTAssertNil(reader.next())
        XCTAssertEqual(reader.bufferedBytes, 0)
    }

    func test_reader_no_frame_until_length_complete() throws {
        let reader = BareRPCFrameReader()
        try reader.append(Data([0x05, 0x00]))   // only 2/4 length bytes
        XCTAssertNil(reader.next())
        try reader.append(Data([0x00, 0x00]))   // complete length: body=5
        XCTAssertNil(reader.next())
        try reader.append(Data([0x03, 0x05, 0xfd, 0x01, 0x02])) // STREAM id=5 stream=0x201
        XCTAssertNotNil(reader.next())
    }

    // §10 from AUDIT.md — the reader must reject a frame whose declared length exceeds
    // its `maxFrameSize`. A malformed/hostile peer that ships `0xFFFFFFFF` as the length
    // prefix would otherwise grow the buffer to 4 GiB and OOM the process.
    func test_reader_rejects_frame_larger_than_max_frame_size() throws {
        let reader = try BareRPCFrameReader(maxFrameSize: 1024)
        // 4-byte little-endian length prefix = 0x00000800 = 2048 (> 1024 max).
        let oversizeLen = Data([0x00, 0x08, 0x00, 0x00])
        XCTAssertThrowsError(try reader.append(oversizeLen)) { err in
            guard case BareRPCCodecError.frameTooLarge(let declared, let max) = err else {
                return XCTFail("expected frameTooLarge, got \(err)")
            }
            XCTAssertEqual(declared, 2048)
            XCTAssertEqual(max, 1024)
        }
    }

    func test_decoder_rejects_uint64_payload_length_without_integer_conversion_trap() {
        // STREAM(type=3), id=1, RESPONSE|DATA(0x210), then a compact-encoding
        // UInt64.max payload length. The peer supplied no payload; decoding must
        // report truncation instead of narrowing UInt64.max to Int and trapping.
        let body = Data([
            0x03, 0x01,
            0xfd, 0x10, 0x02,
            0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        ])

        XCTAssertThrowsError(try BareRPCCodec.decodeFrameBody(body)) { error in
            XCTAssertEqual(error as? BareRPCCodecError, .truncated)
        }
    }

    /// Default reader must accept the largest plausibly-legitimate frame (1 MiB ≪ the
    /// configured default cap, to keep the ceiling from accidentally rejecting real traffic.
    func test_reader_accepts_one_mib_frame_under_default_cap() throws {
        let payload = Data(repeating: 0xab, count: 1 * 1024 * 1024)
        let frame = BareRPCCodec.__testEncodeRequestFrame(id: 1, command: 1, data: payload)
        let reader = BareRPCFrameReader()
        try reader.append(frame)
        XCTAssertNotNil(reader.next())
    }

    func test_reader_compacts_after_large_consumption() throws {
        // Feed 70KB of small frames; verify internal buffer doesn't grow unbounded.
        // Each frame is `04000000 03 01 fd 01 02` = 9 bytes (STREAM RESPONSE|OPEN id=1).
        let oneFrame = BareRPCCodec.__testEncodeStreamFrame(id: 1, flags: [.response, .open])
        XCTAssertEqual(oneFrame.count, 9)
        let reader = BareRPCFrameReader()
        for _ in 0..<8000 {
            try reader.append(oneFrame)
            _ = reader.next()
        }
        XCTAssertLessThan(reader.bufferedBytes, 64 * 1024 + 100,
                          "reader should compact periodically")
    }

    // MARK: - Stream-flag bitmask self-check

    func test_stream_flag_values_match_bare_rpc_constants() {
        XCTAssertEqual(BareRPCStreamFlags.open.rawValue,     0x1)
        XCTAssertEqual(BareRPCStreamFlags.close.rawValue,    0x2)
        XCTAssertEqual(BareRPCStreamFlags.pause.rawValue,    0x4)
        XCTAssertEqual(BareRPCStreamFlags.resume.rawValue,   0x8)
        XCTAssertEqual(BareRPCStreamFlags.data.rawValue,     0x10)
        XCTAssertEqual(BareRPCStreamFlags.end.rawValue,      0x20)
        XCTAssertEqual(BareRPCStreamFlags.destroy.rawValue,  0x40)
        XCTAssertEqual(BareRPCStreamFlags.error.rawValue,    0x80)
        XCTAssertEqual(BareRPCStreamFlags.request.rawValue,  0x100)
        XCTAssertEqual(BareRPCStreamFlags.response.rawValue, 0x200)
    }

    // MARK: - Symmetric encode/decode round-trip for every supported shape

    func test_request_frame_roundtrip() throws {
        for command in [UInt64(1), UInt64(42), UInt64(0xfff), UInt64(0xfffffffff)] {
            let body = Data("payload-\(command)".utf8)
            let frame = BareRPCCodec.__testEncodeRequestFrame(id: command, command: command, stream: [], data: body)
            let reader = BareRPCFrameReader()
            try reader.append(frame)
            guard case .request(let id, let cmd, let flags, let data) = reader.next() else {
                XCTFail("not a request"); continue
            }
            XCTAssertEqual(id, command)
            XCTAssertEqual(cmd, command)
            XCTAssertEqual(flags, [])
            XCTAssertEqual(data, body)
        }
    }

    func test_response_frame_with_error_roundtrip() throws {
        let e = BareRPCError(message: "nope", code: "E_NOPE", errno: -7)
        let frame = BareRPCCodec.__testEncodeResponseFrame(id: 99, stream: [], payload: .failure(e))
        let reader = BareRPCFrameReader()
        try reader.append(frame)
        guard case .response(let id, _, .failure(let decoded)) = reader.next() else {
            return XCTFail("expected failure response")
        }
        XCTAssertEqual(id, 99)
        XCTAssertEqual(decoded, e)
    }
}
