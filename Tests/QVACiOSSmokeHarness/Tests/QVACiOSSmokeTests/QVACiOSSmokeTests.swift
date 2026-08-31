import Foundation
import XCTest
import QVACClient

final class QVACiOSSmokeTests: XCTestCase {
    func testExternalPackageImportAndBundledWorkerResource() throws {
        XCTAssertEqual(HeartbeatRequest().type, "heartbeat")

        let arguments = QVACClient.Configuration.defaultWorkletArguments(
            homeDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("qvac-ios-smoke", isDirectory: true)
        )
        XCTAssertEqual(arguments.count, 3)
        XCTAssertNoThrow(
            try QVACClient.Configuration.iOSWithBundledResource(arguments: arguments)
        )
    }
}
