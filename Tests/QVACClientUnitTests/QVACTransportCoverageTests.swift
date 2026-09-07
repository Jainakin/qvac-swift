import Foundation
import XCTest
@testable import QVACClient

/// Adversarial coverage for byte transport, bare-rpc lifecycle, and pull-driven
/// stream mapping. These tests stay in memory: failures identify protocol-state
/// regressions without depending on a worker process or wall-clock request timing.
final class QVACTransportCoverageTests: XCTestCase {
    private struct TestDeadlineExceeded: Error, CustomStringConvertible {
        let context: String
        var description: String { "timed out waiting for \(context)" }
    }

    private struct TerminalMarker: Error, Sendable, Equatable {}

    private final class InboundPipe: @unchecked Sendable {
        let stream: AsyncThrowingStream<Data, Error>
        let continuation: AsyncThrowingStream<Data, Error>.Continuation

        init() {
            var captured: AsyncThrowingStream<Data, Error>.Continuation!
            stream = AsyncThrowingStream { captured = $0 }
            continuation = captured
        }
    }

    private actor MockTransport: BareTransport {
        nonisolated private let inbound = InboundPipe()
        private var outboundBytes = Data()
        private var isClosed = false
        private var closeCount = 0

        nonisolated func inboundStream() -> AsyncThrowingStream<Data, Error> {
            inbound.stream
        }

        func write(_ data: Data) async throws {
            guard !isClosed else { throw BareRPCConnectionClosed() }
            outboundBytes.append(data)
        }

        func close() {
            guard !isClosed else { return }
            isClosed = true
            closeCount += 1
            inbound.continuation.finish()
        }

        func feed(_ data: Data) {
            inbound.continuation.yield(data)
        }

        func outbound() -> Data { outboundBytes }
        func closes() -> Int { closeCount }
    }

    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0

        func increment() {
            lock.withLock { storage += 1 }
        }

        func value() -> Int {
            lock.withLock { storage }
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

    private final class CapturingLogger: BareRPCLogger, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [(BareRPCLogLevel, String)] = []

        func log(_ level: BareRPCLogLevel, _ message: String) {
            lock.withLock { storage.append((level, message)) }
        }

        func records() -> [(BareRPCLogLevel, String)] {
            lock.withLock { storage }
        }
    }

    private final class LockedIntSource: @unchecked Sendable {
        private let lock = NSLock()
        private var values: ArraySlice<Int>

        init(_ values: [Int]) {
            self.values = ArraySlice(values)
        }

        func next() -> Int? {
            lock.withLock {
                guard let value = values.first else { return nil }
                values = values.dropFirst()
                return value
            }
        }
    }

    private actor SuspendedIntSource {
        private var waiter: CheckedContinuation<Int?, Never>?

        func next() async -> Int? {
            await withCheckedContinuation { continuation in
                guard waiter == nil else {
                    // A regression in the mapped driver's reentrancy guard must
                    // fail the scoped XCTest assertion, not trap the test host.
                    continuation.resume(returning: nil)
                    return
                }
                waiter = continuation
            }
        }

        func hasPendingRead() -> Bool { waiter != nil }

        func resume(returning value: Int?) {
            let pending = waiter
            waiter = nil
            pending?.resume(returning: value)
        }
    }

    /// Each box is used by one task. Two boxes can intentionally hold copies of
    /// one iterator to exercise the mapped driver's reentrancy defense.
    private final class IteratorBox<Element: Sendable>: @unchecked Sendable {
        private var iterator: QVACResponseStream<Element>.AsyncIterator

        init(_ iterator: QVACResponseStream<Element>.AsyncIterator) {
            self.iterator = iterator
        }

        func next() async throws -> Element? {
            try await iterator.next()
        }
    }

    private enum TransportReadOutcome: Sendable, Equatable {
        case value(Data?)
        case protocolViolation(String)
        case cancelled
        case unexpected(String)
        case deadline
        case deadlineCancelled
    }

    private static func readOnce(
        from stream: AsyncThrowingStream<Data, Error>
    ) async -> TransportReadOutcome {
        var iterator = stream.makeAsyncIterator()
        do {
            return .value(try await iterator.next())
        } catch let error as BareRPCProtocolError {
            return .protocolViolation(error.reason)
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .unexpected(String(describing: error))
        }
    }

    private static func transportRetainedCost(payloadBytes: Int) -> Int {
        payloadBytes + BoundedTransportInboundChannel.retainedValueOverheadBytes
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

    private static func frames(in data: Data) throws -> [BareRPCFrame] {
        let reader = BareRPCFrameReader()
        try reader.append(data)
        var frames: [BareRPCFrame] = []
        while let frame = reader.next() { frames.append(frame) }
        return frames
    }

    private static func waitForFrames(
        _ count: Int,
        on transport: MockTransport,
        timeout: Duration = .seconds(1)
    ) async throws -> [BareRPCFrame] {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            let decoded = try frames(in: await transport.outbound())
            if decoded.count >= count { return decoded }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw TestDeadlineExceeded(context: "\(count) outbound bare-rpc frames")
    }

    private static func waitForNoInFlight(
        _ rpc: BareRPCClient,
        timeout: Duration = .seconds(1)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await rpc.__testInFlightCounts() == (0, 0, 0) { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw TestDeadlineExceeded(context: "bare-rpc in-flight state cleanup")
    }

    private static func waitForStreamGeneration(
        id: UInt64,
        greaterThan previous: UInt64,
        on rpc: BareRPCClient,
        timeout: Duration = .seconds(1)
    ) async throws -> UInt64 {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let current = await rpc.__testStreamTimeoutGeneration(id: id),
               current > previous {
                return current
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw TestDeadlineExceeded(context: "stream timeout generation advancement")
    }

    private static func waitForPendingRead(
        on channel: BoundedRPCDataChannel,
        timeout: Duration = .seconds(1)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if channel.__testState().hasPendingWaiter { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw TestDeadlineExceeded(context: "bounded RPC channel reader")
    }

    private static func waitForPendingRead(
        on source: SuspendedIntSource,
        timeout: Duration = .seconds(1)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await source.hasPendingRead() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw TestDeadlineExceeded(context: "mapped stream source reader")
    }

    private static func waitForLog(
        on logger: CapturingLogger,
        timeout: Duration = .seconds(1)
    ) async throws -> (BareRPCLogLevel, String) {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let record = logger.records().first { return record }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw TestDeadlineExceeded(context: "unexpected-frame diagnostic")
    }

    private static func openDuplex(
        on rpc: BareRPCClient,
        transport: MockTransport,
        responseAsResponseFrame: Bool = false
    ) async throws -> (BareRPCDuplexSession, UInt64) {
        let opening = Task {
            try await rpc.duplex(
                command: 71,
                initialPayload: Data("initial".utf8),
                timeout: .seconds(5)
            )
        }
        let frames = try await waitForFrames(3, on: transport)
        guard case .request(let id, _, _, _) = frames[0] else {
            opening.cancel()
            await rpc.close()
            _ = try? await opening.value
            throw BareRPCProtocolError("test peer did not receive duplex request")
        }

        var acknowledgements = BareRPCCodec.__testEncodeStreamFrame(
            id: id,
            flags: [.request, .open]
        )
        if responseAsResponseFrame {
            acknowledgements.append(BareRPCCodec.__testEncodeResponseFrame(
                id: id,
                stream: [.open],
                payload: .success(nil)
            ))
        } else {
            acknowledgements.append(BareRPCCodec.__testEncodeStreamFrame(
                id: id,
                flags: [.response, .open]
            ))
        }
        await transport.feed(acknowledgements)
        return (try await opening.value, id)
    }

    private static func reply(
        _ payload: BareRPCResponsePayload,
        to task: Task<Void, Error>,
        rpc: BareRPCClient,
        transport: MockTransport
    ) async throws -> Result<Void, Error> {
        let frames = try await waitForFrames(1, on: transport)
        guard case .request(let id, _, _, _) = frames[0] else {
            task.cancel()
            await rpc.close()
            _ = try? await task.value
            throw BareRPCProtocolError("test peer did not receive handshake request")
        }
        await transport.feed(BareRPCCodec.__testEncodeResponseFrame(
            id: id,
            stream: [],
            payload: payload
        ))
        return await task.result
    }

    // MARK: - Transport channel lifecycle

    func test_transportChannelRejectsSecondClaimWithoutDisturbingOwner() async throws {
        let channel = BoundedTransportInboundChannel(
            maximumBufferedBytes: Self.transportRetainedCost(payloadBytes: 2)
        )
        let owner = channel.stream()
        let rejected = channel.stream()

        do {
            for try await _ in rejected {}
            XCTFail("a transport channel must not permit a second stream claim")
        } catch let error as BareRPCProtocolError {
            XCTAssertEqual(error.reason, "transport inboundStream() may be claimed only once")
        } catch {
            XCTFail("unexpected second-claim error: \(error)")
        }

        let payload = Data([0x01, 0x02])
        XCTAssertNil(channel.yield(payload))
        channel.finish()
        var received: [Data] = []
        for try await value in owner { received.append(value) }
        XCTAssertEqual(received, [payload])
    }

    func test_transportChannelConcurrentReadsFailOneAndCancellationWakesTheOwner() async {
        let cancellationCount = LockedCounter()
        let channel = BoundedTransportInboundChannel(maximumBufferedBytes: 8)
        channel.setCancellationHandler { cancellationCount.increment() }
        let stream = channel.stream()

        let outcomes = await withTaskGroup(
            of: TransportReadOutcome.self,
            returning: [TransportReadOutcome].self
        ) { group in
            group.addTask { await Self.readOnce(from: stream) }
            group.addTask { await Self.readOnce(from: stream) }
            group.addTask {
                do {
                    try await Task.sleep(for: .seconds(1))
                    return .deadline
                } catch {
                    return .deadlineCancelled
                }
            }

            guard let first = await group.next() else { return [] }
            group.cancelAll()
            var values = [first]
            while let next = await group.next() { values.append(next) }
            return values
        }

        XCTAssertTrue(outcomes.contains(.protocolViolation(
            "transport inbound stream supports only one active iterator"
        )))
        XCTAssertTrue(outcomes.contains(.cancelled))
        XCTAssertFalse(outcomes.contains(.deadline), "concurrent read defense must not hang")
        XCTAssertEqual(cancellationCount.value(), 1)
        let state = channel.__testState()
        XCTAssertEqual(state.queuedValues, 0)
        XCTAssertEqual(state.inFlightBytes, 0)
        XCTAssertEqual(state.bufferedBytes, 0)
        XCTAssertFalse(state.hasPendingWaiter)

        channel.finish()
        XCTAssertNil(channel.yield(Data([0xff])), "cancelled terminal channels ignore late bytes")
    }

    func test_transportChannelLargeAdapterReadOverflowIsAtomicAndDescriptive() async {
        let deliveryChunk = BoundedTransportInboundChannel.maximumDeliveryChunkBytes
        let retainedChunk = Self.transportRetainedCost(payloadBytes: deliveryChunk)
        let channel = BoundedTransportInboundChannel(
            maximumBufferedBytes: retainedChunk + 1
        )
        let stream = channel.stream()

        let overflow = channel.yield(Data(repeating: 0xa5, count: deliveryChunk * 2))
        XCTAssertEqual(overflow, BareTransportInboundBufferOverflow(
            maximumBufferedBytes: retainedChunk + 1,
            attemptedBufferedBytes: retainedChunk * 2
        ))
        XCTAssertEqual(
            overflow?.description,
            "transport inbound buffer would grow to \(retainedChunk * 2) bytes; "
                + "maximum is \(retainedChunk + 1)"
        )

        do {
            for try await _ in stream {}
            XCTFail("overflow must discard the first split chunk and fail the stream")
        } catch let error as BareTransportInboundBufferOverflow {
            XCTAssertEqual(error, overflow)
        } catch {
            XCTFail("unexpected overflow error: \(error)")
        }
    }

    func test_transportChannelTerminalErrorDrainsQueuedBytesAndIsFirstTerminalWins() async throws {
        let queued = Data("queued".utf8)
        let channel = BoundedTransportInboundChannel(
            maximumBufferedBytes: Self.transportRetainedCost(payloadBytes: queued.count)
        )
        let stream = channel.stream()
        XCTAssertNil(channel.yield(queued))
        channel.finish(throwing: TerminalMarker())
        channel.finish()
        XCTAssertNil(channel.yield(Data("late".utf8)))

        var iterator = stream.makeAsyncIterator()
        let first = try await iterator.next()
        XCTAssertEqual(first, queued)
        do {
            _ = try await iterator.next()
            XCTFail("the original terminal error must follow already-buffered bytes")
        } catch let error as TerminalMarker {
            XCTAssertEqual(error, TerminalMarker())
        } catch {
            XCTFail("unexpected terminal error: \(error)")
        }
    }

    func test_transportChannelCompactsLongQueuesWithoutReordering() async throws {
        let count = 130
        let retainedCost = Self.transportRetainedCost(payloadBytes: count)
        let channel = BoundedTransportInboundChannel(
            maximumBufferedBytes: retainedCost
        )
        let stream = channel.stream()
        for index in 0..<count {
            XCTAssertNil(channel.yield(Data([UInt8(index)])))
        }
        var state = channel.__testState()
        XCTAssertEqual(state.queuedValues, 1)
        XCTAssertEqual(state.bufferedBytes, retainedCost)
        channel.finish()

        var received: [UInt8] = []
        for try await value in stream {
            received.append(contentsOf: value)
        }
        XCTAssertEqual(received, (0..<count).map(UInt8.init))

        // Keep the consumed-prefix compaction path covered with true logical
        // deliveries rather than arbitrary native callback boundaries.
        let chunk = BoundedTransportInboundChannel.maximumDeliveryChunkBytes
        let logicalValueCost = Self.transportRetainedCost(payloadBytes: chunk)
        let compactionChannel = BoundedTransportInboundChannel(
            maximumBufferedBytes: logicalValueCost * count
        )
        let compactionStream = compactionChannel.stream()
        for index in 0..<count {
            XCTAssertNil(compactionChannel.yield(Data(
                repeating: UInt8(index),
                count: chunk
            )))
        }
        compactionChannel.finish()
        var logicalIndex = 0
        for try await value in compactionStream {
            XCTAssertEqual(value.count, chunk)
            XCTAssertEqual(value.first, UInt8(logicalIndex))
            XCTAssertEqual(value.last, UInt8(logicalIndex))
            logicalIndex += 1
        }
        XCTAssertEqual(logicalIndex, count)
        state = compactionChannel.__testState()
        XCTAssertEqual(state.queuedValues, 0)
        XCTAssertEqual(state.inFlightBytes, 0)
        XCTAssertEqual(state.bufferedBytes, 0)
    }

    func test_transportChannelEmptyAndTinyFloodsConsumeStructuralBudget() async throws {
        let emptyCount = 256
        let emptyCost = Self.transportRetainedCost(payloadBytes: 0)
        let emptyMaximum = emptyCost * emptyCount
        let emptyChannel = BoundedTransportInboundChannel(
            maximumBufferedBytes: emptyMaximum
        )

        for index in 0..<emptyCount {
            XCTAssertNil(emptyChannel.yield(Data()), "empty read \(index) should fit")
        }
        var state = emptyChannel.__testState()
        XCTAssertEqual(state.queuedValues, emptyCount)
        XCTAssertEqual(state.inFlightBytes, 0)
        XCTAssertEqual(state.bufferedBytes, emptyMaximum)

        let overflow = try XCTUnwrap(emptyChannel.yield(Data()))
        XCTAssertEqual(overflow.maximumBufferedBytes, emptyMaximum)
        XCTAssertEqual(overflow.attemptedBufferedBytes, emptyMaximum + emptyCost)
        state = emptyChannel.__testState()
        XCTAssertEqual(state.queuedValues, 0)
        XCTAssertEqual(state.inFlightBytes, 0)
        XCTAssertEqual(state.bufferedBytes, 0)

        let tinyCount = 130
        let tinyCost = Self.transportRetainedCost(payloadBytes: tinyCount)
        let tinyChannel = BoundedTransportInboundChannel(
            maximumBufferedBytes: tinyCost
        )
        let stream = tinyChannel.stream()
        for index in 0..<tinyCount {
            XCTAssertNil(tinyChannel.yield(Data([UInt8(index)])))
        }
        state = tinyChannel.__testState()
        XCTAssertEqual(state.queuedValues, 1)
        XCTAssertEqual(state.inFlightBytes, 0)
        XCTAssertEqual(state.bufferedBytes, tinyCost)
        tinyChannel.finish()

        var iterator = stream.makeAsyncIterator()
        let value = try await iterator.next()
        XCTAssertEqual(value, Data((0..<tinyCount).map(UInt8.init)))
        state = tinyChannel.__testState()
        XCTAssertEqual(state.queuedValues, 0)
        XCTAssertEqual(state.inFlightBytes, tinyCost)
        XCTAssertEqual(state.bufferedBytes, tinyCost)
        let terminalValue = try await iterator.next()
        XCTAssertNil(terminalValue)
        state = tinyChannel.__testState()
        XCTAssertEqual(state.queuedValues, 0)
        XCTAssertEqual(state.inFlightBytes, 0)
        XCTAssertEqual(state.bufferedBytes, 0)
    }

    func test_transportChannelDequeueAndDiscardingCloseReleaseRetention() async throws {
        let payloadBytes = 4_096
        let retainedCost = Self.transportRetainedCost(payloadBytes: payloadBytes)
        let dequeueProbe = DeallocationProbe()
        let dequeueChannel = BoundedTransportInboundChannel(
            maximumBufferedBytes: retainedCost
        )
        let dequeueStream = dequeueChannel.stream()
        var queued: Data? = Self.trackedData(count: payloadBytes, probe: dequeueProbe)
        XCTAssertNil(dequeueChannel.yield(try XCTUnwrap(queued)))
        queued = nil
        XCTAssertFalse(dequeueProbe.isReleased())

        var iterator = dequeueStream.makeAsyncIterator()
        var delivered: Data? = try await iterator.next()
        XCTAssertEqual(delivered?.count, payloadBytes)
        delivered = nil
        XCTAssertTrue(
            dequeueProbe.isReleased(),
            "dequeue must clear the channel's payload reference immediately"
        )
        var state = dequeueChannel.__testState()
        XCTAssertEqual(state.queuedValues, 0)
        XCTAssertEqual(state.inFlightBytes, retainedCost)
        XCTAssertEqual(state.bufferedBytes, retainedCost)
        dequeueChannel.finish()
        let terminalValue = try await iterator.next()
        XCTAssertNil(terminalValue)
        state = dequeueChannel.__testState()
        XCTAssertEqual(state.inFlightBytes, 0)
        XCTAssertEqual(state.bufferedBytes, 0)

        let closeProbe = DeallocationProbe()
        let closeChannel = BoundedTransportInboundChannel(
            maximumBufferedBytes: retainedCost
        )
        var closeQueued: Data? = Self.trackedData(
            count: payloadBytes,
            probe: closeProbe
        )
        XCTAssertNil(closeChannel.yield(try XCTUnwrap(closeQueued)))
        closeQueued = nil
        XCTAssertFalse(closeProbe.isReleased())
        closeChannel.finish(discardingBuffered: true)
        XCTAssertTrue(
            closeProbe.isReleased(),
            "the cancellation-driven transport close must discard queued storage"
        )
        state = closeChannel.__testState()
        XCTAssertEqual(state.queuedValues, 0)
        XCTAssertEqual(state.inFlightBytes, 0)
        XCTAssertEqual(state.bufferedBytes, 0)
    }

    // MARK: - Raw RPC data channel

    func test_rpcDataChannelRejectsConcurrentReadButKeepsOwnerUsable() async throws {
        let channel = BoundedRPCDataChannel(maximumBufferedBytes: 256) {}
        let owner = Task { try await channel.next() }
        try await Self.waitForPendingRead(on: channel)

        do {
            _ = try await channel.next()
            XCTFail("a second active raw reader must fail")
        } catch let error as BareRPCProtocolError {
            XCTAssertEqual(
                error.reason,
                "bare-rpc response stream supports only one active iterator"
            )
        } catch {
            XCTFail("unexpected concurrent-reader error: \(error)")
        }

        let payload = Data("owner".utf8)
        XCTAssertNil(channel.yield(payload))
        let ownerValue = try await owner.value
        XCTAssertEqual(ownerValue, payload)
        channel.finish()
        let terminalValue = try await channel.next()
        XCTAssertNil(terminalValue)
    }

    func test_rpcDataChannelFirstTerminalWinsAndLateValuesAreIgnored() async throws {
        let channel = BoundedRPCDataChannel(maximumBufferedBytes: 128) {}
        channel.finish()
        channel.finish(throwing: TerminalMarker())
        XCTAssertNil(channel.yield(Data("late".utf8)))
        let terminalValue = try await channel.next()
        XCTAssertNil(terminalValue)
        XCTAssertEqual(channel.__testState().bufferedBytes, 0)
    }

    // MARK: - Bare-rpc state machine

    func test_rpcRejectsZeroTimeoutBeforeAllocatingOrWriting() async {
        let transport = MockTransport()
        let rpc = BareRPCClient(transport: transport)

        do {
            _ = try await rpc.send(command: 1, data: nil, timeout: .zero)
            XCTFail("zero timeout must be rejected")
        } catch let error as BareRPCInvalidArgument {
            XCTAssertEqual(error.reason, "timeout must be greater than zero")
        } catch {
            XCTFail("unexpected timeout-validation error: \(error)")
        }

        let isOpen = await rpc.isOpen()
        let outbound = await transport.outbound()
        let inFlight = await rpc.__testInFlightCounts()
        XCTAssertTrue(isOpen)
        XCTAssertTrue(outbound.isEmpty)
        XCTAssertEqual(inFlight.sends, 0)
        XCTAssertEqual(inFlight.streams, 0)
        XCTAssertEqual(inFlight.duplexes, 0)
        await rpc.close()
    }

    func test_rpcIgnoresUnsolicitedRequestAndRemainsUsable() async throws {
        let transport = MockTransport()
        let logger = CapturingLogger()
        let rpc = BareRPCClient(transport: transport, logger: logger)

        await transport.feed(BareRPCCodec.__testEncodeRequestFrame(
            id: 0,
            command: 999,
            data: Data("event".utf8)
        ))
        let log = try await Self.waitForLog(on: logger)
        XCTAssertEqual(log.0, .debug)
        XCTAssertEqual(log.1, "ignoring unexpected REQUEST frame from server")

        let sending = Task {
            try await rpc.send(command: 2, data: Data("ping".utf8), timeout: .seconds(1))
        }
        let frames = try await Self.waitForFrames(1, on: transport)
        guard case .request(let id, _, _, _) = frames[0] else {
            sending.cancel()
            await rpc.close()
            return XCTFail("expected a request after the unsolicited peer frame")
        }
        let reply = Data("pong".utf8)
        await transport.feed(BareRPCCodec.__testEncodeResponseFrame(
            id: id,
            stream: [],
            payload: .success(reply)
        ))
        let response = try await sending.value
        XCTAssertEqual(response, reply)
        await rpc.close()
    }

    func test_streamResumeRefreshesIdleDeadlineAndCloseTerminatesCleanly() async throws {
        let transport = MockTransport()
        let rpc = BareRPCClient(transport: transport)
        let stream = try await rpc.stream(
            command: 8,
            data: Data("{}".utf8),
            timeout: .seconds(30)
        )
        let frames = try await Self.waitForFrames(2, on: transport)
        guard case .request(let id, _, _, _) = frames[0],
              let initialGeneration = await rpc.__testStreamTimeoutGeneration(id: id) else {
            await rpc.close()
            return XCTFail("expected a timed stream request")
        }

        await transport.feed(BareRPCCodec.__testEncodeStreamFrame(
            id: id,
            flags: [.response, .resume]
        ))
        _ = try await Self.waitForStreamGeneration(
            id: id,
            greaterThan: initialGeneration,
            on: rpc
        )
        let staleTimeoutDelivered = await rpc.__testFireStreamTimeout(
            id: id,
            generation: initialGeneration
        )
        let inFlightAfterStaleTimeout = await rpc.__testInFlightCounts()
        XCTAssertTrue(staleTimeoutDelivered)
        XCTAssertEqual(inFlightAfterStaleTimeout.streams, 1)

        await transport.feed(BareRPCCodec.__testEncodeStreamFrame(
            id: id,
            flags: [.response, .close]
        ))
        var iterator = stream.chunks.makeAsyncIterator()
        let terminalValue = try await iterator.next()
        XCTAssertNil(terminalValue)
        try await Self.waitForNoInFlight(rpc)
        await rpc.close()
    }

    func test_duplexAcceptsResponseEnvelopeAsResponseOpenAndHalfClosesCleanly() async throws {
        let transport = MockTransport()
        let rpc = BareRPCClient(transport: transport)
        let (session, id) = try await Self.openDuplex(
            on: rpc,
            transport: transport,
            responseAsResponseFrame: true
        )

        try await session.end()
        await transport.feed(BareRPCCodec.__testEncodeStreamFrame(
            id: id,
            flags: [.response, .end]
        ))
        var iterator = session.chunks.makeAsyncIterator()
        let terminalValue = try await iterator.next()
        XCTAssertNil(terminalValue)
        try await Self.waitForNoInFlight(rpc)

        let frames = try Self.frames(in: await transport.outbound())
        XCTAssertEqual(frames.count, 4)
        XCTAssertEqual(frames.map(\.id), [id, id, id, id])
        guard case .stream(_, let flags, .control) = frames[3] else {
            await rpc.close()
            return XCTFail("expected local request END")
        }
        XCTAssertEqual(flags, [.request, .end])
        await rpc.close()
    }

    func test_duplexResponseOverflowDiscardsQueuedDataAndTearsDownBothHalves() async throws {
        let perValueCost = BoundedRPCDataChannel.retainedValueOverheadBytes + 1
        let transport = MockTransport()
        let rpc = try BareRPCClient(
            transport: transport,
            maximumWireMessageBytes: 1_024,
            maximumBufferedStreamBytes: perValueCost
        )
        let (session, id) = try await Self.openDuplex(on: rpc, transport: transport)

        var inbound = BareRPCCodec.__testEncodeStreamFrame(
            id: id,
            flags: [.response, .data],
            payload: .data(Data([0x01]))
        )
        inbound.append(BareRPCCodec.__testEncodeStreamFrame(
            id: id,
            flags: [.response, .data],
            payload: .data(Data([0x02]))
        ))
        await transport.feed(inbound)
        try await Self.waitForNoInFlight(rpc)

        var iterator = session.chunks.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            XCTFail("overflow must discard previously queued response data")
        } catch let error as BareRPCStreamBufferOverflow {
            XCTAssertEqual(error.maximumBufferedBytes, perValueCost)
            XCTAssertEqual(error.attemptedBufferedBytes, perValueCost * 2)
            XCTAssertEqual(
                error.description,
                "bare-rpc stream buffer would grow to \(perValueCost * 2) bytes; "
                    + "maximumBufferedStreamBytes is \(perValueCost)"
            )
        } catch {
            XCTFail("unexpected duplex overflow error: \(error)")
        }

        let frames = try await Self.waitForFrames(5, on: transport)
        let teardownFlags = frames.compactMap { frame -> BareRPCStreamFlags? in
            guard case .stream(let frameID, let flags, _) = frame, frameID == id,
                  flags.contains(.close) || flags.contains(.destroy) else { return nil }
            return flags
        }
        XCTAssertEqual(teardownFlags, [[.request, .close], [.response, .destroy]])

        do {
            try await session.write(Data([0x03]))
            XCTFail("writes after response overflow must fail")
        } catch is BareRPCStreamClosed {
            // Expected: operation state was removed before remote teardown.
        } catch {
            XCTFail("unexpected post-overflow write error: \(error)")
        }
        await rpc.close()
    }

    func test_duplexRequestDirectionErrorIsAuthoritativeAndDoesNotEchoTeardown() async throws {
        let transport = MockTransport()
        let rpc = BareRPCClient(transport: transport)
        let (session, id) = try await Self.openDuplex(on: rpc, transport: transport)
        let remoteError = BareRPCError(
            message: "request input rejected",
            code: "E_INPUT",
            errno: 22
        )
        XCTAssertEqual(remoteError.description, "E_INPUT request input rejected (errno=22)")

        await transport.feed(BareRPCCodec.__testEncodeStreamFrame(
            id: id,
            flags: [.request, .error],
            payload: .error(remoteError)
        ))
        try await Self.waitForNoInFlight(rpc)

        var iterator = session.chunks.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            XCTFail("request-direction peer error must fail the duplex session")
        } catch let error as BareRPCError {
            XCTAssertEqual(error, remoteError)
        } catch {
            XCTFail("unexpected duplex peer error: \(error)")
        }
        let outbound = await transport.outbound()
        XCTAssertEqual(try Self.frames(in: outbound).count, 3)
        await rpc.close()
    }

    // MARK: - Wire framing and handshake failures

    func test_frameReaderCompactionPreservesFragmentedNextPrefix() throws {
        let large = BareRPCCodec.__testEncodeRequestFrame(
            id: 77,
            command: 4,
            data: Data(repeating: 0xa5, count: 70 * 1_024)
        )
        let next = BareRPCCodec.__testEncodeStreamFrame(
            id: 78,
            flags: [.response, .end]
        )
        var firstRead = large
        firstRead.append(next.prefix(2))

        let reader = BareRPCFrameReader()
        try reader.append(firstRead)
        XCTAssertEqual(reader.bufferedBytes, 2)
        XCTAssertEqual(reader.next()?.id, 77)

        try reader.append(next.dropFirst(2))
        XCTAssertEqual(reader.next()?.id, 78)
        XCTAssertNil(reader.next())
        XCTAssertEqual(reader.bufferedBytes, 0)
    }

    func test_wireCodecRejectsInvalidRangesUnknownTypesAndEncodedHeaderOverflow() {
        XCTAssertThrowsError(try BareRPCCodec.decodeFrameBody(
            Data([0x01, 0x02, 0x03]),
            in: 0..<4
        )) { error in
            XCTAssertEqual(error as? BareRPCCodecError, .truncated)
        }

        XCTAssertThrowsError(try BareRPCCodec.decodeFrameBody(Data([0x63, 0x01]))) { error in
            XCTAssertEqual(error as? BareRPCCodecError, .unknownType(99))
        }

        XCTAssertThrowsError(try BareRPCCodec.encodeResponseFrame(
            id: 1,
            stream: [],
            payload: .success(nil),
            maximumBodyBytes: 1
        )) { error in
            guard let invalid = error as? BareRPCInvalidArgument else {
                return XCTFail("expected local encoded-body limit error, got \(error)")
            }
            XCTAssertTrue(invalid.reason.contains("outbound bare-rpc frame is"))
            XCTAssertTrue(invalid.reason.contains("maximumWireMessageBytes is 1"))
        }

        for invalidLimit in [0, -1, Int(UInt32.max) + 1] {
            XCTAssertThrowsError(try BareRPCFrameReader(maxFrameSize: invalidLimit)) { error in
                XCTAssertEqual(
                    (error as? BareRPCInvalidArgument)?.reason,
                    "maxFrameSize must be between 1 and UInt32.max"
                )
            }
        }
    }

    func test_initHandshakeRejectsEmptyReplyWithStableDiagnostic() async throws {
        let transport = MockTransport()
        let rpc = BareRPCClient(transport: transport)
        let handshake = Task {
            try await QVACHandshake.sendInitConfig(
                on: rpc,
                config: .object(["mode": .string("test")]),
                runtimeContext: QVACRuntimeContext(runtime: "node", platform: "darwin"),
                timeout: .seconds(1)
            )
        }
        let result = try await Self.reply(
            .success(nil),
            to: handshake,
            rpc: rpc,
            transport: transport
        )

        switch result {
        case .success:
            XCTFail("empty init reply must fail")
        case .failure(let error as QVACInitConfigFailed):
            XCTAssertEqual(error.message, "empty reply")
            XCTAssertEqual(error.description, "init_config rejected by worker: empty reply")
        case .failure(let error):
            XCTFail("unexpected init handshake error: \(error)")
        }
        await rpc.close()
    }

    func test_shutdownHandshakeRejectsEmptyAndNegativeReplies() async throws {
        let cases: [(BareRPCResponsePayload, String)] = [
            (.success(nil), "empty shutdown reply"),
            (.success(Data(#"{"success":false}"#.utf8)), "shutdown rejected"),
            (.success(Data(#"{"success":false,"error":"worker busy"}"#.utf8)), "worker busy"),
        ]

        for (payload, expectedMessage) in cases {
            let transport = MockTransport()
            let rpc = BareRPCClient(transport: transport)
            let shutdown = Task {
                try await QVACHandshake.sendShutdown(on: rpc, timeout: .seconds(1))
            }
            let result = try await Self.reply(
                payload,
                to: shutdown,
                rpc: rpc,
                transport: transport
            )
            switch result {
            case .success:
                XCTFail("shutdown reply case must fail: \(expectedMessage)")
            case .failure(let error as QVACInitConfigFailed):
                XCTAssertEqual(error.message, expectedMessage)
            case .failure(let error):
                XCTFail("unexpected shutdown handshake error: \(error)")
            }
            await rpc.close()
        }
    }

    func test_runtimeContextCurrentMatchesNativeMacOSWorkerContract() {
        #if os(macOS)
        XCTAssertEqual(
            QVACRuntimeContext.current,
            QVACRuntimeContext(runtime: "node", platform: "darwin")
        )
        #endif
    }

    // MARK: - NDJSON and pull mapping

    func test_ndjsonFinishDrainsCompleteAndResidualRecordsReceivedWithoutExpansion() throws {
        var decoder = QVACNDJSONDecoder(maximumRecordBytes: 16)
        try decoder.receive(Data("one\n\n two ".utf8))
        XCTAssertEqual(
            try decoder.finish().map { String(decoding: $0, as: UTF8.self) },
            ["one", "two"]
        )

        try decoder.receive(Data("discard-me".utf8))
        decoder.discardBufferedBytes()
        XCTAssertEqual(try decoder.finish(), [])
    }

    func test_pullMapEmitManyDrainsPendingValuesInOrder() async throws {
        let sourceValues = LockedIntSource([3])
        let terminationCount = LockedCounter()
        let source = QVACResponseStream<Int>(
            unfolding: { sourceValues.next() },
            onTermination: { terminationCount.increment() }
        )
        let mapped: QVACResponseStream<Int> = QVACClient.pullMap(source) { value in
            .emitMany([value, value + 1, value + 2])
        }

        var received: [Int] = []
        for try await value in mapped { received.append(value) }
        XCTAssertEqual(received, [3, 4, 5])
        XCTAssertEqual(terminationCount.value(), 1)
    }

    func test_pullMapEmitThenDrainSupportsMultipleAndEmptyTerminalOutputs() async throws {
        do {
            let sourceValues = LockedIntSource([5])
            let source = QVACResponseStream<Int>(
                unfolding: { sourceValues.next() },
                onTermination: {}
            )
            let mapped: QVACResponseStream<Int> = QVACClient.pullMap(source) { value in
                .emitThenDrain([value, value + 1, value + 2])
            }

            var received: [Int] = []
            for try await value in mapped { received.append(value) }
            XCTAssertEqual(received, [5, 6, 7])
        }

        do {
            let sourceValues = LockedIntSource([9])
            let terminationCount = LockedCounter()
            let source = QVACResponseStream<Int>(
                unfolding: { sourceValues.next() },
                onTermination: { terminationCount.increment() }
            )
            let mapped: QVACResponseStream<Int> = QVACClient.pullMap(source) { _ in
                .emitThenDrain([])
            }

            var iterator = mapped.makeAsyncIterator()
            let terminalValue = try await iterator.next()
            XCTAssertNil(terminalValue)
            XCTAssertEqual(terminationCount.value(), 1)
        }
    }

    func test_pullMapCopiedIteratorCannotReenterDriverWhileSourceReadIsSuspended() async throws {
        let sourceValues = SuspendedIntSource()
        let source = QVACResponseStream<Int>(
            unfolding: { await sourceValues.next() },
            onTermination: {}
        )
        let mapped: QVACResponseStream<Int> = QVACClient.pullMap(
            source,
            operation: "copied-iterator"
        ) { .emit($0) }
        let iterator = mapped.makeAsyncIterator()
        let owner = IteratorBox(iterator)
        let copied = IteratorBox(iterator)

        let ownerRead = Task { try await owner.next() }
        try await Self.waitForPendingRead(on: sourceValues)

        do {
            _ = try await copied.next()
            XCTFail("a copied iterator must not reenter a suspended mapped read")
        } catch let error as QVACError {
            guard case .protocolViolation(let message) = error else {
                await sourceValues.resume(returning: nil)
                _ = try? await ownerRead.value
                return XCTFail("expected protocolViolation, got \(error)")
            }
            XCTAssertEqual(
                message,
                "mapped response stream does not support concurrent next() calls"
            )
        } catch {
            await sourceValues.resume(returning: nil)
            _ = try? await ownerRead.value
            return XCTFail("unexpected mapped reentrancy error: \(error)")
        }

        await sourceValues.resume(returning: 42)
        let ownerValue = try await ownerRead.value
        XCTAssertEqual(ownerValue, 42)
        mapped.cancel()
    }
}
