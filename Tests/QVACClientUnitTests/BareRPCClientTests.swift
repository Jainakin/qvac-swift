// BareRPCClient tests — exercise the full request/response/stream/duplex mux against
// a programmable in-memory transport. No network, no subprocess.

import XCTest
@testable import QVACClient

final class BareRPCClientTests: XCTestCase {

    // MARK: - In-memory transport

    private final class InboundPipe: @unchecked Sendable {
        let stream: AsyncThrowingStream<Data, Error>
        let continuation: AsyncThrowingStream<Data, Error>.Continuation

        init() {
            var captured: AsyncThrowingStream<Data, Error>.Continuation!
            stream = AsyncThrowingStream { captured = $0 }
            continuation = captured
        }
    }

    /// Programmable transport: caller injects inbound frames via `feedInbound`; outbound
    /// writes accumulate and can be inspected via `outbound()`.
    /// Actor-based so it's Sendable + Swift-6 clean without manual locking.
    actor MockTransport: BareTransport {
        nonisolated private let inbound = InboundPipe()
        private var _outboundBytes = Data()
        private var closed = false
        private var closeCount = 0
        private var _onWrite: (@Sendable (Data) -> Void)?

        nonisolated func inboundStream() -> AsyncThrowingStream<Data, Error> {
            inbound.stream
        }

        func write(_ data: Data) async throws {
            _outboundBytes.append(data)
            _onWrite?(data)
        }
        func close() {
            if closed { return }
            closed = true
            closeCount += 1
            inbound.continuation.finish()
        }
        func feedInbound(_ data: Data) { inbound.continuation.yield(data) }
        func feedError(_ e: Error) {
            inbound.continuation.finish(throwing: e)
        }
        func setOnWrite(_ handler: @escaping @Sendable (Data) -> Void) {
            _onWrite = handler
        }
        func outbound() -> Data { _outboundBytes }
        func closes() -> Int { closeCount }
    }

    /// A transport whose writes suspend until close and deliberately ignore task
    /// cancellation. It models a full OS send buffer / non-cooperative adapter.
    actor GatedWriteTransport: BareTransport {
        nonisolated private let inbound = InboundPipe()
        private var writeWaiters: [CheckedContinuation<Void, Error>] = []
        private var writeCount = 0
        private var closeCount = 0

        nonisolated func inboundStream() -> AsyncThrowingStream<Data, Error> { inbound.stream }

        func write(_ data: Data) async throws {
            writeCount += 1
            try await withCheckedThrowingContinuation { continuation in
                writeWaiters.append(continuation)
            }
        }

        func close() {
            closeCount += 1
            let waiters = writeWaiters
            writeWaiters.removeAll()
            for waiter in waiters { waiter.resume(returning: ()) }
            inbound.continuation.finish()
        }

        func counts() -> (writes: Int, closes: Int) { (writeCount, closeCount) }
    }

    actor SuspendedCloseTransport: BareTransport {
        nonisolated private let inbound = InboundPipe()
        private var closeCalls = 0
        private var closeWaiter: CheckedContinuation<Void, Never>?

        nonisolated func inboundStream() -> AsyncThrowingStream<Data, Error> { inbound.stream }
        func write(_ data: Data) async throws {}
        func close() async {
            closeCalls += 1
            await withCheckedContinuation { continuation in closeWaiter = continuation }
            inbound.continuation.finish()
        }
        func calls() -> Int { closeCalls }
        func releaseClose() {
            closeWaiter?.resume()
            closeWaiter = nil
        }
    }

    actor FailingWriteTransport: BareTransport {
        struct Failure: Error, Sendable {}

        nonisolated private let inbound = InboundPipe()
        private var closeCount = 0
        private var closed = false

        nonisolated func inboundStream() -> AsyncThrowingStream<Data, Error> {
            inbound.stream
        }

        func write(_ data: Data) async throws {
            throw Failure()
        }

        func close() {
            guard !closed else { return }
            closed = true
            closeCount += 1
            inbound.continuation.finish()
        }

        func closes() -> Int { closeCount }
    }

    actor CompletionFlag {
        private var value = false
        func set() { value = true }
        func get() -> Bool { value }
    }

    actor StartGate {
        private var waiter: CheckedContinuation<Void, Never>?
        func wait() async { await withCheckedContinuation { waiter = $0 } }
        func isWaiting() -> Bool { waiter != nil }
        func release() { waiter?.resume(); waiter = nil }
    }

    /// Captures the first REQUEST id from outbound bytes (across multiple writes).
    /// Used by mock-handlers that need to echo back the right id.
    private static func firstRequestId(in data: Data) -> UInt64? {
        let reader = BareRPCFrameReader()
        try? reader.append(data)
        while let f = reader.next() {
            if case .request(let id, _, _, _) = f { return id }
        }
        return nil
    }

    private static func frames(in data: Data) -> [BareRPCFrame] {
        let reader = BareRPCFrameReader()
        try? reader.append(data)
        var result: [BareRPCFrame] = []
        while let frame = reader.next() { result.append(frame) }
        return result
    }

    private static func waitForFrames(
        _ count: Int,
        on transport: MockTransport,
        timeout: Duration = .seconds(1)
    ) async throws -> [BareRPCFrame] {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            let decoded = frames(in: await transport.outbound())
            if decoded.count >= count { return decoded }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("timed out waiting for \(count) outbound frames")
        return frames(in: await transport.outbound())
    }

    private static func waitForNoInFlight(
        _ rpc: BareRPCClient,
        timeout: Duration = .seconds(1)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            let counts = await rpc.__testInFlightCounts()
            if counts == (0, 0, 0) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        let counts = await rpc.__testInFlightCounts()
        XCTFail("in-flight RPC state leaked: \(counts)")
    }

    /// Keep iterator lifetime out of the caller's scope so this proves that an
    /// ordinary early `break` tears down the live RPC while the sequence remains retained.
    private static func consumeOneAndBreak<Element: Sendable>(
        _ stream: QVACResponseStream<Element>
    ) async throws {
        for try await _ in stream {
            break
        }
    }

    private static func waitForGatedCounts(
        _ expected: (writes: Int, closes: Int),
        on transport: GatedWriteTransport,
        timeout: Duration = .seconds(1)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            let counts = await transport.counts()
            if counts.writes >= expected.writes, counts.closes >= expected.closes { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("timed out waiting for gated transport counts \(expected); got \(await transport.counts())")
    }

    // MARK: - send (single-shot RPC)

    func test_transport_inbound_channel_overflow_is_explicit_and_discards_queued_bytes() async {
        let channel = BoundedTransportInboundChannel(maximumBufferedBytes: 4)
        let stream = channel.stream()
        XCTAssertNil(channel.yield(Data(repeating: 1, count: 3)))
        let overflow = channel.yield(Data(repeating: 2, count: 2))
        XCTAssertEqual(overflow?.maximumBufferedBytes, 4)
        XCTAssertEqual(overflow?.attemptedBufferedBytes, 5)

        var iterator = stream.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            XCTFail("expected explicit inbound overflow")
        } catch let error as BareTransportInboundBufferOverflow {
            XCTAssertEqual(error, overflow)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_transport_inbound_channel_splits_large_adapter_reads_into_bounded_chunks() async throws {
        let chunk = BoundedTransportInboundChannel.maximumDeliveryChunkBytes
        let channel = BoundedTransportInboundChannel(
            maximumBufferedBytes: chunk * 3
        )
        let stream = channel.stream()
        XCTAssertNil(channel.yield(Data(repeating: 0xa5, count: chunk * 2 + 7)))
        channel.finish()

        var sizes: [Int] = []
        for try await value in stream { sizes.append(value.count) }
        XCTAssertEqual(sizes, [chunk, chunk, 7])
    }

    func test_invalid_low_level_size_limits_throw_instead_of_trapping() {
        XCTAssertThrowsError(try BareRPCClient(
            transport: MockTransport(),
            maximumWireMessageBytes: 0
        ))
        XCTAssertThrowsError(try BareRPCClient(
            transport: MockTransport(),
            maximumWireMessageBytes: 1024,
            maximumBufferedStreamBytes: 0
        ))
    }

    func test_oversized_typed_request_fails_locally_without_transport_write() async {
        let mock = MockTransport()
        let client = QVACClient(testing: mock, maximumWireMessageBytes: 8)
        do {
            let _: QVACResponse = try await client.sendTyped(.heartbeat(HeartbeatRequest()))
            XCTFail("expected outbound wire-limit failure")
        } catch let error as QVACError {
            guard case .invalidArgument = error else {
                return XCTFail("expected invalidArgument, got \(error)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        let outbound = await mock.outbound()
        XCTAssertTrue(outbound.isEmpty)
        await client.close()
    }

    func test_oversized_public_duplex_chunk_fails_locally_without_poisoning_write_queue() async throws {
        struct Response: Decodable, Sendable { let value: Int }

        let mock = MockTransport()
        let rpc = try BareRPCClient(
            transport: mock,
            maximumWireMessageBytes: 64,
            maximumBufferedStreamBytes: 64
        )
        let raw = try await rpc.duplex(command: 9, initialPayload: Data("{}".utf8))
        _ = try await Self.waitForFrames(3, on: mock)
        let session = QVACDuplexSession<Response>(raw: raw, operation: "duplex-size-test")

        do {
            try await session.write(Data(repeating: 0xab, count: 65))
            XCTFail("expected outbound duplex chunk limit failure")
        } catch let error as QVACError {
            guard case .invalidArgument = error else {
                return XCTFail("expected invalidArgument, got \(error)")
            }
        }
        try await session.write(Data([0x01]))
        _ = try await Self.waitForFrames(4, on: mock)
        let outbound = await mock.outbound()
        XCTAssertEqual(Self.frames(in: outbound).count, 4)
        session.destroy()
        await rpc.close()
    }

    func test_send_roundtrips_payload() async throws {
        let mock = MockTransport()
        let rpc = BareRPCClient(transport: mock)

        let respPayload = Data(#"{"type":"heartbeat","number":42}"#.utf8)
        await mock.setOnWrite { _ in
            Task {
                let out = await mock.outbound()
                guard let id = Self.firstRequestId(in: out) else { return }
                let resp = BareRPCCodec.__testEncodeResponseFrame(
                    id: id, stream: [], payload: .success(respPayload)
                )
                await mock.feedInbound(resp)
            }
        }

        let reply = try await rpc.send(command: 1, data: Data(#"{"type":"heartbeat"}"#.utf8))
        XCTAssertEqual(reply, respPayload)
        await rpc.close()
    }

    func test_send_propagates_typed_error() async throws {
        let mock = MockTransport()
        let rpc = BareRPCClient(transport: mock)
        let serverError = BareRPCError(message: "boom", code: "E_BOOM", errno: -1)

        await mock.setOnWrite { _ in
            Task {
                let out = await mock.outbound()
                guard let id = Self.firstRequestId(in: out) else { return }
                let resp = BareRPCCodec.__testEncodeResponseFrame(
                    id: id, stream: [], payload: .failure(serverError)
                )
                await mock.feedInbound(resp)
            }
        }

        do {
            _ = try await rpc.send(command: 1, data: Data("x".utf8))
            XCTFail("expected throw")
        } catch let e as BareRPCError {
            XCTAssertEqual(e, serverError)
        }
        await rpc.close()
    }

    func test_send_timeout_removes_state_and_ignores_late_response() async throws {
        let mock = MockTransport()
        let rpc = BareRPCClient(transport: mock)
        let task = Task {
            try await rpc.send(
                command: 7,
                data: Data("request".utf8),
                timeout: .milliseconds(50)
            )
        }

        let outbound = try await Self.waitForFrames(1, on: mock)
        guard case .request(let id, _, _, _) = outbound[0] else {
            return XCTFail("expected request frame")
        }
        do {
            _ = try await task.value
            XCTFail("expected timeout")
        } catch let error as BareRPCRequestTimeout {
            XCTAssertEqual(error.timeout, .milliseconds(50))
        }
        try await Self.waitForNoInFlight(rpc)

        let late = BareRPCCodec.__testEncodeResponseFrame(
            id: id,
            stream: [],
            payload: .success(Data("late".utf8))
        )
        await mock.feedInbound(late)
        try await Task.sleep(for: .milliseconds(20))
        try await Self.waitForNoInFlight(rpc)
        await rpc.close()
    }

    func test_send_caller_cancellation_is_exactly_once_and_late_frame_safe() async throws {
        let mock = MockTransport()
        let rpc = BareRPCClient(transport: mock)
        let task = Task { try await rpc.send(command: 8, data: Data("request".utf8)) }
        let outbound = try await Self.waitForFrames(1, on: mock)
        guard case .request(let id, _, _, _) = outbound[0] else {
            return XCTFail("expected request frame")
        }

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // expected
        }
        try await Self.waitForNoInFlight(rpc)

        await mock.feedInbound(BareRPCCodec.__testEncodeResponseFrame(
            id: id,
            stream: [],
            payload: .success(Data("late".utf8))
        ))
        try await Task.sleep(for: .milliseconds(20))
        try await Self.waitForNoInFlight(rpc)
        await rpc.close()
    }

    func test_send_timeout_aborts_connection_when_transport_write_ignores_cancellation() async throws {
        let transport = GatedWriteTransport()
        let rpc = BareRPCClient(transport: transport)
        let task = Task {
            try await rpc.send(
                command: 80,
                data: Data("blocked".utf8),
                timeout: .milliseconds(50)
            )
        }
        try await Self.waitForGatedCounts((writes: 1, closes: 0), on: transport)

        do {
            _ = try await task.value
            XCTFail("expected timeout")
        } catch let error as BareRPCRequestTimeout {
            XCTAssertEqual(error.timeout, .milliseconds(50))
        }
        try await Self.waitForGatedCounts((writes: 1, closes: 1), on: transport)
        try await Self.waitForNoInFlight(rpc)
        await rpc.close()
        let finalCounts = await transport.counts()
        XCTAssertEqual(finalCounts.closes, 1)
    }

    func test_stream_setup_cancellation_aborts_noncooperative_blocked_write() async throws {
        let transport = GatedWriteTransport()
        let rpc = BareRPCClient(transport: transport)
        let task = Task {
            try await rpc.stream(command: 81, data: Data("blocked".utf8))
        }
        try await Self.waitForGatedCounts((writes: 1, closes: 0), on: transport)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // expected
        }
        try await Self.waitForGatedCounts((writes: 1, closes: 1), on: transport)
        try await Self.waitForNoInFlight(rpc)
        await rpc.close()
    }

    func test_precancelled_send_stream_and_duplex_never_register_or_write() async throws {
        let mock = MockTransport()
        let rpc = BareRPCClient(transport: mock)

        let sendGate = StartGate()
        let send = Task {
            await sendGate.wait()
            return try await rpc.send(command: 82, data: Data("x".utf8))
        }
        while !(await sendGate.isWaiting()) { await Task.yield() }
        send.cancel()
        await sendGate.release()
        do { _ = try await send.value; XCTFail("expected send cancellation") }
        catch is CancellationError {}

        let streamGate = StartGate()
        let stream = Task {
            await streamGate.wait()
            return try await rpc.stream(command: 83, data: Data("x".utf8))
        }
        while !(await streamGate.isWaiting()) { await Task.yield() }
        stream.cancel()
        await streamGate.release()
        do { _ = try await stream.value; XCTFail("expected stream cancellation") }
        catch is CancellationError {}

        let duplexGate = StartGate()
        let duplex = Task {
            await duplexGate.wait()
            return try await rpc.duplex(command: 84, initialPayload: Data("x".utf8))
        }
        while !(await duplexGate.isWaiting()) { await Task.yield() }
        duplex.cancel()
        await duplexGate.release()
        do { _ = try await duplex.value; XCTFail("expected duplex cancellation") }
        catch is CancellationError {}

        try await Self.waitForNoInFlight(rpc)
        let outbound = await mock.outbound()
        XCTAssertTrue(outbound.isEmpty)
        await rpc.close()
    }

    func test_close_fails_pending_send_before_transport_teardown() async throws {
        let mock = MockTransport()
        let rpc = BareRPCClient(transport: mock)
        let task = Task { try await rpc.send(command: 9, data: Data("request".utf8)) }
        _ = try await Self.waitForFrames(1, on: mock)

        await rpc.close()
        do {
            _ = try await task.value
            XCTFail("expected connection-closed error")
        } catch is BareRPCConnectionClosed {
            // expected
        }
        try await Self.waitForNoInFlight(rpc)
    }

    func test_init_handshake_timeout_is_bounded() async throws {
        let mock = MockTransport()
        let rpc = BareRPCClient(transport: mock)
        let clock = ContinuousClock()
        let start = clock.now
        do {
            try await QVACHandshake.sendInitConfig(
                on: rpc,
                runtimeContext: nil,
                timeout: .milliseconds(50)
            )
            XCTFail("expected timeout")
        } catch let error as BareRPCRequestTimeout {
            XCTAssertEqual(error.timeout, .milliseconds(50))
        }
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(1))
        try await Self.waitForNoInFlight(rpc)
        await rpc.close()
    }

    func test_public_initializer_maps_malformed_handshake_reply_to_qvac_encoding_error() async throws {
        let mock = MockTransport()
        let initialization = Task {
            try await QVACClient(
                configuration: .testing(mock),
                runtimeContext: nil,
                initHandshakeTimeout: .seconds(1),
                logger: nil
            )
        }
        let frames = try await Self.waitForFrames(1, on: mock)
        guard case .request(let id, _, _, _) = frames[0] else {
            initialization.cancel()
            return XCTFail("expected init request")
        }
        await mock.feedInbound(BareRPCCodec.__testEncodeResponseFrame(
            id: id,
            stream: [],
            payload: .success(Data("{".utf8))
        ))

        do {
            let client = try await initialization.value
            await client.close()
            XCTFail("expected malformed init reply to fail")
        } catch let error as QVACError {
            guard case .encoding = error else {
                return XCTFail("expected QVACError.encoding, got \(error)")
            }
        } catch {
            XCTFail("public initializer leaked non-QVAC error: \(error)")
        }
        let closeCount = await mock.closes()
        XCTAssertEqual(closeCount, 1)
    }

    func test_public_initializer_maps_handshake_write_failure_to_qvac_transport_error() async {
        let transport = FailingWriteTransport()
        do {
            let client = try await QVACClient(
                configuration: .testing(transport),
                runtimeContext: nil,
                initHandshakeTimeout: .seconds(1),
                logger: nil
            )
            await client.close()
            XCTFail("expected handshake write failure")
        } catch let error as QVACError {
            guard case .transport(let reason, let underlying) = error else {
                return XCTFail("expected QVACError.transport, got \(error)")
            }
            XCTAssertTrue(reason.contains("__init_config"))
            XCTAssertTrue(underlying is FailingWriteTransport.Failure)
        } catch {
            XCTFail("public initializer leaked non-QVAC error: \(error)")
        }
        let closeCount = await transport.closes()
        XCTAssertEqual(closeCount, 1)
    }

    func test_public_initializer_preserves_structured_cancellation() async throws {
        let mock = MockTransport()
        let initialization = Task {
            try await QVACClient(
                configuration: .testing(mock),
                runtimeContext: nil,
                initHandshakeTimeout: .seconds(1),
                logger: nil
            )
        }
        _ = try await Self.waitForFrames(1, on: mock)
        initialization.cancel()

        do {
            let client = try await initialization.value
            await client.close()
            XCTFail("expected initialization cancellation")
        } catch is CancellationError {
            // Expected: cancellation is the one non-QVAC public failure.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        let closeCount = await mock.closes()
        XCTAssertEqual(closeCount, 1)
    }

    // MARK: - stream (server-pushed)

    func test_stream_yields_data_chunks_until_end() async throws {
        let mock = MockTransport()
        let rpc = BareRPCClient(transport: mock)

        let chunk1 = Data(#"{"type":"chunk","value":1}"#.utf8)
        let chunk2 = Data(#"{"type":"chunk","value":2}"#.utf8)

        // The client sends 2 outbound frames on stream(): REQUEST + STREAM(RESPONSE|OPEN).
        // We respond after seeing the second frame.
        let writeCount = OSAllocatedAtomic(initial: 0)
        await mock.setOnWrite { _ in
            let n = writeCount.increment()
            guard n == 2 else { return }
            Task {
                let out = await mock.outbound()
                guard let id = Self.firstRequestId(in: out) else { return }
                let r1 = BareRPCCodec.__testEncodeResponseFrame(id: id, stream: [.open], payload: .success(nil))
                let d1 = BareRPCCodec.__testEncodeStreamFrame(id: id, flags: [.response, .data], payload: .data(chunk1))
                let d2 = BareRPCCodec.__testEncodeStreamFrame(id: id, flags: [.response, .data], payload: .data(chunk2))
                let end = BareRPCCodec.__testEncodeStreamFrame(id: id, flags: [.response, .end])
                await mock.feedInbound(r1)
                await mock.feedInbound(d1)
                await mock.feedInbound(d2)
                await mock.feedInbound(end)
            }
        }

        let stream = try await rpc.stream(command: 2, data: Data("{}".utf8))
        var got: [Data] = []
        for try await c in stream.chunks { got.append(c) }
        XCTAssertEqual(got, [chunk1, chunk2])
        await rpc.close()
    }

    func test_stream_error_frame_throws_into_iterator() async throws {
        let mock = MockTransport()
        let rpc = BareRPCClient(transport: mock)

        let serverErr = BareRPCError(message: "stream broke", code: "E_STREAM", errno: -2)
        let writeCount = OSAllocatedAtomic(initial: 0)
        await mock.setOnWrite { _ in
            let n = writeCount.increment()
            guard n == 2 else { return }
            Task {
                let out = await mock.outbound()
                guard let id = Self.firstRequestId(in: out) else { return }
                let r1 = BareRPCCodec.__testEncodeResponseFrame(id: id, stream: [.open], payload: .success(nil))
                let err = BareRPCCodec.__testEncodeStreamFrame(id: id, flags: [.response, .error], payload: .error(serverErr))
                await mock.feedInbound(r1)
                await mock.feedInbound(err)
            }
        }

        let stream = try await rpc.stream(command: 2, data: Data("{}".utf8))
        do {
            for try await _ in stream.chunks {}
            XCTFail("expected error")
        } catch let e as BareRPCError {
            XCTAssertEqual(e, serverErr)
        }
        await rpc.close()
    }

    func test_stream_idle_timeout_sends_one_response_destroy_and_ignores_late_frames() async throws {
        let mock = MockTransport()
        let rpc = BareRPCClient(transport: mock)
        let stream = try await rpc.stream(
            command: 10,
            data: Data("{}".utf8),
            timeout: .milliseconds(50)
        )
        let initial = try await Self.waitForFrames(2, on: mock)
        guard case .request(let id, _, _, _) = initial[0] else {
            return XCTFail("expected request frame")
        }

        do {
            for try await _ in stream.chunks {}
            XCTFail("expected idle timeout")
        } catch let error as BareRPCRequestTimeout {
            XCTAssertEqual(error.timeout, .milliseconds(50))
        }

        let frames = try await Self.waitForFrames(3, on: mock)
        let destroys = frames.filter {
            guard case .stream(let frameId, let flags, _) = $0 else { return false }
            return frameId == id && flags == [.response, .destroy]
        }
        XCTAssertEqual(destroys.count, 1)
        try await Self.waitForNoInFlight(rpc)

        await mock.feedInbound(BareRPCCodec.__testEncodeStreamFrame(
            id: id,
            flags: [.response, .data],
            payload: .data(Data("late".utf8))
        ))
        await mock.feedInbound(BareRPCCodec.__testEncodeStreamFrame(
            id: id,
            flags: [.response, .end]
        ))
        try await Task.sleep(for: .milliseconds(20))
        let outboundAfterLateFrames = await mock.outbound()
        XCTAssertEqual(Self.frames(in: outboundAfterLateFrames).count, 3)
        try await Self.waitForNoInFlight(rpc)
        await rpc.close()
    }

    func test_stream_activity_refreshes_idle_timeout() async throws {
        let mock = MockTransport()
        let rpc = BareRPCClient(transport: mock)
        let stream = try await rpc.stream(
            command: 11,
            data: Data("{}".utf8),
            timeout: .milliseconds(250)
        )
        let frames = try await Self.waitForFrames(2, on: mock)
        guard case .request(let id, _, _, _) = frames[0] else {
            return XCTFail("expected request frame")
        }
        let payload = Data("chunk".utf8)
        await mock.feedInbound(BareRPCCodec.__testEncodeResponseFrame(
            id: id,
            stream: [.open],
            payload: .success(nil)
        ))
        try await Task.sleep(for: .milliseconds(140))
        await mock.feedInbound(BareRPCCodec.__testEncodeStreamFrame(
            id: id,
            flags: [.response, .data],
            payload: .data(payload)
        ))
        try await Task.sleep(for: .milliseconds(140))
        await mock.feedInbound(BareRPCCodec.__testEncodeStreamFrame(
            id: id,
            flags: [.response, .end]
        ))

        var received: [Data] = []
        for try await chunk in stream.chunks { received.append(chunk) }
        XCTAssertEqual(received, [payload])
        try await Self.waitForNoInFlight(rpc)
        await rpc.close()
    }

    func test_stream_destroy_is_idempotent_and_tears_down_once() async throws {
        let mock = MockTransport()
        let rpc = BareRPCClient(transport: mock)
        let stream = try await rpc.stream(command: 12, data: Data("{}".utf8))
        _ = try await Self.waitForFrames(2, on: mock)

        stream.destroy()
        stream.destroy()
        let frames = try await Self.waitForFrames(3, on: mock)
        let destroys = frames.filter {
            guard case .stream(_, let flags, _) = $0 else { return false }
            return flags == [.response, .destroy]
        }
        XCTAssertEqual(destroys.count, 1)
        try await Task.sleep(for: .milliseconds(20))
        let outboundAfterSecondDestroy = await mock.outbound()
        XCTAssertEqual(Self.frames(in: outboundAfterSecondDestroy).count, 3)
        try await Self.waitForNoInFlight(rpc)
        await rpc.close()
    }

    func test_stream_destroy_discards_already_buffered_chunks() async throws {
        let mock = MockTransport()
        let rpc = BareRPCClient(transport: mock)
        let raw = try await rpc.stream(command: 9, data: Data("request".utf8))
        let frames = try await Self.waitForFrames(2, on: mock)
        guard case .request(let id, _, _, _) = frames[0] else {
            return XCTFail("expected request")
        }
        await mock.feedInbound(BareRPCCodec.__testEncodeStreamFrame(
            id: id,
            flags: [.response, .data],
            payload: .data(Data("stale".utf8))
        ))
        try await Task.sleep(for: .milliseconds(10))
        raw.destroy()
        try await Self.waitForNoInFlight(rpc)

        var iterator = raw.chunks.makeAsyncIterator()
        let valueAfterDestroy = try await iterator.next()
        XCTAssertNil(valueAfterDestroy, "destroy must not expose stale queued data")
        await rpc.close()
    }

    func test_slow_raw_stream_consumer_gets_explicit_byte_budget_overflow() async throws {
        let mock = MockTransport()
        let rpc = try BareRPCClient(
            transport: mock,
            maximumWireMessageBytes: 1_024,
            maximumBufferedStreamBytes: 8
        )
        let stream = try await rpc.stream(command: 85, data: Data("{}".utf8))
        let frames = try await Self.waitForFrames(2, on: mock)
        guard case .request(let id, _, _, _) = frames[0] else {
            return XCTFail("expected request")
        }

        var inbound = BareRPCCodec.__testEncodeStreamFrame(
            id: id,
            flags: [.response, .data],
            payload: .data(Data("123456".utf8))
        )
        inbound.append(BareRPCCodec.__testEncodeStreamFrame(
            id: id,
            flags: [.response, .data],
            payload: .data(Data("abcdef".utf8))
        ))
        await mock.feedInbound(inbound)
        try await Self.waitForNoInFlight(rpc)

        var received: [Data] = []
        do {
            for try await chunk in stream.chunks { received.append(chunk) }
            XCTFail("expected stream buffer overflow")
        } catch let error as BareRPCStreamBufferOverflow {
            XCTAssertEqual(error.maximumBufferedBytes, 8)
            XCTAssertEqual(error.attemptedBufferedBytes, 12)
        }
        XCTAssertEqual(received, [], "overflow is terminal and discards stale queued chunks")
        let outbound = try await Self.waitForFrames(3, on: mock)
        guard case .stream(_, let flags, _) = outbound[2] else {
            return XCTFail("expected destroy frame")
        }
        XCTAssertEqual(flags, [.response, .destroy])
        await rpc.close()
    }

    // MARK: - duplex

    func test_duplex_emits_three_step_handshake() async throws {
        let mock = MockTransport()
        let rpc = BareRPCClient(transport: mock)
        let initialPayload = Data("hello".utf8)
        let session = try await rpc.duplex(command: 5, initialPayload: initialPayload)

        // Inspect outbound bytes. Should contain 3 handshake frames.
        let out = await mock.outbound()
        let reader = BareRPCFrameReader()
        try reader.append(out)
        guard case .request(let id1, _, let f1, _) = reader.next() else { return XCTFail("frame 1") }
        XCTAssertTrue(f1.contains(.open))
        guard case .stream(let id2, let f2, _) = reader.next() else { return XCTFail("frame 2") }
        XCTAssertEqual(id2, id1)
        XCTAssertEqual(f2, [.response, .open])
        guard case .stream(let id3, let f3, .data(let payload)) = reader.next() else { return XCTFail("frame 3") }
        XCTAssertEqual(id3, id1)
        XCTAssertEqual(f3, [.request, .data])
        XCTAssertEqual(payload, initialPayload)
        session.destroy()
        await rpc.close()
    }

    func test_duplex_write_emits_data_frames() async throws {
        let mock = MockTransport()
        let rpc = BareRPCClient(transport: mock)
        let session = try await rpc.duplex(command: 5, initialPayload: Data("init".utf8))
        let chunk = Data("audio-chunk".utf8)
        try await session.write(chunk)
        try await session.end()

        // After the 3 handshake frames, there should be the chunk + an end frame.
        let out = await mock.outbound()
        let reader = BareRPCFrameReader()
        try reader.append(out)
        _ = reader.next(); _ = reader.next(); _ = reader.next() // skip handshake
        guard case .stream(_, let f4, .data(let d)) = reader.next() else { return XCTFail("expected data") }
        XCTAssertEqual(f4, [.request, .data])
        XCTAssertEqual(d, chunk)
        guard case .stream(_, let f5, .control) = reader.next() else { return XCTFail("expected end") }
        XCTAssertEqual(f5, [.request, .end])
        await rpc.close()
    }

    func test_duplex_open_timeout_sends_both_half_stream_teardowns_once() async throws {
        let mock = MockTransport()
        let rpc = BareRPCClient(transport: mock)
        let task = Task {
            try await rpc.duplex(
                command: 13,
                initialPayload: Data("metadata".utf8),
                timeout: .milliseconds(50)
            )
        }
        let initial = try await Self.waitForFrames(3, on: mock)
        guard case .request(let id, _, _, _) = initial[0] else {
            return XCTFail("expected request frame")
        }
        do {
            _ = try await task.value
            XCTFail("expected timeout")
        } catch let error as BareRPCRequestTimeout {
            XCTAssertEqual(error.timeout, .milliseconds(50))
        }

        let frames = try await Self.waitForFrames(5, on: mock)
        guard case .stream(let closeId, let closeFlags, _) = frames[3],
              case .stream(let destroyId, let destroyFlags, _) = frames[4] else {
            return XCTFail("expected duplex teardown frames")
        }
        XCTAssertEqual(closeId, id)
        XCTAssertEqual(closeFlags, [.request, .close])
        XCTAssertEqual(destroyId, id)
        XCTAssertEqual(destroyFlags, [.response, .destroy])
        try await Self.waitForNoInFlight(rpc)

        await mock.feedInbound(BareRPCCodec.__testEncodeStreamFrame(id: id, flags: [.request, .open]))
        await mock.feedInbound(BareRPCCodec.__testEncodeResponseFrame(
            id: id,
            stream: [.open],
            payload: .success(nil)
        ))
        try await Task.sleep(for: .milliseconds(20))
        let outboundAfterLateOpen = await mock.outbound()
        XCTAssertEqual(Self.frames(in: outboundAfterLateOpen).count, 5)
        try await Self.waitForNoInFlight(rpc)
        await rpc.close()
    }

    func test_duplex_caller_cancellation_during_open_tears_down_once() async throws {
        let mock = MockTransport()
        let rpc = BareRPCClient(transport: mock)
        let task = Task {
            try await rpc.duplex(
                command: 14,
                initialPayload: Data("metadata".utf8),
                timeout: .seconds(5)
            )
        }
        _ = try await Self.waitForFrames(3, on: mock)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // expected
        }

        let frames = try await Self.waitForFrames(5, on: mock)
        let teardowns = frames.compactMap { frame -> BareRPCStreamFlags? in
            guard case .stream(_, let flags, _) = frame,
                  flags.contains(.close) || flags.contains(.destroy) else { return nil }
            return flags
        }
        XCTAssertEqual(teardowns, [[.request, .close], [.response, .destroy]])
        try await Self.waitForNoInFlight(rpc)
        await rpc.close()
    }

    func test_duplex_decoder_skips_profile_trailer_record() async throws {
        struct Value: Decodable, Sendable, Equatable { let value: Int }

        let mock = MockTransport()
        let rpc = BareRPCClient(transport: mock)
        let raw = try await rpc.duplex(command: 15, initialPayload: Data("metadata".utf8))
        let frames = try await Self.waitForFrames(3, on: mock)
        guard case .request(let id, _, _, _) = frames[0] else {
            return XCTFail("expected request frame")
        }
        let session = QVACDuplexSession<Value>(raw: raw, operation: "testDuplex")

        var ndjson = Data(#"{"value":1}"#.utf8)
        ndjson.append(0x0A)
        ndjson.append(Data(#"{"__profilingTrailer":true,"__profiling":{"elapsedMs":1}}"#.utf8))
        ndjson.append(0x0A)
        var inbound = BareRPCCodec.__testEncodeStreamFrame(
            id: id,
            flags: [.response, .data],
            payload: .data(ndjson)
        )
        inbound.append(BareRPCCodec.__testEncodeStreamFrame(id: id, flags: [.response, .end]))
        await mock.feedInbound(inbound)

        var values: [Value] = []
        for try await value in session.responses { values.append(value) }
        XCTAssertEqual(values, [Value(value: 1)])
        try await Self.waitForNoInFlight(rpc)
        await rpc.close()
    }

    func test_retained_duplex_response_stream_early_break_tears_down_both_directions() async throws {
        struct Value: Decodable, Sendable { let value: Int }

        let mock = MockTransport()
        let rpc = BareRPCClient(transport: mock)
        let raw = try await rpc.duplex(command: 151, initialPayload: Data("metadata".utf8))
        let initialFrames = try await Self.waitForFrames(3, on: mock)
        guard case .request(let id, _, _, _) = initialFrames[0] else {
            return XCTFail("expected request frame")
        }
        let session = QVACDuplexSession<Value>(raw: raw, operation: "testDuplex")
        let retainedResponses = session.responses

        await mock.feedInbound(BareRPCCodec.__testEncodeStreamFrame(
            id: id,
            flags: [.response, .data],
            payload: .data(Data("{\"value\":1}\n".utf8))
        ))
        try await Self.consumeOneAndBreak(retainedResponses)

        let frames = try await Self.waitForFrames(5, on: mock)
        let teardowns = frames.compactMap { frame -> BareRPCStreamFlags? in
            guard case .stream(let frameID, let flags, _) = frame,
                  frameID == id,
                  flags.contains(.close) || flags.contains(.destroy) else { return nil }
            return flags
        }
        XCTAssertEqual(teardowns, [[.request, .close], [.response, .destroy]])
        try await Self.waitForNoInFlight(rpc)
        withExtendedLifetime(retainedResponses) {}
        await rpc.close()
    }

    func test_public_duplex_second_responses_access_fails_without_trapping() async throws {
        struct Value: Decodable, Sendable { let value: Int }

        let mock = MockTransport()
        let rpc = BareRPCClient(transport: mock)
        let raw = try await rpc.duplex(command: 16, initialPayload: Data("metadata".utf8))
        let session = QVACDuplexSession<Value>(raw: raw, operation: "testDuplex")
        let first = session.responses
        _ = first
        var duplicate = session.responses.makeAsyncIterator()
        do {
            _ = try await duplicate.next()
            XCTFail("expected single-consumer failure")
        } catch let error as QVACError {
            guard case .protocolViolation = error else {
                return XCTFail("expected protocolViolation, got \(error)")
            }
        }
        session.destroy()
        await rpc.close()
    }

    func test_generic_typed_stream_skips_profile_trailer_record() async throws {
        let mock = MockTransport()
        let client = QVACClient(testing: mock)
        let stream = try await client.loggingStream(id: "logs")
        let frames = try await Self.waitForFrames(2, on: mock)
        guard case .request(let id, _, _, _) = frames[0] else {
            return XCTFail("expected request frame")
        }

        var ndjson = Data(
            #"{"type":"loggingStream","id":"logs","level":"info","message":"ready","namespace":"test","timestamp":1}"#.utf8
        )
        ndjson.append(0x0A)
        ndjson.append(Data(#"{"__profilingTrailer":true,"__profiling":{"id":"p"}}"#.utf8))
        ndjson.append(0x0A)
        var inbound = BareRPCCodec.__testEncodeStreamFrame(
            id: id,
            flags: [.response, .data],
            payload: .data(ndjson)
        )
        inbound.append(BareRPCCodec.__testEncodeStreamFrame(id: id, flags: [.response, .end]))
        await mock.feedInbound(inbound)

        var events: [LoggingStreamResponse] = []
        for try await event in stream { events.append(event) }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.message, "ready")
        await client.close()
    }

    func test_retained_public_stream_early_break_sends_destroy_and_releases_in_flight_state() async throws {
        let mock = MockTransport()
        let client = QVACClient(testing: mock)
        let retainedStream = try await client.loggingStream(id: "early-break")
        let frames = try await Self.waitForFrames(2, on: mock)
        guard case .request(let id, _, _, _) = frames[0] else {
            return XCTFail("expected loggingStream request")
        }

        var record = Data(
            #"{"type":"loggingStream","id":"early-break","level":"info","message":"one","namespace":"test","timestamp":1}"#.utf8
        )
        record.append(0x0A)
        await mock.feedInbound(BareRPCCodec.__testEncodeStreamFrame(
            id: id,
            flags: [.response, .data],
            payload: .data(record)
        ))

        try await Self.consumeOneAndBreak(retainedStream)
        let teardown = try await Self.waitForFrames(3, on: mock)
        guard case .stream(let destroyID, let flags, _) = teardown[2] else {
            return XCTFail("expected response destroy after early break")
        }
        XCTAssertEqual(destroyID, id)
        XCTAssertEqual(flags, [.response, .destroy])
        try await Self.waitForNoInFlight(client.rpc)
        withExtendedLifetime(retainedStream) {}
        await client.close()
    }

    func test_dropping_public_stream_iterator_without_reading_releases_in_flight_state() async throws {
        let mock = MockTransport()
        let client = QVACClient(testing: mock)
        let retainedStream = try await client.loggingStream(id: "drop-iterator")
        let frames = try await Self.waitForFrames(2, on: mock)
        guard case .request(let id, _, _, _) = frames[0] else {
            return XCTFail("expected loggingStream request")
        }

        var iterator: QVACResponseStream<LoggingStreamResponse>.AsyncIterator? =
            retainedStream.makeAsyncIterator()
        XCTAssertNotNil(iterator)
        iterator = nil

        let teardown = try await Self.waitForFrames(3, on: mock)
        guard case .stream(let destroyID, let flags, _) = teardown[2] else {
            return XCTFail("expected response destroy after iterator deinit")
        }
        XCTAssertEqual(destroyID, id)
        XCTAssertEqual(flags, [.response, .destroy])
        try await Self.waitForNoInFlight(client.rpc)
        withExtendedLifetime(retainedStream) {}
        await client.close()
    }

    func test_public_stream_normal_completion_releases_state_without_destroy_frame() async throws {
        let mock = MockTransport()
        let client = QVACClient(testing: mock)
        let retainedStream = try await client.loggingStream(id: "normal-end")
        let frames = try await Self.waitForFrames(2, on: mock)
        guard case .request(let id, _, _, _) = frames[0] else {
            return XCTFail("expected loggingStream request")
        }

        var record = Data(
            #"{"type":"loggingStream","id":"normal-end","level":"info","message":"one","namespace":"test","timestamp":1}"#.utf8
        )
        record.append(0x0A)
        var inbound = BareRPCCodec.__testEncodeStreamFrame(
            id: id,
            flags: [.response, .data],
            payload: .data(record)
        )
        inbound.append(BareRPCCodec.__testEncodeStreamFrame(
            id: id,
            flags: [.response, .end]
        ))
        await mock.feedInbound(inbound)

        var received: [LoggingStreamResponse] = []
        for try await event in retainedStream { received.append(event) }
        XCTAssertEqual(received.map(\.message), ["one"])
        try await Self.waitForNoInFlight(client.rpc)
        try await Task.sleep(for: .milliseconds(20))
        let outbound = await mock.outbound()
        XCTAssertEqual(Self.frames(in: outbound).count, 2)
        withExtendedLifetime(retainedStream) {}
        await client.close()
    }

    func test_public_stream_task_cancellation_sends_destroy_and_releases_in_flight_state() async throws {
        let mock = MockTransport()
        let client = QVACClient(testing: mock)
        let retainedStream = try await client.loggingStream(id: "task-cancel")
        let frames = try await Self.waitForFrames(2, on: mock)
        guard case .request(let id, _, _, _) = frames[0] else {
            return XCTFail("expected loggingStream request")
        }

        let read = Task {
            var iterator = retainedStream.makeAsyncIterator()
            return try await iterator.next()
        }
        try await Task.sleep(for: .milliseconds(20))
        read.cancel()
        do {
            _ = try await read.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // expected
        }

        let teardown = try await Self.waitForFrames(3, on: mock)
        guard case .stream(let destroyID, let flags, _) = teardown[2] else {
            return XCTFail("expected response destroy after task cancellation")
        }
        XCTAssertEqual(destroyID, id)
        XCTAssertEqual(flags, [.response, .destroy])
        try await Self.waitForNoInFlight(client.rpc)
        withExtendedLifetime(retainedStream) {}
        await client.close()
    }

    func test_typed_stream_decodes_coalesced_records_only_as_consumer_demands_them() async throws {
        DemandProbeResponse.decodeCount.set(0)
        let mock = MockTransport()
        let client = QVACClient(testing: mock)
        let stream: QVACResponseStream<DemandProbeResponse> = try await client.streamTyped(
            .heartbeat(HeartbeatRequest())
        )
        let frames = try await Self.waitForFrames(2, on: mock)
        guard case .request(let id, _, _, _) = frames[0] else {
            return XCTFail("expected request frame")
        }

        let records = Data("{\"value\":1}\n{\"value\":2}\n{\"value\":3}\n".utf8)
        var inbound = BareRPCCodec.__testEncodeStreamFrame(
            id: id,
            flags: [.response, .data],
            payload: .data(records)
        )
        inbound.append(BareRPCCodec.__testEncodeStreamFrame(
            id: id,
            flags: [.response, .end]
        ))
        await mock.feedInbound(inbound)

        var iterator = stream.makeAsyncIterator()
        let first = try await iterator.next()
        XCTAssertEqual(first?.value, 1)
        XCTAssertEqual(
            DemandProbeResponse.decodeCount.get(),
            1,
            "coalesced records must not all be decoded into an eager pending array"
        )
        let second = try await iterator.next()
        let third = try await iterator.next()
        XCTAssertEqual(second?.value, 2)
        XCTAssertEqual(third?.value, 3)
        let terminal = try await iterator.next()
        XCTAssertNil(terminal)
        XCTAssertEqual(DemandProbeResponse.decodeCount.get(), 3)
        await client.close()
    }

    func test_public_typed_stream_concurrent_next_surfaces_only_qvac_error() async throws {
        let mock = MockTransport()
        let client = QVACClient(testing: mock)
        let stream = try await client.loggingStream(id: "single-consumer")
        _ = try await Self.waitForFrames(2, on: mock)
        var firstIterator = stream.makeAsyncIterator()
        var secondIterator = stream.makeAsyncIterator()
        let firstRead = Task { try await firstIterator.next() }
        try await Task.sleep(for: .milliseconds(10))

        do {
            _ = try await secondIterator.next()
            XCTFail("expected concurrent-next failure")
        } catch let error as QVACError {
            guard case .protocolViolation = error else {
                return XCTFail("expected protocolViolation, got \(error)")
            }
        }
        firstRead.cancel()
        _ = try? await firstRead.value
        await client.close()
    }

    func test_fragmented_ndjson_record_limit_maps_to_public_encoding_error() async throws {
        let mock = MockTransport()
        let client = QVACClient(testing: mock, maximumWireMessageBytes: 1_024)
        let stream = try await client.loggingStream(id: "oversize-record")
        let frames = try await Self.waitForFrames(2, on: mock)
        guard case .request(let id, _, _, _) = frames[0] else {
            return XCTFail("expected request")
        }

        var inbound = BareRPCCodec.__testEncodeStreamFrame(
            id: id,
            flags: [.response, .data],
            payload: .data(Data(repeating: 0x61, count: 700))
        )
        inbound.append(BareRPCCodec.__testEncodeStreamFrame(
            id: id,
            flags: [.response, .data],
            payload: .data(Data(repeating: 0x61, count: 700))
        ))
        await mock.feedInbound(inbound)

        var iterator = stream.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            XCTFail("expected record limit error")
        } catch let error as QVACError {
            guard case .encoding = error else {
                return XCTFail("expected encoding, got \(error)")
            }
        }
        await client.close()
    }

    func test_upscale_base64_result_over_64_mib_decodes_by_default_and_lower_limit_fails_explicitly() async throws {
        func responseWire(id: UInt64, encodedByteCount: Int) -> Data {
            precondition(encodedByteCount.isMultiple(of: 4))
            let prefix = Data("{\"type\":\"upscaleStream\",\"data\":\"".utf8)
            let suffix = Data("\",\"done\":true,\"outputIndex\":0}\n".utf8)
            var record = Data(repeating: 0x41, count: prefix.count + encodedByteCount + suffix.count)
            record.replaceSubrange(0..<prefix.count, with: prefix)
            record.replaceSubrange((prefix.count + encodedByteCount)..<record.count, with: suffix)
            var framed = BareRPCCodec.__testEncodeStreamFrame(
                id: id,
                flags: [.response, .data],
                payload: .data(record)
            )
            framed.append(BareRPCCodec.__testEncodeStreamFrame(id: id, flags: [.response, .end]))
            return framed
        }

        do {
            let defaultTransport = MockTransport()
            let defaultClient = QVACClient(testing: defaultTransport)
            let run = try await defaultClient.upscale(
                modelId: "upscaler",
                image: Data([0x89, 0x50, 0x4e, 0x47])
            )
            let defaultFrames = try await Self.waitForFrames(2, on: defaultTransport)
            guard case .request(let requestID, _, _, _) = defaultFrames[0] else {
                return XCTFail("expected upscaleStream request")
            }

            let encodedByteCount = 64 * 1024 * 1024 + 4
            await defaultTransport.feedInbound(responseWire(
                id: requestID,
                encodedByteCount: encodedByteCount
            ))
            var outputs = try await run.outputs.value
            XCTAssertEqual(outputs.count, 1)
            XCTAssertEqual(outputs[0].count, encodedByteCount / 4 * 3)
            XCTAssertTrue(
                outputs[0].allSatisfy { $0 == 0 },
                "the >64 MiB base64 payload must decode byte-for-byte, not just to the expected length"
            )
            outputs.removeAll(keepingCapacity: false)
            await defaultClient.close()
        }

        // The failure half uses a much smaller fixture to avoid paying the >64 MiB
        // allocation twice while still traversing the same public rich wrapper.
        let lowerTransport = MockTransport()
        let lowerClient = QVACClient(
            testing: lowerTransport,
            maximumWireMessageBytes: 1024 * 1024
        )
        let lowerRun = try await lowerClient.upscale(
            modelId: "upscaler",
            image: Data([0x89, 0x50, 0x4e, 0x47])
        )
        let lowerFrames = try await Self.waitForFrames(2, on: lowerTransport)
        guard case .request(let lowerID, _, _, _) = lowerFrames[0] else {
            return XCTFail("expected lower-limit upscaleStream request")
        }
        let lowerWire = responseWire(id: lowerID, encodedByteCount: 2 * 1024 * 1024)
        await lowerTransport.feedInbound(lowerWire)
        do {
            _ = try await lowerRun.outputs.value
            XCTFail("expected configured wire ceiling failure")
        } catch let error as QVACError {
            guard case .protocolViolation = error else {
                return XCTFail("expected protocolViolation, got \(error)")
            }
        }
        await lowerClient.close()
    }

    func test_model_progress_parser_skips_profile_trailer_record() async throws {
        let mock = MockTransport()
        let client = QVACClient(testing: mock)
        let run = try await client.loadModelStreaming(
            modelSrc: "model-source",
            modelType: "llamacpp-completion"
        )
        let frames = try await Self.waitForFrames(2, on: mock)
        guard case .request(let id, _, _, _) = frames[0] else {
            return XCTFail("expected request frame")
        }
        let progressTask = Task {
            var values: [QVACClient.ModelLoadProgress] = []
            for try await value in run.progress { values.append(value) }
            return values
        }

        let lines = [
            #"{"type":"modelProgress","downloaded":5,"downloadKey":"key","percentage":50,"total":10}"#,
            #"{"__profilingTrailer":true,"__profiling":{"id":"p"}}"#,
            #"{"type":"loadModel","success":true,"modelId":"model-id"}"#,
        ]
        let ndjson = Data((lines.joined(separator: "\n") + "\n").utf8)
        var inbound = BareRPCCodec.__testEncodeStreamFrame(
            id: id,
            flags: [.response, .data],
            payload: .data(ndjson)
        )
        inbound.append(BareRPCCodec.__testEncodeStreamFrame(id: id, flags: [.response, .end]))
        await mock.feedInbound(inbound)

        let modelId = try await run.result.value
        XCTAssertEqual(modelId, "model-id")
        let progress = try await progressTask.value
        XCTAssertEqual(progress.count, 1)
        XCTAssertEqual(progress.first?.percentage, 50)
        await client.close()
    }

    func test_download_progress_parser_skips_profile_trailer_record() async throws {
        let mock = MockTransport()
        let client = QVACClient(testing: mock)
        let run = try await client.downloadAssetStreaming(assetSrc: "https://example.invalid/model")
        let frames = try await Self.waitForFrames(2, on: mock)
        guard case .request(let id, _, _, _) = frames[0] else {
            return XCTFail("expected request frame")
        }
        let progressTask = Task {
            var values: [QVACClient.ModelLoadProgress] = []
            for try await value in run.progress { values.append(value) }
            return values
        }

        let lines = [
            #"{"type":"modelProgress","downloaded":10,"downloadKey":"key","percentage":100,"total":10}"#,
            #"{"__profilingTrailer":true,"__profiling":{"id":"p"}}"#,
            #"{"type":"downloadAsset","success":true,"assetId":"asset-id"}"#,
        ]
        let ndjson = Data((lines.joined(separator: "\n") + "\n").utf8)
        var inbound = BareRPCCodec.__testEncodeStreamFrame(
            id: id,
            flags: [.response, .data],
            payload: .data(ndjson)
        )
        inbound.append(BareRPCCodec.__testEncodeStreamFrame(id: id, flags: [.response, .end]))
        await mock.feedInbound(inbound)

        let assetId = try await run.result.value
        XCTAssertEqual(assetId, "asset-id")
        let progress = try await progressTask.value
        XCTAssertEqual(progress.count, 1)
        XCTAssertEqual(progress.first?.percentage, 100)
        await client.close()
    }

    // MARK: - Connection failure

    func test_send_fails_when_transport_closes() async throws {
        let mock = MockTransport()
        let rpc = BareRPCClient(transport: mock)

        // Schedule transport failure shortly after the send goes out.
        await mock.setOnWrite { _ in
            Task {
                try? await Task.sleep(nanoseconds: 50_000_000)
                await mock.feedError(NSError(domain: "test", code: 99))
            }
        }

        do {
            _ = try await rpc.send(command: 1, data: Data("x".utf8))
            XCTFail("expected throw")
        } catch {
            // Either NSError from the transport or BareRPCConnectionClosed — both fine.
            XCTAssertTrue(error is BareRPCConnectionClosed || (error as NSError).code == 99,
                          "unexpected error: \(error)")
        }
        await rpc.close()
    }

    func test_inbound_eof_starts_and_joins_transport_teardown() async throws {
        let mock = MockTransport()
        let rpc = BareRPCClient(transport: mock)
        await mock.feedError(BareRPCConnectionClosed())

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while await mock.closes() == 0, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let closesAfterEOF = await mock.closes()
        XCTAssertEqual(closesAfterEOF, 1)
        await rpc.close()
        let closesAfterExplicitClose = await mock.closes()
        XCTAssertEqual(closesAfterExplicitClose, 1)
    }

    func test_close_is_idempotent() async {
        let mock = MockTransport()
        let rpc = BareRPCClient(transport: mock)
        await rpc.close()
        await rpc.close() // no crash
    }

    func test_concurrent_close_callers_join_one_transport_teardown() async throws {
        let transport = SuspendedCloseTransport()
        let rpc = BareRPCClient(transport: transport)
        let first = Task { await rpc.close() }
        while await transport.calls() == 0 { await Task.yield() }

        let secondFinished = CompletionFlag()
        let second = Task {
            await rpc.close()
            await secondFinished.set()
        }
        try await Task.sleep(for: .milliseconds(30))
        let finishedBeforeRelease = await secondFinished.get()
        let callsBeforeRelease = await transport.calls()
        XCTAssertFalse(finishedBeforeRelease, "second close returned before teardown completed")
        XCTAssertEqual(callsBeforeRelease, 1)

        await transport.releaseClose()
        await first.value
        await second.value
        let finishedAfterRelease = await secondFinished.get()
        let finalCallCount = await transport.calls()
        XCTAssertTrue(finishedAfterRelease)
        XCTAssertEqual(finalCallCount, 1)
    }

    func test_qvac_client_concurrent_close_sends_one_bounded_shutdown_and_joins_transport() async throws {
        let mock = MockTransport()
        await mock.setOnWrite { data in
            for frame in Self.frames(in: data) {
                guard case .request(let id, _, _, let payload) = frame,
                      let payload,
                      let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                      object["type"] as? String == "__shutdown__" else { continue }
                let reply = try! JSONSerialization.data(
                    withJSONObject: ["success": true],
                    options: [.sortedKeys]
                )
                Task {
                    await mock.feedInbound(BareRPCCodec.__testEncodeResponseFrame(
                        id: id,
                        stream: [],
                        payload: .success(reply)
                    ))
                }
            }
        }
        let client = QVACClient(
            testing: mock,
            shutdownBeforeClose: true,
            shutdownTimeout: .milliseconds(100)
        )

        async let firstClose: Void = client.close()
        async let secondClose: Void = client.close()
        _ = await (firstClose, secondClose)

        let outbound = await mock.outbound()
        let requests = Self.frames(in: outbound).compactMap { frame -> Data? in
            guard case .request(_, _, _, let payload) = frame else { return nil }
            return payload
        }
        let shutdownCount = requests.filter { payload in
            guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
            else { return false }
            return object["type"] as? String == "__shutdown__"
        }.count
        XCTAssertEqual(shutdownCount, 1)
        let closeCount = await mock.closes()
        XCTAssertEqual(closeCount, 1)
    }

    func test_qvac_client_shutdown_timeout_cannot_hang_close() async {
        let mock = MockTransport()
        let client = QVACClient(
            testing: mock,
            shutdownBeforeClose: true,
            shutdownTimeout: .milliseconds(50)
        )
        let clock = ContinuousClock()
        let started = clock.now
        await client.close()
        XCTAssertLessThan(started.duration(to: clock.now), .milliseconds(500))
        let closeCount = await mock.closes()
        XCTAssertEqual(closeCount, 1)
    }
}

// MARK: - Tiny thread-safe atomic counter for use in @Sendable closures

final class OSAllocatedAtomic: @unchecked Sendable {
    private var value: Int
    private let lock = NSLock()
    init(initial: Int) { self.value = initial }
    func increment() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    func get() -> Int { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: Int) { lock.lock(); defer { lock.unlock() }; value = newValue }
}

private struct DemandProbeResponse: Decodable, Sendable {
    static let decodeCount = OSAllocatedAtomic(initial: 0)
    let value: Int

    init(from decoder: Decoder) throws {
        _ = Self.decodeCount.increment()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = try container.decode(Int.self, forKey: .value)
    }

    private enum CodingKeys: String, CodingKey { case value }
}
