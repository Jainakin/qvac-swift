import Foundation
import XCTest
@testable import QVACClient

final class BareIPCReadableDrainTests: XCTestCase {
    func testCheckedNativeReaderUsesTypedIMPForDataAndNSError() throws {
        let mock = CheckedNativeReadMock()
        let reader = try BareIPCTransport.__testCheckedNativeReader(for: mock)
        let payload = Data([0x10, 0x20, 0x30])

        mock.payload = payload as NSData
        XCTAssertEqual(try reader(), payload)

        mock.payload = nil
        mock.reportedError = NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        XCTAssertThrowsError(try reader()) { error in
            guard case let BareIPCTransport.Error.readFailed(underlying) = error else {
                return XCTFail("expected readFailed, got \(error)")
            }
            XCTAssertEqual((underlying as NSError).domain, NSPOSIXErrorDomain)
            XCTAssertEqual((underlying as NSError).code, Int(EIO))
        }
    }

    func testResponseBytesAreDeliveredBeforeObservableZeroByteEOF() async throws {
        let response = Data([0x01, 0x02, 0x03, 0x04])
        let reads: [Data?] = [response, Data(), nil]
        var readIndex = 0
        let channel = BoundedTransportInboundChannel(
            maximumBufferedBytes: response.count
                + BoundedTransportInboundChannel.retainedValueOverheadBytes
        )
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

    func testQueuedBytesDrainBeforeCheckedReadFailureIsObserved() async throws {
        let response = Data([0xa1, 0xb2, 0xc3])
        let nativeError = NSError(domain: NSPOSIXErrorDomain, code: Int(EBADF))
        var readCount = 0
        let channel = BoundedTransportInboundChannel(
            maximumBufferedBytes: response.count
                + BoundedTransportInboundChannel.retainedValueOverheadBytes
        )
        var iterator = channel.stream().makeAsyncIterator()

        let result = BareIPCTransport.__testDrainReadable(
            read: {
                readCount += 1
                if readCount == 1 { return response }
                throw nativeError
            },
            into: channel
        )

        XCTAssertEqual(result, .readFailed)
        XCTAssertEqual(readCount, 2)
        let deliveredResponse = try await iterator.next()
        XCTAssertEqual(deliveredResponse, response)
        do {
            _ = try await iterator.next()
            XCTFail("expected checked read failure after queued bytes")
        } catch {
            let captured = error as NSError
            XCTAssertEqual(captured.domain, NSPOSIXErrorDomain)
            XCTAssertEqual(captured.code, Int(EBADF))
        }
    }
}

private final class CheckedNativeReadMock: NSObject {
    var payload: NSData?
    var reportedError: NSError?

    @objc(readWithError:)
    func readWithError(
        _ error: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> NSData? {
        error?.pointee = reportedError
        return payload
    }
}
