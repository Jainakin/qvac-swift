// BareRPCClient — multiplexing RPC client built on a `BareTransport`.
//
// Mirrors the JS `bare-rpc` `RPC` class (https://github.com/holepunchto/bare-rpc/blob/main/index.js)
// from the CLIENT side: allocates per-request message ids, correlates RESPONSE / STREAM frames
// back to awaiting callers, and exposes three primitives — single-shot `send`, server-pushed
// `stream`, and bidirectional `duplex`. The full stream-lifecycle dance (OPEN ack, RESUME flow
// control, END / CLOSE / DESTROY teardown) is hidden from the caller.
//
// Threading model: this is an `actor` so all bookkeeping (the in-flight tables, the next-id
// counter) is serialized. Inbound bytes from the transport are fed in via `feed(_:)`.

import Foundation

// MARK: - Public errors

public struct BareRPCConnectionClosed: Error, Sendable, Equatable {
    public init() {}
}

public struct BareRPCProtocolError: Error, Sendable, Equatable {
    public let reason: String
    public init(_ reason: String) { self.reason = reason }
}

// MARK: - Streaming abstractions

/// Server-pushed response stream. Consume with `for await frame in stream.chunks`.
public final class BareRPCResponseStream: @unchecked Sendable {
    public let chunks: AsyncThrowingStream<Data, Error>
    private let onCancel: @Sendable () -> Void

    init(chunks: AsyncThrowingStream<Data, Error>, onCancel: @escaping @Sendable () -> Void) {
        self.chunks = chunks
        self.onCancel = onCancel
    }

    /// Signal the server we want no more frames (sends `STREAM | DESTROY | RESPONSE`).
    /// Idempotent.
    public func destroy() { onCancel() }
}

/// Bidirectional session for duplex APIs. Write outbound chunks via `write(_:)`,
/// consume server frames via `chunks`.
public final class BareRPCDuplexSession: @unchecked Sendable {
    public let chunks: AsyncThrowingStream<Data, Error>
    private let onWrite: @Sendable (Data) async -> Void
    private let onEnd: @Sendable () async -> Void
    private let onDestroy: @Sendable () -> Void

    init(
        chunks: AsyncThrowingStream<Data, Error>,
        onWrite: @escaping @Sendable (Data) async -> Void,
        onEnd: @escaping @Sendable () async -> Void,
        onDestroy: @escaping @Sendable () -> Void
    ) {
        self.chunks = chunks
        self.onWrite = onWrite
        self.onEnd = onEnd
        self.onDestroy = onDestroy
    }

    /// Push a chunk to the server. Emits `STREAM | DATA | REQUEST` on the wire.
    public func write(_ chunk: Data) async { await onWrite(chunk) }

    /// Signal end-of-stream on the client→server direction. Emits `STREAM | END | REQUEST`.
    public func end() async { await onEnd() }

    /// Force-terminate the whole session. Emits `STREAM | DESTROY | REQUEST` and tears
    /// down the response side.
    public func destroy() { onDestroy() }
}

// MARK: - The actor

public actor BareRPCClient {

    // ----------- Configuration & state -----------

    /// Per-request bookkeeping for `send`.
    private struct PendingSend {
        let continuation: CheckedContinuation<Data?, Error>
    }

    /// Per-request bookkeeping for `stream`.
    private final class PendingStream {
        let id: UInt64
        var continuation: AsyncThrowingStream<Data, Error>.Continuation
        /// Set once we've sent `STREAM | RESPONSE | OPEN`.
        var openSent = false
        /// Set once the server has sent `RESPONSE | OPEN` (or first DATA).
        var serverOpened = false
        /// True once we've yielded END/CLOSE/DESTROY (terminal).
        var finished = false
        init(id: UInt64, continuation: AsyncThrowingStream<Data, Error>.Continuation) {
            self.id = id; self.continuation = continuation
        }
    }

    /// Per-request bookkeeping for `duplex`.
    private final class PendingDuplex {
        let id: UInt64
        var continuation: AsyncThrowingStream<Data, Error>.Continuation
        /// `STREAM | REQUEST | OPEN` ack from server received.
        var requestOpened = false
        /// `RESPONSE | OPEN` from server received.
        var responseOpened = false
        var finished = false
        init(id: UInt64, continuation: AsyncThrowingStream<Data, Error>.Continuation) {
            self.id = id; self.continuation = continuation
        }
    }

    private let transport: BareTransport
    private let logger: BareRPCLogger?
    private var nextId: UInt64 = 1
    private var pendingSends: [UInt64: PendingSend] = [:]
    private var pendingStreams: [UInt64: PendingStream] = [:]
    private var pendingDuplex: [UInt64: PendingDuplex] = [:]
    private let reader = BareRPCFrameReader()
    private var closed = false
    private var feederTask: Task<Void, Never>?

    /// Construct the RPC client around a connected transport. The inbound stream is
    /// claimed SYNCHRONOUSLY here (so any subsequent `send` / `stream` call is guaranteed
    /// to have a destination for incoming bytes) and the feeder task that pumps the
    /// stream into the RPC state machine is spawned immediately. Caller MUST `await
    /// close()` to release resources.
    public init(transport: BareTransport, logger: BareRPCLogger? = nil) {
        self.transport = transport
        self.logger = logger
        // Claim the inbound stream NOW so the transport's reader thread has somewhere
        // to deliver bytes. Doing this lazily inside a Task creates a race: if the
        // caller fires a `send` immediately and the worker's response arrives before
        // the lazy Task scheduled the inboundStream() call, the response is dropped.
        let inbound = transport.inboundStream()
        feederTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await chunk in inbound {
                    try await self.feed(chunk)
                }
                await self.failAllInFlight(with: BareRPCConnectionClosed())
            } catch {
                await self.failAllInFlight(with: error)
            }
        }
    }

    deinit {
        feederTask?.cancel()
    }

    // ----------- Public surface -----------

    /// Single-shot RPC: send a REQUEST with `data` inline, await the RESPONSE's data.
    /// Throws on connection failure, server-side error frame, or transport timeout.
    public func send(command: UInt64, data: Data?) async throws -> Data? {
        try await ensureOpen()
        let id = allocateId()
        let frame = BareRPCCodec.encodeRequestFrame(id: id, command: command, stream: [], data: data)
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data?, Error>) in
            pendingSends[id] = PendingSend(continuation: c)
            Task { [transport] in
                do {
                    try await transport.write(frame)
                } catch {
                    Task { await self.resolveSend(id: id, with: .failure(error)) }
                }
            }
        }
    }

    /// Server-pushed streaming RPC: send a REQUEST + STREAM-OPEN-RESPONSE handshake, then
    /// yield each DATA frame's payload. Terminates on END/CLOSE/DESTROY or error.
    public func stream(command: UInt64, data: Data?) async throws -> BareRPCResponseStream {
        try await ensureOpen()
        let id = allocateId()
        // We need to start awaiting frames BEFORE the request goes out, because the server's
        // RESPONSE(OPEN) may race with our STREAM(RESPONSE|OPEN). Bookkeeping first.
        let (asyncStream, cont) = makeStream()
        let pending = PendingStream(id: id, continuation: cont)
        pendingStreams[id] = pending
        // Send REQUEST inline + STREAM(RESPONSE|OPEN) immediately (mirrors what JS
        // bare-rpc's req.createResponseStream({ eagerOpen: true }) does — see the wire
        // capture for Spike-B in docs/spike-validations.md).
        let req = BareRPCCodec.encodeRequestFrame(id: id, command: command, stream: [], data: data)
        let openAck = BareRPCCodec.encodeStreamFrame(id: id, flags: [.response, .open])
        do {
            try await transport.write(req)
            try await transport.write(openAck)
            pending.openSent = true
        } catch {
            pendingStreams.removeValue(forKey: id)
            cont.finish(throwing: error)
            throw error
        }
        let onCancel: @Sendable () -> Void = { [weak self, id] in
            Task { await self?.destroyStream(id: id) }
        }
        return BareRPCResponseStream(chunks: asyncStream, onCancel: onCancel)
    }

    /// Bidirectional session: emits the canonical 3-step duplex handshake
    /// (REQUEST(stream=OPEN, no data) + STREAM(RESPONSE|OPEN) + STREAM(REQUEST|DATA, payload))
    /// then exposes a session that callers can write to and iterate.
    public func duplex(command: UInt64, initialPayload: Data) async throws -> BareRPCDuplexSession {
        try await ensureOpen()
        let id = allocateId()
        let (asyncStream, cont) = makeStream()
        let pending = PendingDuplex(id: id, continuation: cont)
        pendingDuplex[id] = pending

        let openRequest = BareRPCCodec.encodeRequestFrame(id: id, command: command, stream: [.open], data: nil)
        let openResponse = BareRPCCodec.encodeStreamFrame(id: id, flags: [.response, .open])
        let firstChunk = BareRPCCodec.encodeStreamFrame(id: id, flags: [.request, .data], payload: .data(initialPayload))
        do {
            try await transport.write(openRequest)
            try await transport.write(openResponse)
            try await transport.write(firstChunk)
        } catch {
            pendingDuplex.removeValue(forKey: id)
            cont.finish(throwing: error)
            throw error
        }

        let onWrite: @Sendable (Data) async -> Void = { [weak self] data in
            await self?.sendDuplexChunk(id: id, data: data)
        }
        let onEnd: @Sendable () async -> Void = { [weak self] in
            await self?.endDuplexOutbound(id: id)
        }
        let onDestroy: @Sendable () -> Void = { [weak self] in
            Task { await self?.destroyDuplex(id: id) }
        }
        return BareRPCDuplexSession(
            chunks: asyncStream, onWrite: onWrite, onEnd: onEnd, onDestroy: onDestroy
        )
    }

    /// Close the connection and fail any in-flight requests/streams.
    public func close() async {
        if closed { return }
        closed = true
        feederTask?.cancel()
        await transport.close()
        await failAllInFlight(with: BareRPCConnectionClosed())
    }

    // ----------- Inbound dispatch -----------

    /// Feed a chunk of bytes from the transport. Used by the feeder task; not part of the
    /// public API.
    private func feed(_ data: Data) throws {
        try reader.append(data)
        while let frame = reader.next() {
            dispatch(frame)
        }
    }

    private func dispatch(_ frame: BareRPCFrame) {
        switch frame {
        case .response(let id, let flags, let payload):
            handleResponse(id: id, flags: flags, payload: payload)
        case .stream(let id, let flags, let payload):
            handleStream(id: id, flags: flags, payload: payload)
        case .request:
            // Servers send REQUEST frames to clients only in the event/notification
            // pattern (id=0). QVAC never uses this in practice. Drop silently.
            logger?.log(.debug, "ignoring unexpected REQUEST frame from server")
        }
    }

    private func handleResponse(id: UInt64, flags: BareRPCStreamFlags, payload: BareRPCResponsePayload) {
        // Streaming bootstrap: RESPONSE with non-zero stream flags is the server saying
        // "I've opened my outgoing-response stream; STREAM frames follow."
        if flags.rawValue != 0 {
            if let s = pendingStreams[id] {
                s.serverOpened = true
                return
            }
            if let d = pendingDuplex[id] {
                d.responseOpened = true
                return
            }
            // Unrequested RESPONSE(stream=*) — server bug or stale id. Ignore.
            return
        }
        // Single-shot RESPONSE.
        guard let pending = pendingSends.removeValue(forKey: id) else { return }
        switch payload {
        case .success(let data):
            pending.continuation.resume(returning: data)
        case .failure(let err):
            pending.continuation.resume(throwing: err)
        }
    }

    private func handleStream(id: UInt64, flags: BareRPCStreamFlags, payload: BareRPCStreamPayload) {
        // Streaming response (REQUEST direction not set → server-to-client = RESPONSE)
        if flags.contains(.response) {
            handleStreamResponseDirection(id: id, flags: flags, payload: payload)
        }
        if flags.contains(.request) {
            handleStreamRequestDirection(id: id, flags: flags, payload: payload)
        }
    }

    /// Server-pushed STREAM frames (direction bit = RESPONSE).
    private func handleStreamResponseDirection(id: UInt64, flags: BareRPCStreamFlags, payload: BareRPCStreamPayload) {
        if let s = pendingStreams[id] {
            switch payload {
            case .data(let d):
                s.continuation.yield(d)
            case .error(let err):
                s.finished = true
                s.continuation.finish(throwing: err)
                pendingStreams.removeValue(forKey: id)
            case .control:
                if flags.contains(.end) || flags.contains(.close) || flags.contains(.destroy) {
                    s.finished = true
                    s.continuation.finish()
                    pendingStreams.removeValue(forKey: id)
                }
                // OPEN/PAUSE/RESUME are bookkeeping for backpressure; ignore at our layer.
            }
            return
        }
        if let d = pendingDuplex[id] {
            switch payload {
            case .data(let chunk):
                d.continuation.yield(chunk)
            case .error(let err):
                d.finished = true
                d.continuation.finish(throwing: err)
                pendingDuplex.removeValue(forKey: id)
            case .control:
                if flags.contains(.end) || flags.contains(.close) || flags.contains(.destroy) {
                    d.finished = true
                    d.continuation.finish()
                    pendingDuplex.removeValue(forKey: id)
                }
            }
        }
    }

    /// Server acknowledgements on our outgoing request stream (direction bit = REQUEST).
    /// Server sends STREAM(REQUEST|OPEN) to acknowledge our open, STREAM(REQUEST|RESUME) to
    /// signal "send more data," etc. None of these require client-visible action in the
    /// current model — bare-rpc already buffers writes at the transport layer.
    private func handleStreamRequestDirection(id: UInt64, flags: BareRPCStreamFlags, payload: BareRPCStreamPayload) {
        if let d = pendingDuplex[id] {
            if flags.contains(.open) {
                d.requestOpened = true
            }
            if flags.contains(.error), case .error(let err) = payload {
                d.finished = true
                d.continuation.finish(throwing: err)
                pendingDuplex.removeValue(forKey: id)
            }
            // RESUME/PAUSE/END/CLOSE/DESTROY on request direction: bookkeeping only.
        }
    }

    // ----------- Duplex helpers -----------

    private func sendDuplexChunk(id: UInt64, data: Data) async {
        let frame = BareRPCCodec.encodeStreamFrame(id: id, flags: [.request, .data], payload: .data(data))
        do { try await transport.write(frame) }
        catch { /* Reported via stream's finish path on next failure or close */ }
    }

    private func endDuplexOutbound(id: UInt64) async {
        let frame = BareRPCCodec.encodeStreamFrame(id: id, flags: [.request, .end])
        try? await transport.write(frame)
    }

    private func destroyDuplex(id: UInt64) {
        guard let d = pendingDuplex[id], !d.finished else { return }
        d.finished = true
        let frame = BareRPCCodec.encodeStreamFrame(id: id, flags: [.request, .destroy])
        Task { [transport] in try? await transport.write(frame) }
        d.continuation.finish()
        pendingDuplex.removeValue(forKey: id)
    }

    private func destroyStream(id: UInt64) {
        guard let s = pendingStreams[id], !s.finished else { return }
        s.finished = true
        let frame = BareRPCCodec.encodeStreamFrame(id: id, flags: [.response, .destroy])
        Task { [transport] in try? await transport.write(frame) }
        s.continuation.finish()
        pendingStreams.removeValue(forKey: id)
    }

    // ----------- Bookkeeping primitives -----------

    private func allocateId() -> UInt64 {
        let id = nextId
        nextId = nextId &+ 1
        // bare-rpc treats id=0 as the events channel. Skip it.
        if nextId == 0 { nextId = 1 }
        return id
    }

    private func resolveSend(id: UInt64, with result: Result<Data?, Error>) {
        guard let pending = pendingSends.removeValue(forKey: id) else { return }
        switch result {
        case .success(let d): pending.continuation.resume(returning: d)
        case .failure(let e): pending.continuation.resume(throwing: e)
        }
    }

    private func makeStream() -> (AsyncThrowingStream<Data, Error>, AsyncThrowingStream<Data, Error>.Continuation) {
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        let stream = AsyncThrowingStream<Data, Error> { c in continuation = c }
        return (stream, continuation)
    }

    private func ensureOpen() async throws {
        if closed { throw BareRPCConnectionClosed() }
    }

    private func failAllInFlight(with error: Error) {
        for (_, p) in pendingSends { p.continuation.resume(throwing: error) }
        pendingSends.removeAll()
        for (_, s) in pendingStreams where !s.finished {
            s.continuation.finish(throwing: error)
        }
        pendingStreams.removeAll()
        for (_, d) in pendingDuplex where !d.finished {
            d.continuation.finish(throwing: error)
        }
        pendingDuplex.removeAll()
    }
}

// MARK: - Optional logger hook

public protocol BareRPCLogger: Sendable {
    func log(_ level: BareRPCLogLevel, _ message: String)
}

public enum BareRPCLogLevel: Int, Sendable, Comparable {
    case debug, info, warn, error
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}
