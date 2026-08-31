import Foundation
import XCTest
@testable import QVACClient

final class QVACVLAParityTests: XCTestCase {
    func test_preprocess_hwc_bytes_matches_published_017_javascript_fixture() throws {
        let output = try vlaPreprocessImage(
            [255, 0, 127, 0, 255, 128] as [UInt8],
            width: 2,
            height: 1,
            options: .init(size: 3, layout: .hwc)
        )
        XCTAssertEqual(
            littleEndianBase64(output),
            "AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAPwAAAAAAAIC/"
                + "AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAAAAAAIA/"
                + "AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/gYCAuwAAAACBgIA7"
        )
    }

    func test_preprocess_chw_float_matches_published_017_javascript_fixture() throws {
        let output = try vlaPreprocessImage(
            [0, 1, 0.25, 0.75, 0.5, 0.125] as [Float],
            width: 2,
            height: 1,
            options: .init(size: 3, layout: .chw, scale: 1)
        )
        XCTAssertEqual(
            littleEndianBase64(output),
            "AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AACAvwAAAAAAAIA/"
                + "AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AAAAvwAAAAAAAAA/"
                + "AACAvwAAgL8AAIC/AACAvwAAgL8AAIC/AAAAAAAAwL4AAEC/"
        )
    }

    func test_pad_state_matches_published_017_javascript_fixture() throws {
        let padded = try vlaPadState([1.5, -2] as [Float], targetDimension: 4)
        XCTAssertEqual(padded, [1.5, -2, 0, 0])
        XCTAssertEqual(littleEndianBase64(padded), "AADAPwAAAMAAAAAAAAAAAA==")
    }

    func test_preprocessing_and_padding_validate_shape() throws {
        XCTAssertThrowsError(try vlaPreprocessImage([UInt8](repeating: 0, count: 5), width: 1, height: 2))
        XCTAssertThrowsError(try vlaPreprocessImage([UInt8](repeating: 0, count: 3), width: 1, height: 1, options: .init(size: 0)))
        XCTAssertThrowsError(try vlaPadState([1, 2] as [Float], targetDimension: 1))
    }

    private func littleEndianBase64(_ values: [Float]) -> String {
        var data = Data(capacity: values.count * 4)
        for value in values {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data.base64EncodedString()
    }
}
