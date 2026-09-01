import Foundation
import XCTest
@testable import QVACClient

/// Focused regressions for the raw RPC channel's retained-byte invariant.
final class BareRPCDataChannelRetentionTests: XCTestCase {
    private struct WaiterTimeout: Error {}

    private actor Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var open = false

        func wait() async {
            if open { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            guard !open else { return }
            open = true
            let pending = continuation
            continuation = nil
            pending?.resume()
        }
    }

    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() {
            lock.withLock { value += 1 }
        }

        func get() -> Int {
            lock.withLock { value }
        }
    }

    private final class DeallocationProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var released = false

        func markReleased() {
            lock.withLock { released = true }
        }

        func isReleased() -> Bool {
            lock.withLock { released }
        }
    }

    private static func waitForPendingWaiter(
        on channel: BoundedRPCDataChannel,
        timeout: Duration = .seconds(1)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if channel.__testState().hasPendingWaiter {
                return
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("timed out waiting for the raw RPC channel consumer")
        throw WaiterTimeout()
    }

    private static func trackedData(
        count: Int,
        probe: DeallocationProbe
    ) -> Data {
        let bytes = UnsafeMutableRawPointer.allocate(
            byteCount: count,
            alignment: MemoryLayout<UInt8>.alignment
        )
        bytes.initializeMemory(as: UInt8.self, repeating: 0xa5, count: count)
        return Data(
            bytesNoCopy: bytes,
            count: count,
            deallocator: .custom { pointer, _ in
                pointer.deallocate()
                probe.markReleased()
            }
        )
    }

    private static func consumeOne(_ channel: BoundedRPCDataChannel) async throws -> Int? {
        let value = try await channel.next()
        return value?.count
    }

    private static func retainedCost(payloadBytes: Int) -> Int {
        payloadBytes + BoundedRPCDataChannel.retainedValueOverheadBytes
    }

    func test_dequeuedPayloadIsReleasedWhileItsByteLeaseRemainsCharged() async throws {
        let payloadBytes = 4_096
        let retainedBytes = Self.retainedCost(payloadBytes: payloadBytes)
        let maximumBytes = retainedBytes * 2
        let probe = DeallocationProbe()
        let channel = BoundedRPCDataChannel(maximumBufferedBytes: maximumBytes) {}

        var payload: Data? = Self.trackedData(count: payloadBytes, probe: probe)
        XCTAssertFalse(probe.isReleased())
        XCTAssertNil(channel.yield(try XCTUnwrap(payload)))
        payload = nil
        XCTAssertFalse(probe.isReleased(), "the queued payload must remain alive")

        let consumedBytes = try await Self.consumeOne(channel)
        XCTAssertEqual(consumedBytes, payloadBytes)
        XCTAssertTrue(
            probe.isReleased(),
            "dequeue must release the channel's payload reference immediately"
        )

        let state = channel.__testState()
        XCTAssertEqual(state.queuedValues, 0)
        XCTAssertEqual(state.inFlightBytes, retainedBytes)
        XCTAssertEqual(state.bufferedBytes, retainedBytes)

        let overflow = try XCTUnwrap(channel.yield(Data(count: payloadBytes + 1)))
        XCTAssertEqual(overflow.maximumBufferedBytes, maximumBytes)
        XCTAssertEqual(overflow.attemptedBufferedBytes, maximumBytes + 1)

        channel.finish(throwing: overflow, discardingBuffered: true)
        XCTAssertEqual(channel.__testState().bufferedBytes, 0)
    }

    func test_directHandoffRemainsChargedAgainstSubsequentQueuedValues() async throws {
        let firstCost = Self.retainedCost(payloadBytes: 6)
        let acceptedQueuedCost = Self.retainedCost(payloadBytes: 4)
        let maximumBytes = firstCost + acceptedQueuedCost
        let channel = BoundedRPCDataChannel(maximumBufferedBytes: maximumBytes) {}
        let firstRead = Task { try await channel.next() }
        try await Self.waitForPendingWaiter(on: channel)

        XCTAssertNil(channel.yield(Data(repeating: 1, count: 6)))
        let firstValue = try await firstRead.value
        XCTAssertEqual(firstValue?.count, 6)

        let handedOff = channel.__testState()
        XCTAssertEqual(handedOff.queuedValues, 0)
        XCTAssertEqual(handedOff.inFlightBytes, firstCost)
        XCTAssertEqual(handedOff.bufferedBytes, firstCost)

        let overflow = try XCTUnwrap(channel.yield(Data(repeating: 2, count: 5)))
        XCTAssertEqual(overflow.maximumBufferedBytes, maximumBytes)
        XCTAssertEqual(overflow.attemptedBufferedBytes, maximumBytes + 1)

        XCTAssertNil(channel.yield(Data(repeating: 3, count: 4)))
        let full = channel.__testState()
        XCTAssertEqual(full.queuedValues, 1)
        XCTAssertEqual(full.inFlightBytes, firstCost)
        XCTAssertEqual(full.bufferedBytes, maximumBytes)

        channel.finish(discardingBuffered: true)
        XCTAssertEqual(channel.__testState().bufferedBytes, 0)
    }

    func test_oversizedValueIsRejectedEvenWhenAnIteratorIsWaiting() async throws {
        let maximumBytes = Self.retainedCost(payloadBytes: 4)
        let channel = BoundedRPCDataChannel(maximumBufferedBytes: maximumBytes) {}
        let read = Task { try await channel.next() }
        try await Self.waitForPendingWaiter(on: channel)

        let overflow = try XCTUnwrap(channel.yield(Data(repeating: 1, count: 5)))
        XCTAssertEqual(overflow.maximumBufferedBytes, maximumBytes)
        XCTAssertEqual(overflow.attemptedBufferedBytes, maximumBytes + 1)

        let waiting = channel.__testState()
        XCTAssertTrue(waiting.hasPendingWaiter)
        XCTAssertEqual(waiting.bufferedBytes, 0)
        XCTAssertEqual(waiting.inFlightBytes, 0)

        // The channel reports overflow to its owning RPC operation; operation
        // teardown then delivers that same terminal error to the active reader.
        channel.finish(throwing: overflow, discardingBuffered: true)
        do {
            _ = try await read.value
            XCTFail("expected the active reader to receive buffer overflow")
        } catch let error as BareRPCStreamBufferOverflow {
            XCTAssertEqual(error, overflow)
        } catch {
            XCTFail("unexpected terminal error: \(error)")
        }
    }

    func test_normalTerminalDrainsQueuedValuesAndReleasesEachLease() async throws {
        let firstCost = Self.retainedCost(payloadBytes: 4)
        let secondCost = Self.retainedCost(payloadBytes: 3)
        let maximumBytes = firstCost + secondCost
        let channel = BoundedRPCDataChannel(maximumBufferedBytes: maximumBytes) {}
        XCTAssertNil(channel.yield(Data(repeating: 1, count: 4)))
        XCTAssertNil(channel.yield(Data(repeating: 2, count: 3)))
        channel.finish()

        let firstValue = try await channel.next()
        XCTAssertEqual(firstValue?.count, 4)
        var state = channel.__testState()
        XCTAssertEqual(state.queuedValues, 1)
        XCTAssertEqual(state.inFlightBytes, firstCost)
        XCTAssertEqual(state.bufferedBytes, maximumBytes)

        let secondValue = try await channel.next()
        XCTAssertEqual(secondValue?.count, 3)
        state = channel.__testState()
        XCTAssertEqual(state.queuedValues, 0)
        XCTAssertEqual(state.inFlightBytes, secondCost)
        XCTAssertEqual(state.bufferedBytes, secondCost)

        let terminalValue = try await channel.next()
        XCTAssertNil(terminalValue)
        state = channel.__testState()
        XCTAssertEqual(state.queuedValues, 0)
        XCTAssertEqual(state.inFlightBytes, 0)
        XCTAssertEqual(state.bufferedBytes, 0)
    }

    func test_emptyFrameFloodHitsStructuralBoundAndDiscardReleasesAccounting() throws {
        let frameCount = 1_024
        let perFrameCost = Self.retainedCost(payloadBytes: 0)
        let maximumBytes = perFrameCost * frameCount
        let channel = BoundedRPCDataChannel(maximumBufferedBytes: maximumBytes) {}

        for index in 0..<frameCount {
            XCTAssertNil(channel.yield(Data()), "empty frame \(index) should fit")
        }

        var state = channel.__testState()
        XCTAssertEqual(state.queuedValues, frameCount)
        XCTAssertEqual(state.inFlightBytes, 0)
        XCTAssertEqual(state.bufferedBytes, maximumBytes)

        let overflow = try XCTUnwrap(channel.yield(Data()))
        XCTAssertEqual(overflow.maximumBufferedBytes, maximumBytes)
        XCTAssertEqual(overflow.attemptedBufferedBytes, maximumBytes + perFrameCost)

        channel.finish(throwing: overflow, discardingBuffered: true)
        state = channel.__testState()
        XCTAssertEqual(state.queuedValues, 0)
        XCTAssertEqual(state.inFlightBytes, 0)
        XCTAssertEqual(state.bufferedBytes, 0)
    }

    func test_tinyFrameFloodDrainsWithQueuedAndInFlightChargesThenReleasesAccounting() async throws {
        let frameCount = 256
        let perFrameCost = Self.retainedCost(payloadBytes: 1)
        let maximumBytes = perFrameCost * frameCount
        let channel = BoundedRPCDataChannel(maximumBufferedBytes: maximumBytes) {}

        for index in 0..<frameCount {
            XCTAssertNil(
                channel.yield(Data([UInt8(truncatingIfNeeded: index)])),
                "tiny frame \(index) should fit"
            )
        }
        channel.finish()

        for index in 0..<frameCount {
            let value = try await channel.next()
            XCTAssertEqual(value, Data([UInt8(truncatingIfNeeded: index)]))
            let state = channel.__testState()
            XCTAssertEqual(state.queuedValues, frameCount - index - 1)
            XCTAssertEqual(state.inFlightBytes, perFrameCost)
            XCTAssertEqual(state.bufferedBytes, perFrameCost * (frameCount - index))
        }

        let terminalValue = try await channel.next()
        XCTAssertNil(terminalValue)
        let state = channel.__testState()
        XCTAssertEqual(state.queuedValues, 0)
        XCTAssertEqual(state.inFlightBytes, 0)
        XCTAssertEqual(state.bufferedBytes, 0)
    }

    func test_cancelAfterNormalTerminalDiscardsQueuedAndInFlightRetention() async throws {
        let cancellations = LockedCounter()
        let firstCost = Self.retainedCost(payloadBytes: 4)
        let secondCost = Self.retainedCost(payloadBytes: 3)
        let channel = BoundedRPCDataChannel(
            maximumBufferedBytes: firstCost + secondCost
        ) {
            cancellations.increment()
        }
        XCTAssertNil(channel.yield(Data(repeating: 1, count: 4)))
        XCTAssertNil(channel.yield(Data(repeating: 2, count: 3)))
        channel.finish()

        let firstValue = try await channel.next()
        XCTAssertEqual(firstValue, Data(repeating: 1, count: 4))
        var state = channel.__testState()
        XCTAssertEqual(state.queuedValues, 1)
        XCTAssertEqual(state.inFlightBytes, firstCost)
        XCTAssertEqual(state.bufferedBytes, firstCost + secondCost)

        channel.cancel()
        channel.cancel()
        state = channel.__testState()
        XCTAssertEqual(state.queuedValues, 0)
        XCTAssertEqual(state.inFlightBytes, 0)
        XCTAssertEqual(state.bufferedBytes, 0)
        XCTAssertEqual(
            cancellations.get(),
            0,
            "a remotely completed operation must not send a late destroy"
        )

        let terminalValue = try await channel.next()
        XCTAssertNil(terminalValue)
    }

    func test_pendingReadCancellationStillNotifiesExactlyOnce() async throws {
        let cancellations = LockedCounter()
        let channel = BoundedRPCDataChannel(maximumBufferedBytes: 8) {
            cancellations.increment()
        }
        let read = Task { try await channel.next() }
        try await Self.waitForPendingWaiter(on: channel)

        read.cancel()
        do {
            _ = try await read.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("unexpected cancellation error: \(error)")
        }

        XCTAssertEqual(cancellations.get(), 1)
        XCTAssertFalse(channel.__testState().hasPendingWaiter)
        channel.finish(discardingBuffered: true)
    }

    func test_preCancelledReadStillNotifiesExactlyOnce() async throws {
        let cancellations = LockedCounter()
        let channel = BoundedRPCDataChannel(maximumBufferedBytes: 8) {
            cancellations.increment()
        }
        let gate = Gate()
        let read = Task {
            await gate.wait()
            return try await channel.next()
        }
        read.cancel()
        await gate.release()

        do {
            _ = try await read.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("unexpected cancellation error: \(error)")
        }

        XCTAssertEqual(cancellations.get(), 1)
        XCTAssertFalse(channel.__testState().hasPendingWaiter)
        channel.finish(discardingBuffered: true)
    }
}
