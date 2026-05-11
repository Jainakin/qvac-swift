import XCTest
@testable import BareRPC
import CompactEncoding

final class BareRPCCodecTests: XCTestCase {
    private func unhex(_ s: String) -> Data {
        var out = Data(); var i = s.startIndex
        while i < s.endIndex {
            let next = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<next], radix: 16)!)
            i = next
        }
        return out
    }

    /// The exact bytes the worker sent for the heartbeat response in the live probe.
    func test_decode_heartbeat_response_from_live_probe() throws {
        let bytes = unhex("3400000002020000" + "2f" + "7b2274797065223a22686561727462656174222c226e756d626572223a34392e34323438343131353738383732367d")
        XCTAssertEqual(bytes.count, 56)

        let reader = BareRPCFrameReader()
        try reader.append(bytes)
        guard let frame = reader.nextFrame() else {
            XCTFail("no frame decoded")
            return
        }
        guard case .response(let id, let flags, let payload) = frame else {
            XCTFail("expected response, got \(frame)")
            return
        }
        XCTAssertEqual(id, 2)
        XCTAssertEqual(flags.rawValue, 0)
        switch payload {
        case .success(let data):
            let json = try JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any] ?? [:]
            XCTAssertEqual(json["type"] as? String, "heartbeat")
            XCTAssertNotNil(json["number"])
        case .failure(let err):
            XCTFail("unexpected error frame: \(err)")
        }
        XCTAssertNil(reader.nextFrame(), "no second frame expected")
    }

    /// Reader should handle a frame arriving in multiple chunks.
    func test_decode_handles_fragmented_arrival() throws {
        let bytes = unhex("3400000002020000" + "2f" + "7b2274797065223a22686561727462656174222c226e756d626572223a34392e34323438343131353738383732367d")
        let reader = BareRPCFrameReader()
        // Feed 1 byte at a time
        for b in bytes {
            try reader.append(Data([b]))
        }
        XCTAssertNotNil(reader.nextFrame(), "should still decode the frame")
    }

    /// Reader should handle two frames in one chunk.
    func test_decode_two_frames_in_one_chunk() throws {
        let one = unhex("1500000002010000" + "10" + "7b2273756363657373223a747275657d")  // {"success":true}
        let two = unhex("3400000002020000" + "2f" + "7b2274797065223a22686561727462656174222c226e756d626572223a34392e34323438343131353738383732367d")
        let reader = BareRPCFrameReader()
        try reader.append(one + two)
        XCTAssertNotNil(reader.nextFrame(), "frame 1")
        XCTAssertNotNil(reader.nextFrame(), "frame 2")
        XCTAssertNil(reader.nextFrame())
    }
}
