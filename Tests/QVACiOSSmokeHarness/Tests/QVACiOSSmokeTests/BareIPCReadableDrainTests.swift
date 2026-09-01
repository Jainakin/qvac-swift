import Foundation
import XCTest
@testable import QVACClient

final class BareIPCReadableDrainTests: XCTestCase {
    func testResponseBytesAreDeliveredBeforeObservableZeroByteEOF() async throws {
        let response = Data([0x01, 0x02, 0x03, 0x04])
        let reads: [Data?] = [response, Data(), nil]
        var readIndex = 0
        let channel = BoundedTransportInboundChannel(maximumBufferedBytes: 64)
        let stream = channel.stream()

        let result = BareIPCTransport.__testDrainReadable(
            read: {
                defer { readIndex += 1 }
                return reads[readIndex]
            },
            into: channel
        )

        XCTAssertEqual(result, .peerEOF)
        XCTAssertEqual(readIndex, 2, "the adapter must stop reading immediately at EOF")
        var iterator = stream.makeAsyncIterator()
        let deliveredResponse = try await iterator.next()
        let terminal = try await iterator.next()
        XCTAssertEqual(deliveredResponse, response)
        XCTAssertNil(terminal, "queued bytes must drain before terminal EOF")
    }
}
