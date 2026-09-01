import Foundation
import XCTest
import QVACClient

final class QVACiOSSmokeTests: XCTestCase {
    func testBundledWorkerHandshakeHeartbeatAndIdempotentClose() async throws {
        XCTAssertEqual(HeartbeatRequest().type, "heartbeat")

        let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("qvac-ios-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: home)
        }
        let arguments = QVACClient.Configuration.defaultWorkletArguments(
            homeDirectory: home
        )
        XCTAssertEqual(arguments.count, 3)
        let configuration = try QVACClient.Configuration.iOSWithBundledResource(
            arguments: arguments
        )
        let client = try await QVACClient(
            configuration: configuration,
            initHandshakeTimeout: .seconds(45)
        )
        addTeardownBlock { await client.close() }

        let response = try await client.heartbeat(
            rpcOptions: .init(timeout: .seconds(15))
        )
        XCTAssertEqual(response.type, HeartbeatResponse.discriminator)
        XCTAssertGreaterThanOrEqual(response.number, 0)

        await client.close()
        await client.close()
    }
}
