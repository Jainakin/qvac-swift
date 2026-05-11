// BareRPCClient tests — exercise the full request/response/stream/duplex mux against
// a programmable in-memory transport. No network, no subprocess.

import XCTest
@testable import QVACClient

final class BareRPCClientTests: XCTestCase {

    // MARK: - In-memory transport

    /// Programmable transport: caller injects inbound frames via `feedInbound`; outbound
    /// writes accumulate and can be inspected via `outbound()`.
    /// Actor-based so it's Sendable + Swift-6 clean without manual locking.
    actor MockTransport: BareTransport {
        private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
        private var _outboundBytes = Data()
        private var closed = false
        private var _onWrite: (@Sendable (Data) -> Void)?

        nonisolated func inboundStream() -> AsyncThrowingStream<Data, Error> {
            AsyncThrowingStream<Data, Error> { c in
                Task { await self.setContinuation(c) }
            }
        }
        private func setContinuation(_ c: AsyncThrowingStream<Data, Error>.Continuation) {
            continuation = c
        }

        func write(_ data: Data) async throws {
            _outboundBytes.append(data)
            _onWrite?(data)
        }
        func close() {
            if closed { return }
            closed = true
            continuation?.finish()
            continuation = nil
        }
        func feedInbound(_ data: Data) { continuation?.yield(data) }
        func feedError(_ e: Error) {
            continuation?.finish(throwing: e)
            continuation = nil
        }
        func setOnWrite(_ handler: @escaping @Sendable (Data) -> Void) {
            _onWrite = handler
        }
        func outbound() -> Data { _outboundBytes }
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

    // MARK: - send (single-shot RPC)

    func test_send_roundtrips_payload() async throws {
        let mock = MockTransport()
        let rpc = BareRPCClient(transport: mock)

        let respPayload = Data(#"{"type":"heartbeat","number":42}"#.utf8)
        await mock.setOnWrite { _ in
            Task {
                let out = await mock.outbound()
                guard let id = Self.firstRequestId(in: out) else { return }
                let resp = BareRPCCodec.encodeResponseFrame(
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
                let resp = BareRPCCodec.encodeResponseFrame(
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
                let r1 = BareRPCCodec.encodeResponseFrame(id: id, stream: [.open], payload: .success(nil))
                let d1 = BareRPCCodec.encodeStreamFrame(id: id, flags: [.response, .data], payload: .data(chunk1))
                let d2 = BareRPCCodec.encodeStreamFrame(id: id, flags: [.response, .data], payload: .data(chunk2))
                let end = BareRPCCodec.encodeStreamFrame(id: id, flags: [.response, .end])
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
                let r1 = BareRPCCodec.encodeResponseFrame(id: id, stream: [.open], payload: .success(nil))
                let err = BareRPCCodec.encodeStreamFrame(id: id, flags: [.response, .error], payload: .error(serverErr))
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
        await session.write(chunk)
        await session.end()

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

    func test_close_is_idempotent() async {
        let mock = MockTransport()
        let rpc = BareRPCClient(transport: mock)
        await rpc.close()
        await rpc.close() // no crash
    }
}

// MARK: - Tiny thread-safe atomic counter for use in @Sendable closures

final class OSAllocatedAtomic: @unchecked Sendable {
    private var value: Int
    private let lock = NSLock()
    init(initial: Int) { self.value = initial }
    func increment() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    func get() -> Int { lock.lock(); defer { lock.unlock() }; return value }
}
