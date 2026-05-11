import XCTest
@testable import QVACClient

final class CompactEncodingTests: XCTestCase {

    // MARK: - Fixture decoding

    struct Fixture: Decodable {
        let codec: String
        let value: AnyDecodable?
        let hex: String
        let json: String?
        let bodyLength: Int?
    }

    struct AnyDecodable: Decodable {
        let raw: Any?
        init(from d: Decoder) throws {
            let c = try d.singleValueContainer()
            if c.decodeNil() { raw = nil; return }
            if let v = try? c.decode(Bool.self) { raw = v; return }
            // Try integer before double so we don't lose precision.
            if let v = try? c.decode(Int64.self) { raw = v; return }
            if let v = try? c.decode(UInt64.self) { raw = v; return }
            if let v = try? c.decode(Double.self) { raw = v; return }
            if let v = try? c.decode(String.self) { raw = v; return }
            raw = nil
        }
    }

    var fixtures: [String: Fixture] = [:]

    override func setUpWithError() throws {
        let url = Bundle.module.url(forResource: "compact-encoding", withExtension: "json", subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: "compact-encoding", withExtension: "json")
        XCTAssertNotNil(url, "compact-encoding fixtures must be bundled")
        let data = try Data(contentsOf: url!)
        fixtures = try JSONDecoder().decode([String: Fixture].self, from: data)
        XCTAssertGreaterThan(fixtures.count, 25, "expected >25 fixtures")
    }

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

    // MARK: - Per-codec roundtrip from fixtures

    func test_uint_varint_against_fixtures() throws {
        for (name, f) in fixtures where f.codec == "uint" {
            let raw = f.value?.raw
            let value: UInt64
            if let n = raw as? Int64 { value = UInt64(n) }
            else if let n = raw as? UInt64 { value = n }
            else { XCTFail("[\(name)] missing value"); continue }
            XCTAssertEqual(hex(c.uint.encode(value)), f.hex, "[\(name)] encode")
            XCTAssertEqual(try c.uint.decode(unhex(f.hex)), value, "[\(name)] decode")
        }
    }

    func test_int_zigzag_against_fixtures() throws {
        for (name, f) in fixtures where f.codec == "int" {
            guard let n = f.value?.raw as? Int64 else { XCTFail("[\(name)] missing value"); continue }
            XCTAssertEqual(hex(c.int.encode(n)), f.hex, "[\(name)] encode")
            XCTAssertEqual(try c.int.decode(unhex(f.hex)), n, "[\(name)] decode")
        }
    }

    func test_uint32_fixed_against_fixtures() throws {
        for (name, f) in fixtures where f.codec == "uint32" {
            let v: UInt64
            if let n = f.value?.raw as? Int64 { v = UInt64(bitPattern: n) }
            else if let n = f.value?.raw as? UInt64 { v = n }
            else { XCTFail("[\(name)] missing value"); continue }
            XCTAssertEqual(hex(c.uint32.encode(v)), f.hex, "[\(name)] encode")
            XCTAssertEqual(try c.uint32.decode(unhex(f.hex)), v, "[\(name)] decode")
        }
    }

    func test_bool_against_fixtures() throws {
        for (name, f) in fixtures where f.codec == "bool" {
            guard let b = f.value?.raw as? Bool else { XCTFail("[\(name)] missing value"); continue }
            XCTAssertEqual(hex(c.bool.encode(b)), f.hex, "[\(name)] encode")
            XCTAssertEqual(try c.bool.decode(unhex(f.hex)), b, "[\(name)] decode")
        }
    }

    func test_utf8_against_fixtures() throws {
        for (name, f) in fixtures where f.codec == "utf8" {
            guard let s = f.value?.raw as? String else { XCTFail("[\(name)] missing value"); continue }
            XCTAssertEqual(hex(c.utf8.encode(s)), f.hex, "[\(name)] encode")
            XCTAssertEqual(try c.utf8.decode(unhex(f.hex)), s, "[\(name)] decode")
        }
    }

    func test_buffer_against_fixtures() throws {
        for (name, f) in fixtures where f.codec == "buffer" {
            guard let s = f.value?.raw as? String else { XCTFail("[\(name)] missing value"); continue }
            let data = unhex(s)
            XCTAssertEqual(hex(c.buffer.encode(data)), f.hex, "[\(name)] encode")
            XCTAssertEqual(try c.buffer.decode(unhex(f.hex)), data, "[\(name)] decode")
        }
    }

    func test_optionalBuffer_against_fixtures() throws {
        for (name, f) in fixtures where f.codec == "optionalBuffer" {
            let v: Data? = (f.value?.raw as? String).map { unhex($0) }
            XCTAssertEqual(hex(c.optionalBuffer.encode(v)), f.hex, "[\(name)] encode")
            let decoded = try c.optionalBuffer.decode(unhex(f.hex))
            // null and zero-length encode identically and decode to nil.
            if v == nil || v?.isEmpty == true {
                XCTAssertNil(decoded, "[\(name)] expected nil decode")
            } else {
                XCTAssertEqual(decoded, v, "[\(name)] decode mismatch")
            }
        }
    }

    // MARK: - Codecs not covered by the JS-generated fixtures

    func test_uint8_boundary() throws {
        XCTAssertEqual(hex(c.uint8.encode(0)), "00")
        XCTAssertEqual(hex(c.uint8.encode(255)), "ff")
        XCTAssertEqual(try c.uint8.decode(Data([0xab])), 0xab)
    }

    func test_uint16_LE() throws {
        XCTAssertEqual(hex(c.uint16.encode(0x1234)), "3412")
        XCTAssertEqual(try c.uint16.decode(Data([0x78, 0x56])), 0x5678)
    }

    func test_uint64_LE() throws {
        let v: UInt64 = 0x0123456789abcdef
        XCTAssertEqual(hex(c.uint64.encode(v)), "efcdab8967452301")
        XCTAssertEqual(try c.uint64.decode(c.uint64.encode(v)), v)
    }

    func test_float32_roundtrip() throws {
        let values: [Float] = [0, 1.0, -1.0, .pi, -.infinity, .infinity, .leastNormalMagnitude, .greatestFiniteMagnitude]
        for v in values {
            let encoded = c.float32.encode(v)
            XCTAssertEqual(encoded.count, 4)
            let decoded = try c.float32.decode(encoded)
            // NaN handled separately (XCTAssertEqual returns false on NaN equality)
            XCTAssertEqual(decoded, v, "Float32 roundtrip \(v)")
        }
    }

    func test_float64_roundtrip() throws {
        let values: [Double] = [0, 1.0, -1.0, .pi, .greatestFiniteMagnitude]
        for v in values {
            let encoded = c.float64.encode(v)
            XCTAssertEqual(encoded.count, 8)
            XCTAssertEqual(try c.float64.decode(encoded), v, "Float64 roundtrip \(v)")
        }
    }

    func test_fixed_size_enforced() throws {
        let codec = c.fixed(8)
        let data = Data([1,2,3,4,5,6,7,8])
        XCTAssertEqual(codec.encode(data), data)
        XCTAssertEqual(try codec.decode(data), data)
        XCTAssertThrowsError(try codec.decode(Data([1,2,3]))) { e in
            XCTAssertEqual(e as? CompactEncodingError, .outOfBounds)
        }
    }

    func test_array_codec_roundtrip() throws {
        let codec = c.array(c.uint)
        let values: [UInt64] = [0, 1, 100, 65535, 4_294_967_295]
        let encoded = codec.encode(values)
        XCTAssertEqual(try codec.decode(encoded), values)
    }

    func test_array_codec_huge_array_rejected() throws {
        // Construct a buffer whose declared length exceeds the safety cap. Should fail decoding.
        // 0xfe = uint32 prefix; then 0x00200000 = 0x200000 = 2,097,152 — over the 0x100000 cap.
        let evil = Data([0xfe, 0x00, 0x00, 0x20, 0x00])
        let codec = c.array(c.uint)
        XCTAssertThrowsError(try codec.decode(evil))
    }

    func test_frame_codec_roundtrip() throws {
        // Wrap a uint64 in a frame.
        let codec = c.frame(c.uint64)
        let value: UInt64 = 0xdeadbeefcafebabe
        let encoded = codec.encode(value)
        XCTAssertEqual(try codec.decode(encoded), value)
        // The first byte is the uint-prefix length (8 for uint64).
        XCTAssertEqual(encoded[encoded.startIndex], 8)
    }

    // MARK: - Decode bounds / robustness

    func test_decode_truncated_uint_throws() {
        XCTAssertThrowsError(try c.uint.decode(Data())) { e in
            XCTAssertEqual(e as? CompactEncodingError, .outOfBounds)
        }
        // 0xfd needs 2 more bytes — give 1.
        XCTAssertThrowsError(try c.uint.decode(Data([0xfd, 0x01]))) { e in
            XCTAssertEqual(e as? CompactEncodingError, .outOfBounds)
        }
    }

    func test_decode_invalid_utf8_throws() {
        // 1-byte length prefix=2, body=[0xff, 0xff] — invalid utf8.
        XCTAssertThrowsError(try c.utf8.decode(Data([0x02, 0xff, 0xff]))) { e in
            XCTAssertEqual(e as? CompactEncodingError, .invalidUTF8)
        }
    }

    // MARK: - Property-based encode-then-decode

    func test_uint_roundtrip_random() throws {
        for _ in 0..<200 {
            let v = UInt64.random(in: 0...UInt64.max)
            XCTAssertEqual(try c.uint.decode(c.uint.encode(v)), v)
        }
    }

    func test_int_roundtrip_random() throws {
        for _ in 0..<200 {
            let v = Int64.random(in: Int64.min...Int64.max)
            XCTAssertEqual(try c.int.decode(c.int.encode(v)), v)
        }
    }

    func test_buffer_roundtrip_random_sizes() throws {
        for size in [0, 1, 10, 252, 253, 256, 1024, 65_535, 65_536] {
            var d = Data(count: size)
            d.withUnsafeMutableBytes { buf in
                let raw = buf.bindMemory(to: UInt8.self)
                for i in 0..<size { raw[i] = UInt8(i & 0xff) }
            }
            XCTAssertEqual(try c.buffer.decode(c.buffer.encode(d)), d, "buffer size \(size)")
        }
    }
}
