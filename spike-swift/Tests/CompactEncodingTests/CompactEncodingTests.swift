import XCTest
@testable import CompactEncoding

final class CompactEncodingTests: XCTestCase {

    struct Fixture: Decodable {
        let codec: String
        let value: AnyDecodable?
        let hex: String
        let json: String?
        let bodyLength: Int?
        let description: String?
    }

    struct AnyDecodable: Decodable {
        let raw: Any?
        init(from d: Decoder) throws {
            let c = try d.singleValueContainer()
            if c.decodeNil() { raw = nil; return }
            if let v = try? c.decode(Bool.self)    { raw = v; return }
            if let v = try? c.decode(Int64.self)   { raw = v; return }
            if let v = try? c.decode(UInt64.self)  { raw = v; return }
            if let v = try? c.decode(Double.self)  { raw = v; return }
            if let v = try? c.decode(String.self)  { raw = v; return }
            raw = nil
        }
    }

    var fixtures: [String: Fixture] = [:]

    override func setUpWithError() throws {
        let url = Bundle.module.url(forResource: "fixtures", withExtension: "json")
        XCTAssertNotNil(url, "fixtures.json must be bundled")
        let data = try Data(contentsOf: url!)
        fixtures = try JSONDecoder().decode([String: Fixture].self, from: data)
        XCTAssertGreaterThan(fixtures.count, 25, "expected >25 fixtures, got \(fixtures.count)")
    }

    // MARK: - Helpers

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
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
            guard let n = f.value?.raw as? Int64 else {
                guard let nu = f.value?.raw as? UInt64 else { XCTFail("[\(name)] missing value"); continue }
                try roundTripUInt(name: name, value: nu, expectedHex: f.hex); continue
            }
            try roundTripUInt(name: name, value: UInt64(n), expectedHex: f.hex)
        }
    }

    private func roundTripUInt(name: String, value: UInt64, expectedHex: String) throws {
        let encoded = c.uint.encode(value)
        XCTAssertEqual(hex(encoded), expectedHex, "[\(name)] encode mismatch")
        let decoded = try c.uint.decode(unhex(expectedHex))
        XCTAssertEqual(decoded, value, "[\(name)] decode mismatch")
    }

    func test_int_zigzag_against_fixtures() throws {
        for (name, f) in fixtures where f.codec == "int" {
            guard let n = f.value?.raw as? Int64 else { XCTFail("[\(name)] missing value"); continue }
            let encoded = c.int.encode(n)
            XCTAssertEqual(hex(encoded), f.hex, "[\(name)] encode mismatch")
            let decoded = try c.int.decode(unhex(f.hex))
            XCTAssertEqual(decoded, n, "[\(name)] decode mismatch")
        }
    }

    func test_uint32_fixed_against_fixtures() throws {
        for (name, f) in fixtures where f.codec == "uint32" {
            let v: UInt64
            if let n = f.value?.raw as? Int64 { v = UInt64(bitPattern: n) }
            else if let n = f.value?.raw as? UInt64 { v = n }
            else { XCTFail("[\(name)] missing value"); continue }
            let encoded = c.uint32.encode(v)
            XCTAssertEqual(hex(encoded), f.hex, "[\(name)] encode mismatch")
            let decoded = try c.uint32.decode(unhex(f.hex))
            XCTAssertEqual(decoded, v, "[\(name)] decode mismatch")
        }
    }

    func test_bool_against_fixtures() throws {
        for (name, f) in fixtures where f.codec == "bool" {
            guard let b = f.value?.raw as? Bool else { XCTFail("[\(name)] missing value"); continue }
            XCTAssertEqual(hex(c.bool.encode(b)), f.hex, "[\(name)] encode mismatch")
            XCTAssertEqual(try c.bool.decode(unhex(f.hex)), b, "[\(name)] decode mismatch")
        }
    }

    func test_utf8_against_fixtures() throws {
        for (name, f) in fixtures where f.codec == "utf8" {
            guard let s = f.value?.raw as? String else { XCTFail("[\(name)] missing value"); continue }
            XCTAssertEqual(hex(c.utf8.encode(s)), f.hex, "[\(name)] encode mismatch")
            XCTAssertEqual(try c.utf8.decode(unhex(f.hex)), s, "[\(name)] decode mismatch")
        }
    }

    func test_buffer_against_fixtures() throws {
        for (name, f) in fixtures where f.codec == "buffer" {
            guard let s = f.value?.raw as? String else { XCTFail("[\(name)] missing value"); continue }
            let data = unhex(s)
            XCTAssertEqual(hex(c.buffer.encode(data)), f.hex, "[\(name)] encode mismatch")
            XCTAssertEqual(try c.buffer.decode(unhex(f.hex)), data, "[\(name)] decode mismatch")
        }
    }

    func test_optionalBuffer_against_fixtures() throws {
        for (name, f) in fixtures where f.codec == "optionalBuffer" {
            let v: Data? = (f.value?.raw as? String).map { unhex($0) }
            XCTAssertEqual(hex(c.optionalBuffer.encode(v)), f.hex, "[\(name)] encode mismatch")
            let decoded = try c.optionalBuffer.decode(unhex(f.hex))
            // both null and zero-length buffer encode to the single byte 0x00 and decode to nil
            if v == nil || v?.isEmpty == true {
                XCTAssertNil(decoded, "[\(name)] expected nil decode")
            } else {
                XCTAssertEqual(decoded, v, "[\(name)] decode mismatch")
            }
        }
    }

    // MARK: - The big one: full bare-rpc REQUEST frame matches the Node-generated fixture

    func test_full_bareRpc_request_frame_matches() throws {
        let f = try XCTUnwrap(fixtures["frame_init_config_request"])
        let payload = f.json!.data(using: .utf8)!

        // Mirror bare-rpc/lib/messages.js header.encode for REQUEST type, stream==0, with data
        var body = EncoderState()
        c.uint.preencode(&body, 1)               // type = REQUEST
        c.uint.preencode(&body, 1)               // id
        c.uint.preencode(&body, 1)               // command
        c.uint.preencode(&body, 0)               // stream flags
        c.optionalBuffer.preencode(&body, payload)
        body.buffer = Data(count: body.end)
        body.start = 0
        c.uint.encode(&body, 1)
        c.uint.encode(&body, 1)
        c.uint.encode(&body, 1)
        c.uint.encode(&body, 0)
        c.optionalBuffer.encode(&body, payload)

        var frame = Data()
        var lenBytes = Data(count: 4)
        let bodyLen = UInt32(body.buffer.count)
        for i in 0..<4 { lenBytes[i] = UInt8((bodyLen >> (8 * i)) & 0xff) }
        frame.append(lenBytes)
        frame.append(body.buffer)

        XCTAssertEqual(hex(frame), f.hex, "Full bare-rpc REQUEST frame must byte-match the Node fixture")
    }
}
