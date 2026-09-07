import Foundation
import XCTest
@testable import QVACClient

#if canImport(Darwin)
import Darwin
#endif

/// Failure-path specifications for the byte transport and the two bounded stream
/// implementations. Every test uses deterministic in-memory peers or local Unix
/// sockets; none requires a QVAC worker, a model download, or external network I/O.
final class QVACTransportFailureContractTests: XCTestCase {
    private struct InjectedWriteFailure: Error, Sendable, Equatable {}

    private struct TestDeadlineExceeded: Error, CustomStringConvertible {
        let context: String
        var description: String { "timed out waiting for \(context)" }
    }

    private final class InboundPipe: @unchecked Sendable {
        let stream: AsyncThrowingStream<Data, Error>
        let continuation: AsyncThrowingStream<Data, Error>.Continuation

        init() {
            var captured: AsyncThrowingStream<Data, Error>.Continuation!
            stream = AsyncThrowingStream { captured = $0 }
            continuation = captured
        }
    }

    /// Records every attempted write and can fail one exact attempt. Failed bytes
    /// are not added to `outbound`, matching a transport that rejects a write before
    /// committing any of that frame to the socket.
    private actor ScriptedWriteTransport: BareTransport {
        nonisolated private let inbound = InboundPipe()
        private let failingWrite: Int?
        private var outbound = Data()
        private var writeAttempts = 0
        private var closeCount = 0
        private var closed = false

        init(failingWrite: Int? = nil) {
            self.failingWrite = failingWrite
        }

        nonisolated func inboundStream() -> AsyncThrowingStream<Data, Error> {
            inbound.stream
        }

        func write(_ data: Data) throws {
            writeAttempts += 1
            guard !closed else { throw BareRPCConnectionClosed() }
            if writeAttempts == failingWrite { throw InjectedWriteFailure() }
            outbound.append(data)
        }

        func close() {
            guard !closed else { return }
            closed = true
            closeCount += 1
            inbound.continuation.finish()
        }

        func feed(_ data: Data) {
            inbound.continuation.yield(data)
        }

        func snapshot() -> (outbound: Data, writes: Int, closes: Int) {
            (outbound, writeAttempts, closeCount)
        }
    }

    /// Allows the three duplex setup writes to complete, then suspends every
    /// application write until connection teardown. Deliberately ignoring task
    /// cancellation models a full OS send buffer or a non-cooperative adapter.
    private actor BlockingDuplexWriteTransport: BareTransport {
        nonisolated private let inbound = InboundPipe()
        private var outbound = Data()
        private var writeAttempts = 0
        private var closeCount = 0
        private var closed = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        nonisolated func inboundStream() -> AsyncThrowingStream<Data, Error> {
            inbound.stream
        }

        func write(_ data: Data) async throws {
            guard !closed else { throw BareRPCConnectionClosed() }
            writeAttempts += 1
            outbound.append(data)
            guard writeAttempts > 3 else { return }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func close() {
            guard !closed else { return }
            closed = true
            closeCount += 1
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
            inbound.continuation.finish()
        }

        func feed(_ data: Data) {
            inbound.continuation.yield(data)
        }

        func snapshot() -> (outbound: Data, writes: Int, closes: Int) {
            (outbound, writeAttempts, closeCount)
        }
    }

    /// Suspends inside a cancellation-aware transport write. This complements the
    /// non-cooperative duplex adapter by specifying the fast path for transports
    /// that promptly honor Swift task cancellation.
    private actor CooperativeBlockingWriteTransport: BareTransport {
        nonisolated private let inbound = InboundPipe()
        private var writeAttempts = 0
        private var closeCount = 0
        private var closed = false

        nonisolated func inboundStream() -> AsyncThrowingStream<Data, Error> {
            inbound.stream
        }

        func write(_ data: Data) async throws {
            guard !closed else { throw BareRPCConnectionClosed() }
            writeAttempts += 1
            try await Task.sleep(for: .seconds(30))
        }

        func close() {
            guard !closed else { return }
            closed = true
            closeCount += 1
            inbound.continuation.finish()
        }

        func snapshot() -> (writes: Int, closes: Int) {
            (writeAttempts, closeCount)
        }
    }

    /// Each box owns one value copy of the same reference-backed iterator cursor.
    private final class BufferedIteratorBox<Element: Sendable>: @unchecked Sendable {
        private var iterator: QVACBufferedStream<Element>.AsyncIterator

        init(_ iterator: QVACBufferedStream<Element>.AsyncIterator) {
            self.iterator = iterator
        }

        func next() async throws -> Element? {
            try await iterator.next()
        }
    }

    private static func frames(in bytes: Data) throws -> [BareRPCFrame] {
        let reader = BareRPCFrameReader()
        try reader.append(bytes)
        var result: [BareRPCFrame] = []
        while let frame = reader.next() { result.append(frame) }
        return result
    }

    private static func waitForWrites(
        _ count: Int,
        on transport: ScriptedWriteTransport,
        timeout: Duration = .seconds(1)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await transport.snapshot().writes >= count { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw TestDeadlineExceeded(context: "\(count) scripted transport writes")
    }

    private static func waitForWrites(
        _ count: Int,
        on transport: BlockingDuplexWriteTransport,
        timeout: Duration = .seconds(1)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await transport.snapshot().writes >= count { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw TestDeadlineExceeded(context: "\(count) blocking transport writes")
    }

    private static func waitForWrites(
        _ count: Int,
        on transport: CooperativeBlockingWriteTransport,
        timeout: Duration = .seconds(1)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await transport.snapshot().writes >= count { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw TestDeadlineExceeded(context: "\(count) cooperative transport writes")
    }

    private static func waitForClose(
        on transport: ScriptedWriteTransport,
        timeout: Duration = .seconds(1)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await transport.snapshot().closes == 1 { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw TestDeadlineExceeded(context: "scripted transport close")
    }

    private static func waitForClose(
        on transport: BlockingDuplexWriteTransport,
        timeout: Duration = .seconds(1)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await transport.snapshot().closes == 1 { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw TestDeadlineExceeded(context: "blocking transport close")
    }

    private static func waitForClose(
        on transport: CooperativeBlockingWriteTransport,
        timeout: Duration = .seconds(1)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await transport.snapshot().closes == 1 { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw TestDeadlineExceeded(context: "cooperative transport close")
    }

    private static func waitForPendingRead<Element: Sendable>(
        on channel: QVACBufferedStreamChannel<Element>,
        timeout: Duration = .seconds(1)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if channel.hasPendingWaiterForTesting() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw TestDeadlineExceeded(context: "buffered-stream consumer")
    }

    private static func waitForPendingRead<Element: Sendable>(
        on sink: QVACBufferedStreamSink<Element>,
        timeout: Duration = .seconds(1)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if sink.hasPendingWaiterForTesting() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw TestDeadlineExceeded(context: "public buffered-stream iterator")
    }

    private static func openDuplex(
        rpc: BareRPCClient,
        transport: ScriptedWriteTransport
    ) async throws -> (session: BareRPCDuplexSession, id: UInt64) {
        let opening = Task {
            try await rpc.duplex(
                command: 901,
                initialPayload: Data("initial".utf8),
                timeout: .seconds(5)
            )
        }
        try await waitForWrites(3, on: transport)
        let outbound = await transport.snapshot().outbound
        guard case .request(let id, _, _, _) = try frames(in: outbound).first else {
            opening.cancel()
            await rpc.close()
            _ = try? await opening.value
            throw BareRPCProtocolError("test peer did not receive duplex request")
        }
        var acknowledgement = BareRPCCodec.__testEncodeStreamFrame(
            id: id,
            flags: [.request, .open]
        )
        acknowledgement.append(BareRPCCodec.__testEncodeStreamFrame(
            id: id,
            flags: [.response, .open]
        ))
        await transport.feed(acknowledgement)
        return (try await opening.value, id)
    }

    private static func openDuplex(
        rpc: BareRPCClient,
        transport: BlockingDuplexWriteTransport
    ) async throws -> (session: BareRPCDuplexSession, id: UInt64) {
        let opening = Task {
            try await rpc.duplex(
                command: 902,
                initialPayload: Data("initial".utf8),
                timeout: .seconds(5)
            )
        }
        try await waitForWrites(3, on: transport)
        let outbound = await transport.snapshot().outbound
        guard case .request(let id, _, _, _) = try frames(in: outbound).first else {
            opening.cancel()
            await rpc.close()
            _ = try? await opening.value
            throw BareRPCProtocolError("test peer did not receive duplex request")
        }
        var acknowledgement = BareRPCCodec.__testEncodeStreamFrame(
            id: id,
            flags: [.request, .open]
        )
        acknowledgement.append(BareRPCCodec.__testEncodeStreamFrame(
            id: id,
            flags: [.response, .open]
        ))
        await transport.feed(acknowledgement)
        return (try await opening.value, id)
    }

    #if canImport(Darwin)
    private static func makeSocketPair() throws -> [Int32] {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw UnixDomainSocketTransport.SpawnError.socketConfigurationFailed(errno: errno)
        }
        return descriptors
    }
    #endif

    // MARK: - Bare-rpc failure containment

    func test_stream_setup_second_write_failure_closes_generation_and_clears_state() async throws {
        let transport = ScriptedWriteTransport(failingWrite: 2)
        let rpc = BareRPCClient(transport: transport)

        do {
            _ = try await rpc.stream(
                command: 903,
                data: Data("request".utf8),
                timeout: .seconds(5)
            )
            XCTFail("a failed response-open write must fail stream setup")
        } catch is InjectedWriteFailure {
            // Expected: the exact transport failure is preserved for the caller.
        } catch {
            XCTFail("unexpected stream setup error: \(error)")
        }

        try await Self.waitForClose(on: transport)
        let state = await rpc.__testInFlightCounts()
        XCTAssertEqual(state.streams, 0)
        let isOpen = await rpc.isOpen()
        XCTAssertFalse(isOpen)
        let snapshot = await transport.snapshot()
        XCTAssertEqual(snapshot.writes, 2)
        XCTAssertEqual(snapshot.closes, 1)
        await rpc.close()
    }

    func test_duplex_initial_chunk_write_failure_closes_generation_and_clears_state() async throws {
        let transport = ScriptedWriteTransport(failingWrite: 3)
        let rpc = BareRPCClient(transport: transport)

        do {
            _ = try await rpc.duplex(
                command: 904,
                initialPayload: Data("initial".utf8),
                timeout: .seconds(5)
            )
            XCTFail("a failed initial DATA write must fail duplex setup")
        } catch is InjectedWriteFailure {
            // Expected.
        } catch {
            XCTFail("unexpected duplex setup error: \(error)")
        }

        try await Self.waitForClose(on: transport)
        let state = await rpc.__testInFlightCounts()
        XCTAssertEqual(state.duplexes, 0)
        let isOpen = await rpc.isOpen()
        XCTAssertFalse(isOpen)
        let snapshot = await transport.snapshot()
        XCTAssertEqual(snapshot.writes, 3)
        XCTAssertEqual(snapshot.closes, 1)
        await rpc.close()
    }

    func test_stream_teardown_write_failure_invalidates_otherwise_open_generation() async throws {
        let transport = ScriptedWriteTransport(failingWrite: 3)
        let rpc = BareRPCClient(transport: transport)
        let stream = try await rpc.stream(command: 905, data: nil, timeout: .seconds(5))

        stream.destroy()

        try await Self.waitForClose(on: transport)
        let isOpen = await rpc.isOpen()
        XCTAssertFalse(isOpen)
        let state = await rpc.__testInFlightCounts()
        XCTAssertEqual(state.streams, 0)
        let snapshot = await transport.snapshot()
        XCTAssertEqual(snapshot.writes, 3)
        XCTAssertEqual(snapshot.closes, 1)
        withExtendedLifetime(stream) {}
        await rpc.close()
    }

    func test_post_handshake_duplex_data_write_failure_invalidates_generation() async throws {
        let transport = ScriptedWriteTransport(failingWrite: 4)
        let rpc = BareRPCClient(transport: transport)
        let opened = try await Self.openDuplex(rpc: rpc, transport: transport)

        do {
            try await opened.session.write(Data("next".utf8))
            XCTFail("a failed application DATA write must be observable")
        } catch is InjectedWriteFailure {
            // Expected.
        } catch {
            XCTFail("unexpected duplex DATA write error: \(error)")
        }

        try await Self.waitForClose(on: transport)
        let isOpen = await rpc.isOpen()
        XCTAssertFalse(isOpen)
        let state = await rpc.__testInFlightCounts()
        XCTAssertEqual(state.duplexes, 0)
        let snapshot = await transport.snapshot()
        XCTAssertEqual(snapshot.writes, 4)
        XCTAssertEqual(snapshot.closes, 1)
        withExtendedLifetime(opened.session) {}
        await rpc.close()
    }

    func test_post_handshake_duplex_end_write_failure_invalidates_generation() async throws {
        let transport = ScriptedWriteTransport(failingWrite: 4)
        let rpc = BareRPCClient(transport: transport)
        let opened = try await Self.openDuplex(rpc: rpc, transport: transport)

        do {
            try await opened.session.end()
            XCTFail("a failed request END write must be observable")
        } catch is InjectedWriteFailure {
            // Expected.
        } catch {
            XCTFail("unexpected duplex END write error: \(error)")
        }

        try await Self.waitForClose(on: transport)
        let isOpen = await rpc.isOpen()
        XCTAssertFalse(isOpen)
        let state = await rpc.__testInFlightCounts()
        XCTAssertEqual(state.duplexes, 0)
        let snapshot = await transport.snapshot()
        XCTAssertEqual(snapshot.writes, 4)
        XCTAssertEqual(snapshot.closes, 1)
        withExtendedLifetime(opened.session) {}
        await rpc.close()
    }

    func test_cancelling_noncooperative_duplex_write_closes_generation_and_unblocks_writer() async throws {
        let transport = BlockingDuplexWriteTransport()
        let rpc = BareRPCClient(transport: transport)
        let opened = try await Self.openDuplex(rpc: rpc, transport: transport)
        let write = Task {
            try await opened.session.write(Data("blocked".utf8))
        }
        try await Self.waitForWrites(4, on: transport)

        write.cancel()

        do {
            try await Self.waitForClose(on: transport)
        } catch {
            await transport.close()
            _ = try? await write.value
            throw error
        }
        do {
            try await write.value
            XCTFail("the canceled write must not report ambiguous success")
        } catch is CancellationError {
            // Expected even though transport.close() releases the blocked adapter.
        } catch {
            XCTFail("unexpected canceled-write error: \(error)")
        }

        let isOpen = await rpc.isOpen()
        XCTAssertFalse(isOpen)
        let snapshot = await transport.snapshot()
        XCTAssertEqual(snapshot.writes, 4)
        XCTAssertEqual(snapshot.closes, 1)
        withExtendedLifetime(opened.session) {}
        await rpc.close()
    }

    func test_cancelling_cooperative_send_write_closes_generation_without_exposing_transport_race() async throws {
        let transport = CooperativeBlockingWriteTransport()
        let rpc = BareRPCClient(transport: transport)
        let request = Task {
            try await rpc.send(command: 907, data: Data("blocked".utf8), timeout: .seconds(5))
        }
        try await Self.waitForWrites(1, on: transport)

        request.cancel()

        do {
            _ = try await request.value
            XCTFail("a canceled request must preserve structured cancellation")
        } catch is CancellationError {
            // Expected. The adapter's CancellationError is contained by the write
            // task while the caller's continuation resolves exactly once.
        } catch {
            XCTFail("unexpected cooperative-write cancellation error: \(error)")
        }
        try await Self.waitForClose(on: transport)
        let state = await rpc.__testInFlightCounts()
        XCTAssertEqual(state.sends, 0)
        let isOpen = await rpc.isOpen()
        XCTAssertFalse(isOpen)
        let snapshot = await transport.snapshot()
        XCTAssertEqual(snapshot.writes, 1)
        XCTAssertEqual(snapshot.closes, 1)
        await rpc.close()
    }

    func test_remote_duplex_error_during_noncooperative_write_preserves_error_and_unblocks_writer() async throws {
        let transport = BlockingDuplexWriteTransport()
        let rpc = BareRPCClient(transport: transport)
        let opened = try await Self.openDuplex(rpc: rpc, transport: transport)
        let write = Task {
            try await opened.session.write(Data("blocked".utf8))
        }
        try await Self.waitForWrites(4, on: transport)
        let remoteError = BareRPCError(
            message: "request rejected while write was pending",
            code: "DUPLEX_REJECTED",
            errno: 4_201
        )

        await transport.feed(BareRPCCodec.__testEncodeStreamFrame(
            id: opened.id,
            flags: [.response, .error],
            payload: .error(remoteError)
        ))

        do {
            try await Self.waitForClose(on: transport)
        } catch {
            await transport.close()
            _ = try? await write.value
            throw error
        }
        do {
            try await write.value
            XCTFail("the interrupted write must not report ambiguous success")
        } catch is CancellationError {
            // The write itself is canceled as part of generation teardown.
        } catch {
            XCTFail("unexpected interrupted-write error: \(error)")
        }

        var responses = opened.session.chunks.makeAsyncIterator()
        do {
            _ = try await responses.next()
            XCTFail("the response stream must preserve the authoritative peer error")
        } catch let error as BareRPCError {
            XCTAssertEqual(error, remoteError)
        } catch {
            XCTFail("unexpected response-stream error: \(error)")
        }
        let isOpen = await rpc.isOpen()
        XCTAssertFalse(isOpen)
        let snapshot = await transport.snapshot()
        XCTAssertEqual(snapshot.writes, 4)
        XCTAssertEqual(snapshot.closes, 1)
        withExtendedLifetime(opened.session) {}
        await rpc.close()
    }

    func test_malformed_inbound_frame_fails_pending_request_and_closes_generation() async throws {
        var oversizedLength = UInt32(65).littleEndian
        let oversizedPrefix = withUnsafeBytes(of: &oversizedLength) { Data($0) }
        let cases: [(frame: Data, expected: BareRPCCodecError)] = [
            (oversizedPrefix, .frameTooLarge(declared: 65, max: 64)),
            // Compact-encoding represents 99 in two bytes. The length prefix must
            // include both bytes so this reaches the unknown-message-type check.
            (Data([2, 0, 0, 0, 0x63, 0x01]), .unknownType(99)),
        ]

        for testCase in cases {
            let transport = ScriptedWriteTransport()
            let rpc = try BareRPCClient(
                transport: transport,
                maximumWireMessageBytes: 64,
                maximumBufferedStreamBytes: 64
            )
            let request = Task {
                try await rpc.send(command: 906, data: nil, timeout: .seconds(5))
            }
            try await Self.waitForWrites(1, on: transport)

            await transport.feed(testCase.frame)

            do {
                _ = try await request.value
                XCTFail("a malformed peer frame must fail the pending operation")
            } catch let error as BareRPCCodecError {
                XCTAssertEqual(error, testCase.expected)
            } catch {
                XCTFail("unexpected malformed-frame error: \(error)")
            }
            try await Self.waitForClose(on: transport)
            let isOpen = await rpc.isOpen()
            XCTAssertFalse(isOpen)
            let state = await rpc.__testInFlightCounts()
            XCTAssertEqual(state.sends, 0)
            await rpc.close()
        }
    }

    func test_bare_rpc_diagnostics_and_log_ordering_are_stable() {
        let timeout = BareRPCRequestTimeout(timeout: .milliseconds(250))
        XCTAssertTrue(timeout.description.hasPrefix("bare-rpc request timed out after "))
        XCTAssertLessThan(BareRPCLogLevel.debug, .info)
        XCTAssertLessThan(BareRPCLogLevel.info, .warn)
        XCTAssertLessThan(BareRPCLogLevel.warn, .error)
        XCTAssertFalse(BareRPCLogLevel.error < .debug)
    }

    // MARK: - Buffered stream concurrency and lease ownership

    func test_buffered_stream_iterator_copies_reject_concurrent_next_without_poisoning_owner() async throws {
        let (stream, sink) = QVACClient.makeBufferedStream(
            of: Int.self,
            name: "iterator-exclusivity-contract",
            maximumBufferedBytes: 128
        )
        let iterator = stream.makeAsyncIterator()
        let owner = BufferedIteratorBox(iterator)
        let copied = BufferedIteratorBox(iterator)
        let ownerRead = Task { try await owner.next() }
        try await Self.waitForPendingRead(on: sink)

        do {
            _ = try await copied.next()
            XCTFail("copied iterators must not reenter their shared cursor")
        } catch let QVACError.protocolViolation(message) {
            XCTAssertEqual(
                message,
                "QVACBufferedStream iterator does not support concurrent next() calls"
            )
        } catch {
            sink.finish(throwing: error)
            _ = try? await ownerRead.value
            return XCTFail("unexpected copied-iterator error: \(error)")
        }

        guard case .enqueued = sink.yield(contentsOf: [42], estimatedBytes: 8) else {
            sink.finish()
            _ = try? await ownerRead.value
            return XCTFail("the waiting owner must accept an in-budget batch")
        }
        sink.finish()
        let ownerValue = try await ownerRead.value
        let terminalValue = try await copied.next()
        XCTAssertEqual(ownerValue, 42)
        XCTAssertNil(terminalValue)
    }

    func test_buffered_channel_rejects_concurrent_read_without_disturbing_registered_owner() async throws {
        let channel = QVACBufferedStreamChannel<Int>(
            streamName: "active-read-exclusivity-contract",
            maximumBufferedBatches: 4,
            maximumBufferedBytes: 128
        )
        let ownerRead = Task { try await channel.next() }
        try await Self.waitForPendingRead(on: channel)

        do {
            _ = try await channel.next()
            XCTFail("a second active batch read must fail")
        } catch let QVACError.protocolViolation(message) {
            XCTAssertEqual(
                message,
                "QVACBufferedStream supports only one active next() call"
            )
        } catch {
            channel.finish(throwing: error)
            _ = try? await ownerRead.value
            return XCTFail("unexpected concurrent-read error: \(error)")
        }

        guard case .enqueued = channel.yield([7], estimatedBytes: 8) else {
            channel.finish(throwing: nil)
            _ = try? await ownerRead.value
            return XCTFail("the registered owner must accept an in-budget batch")
        }
        let ownerLease = try await ownerRead.value
        let lease = try XCTUnwrap(ownerLease)
        XCTAssertEqual(lease.values, [7])
        channel.acknowledge(leaseID: lease.id)
        channel.finish(throwing: nil)
        let terminalLease = try await channel.next()
        XCTAssertNil(terminalLease)
    }

    func test_buffered_channel_requires_lease_acknowledgement_before_next_batch() async throws {
        let channel = QVACBufferedStreamChannel<Int>(
            streamName: "lease-acknowledgement-contract",
            maximumBufferedBatches: 4,
            maximumBufferedBytes: 128
        )
        guard case .enqueued = channel.yield([1, 2], estimatedBytes: 16) else {
            return XCTFail("the initial in-budget batch must be accepted")
        }
        let nextLease = try await channel.next()
        let lease = try XCTUnwrap(nextLease)
        XCTAssertEqual(lease.values, [1, 2])

        do {
            _ = try await channel.next()
            XCTFail("the current lease must be acknowledged before another batch")
        } catch let QVACError.protocolViolation(message) {
            XCTAssertEqual(
                message,
                "QVACBufferedStream cannot request another batch before acknowledging the current batch"
            )
        } catch {
            XCTFail("unexpected unacknowledged-lease error: \(error)")
        }

        channel.acknowledge(leaseID: lease.id &+ 1)
        XCTAssertEqual(channel.retainedBytesForTesting(), 16)
        channel.acknowledge(leaseID: lease.id)
        XCTAssertEqual(channel.retainedBytesForTesting(), 0)
        channel.finish(throwing: nil)
        let terminalLease = try await channel.next()
        XCTAssertNil(terminalLease)
    }

    func test_cancelling_pending_buffered_channel_read_terminates_producer() async throws {
        let channel = QVACBufferedStreamChannel<Int>(
            streamName: "consumer-cancellation-contract",
            maximumBufferedBatches: 4,
            maximumBufferedBytes: 128
        )
        let read = Task { try await channel.next() }
        try await Self.waitForPendingRead(on: channel)

        read.cancel()

        do {
            _ = try await read.value
            XCTFail("a canceled pending read must throw CancellationError")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("unexpected pending-read cancellation error: \(error)")
        }
        guard case .terminated = channel.yield([1], estimatedBytes: 8) else {
            return XCTFail("producer writes after consumer cancellation must be rejected")
        }
        XCTAssertEqual(channel.retainedBytesForTesting(), 0)
    }

    #if canImport(Darwin)
    // MARK: - macOS Unix-domain socket lifecycle

    func test_uds_spawn_errors_retain_actionable_diagnostic_context() {
        let errors: [(UnixDomainSocketTransport.SpawnError, String)] = [
            (.bareNotFound(URL(fileURLWithPath: "/missing/bare")),
             "Bare executable not found at /missing/bare"),
            (.workerNotFound(URL(fileURLWithPath: "/missing/worker.js")),
             "Worker script not found at /missing/worker.js"),
            (.invalidConfiguration(reason: "invalid limit"),
             "Invalid transport configuration: invalid limit"),
            (.socketPathOccupied(path: "/tmp/occupied.sock", reason: "already exists"),
             "Socket path is unavailable at /tmp/occupied.sock: already exists"),
            (.socketBindFailed(errno: EACCES, path: "/tmp/denied.sock"),
             "bind() failed errno=13 on /tmp/denied.sock"),
            (.socketListenFailed(errno: EMFILE), "listen() failed errno=24"),
            (.socketConfigurationFailed(errno: EBADF),
             "socket configuration failed errno=9"),
            (.workerCouldNotStart(reason: "permission denied"),
             "Worker failed to start: permission denied"),
            (.acceptTimeout(seconds: 1.25), "Worker did not connect within 1.25s"),
            (.acceptFailed(errno: EINTR), "accept() failed errno=4"),
            (.writeFailed(errno: EPIPE), "write() failed errno=32"),
            (.readFailed(errno: ECONNRESET), "read() failed errno=54"),
        ]

        for (error, expected) in errors {
            XCTAssertEqual(error.description, expected)
        }
    }

    func test_uds_rejects_nonpositive_inbound_budget_before_filesystem_or_process_io() async {
        for limit in [0, -1] {
            let configuration = UDSTransportConfiguration(
                bareExecutable: URL(fileURLWithPath: "/missing/bare"),
                workerScript: URL(fileURLWithPath: "/missing/worker"),
                workingDirectory: URL(fileURLWithPath: "/tmp")
            )
            do {
                _ = try await UnixDomainSocketTransport.connect(
                    configuration,
                    maximumInboundBufferedBytes: limit
                )
                XCTFail("a nonpositive inbound byte budget must be rejected")
            } catch let error as UnixDomainSocketTransport.SpawnError {
                guard case .invalidConfiguration(let reason) = error else {
                    return XCTFail("expected invalidConfiguration, got \(error)")
                }
                XCTAssertEqual(reason, "maximumInboundBufferedBytes must be greater than zero")
            } catch {
                XCTFail("unexpected inbound-budget error: \(error)")
            }
        }
    }

    func test_uds_listener_rejects_path_that_cannot_fit_sockaddr() {
        // Longer than sockaddr_un.sun_path but below the filesystem's per-component
        // name limit, so validation reaches the socket-address boundary itself.
        let overlongPath = "/tmp/" + String(repeating: "x", count: 128)
        do {
            _ = try UnixDomainSocketTransport.__testMakeListener(at: overlongPath)
            XCTFail("an overlong Unix-domain socket path must be rejected")
        } catch let error as UnixDomainSocketTransport.SpawnError {
            guard case .socketBindFailed(let code, let path) = error else {
                return XCTFail("expected socketBindFailed, got \(error)")
            }
            XCTAssertEqual(code, ENAMETOOLONG)
            XCTAssertEqual(path, overlongPath)
        } catch {
            XCTFail("unexpected overlong-path error: \(error)")
        }
    }

    func test_uds_listener_reports_bind_failure_for_nonexistent_parent_directory() {
        let missingParent = "/tmp/qvac-missing-\(UUID().uuidString.prefix(8))"
        let socketPath = missingParent + "/worker.sock"
        guard !FileManager.default.fileExists(atPath: missingParent) else {
            return XCTFail("test precondition collision at \(missingParent)")
        }

        do {
            _ = try UnixDomainSocketTransport.__testMakeListener(at: socketPath)
            XCTFail("a socket cannot be bound beneath a nonexistent directory")
        } catch let error as UnixDomainSocketTransport.SpawnError {
            guard case .socketBindFailed(let code, let path) = error else {
                return XCTFail("expected socketBindFailed, got \(error)")
            }
            XCTAssertEqual(code, ENOENT)
            XCTAssertEqual(path, socketPath)
        } catch {
            XCTFail("unexpected missing-parent bind error: \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
    }

    func test_uds_worker_launch_failure_cleans_exact_override_socket() async throws {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("qvac-launch-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let nonExecutable = root.appendingPathComponent("not-executable")
        try Data("not an executable".utf8).write(to: nonExecutable)
        let socket = root.appendingPathComponent("worker.sock")
        let configuration = UDSTransportConfiguration(
            bareExecutable: nonExecutable,
            workerScript: URL(fileURLWithPath: "/dev/null"),
            workingDirectory: root,
            socketPathOverride: socket.path,
            initTimeout: 1
        )

        do {
            _ = try await UnixDomainSocketTransport.connect(configuration)
            XCTFail("a non-executable runtime must fail to launch")
        } catch let error as UnixDomainSocketTransport.SpawnError {
            guard case .workerCouldNotStart(let reason) = error else {
                return XCTFail("expected workerCouldNotStart, got \(error)")
            }
            XCTAssertTrue(reason.contains(nonExecutable.path), reason)
            XCTAssertTrue(reason.contains("worker=/dev/null"), reason)
        } catch {
            XCTFail("unexpected worker launch error: \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    func test_uds_connected_transport_factory_cleans_listener_when_socket_configuration_fails() {
        let before = Set(
            (try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? []
        ).filter { $0.hasPrefix("qvac-worker-") }

        do {
            _ = try UnixDomainSocketTransport.__testConnectedTransport(clientFD: -1)
            XCTFail("an invalid connected descriptor must be rejected")
        } catch let error as UnixDomainSocketTransport.SpawnError {
            guard case .socketConfigurationFailed(let code) = error else {
                return XCTFail("expected socketConfigurationFailed, got \(error)")
            }
            XCTAssertEqual(code, EBADF)
        } catch {
            XCTFail("unexpected connected-socket configuration error: \(error)")
        }

        let after = Set(
            (try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? []
        ).filter { $0.hasPrefix("qvac-worker-") }
        XCTAssertEqual(after, before, "failed socket configuration must not leak its listener")
    }

    func test_uds_startup_failure_captures_and_sanitizes_worker_stdout() async throws {
        let script = URL(fileURLWithPath: "/tmp/qvac-output-\(UUID().uuidString.prefix(8)).sh")
        try Data("printf 'worker-stdout-\\001-marker\\n'\nexec /bin/sleep 30\n".utf8)
            .write(to: script, options: .atomic)
        defer { try? FileManager.default.removeItem(at: script) }
        let configuration = UDSTransportConfiguration(
            bareExecutable: URL(fileURLWithPath: "/bin/sh"),
            workerScript: script,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            initTimeout: 0.15
        )

        do {
            _ = try await UnixDomainSocketTransport.connect(configuration)
            XCTFail("a worker that never connects must time out")
        } catch let error as UnixDomainSocketTransport.SpawnError {
            guard case .workerCouldNotStart(let reason) = error else {
                return XCTFail("expected workerCouldNotStart, got \(error)")
            }
            XCTAssertTrue(reason.contains("stdout-tail=worker-stdout-�-marker"), reason)
        } catch {
            XCTFail("unexpected startup diagnostic error: \(error)")
        }
    }

    func test_uds_startup_diagnostics_retain_independent_bounded_stdout_and_stderr_tails() async throws {
        let script = URL(
            fileURLWithPath: "/tmp/qvac-output-tails-\(UUID().uuidString.prefix(8)).sh"
        )
        try Data("""
        printf 'discarded-stdout-prefix\\n'
        /usr/bin/yes O | /usr/bin/head -c 40000
        printf '\\nretained-stdout-tail\\n'
        printf 'discarded-stderr-prefix\\n' >&2
        /usr/bin/yes E | /usr/bin/head -c 40000 >&2
        printf '\\nretained-stderr-tail\\n' >&2
        exec /bin/sleep 30
        """.utf8).write(to: script, options: .atomic)
        defer { try? FileManager.default.removeItem(at: script) }
        let configuration = UDSTransportConfiguration(
            bareExecutable: URL(fileURLWithPath: "/bin/sh"),
            workerScript: script,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            initTimeout: 0.3
        )

        let started = ContinuousClock.now
        do {
            _ = try await UnixDomainSocketTransport.connect(configuration)
            XCTFail("a worker that never connects must time out")
        } catch let error as UnixDomainSocketTransport.SpawnError {
            guard case .workerCouldNotStart(let reason) = error else {
                return XCTFail("expected workerCouldNotStart, got \(error)")
            }
            XCTAssertTrue(reason.contains("stdout-tail="), reason)
            XCTAssertTrue(reason.contains("stderr-tail="), reason)
            XCTAssertTrue(reason.contains("retained-stdout-tail"), reason)
            XCTAssertTrue(reason.contains("retained-stderr-tail"), reason)
            XCTAssertFalse(reason.contains("discarded-stdout-prefix"), reason)
            XCTAssertFalse(reason.contains("discarded-stderr-prefix"), reason)
            XCTAssertLessThan(
                reason.utf8.count,
                70_000,
                "two 32-KiB stream tails plus diagnostic context must remain bounded"
            )
        } catch {
            XCTFail("unexpected startup diagnostic error: \(error)")
        }
        XCTAssertLessThan(
            started.duration(to: .now),
            .seconds(2),
            "bounded output capture must not delay failed-worker cleanup"
        )
    }

    func test_uds_connects_to_local_peer_and_reaps_it_during_close() async throws {
        let suffix = UUID().uuidString.prefix(8)
        let socketPath = "/tmp/qvac-nc-\(suffix).sock"
        let script = URL(fileURLWithPath: "/tmp/qvac-nc-\(suffix).sh")
        try Data("exec /usr/bin/nc -U '\(socketPath)'\n".utf8)
            .write(to: script, options: .atomic)
        defer {
            try? FileManager.default.removeItem(at: script)
            _ = unlink(socketPath)
        }
        let configuration = UDSTransportConfiguration(
            bareExecutable: URL(fileURLWithPath: "/bin/sh"),
            workerScript: script,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            socketPathOverride: socketPath,
            initTimeout: 2
        )

        let transport = try await UnixDomainSocketTransport.connect(configuration)
        XCTAssertEqual(transport.socketPath, socketPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
        let running = try XCTUnwrap(transport.__testWorkerExitInfo())
        XCTAssertTrue(running.isRunning)
        XCTAssertGreaterThan(running.pid, 0)

        await transport.close()

        XCTAssertTrue(transport.__testReaderFinished())
        XCTAssertEqual(transport.__testWorkerPID(), running.pid)
        XCTAssertNil(transport.__testWorkerExitInfo())
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
        errno = 0
        XCTAssertEqual(Darwin.kill(running.pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func test_uds_connected_transport_round_trips_bytes_and_rejects_writes_after_close() async throws {
        let sockets = try Self.makeSocketPair()
        let transport: UnixDomainSocketTransport
        do {
            transport = try UnixDomainSocketTransport.__testConnectedTransport(
                clientFD: sockets[0]
            )
        } catch {
            _ = Darwin.close(sockets[0])
            _ = Darwin.close(sockets[1])
            throw error
        }
        defer { _ = Darwin.close(sockets[1]) }
        var inbound = transport.inboundStream().makeAsyncIterator()

        try await transport.write(Data())
        let outboundPayload = Data("host-to-peer".utf8)
        try await transport.write(outboundPayload)
        var readBuffer = [UInt8](repeating: 0, count: 64)
        let outboundCount = readBuffer.withUnsafeMutableBytes { bytes in
            Darwin.read(sockets[1], bytes.baseAddress, bytes.count)
        }
        guard outboundCount >= 0 else {
            await transport.close()
            return XCTFail("peer read failed with errno \(errno)")
        }
        XCTAssertEqual(outboundCount, outboundPayload.count)
        XCTAssertEqual(Data(readBuffer.prefix(outboundCount)), outboundPayload)

        let inboundPayload = Data("peer-to-host".utf8)
        let inboundCount = inboundPayload.withUnsafeBytes { bytes in
            Darwin.write(sockets[1], bytes.baseAddress, bytes.count)
        }
        guard inboundCount == inboundPayload.count else {
            await transport.close()
            return XCTFail(
                "peer write produced \(inboundCount) of \(inboundPayload.count) bytes, errno=\(errno)"
            )
        }
        let received = try await inbound.next()
        XCTAssertEqual(received, inboundPayload)

        guard Darwin.shutdown(sockets[1], SHUT_WR) == 0 else {
            await transport.close()
            return XCTFail("peer shutdown failed with errno \(errno)")
        }
        let end = try await inbound.next()
        XCTAssertNil(end)
        await transport.close()
        XCTAssertTrue(transport.__testReaderFinished())

        do {
            try await transport.write(Data("late".utf8))
            XCTFail("writes after close must fail")
        } catch let error as UnixDomainSocketTransport.SpawnError {
            guard case .writeFailed(let code) = error else {
                return XCTFail("expected writeFailed, got \(error)")
            }
            XCTAssertEqual(code, EBADF)
        } catch {
            XCTFail("unexpected post-close write error: \(error)")
        }
    }

    func test_uds_peer_closure_surfaces_write_failure_without_sigpipe() async throws {
        let sockets = try Self.makeSocketPair()
        let transport: UnixDomainSocketTransport
        do {
            transport = try UnixDomainSocketTransport.__testConnectedTransport(
                clientFD: sockets[0]
            )
        } catch {
            _ = Darwin.close(sockets[0])
            _ = Darwin.close(sockets[1])
            throw error
        }
        _ = transport.inboundStream()
        guard Darwin.close(sockets[1]) == 0 else {
            await transport.close()
            return XCTFail("peer close failed with errno \(errno)")
        }

        do {
            try await transport.write(Data("cannot-deliver".utf8))
            XCTFail("a write to a closed peer must fail")
        } catch let error as UnixDomainSocketTransport.SpawnError {
            guard case .writeFailed(let code) = error else {
                await transport.close()
                return XCTFail("expected writeFailed, got \(error)")
            }
            XCTAssertTrue(
                [EPIPE, ECONNRESET, ENOTCONN].contains(code),
                "unexpected closed-peer errno \(code)"
            )
        } catch {
            XCTFail("unexpected closed-peer write error: \(error)")
        }

        await transport.close()
        XCTAssertTrue(transport.__testReaderFinished())
    }
    #endif
}
