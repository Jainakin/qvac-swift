import XCTest
@testable import QVACClient

final class QVACNDJSONDecoderTests: XCTestCase {
    func test_fragmentation_coalescing_crlf_blank_lines_and_residual_eof() throws {
        var decoder = QVACNDJSONDecoder()

        XCTAssertEqual(try decoder.append(Data("  \r\n{\"first\":".utf8)), [])
        let records = try decoder.append(Data("1}\n\n\t{\"second\":2}\r\n{\"tail\":3}".utf8))
        XCTAssertEqual(records.map { String(decoding: $0, as: UTF8.self) }, [
            #"{"first":1}"#,
            #"{"second":2}"#,
        ])
        XCTAssertEqual(
            try decoder.finish().map { String(decoding: $0, as: UTF8.self) },
            [#"{"tail":3}"#]
        )
        XCTAssertEqual(try decoder.finish(), [])
    }

    func test_fragmentation_inside_multibyte_utf8_preserves_record_bytes() throws {
        let record = Data(#"{"text":"🙂 café"}"#.utf8)
        let split = record.count - 3
        var decoder = QVACNDJSONDecoder()
        XCTAssertEqual(try decoder.append(record.prefix(split)), [])
        var suffix = Data(record.suffix(from: split))
        suffix.append(0x0A)
        XCTAssertEqual(try decoder.append(suffix), [record])
    }

    func test_record_limit_accepts_boundary_and_rejects_one_byte_over() throws {
        XCTAssertEqual(
            QVACNDJSONDecoder.defaultMaximumRecordBytes,
            QVACClient.defaultMaximumWireMessageBytes
        )

        var atBoundary = QVACNDJSONDecoder(maximumRecordBytes: 4)
        XCTAssertEqual(try atBoundary.append(Data("1234".utf8)), [])
        XCTAssertEqual(try atBoundary.append(Data([0x0A])), [Data("1234".utf8)])

        var overBoundary = QVACNDJSONDecoder(maximumRecordBytes: 4)
        XCTAssertThrowsError(try overBoundary.append(Data("12345".utf8))) { error in
            XCTAssertEqual(error as? QVACNDJSONError, .recordTooLarge(limit: 4))
        }

        var completedOverBoundary = QVACNDJSONDecoder(maximumRecordBytes: 4)
        XCTAssertThrowsError(try completedOverBoundary.append(Data("12345\n".utf8))) { error in
            XCTAssertEqual(error as? QVACNDJSONError, .recordTooLarge(limit: 4))
        }

        var coalescedOverBoundary = QVACNDJSONDecoder(maximumRecordBytes: 4)
        XCTAssertThrowsError(try coalescedOverBoundary.append(Data("ok\n12345\n".utf8))) { error in
            XCTAssertEqual(error as? QVACNDJSONError, .recordTooLarge(limit: 4))
        }
    }

    func test_receive_rejects_cross_chunk_overflow_before_mutating_retained_record() throws {
        var decoder = QVACNDJSONDecoder(maximumRecordBytes: 4)
        try decoder.receive(Data("123".utf8))

        XCTAssertThrowsError(try decoder.receive(Data("45".utf8))) { error in
            XCTAssertEqual(error as? QVACNDJSONError, .recordTooLarge(limit: 4))
        }

        // The rejected chunk must not be retained. The original three-byte prefix
        // can still be completed exactly at the limit and decoded unchanged.
        try decoder.receive(Data("4\n".utf8))
        XCTAssertEqual(try decoder.nextRecord(), Data("1234".utf8))
        XCTAssertNil(try decoder.nextRecord())
    }

    func test_receive_validates_large_coalesced_chunks_transactionally() throws {
        var valid = QVACNDJSONDecoder(maximumRecordBytes: 4)
        try valid.receive(Data("1234\n1\n2345".utf8))
        XCTAssertEqual(
            try valid.finish().map { String(decoding: $0, as: UTF8.self) },
            ["1234", "1", "2345"]
        )

        var invalid = QVACNDJSONDecoder(maximumRecordBytes: 4)
        XCTAssertThrowsError(try invalid.receive(Data("ok\n12345\ntail".utf8))) { error in
            XCTAssertEqual(error as? QVACNDJSONError, .recordTooLarge(limit: 4))
        }
        try invalid.receive(Data("safe\n".utf8))
        XCTAssertEqual(try invalid.nextRecord(), Data("safe".utf8))
        XCTAssertNil(try invalid.nextRecord())
    }

    func test_profiling_trailer_requires_top_level_json_boolean_true() {
        XCTAssertTrue(QVACNDJSONDecoder.isProfilingTrailer(Data(
            #"{"__profilingTrailer":true,"__profiling":{"elapsedMs":12}}"#.utf8
        )))

        let lookalikes = [
            #"{"__profilingTrailer":false}"#,
            #"{"__profilingTrailer":1}"#,
            #"{"__profilingTrailer":"true"}"#,
            #"{"nested":{"__profilingTrailer":true}}"#,
            #"{"__profilingTrailer":true,"profile":{"elapsedMs":12}}"#,
            #"{"type":"domainResponse","__profilingTrailer":true}"#,
            #"{"__profilingTrailer":tru}"#,
            #"["__profilingTrailer",true]"#,
        ]
        for record in lookalikes {
            XCTAssertFalse(
                QVACNDJSONDecoder.isProfilingTrailer(Data(record.utf8)),
                "incorrectly accepted \(record)"
            )
        }
    }

    func test_shared_record_decoder_skips_only_real_trailer() throws {
        struct Value: Codable, Equatable { let value: Int }

        let value: Value? = try QVACClient.decodeStreamRecord(
            Value.self,
            from: Data(#"{"value":7}"#.utf8)
        )
        XCTAssertEqual(value, Value(value: 7))

        let lookalike: Value? = try QVACClient.decodeStreamRecord(
            Value.self,
            from: Data(#"{"__profilingTrailer":true,"value":99}"#.utf8)
        )
        XCTAssertEqual(lookalike, Value(value: 99))

        let trailer: Value? = try QVACClient.decodeStreamRecord(
            Value.self,
            from: Data(#"{"__profilingTrailer":true,"__profiling":{"id":"p"}}"#.utf8)
        )
        XCTAssertNil(trailer)

        XCTAssertThrowsError(try QVACClient.decodeStreamRecord(
            Value.self,
            from: Data(#"{"__profilingTrailer":1}"#.utf8)
        ) as Value?) { error in
            guard case QVACError.encoding = error else {
                return XCTFail("expected encoding error, got \(error)")
            }
        }
    }
}
