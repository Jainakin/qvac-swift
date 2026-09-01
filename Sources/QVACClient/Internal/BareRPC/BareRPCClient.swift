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

// MARK: - Internal errors

struct BareRPCConnectionClosed: Error, Sendable, Equatable {
    init() {}
}

struct BareRPCStreamClosed: Error, Sendable, Equatable {
    init() {}
}

struct BareRPCStreamBufferOverflow: Error, Sendable, Equatable, CustomStringConvertible {
    let maximumBufferedBytes: Int
    let attemptedBufferedBytes: Int

    init(maximumBufferedBytes: Int, attemptedBufferedBytes: Int) {
        self.maximumBufferedBytes = maximumBufferedBytes
        self.attemptedBufferedBytes = attemptedBufferedBytes
    }

    var description: String {
        "bare-rpc stream buffer would grow to \(attemptedBufferedBytes) bytes; "
            + "maximumBufferedStreamBytes is \(maximumBufferedBytes)"
    }
}

struct BareRPCProtocolError: Error, Sendable, Equatable {
    let reason: String
    init(_ reason: String) { self.reason = reason }
}

struct BareRPCInvalidArgument: Error, Sendable, Equatable {
    let reason: String
    init(_ reason: String) { self.reason = reason }
}

/// A local request deadline elapsed before bare-rpc reached the required state.
///
/// This is deliberately separate from `BareRPCError`, which represents an error
/// frame produced by the remote worker. The client translates this value
/// into `QVACError.requestTimedOut` with the operation discriminator attached.
struct BareRPCRequestTimeout: Error, Sendable, Equatable, CustomStringConvertible {
    let timeout: Duration

    init(timeout: Duration) {
        self.timeout = timeout
    }

    var description: String {
        "bare-rpc request timed out after \(timeout)"
    }
}

// MARK: - Streaming abstractions

/// Server-pushed response stream. Consume with `for await frame in stream.chunks`.
final class BareRPCResponseStream: @unchecked Sendable {
    let chunks: AsyncThrowingStream<Data, Error>
    private let onCancel: @Sendable () -> Void

    init(chunks: AsyncThrowingStream<Data, Error>, onCancel: @escaping @Sendable () -> Void) {
        self.chunks = chunks
        self.onCancel = onCancel
    }

    /// Signal the server we want no more frames (sends `STREAM | DESTROY | RESPONSE`).
    /// Idempotent.
    func destroy() { onCancel() }

    deinit { onCancel() }
}

/// Demand-aware, byte-bounded channel used behind raw response streams. Unlike
/// `AsyncThrowingStream`'s default buffering policy, this never retains an
/// unbounded number of large media frames. Queued values and the value currently
/// handed to the consumer remain charged until that consumer asks for its next
/// value. Every value also carries a conservative structural charge so empty or
/// tiny DATA frames cannot grow the queue without consuming the configured budget.
final class BoundedRPCDataChannel: @unchecked Sendable {
    /// Conservative allowance for the `Data` value, its queue entry, spare Array
    /// capacity, and allocator bookkeeping. Payload bytes are charged separately.
    ///
    /// Keep this visible to `@testable` unit tests so boundary assertions derive
    /// from the production accounting rule instead of duplicating a magic number.
    static let retainedValueOverheadBytes = 64

    private struct RetainedValue {
        let data: Data
        let chargedBytes: Int
    }

    private enum Terminal {
        case finished
        case failed(Error)
    }

    private let maximumBufferedBytes: Int
    private let onCancel: @Sendable () -> Void
    private let lock = NSLock()
    /// Consumed slots are cleared immediately so their `Data` storage is not
    /// retained while periodic prefix compaction keeps dequeue amortized O(1).
    private var queue: [RetainedValue?] = []
    private var queueIndex = 0
    /// Includes queued values and the value leased to the active iterator.
    private var bufferedBytes = 0
    /// The active iterator acknowledges this lease by requesting its next value.
    private var inFlightBytes = 0
    private var waiter: CheckedContinuation<Data?, Error>?
    private var terminal: Terminal?
    private var cancellationReported = false

    init(maximumBufferedBytes: Int, onCancel: @escaping @Sendable () -> Void) {
        self.maximumBufferedBytes = maximumBufferedBytes
        self.onCancel = onCancel
    }

    /// Returns an overflow error when the value cannot be retained within the
    /// budget. The caller owns terminating only that RPC operation.
    func yield(_ value: Data) -> BareRPCStreamBufferOverflow? {
        var waiting: CheckedContinuation<Data?, Error>?
        lock.lock()
        if terminal != nil {
            lock.unlock()
            return nil
        }
        let (chargedBytes, chargeOverflowed) = value.count.addingReportingOverflow(
            Self.retainedValueOverheadBytes
        )
        let (attempted, totalOverflowed) = bufferedBytes.addingReportingOverflow(chargedBytes)
        if chargeOverflowed || totalOverflowed || attempted > maximumBufferedBytes {
            lock.unlock()
            return BareRPCStreamBufferOverflow(
                maximumBufferedBytes: maximumBufferedBytes,
                attemptedBufferedBytes: chargeOverflowed || totalOverflowed ? Int.max : attempted
            )
        }
        if let current = waiter {
            waiter = nil
            waiting = current
            inFlightBytes = chargedBytes
        } else {
            queue.append(RetainedValue(data: value, chargedBytes: chargedBytes))
        }
        bufferedBytes = attempted
        lock.unlock()
        waiting?.resume(returning: value)
        return nil
    }

    func finish(throwing error: Error? = nil, discardingBuffered: Bool = false) {
        var waiting: CheckedContinuation<Data?, Error>?
        lock.lock()
        if terminal != nil, !discardingBuffered {
            lock.unlock()
            return
        }
        if terminal == nil {
            terminal = error.map(Terminal.failed) ?? .finished
        }
        if discardingBuffered {
            queue.removeAll(keepingCapacity: false)
            queueIndex = 0
            inFlightBytes = 0
            bufferedBytes = 0
        }
        if queueIndex >= queue.count {
            waiting = waiter
            waiter = nil
        }
        lock.unlock()

        if let error {
            waiting?.resume(throwing: error)
        } else {
            waiting?.resume(returning: nil)
        }
    }

    func next() async throws -> Data? {
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let value: Data? = try await withCheckedThrowingContinuation { continuation in
                var immediateValue: Data?
                var immediateTerminal: Terminal?
                var registered = false

                lock.lock()
                acknowledgeInFlightLocked()
                if queueIndex < queue.count {
                    let retainedValue = queue[queueIndex]
                    queue[queueIndex] = nil
                    queueIndex += 1
                    if queueIndex >= 64, queueIndex >= queue.count / 2 {
                        queue.removeFirst(queueIndex)
                        queueIndex = 0
                    }
                    immediateValue = retainedValue?.data
                    inFlightBytes = retainedValue?.chargedBytes ?? 0
                } else if let terminal {
                    immediateTerminal = terminal
                } else if waiter != nil {
                    immediateTerminal = .failed(BareRPCProtocolError(
                        "bare-rpc response stream supports only one active iterator"
                    ))
                } else {
                    waiter = continuation
                    registered = true
                }
                let cancelledAfterRegistration = registered && Task.isCancelled
                lock.unlock()

                if cancelledAfterRegistration {
                    cancelPendingNext()
                } else if let immediateValue {
                    continuation.resume(returning: immediateValue)
                } else if let immediateTerminal {
                    switch immediateTerminal {
                    case .finished: continuation.resume(returning: nil)
                    case .failed(let error): continuation.resume(throwing: error)
                    }
                }
            }
            try Task.checkCancellation()
            return value
        } onCancel: {
            self.cancelPendingNext()
        }
    }

    /// Cancel local consumption synchronously. This must discard retained values
    /// even after a remote terminal frame removed the operation from the RPC
    /// actor; otherwise an early break can retain a completed stream's full byte
    /// budget for as long as the sequence value itself remains alive.
    func cancel() {
        cancel(resumingPendingNextWith: nil)
    }

    private func cancelPendingNext() {
        cancel(resumingPendingNextWith: CancellationError())
    }

    private func cancel(resumingPendingNextWith error: Error?) {
        let (waiting, shouldNotify): (CheckedContinuation<Data?, Error>?, Bool) = lock.withLock {
            let wasActive = terminal == nil
            if wasActive { terminal = .finished }
            queue.removeAll(keepingCapacity: false)
            queueIndex = 0
            inFlightBytes = 0
            bufferedBytes = 0
            defer { waiter = nil }
            let shouldNotify = !cancellationReported && wasActive
            cancellationReported = true
            return (waiter, shouldNotify)
        }
        if let error {
            waiting?.resume(throwing: error)
        } else {
            waiting?.resume(returning: nil)
        }
        if shouldNotify { onCancel() }
    }

    /// Releases the accounting lease for the value returned by the preceding
    /// `next()` call. The payload's queue slot is cleared at dequeue time,
    /// so the channel does not retain an already-consumed `Data` value.
    private func acknowledgeInFlightLocked() {
        guard inFlightBytes > 0 else { return }
        if inFlightBytes <= bufferedBytes {
            bufferedBytes -= inFlightBytes
        } else {
            // Restore coherent accounting without trapping on corrupted state.
            bufferedBytes = 0
        }
        inFlightBytes = 0
    }

    /// Test-only visibility for deterministic byte-accounting and retention
    /// assertions without timing producer/consumer races.
    func __testState() -> (
        queuedValues: Int,
        bufferedBytes: Int,
        inFlightBytes: Int,
        hasPendingWaiter: Bool
    ) {
        lock.withLock {
            (queue.count - queueIndex, bufferedBytes, inFlightBytes, waiter != nil)
        }
    }
}

/// Bidirectional session for duplex APIs. Write outbound chunks via `write(_:)`,
/// consume server frames via `chunks`.
final class BareRPCDuplexSession: @unchecked Sendable {
    let chunks: AsyncThrowingStream<Data, Error>
    private let onWrite: @Sendable (Data) async throws -> Void
    private let onEnd: @Sendable () async throws -> Void
    private let onDestroy: @Sendable () -> Void

    init(
        chunks: AsyncThrowingStream<Data, Error>,
        onWrite: @escaping @Sendable (Data) async throws -> Void,
        onEnd: @escaping @Sendable () async throws -> Void,
        onDestroy: @escaping @Sendable () -> Void
    ) {
        self.chunks = chunks
        self.onWrite = onWrite
        self.onEnd = onEnd
        self.onDestroy = onDestroy
    }

    /// Push a chunk to the server. Emits `STREAM | DATA | REQUEST` on the wire.
    func write(_ chunk: Data) async throws { try await onWrite(chunk) }

    /// Signal end-of-stream on the client→server direction. Emits `STREAM | END | REQUEST`.
    func end() async throws { try await onEnd() }

    /// Force-terminate the whole session. Closes the outgoing request stream and
    /// destroys the incoming response stream, matching bare-rpc's two half-streams.
    func destroy() { onDestroy() }

    deinit { onDestroy() }
}

// MARK: - The actor

actor BareRPCClient {

    // ----------- Configuration & state -----------

    /// Per-request bookkeeping for `send`.
    private final class PendingSend {
        let continuation: CheckedContinuation<Data?, Error>
        var timeoutTask: Task<Void, Never>?
        var writeTask: Task<Void, Never>?
        var writeStarted = false
        var writeCompleted = false

        init(continuation: CheckedContinuation<Data?, Error>) {
            self.continuation = continuation
        }
    }

    /// Per-request bookkeeping for `stream`.
    private final class PendingStream {
        let id: UInt64
        let channel: BoundedRPCDataChannel
        /// Set once we've sent `STREAM | RESPONSE | OPEN`.
        var openSent = false
        /// Set once the server has sent `RESPONSE | OPEN` (or first DATA).
        var serverOpened = false
        /// True once we've yielded END/CLOSE/DESTROY (terminal).
        var finished = false
        var setupContinuation: CheckedContinuation<Void, Error>?
        var timeout: Duration?
        var timeoutGeneration: UInt64 = 0
        var timeoutTask: Task<Void, Never>?
        var setupWriteTask: Task<Void, Never>?
        var setupWriteStarted = false
        init(id: UInt64, channel: BoundedRPCDataChannel) {
            self.id = id; self.channel = channel
        }
    }

    /// Per-request bookkeeping for `duplex`.
    private final class PendingDuplex {
        struct OutboundWrite {
            let id: UInt64
            let task: Task<Void, Error>
        }

        let id: UInt64
        let channel: BoundedRPCDataChannel
        /// `STREAM | REQUEST | OPEN` ack from server received.
        var requestOpened = false
        /// `RESPONSE | OPEN` from server received.
        var responseOpened = false
        var localWritesComplete = false
        var outboundEnded = false
        var finished = false
        var setupContinuation: CheckedContinuation<Void, Error>?
        var timeout: Duration?
        var timeoutTask: Task<Void, Never>?
        var setupWriteTask: Task<Void, Never>?
        var setupWriteStarted = false
        /// Every queued or executing post-handshake write. Keeping the complete
        /// active set (rather than only the serial tail) lets terminal teardown
        /// cancel predecessor tasks too. A canceled tail waiting on
        /// `predecessor.value` does not propagate cancellation backwards.
        var outboundWrites: [UInt64: Task<Void, Error>] = [:]
        var outboundWriteTail: OutboundWrite?
        var nextOutboundWriteID: UInt64 = 1
        init(id: UInt64, channel: BoundedRPCDataChannel) {
            self.id = id; self.channel = channel
        }
    }

    private let transport: BareTransport
    private let logger: BareRPCLogger?
    private let maximumWireMessageBytes: Int
    private let maximumBufferedStreamBytes: Int
    private var nextId: UInt64 = 1
    private var pendingSends: [UInt64: PendingSend] = [:]
    private var pendingStreams: [UInt64: PendingStream] = [:]
    private var pendingDuplex: [UInt64: PendingDuplex] = [:]
    private let reader: BareRPCFrameReader
    private var closed = false
    private var transportCloseTask: Task<Void, Never>?
    private var feederTask: Task<Void, Never>?

    /// Construct the RPC client around a connected transport. The inbound stream is
    /// claimed SYNCHRONOUSLY here (so any subsequent `send` / `stream` call is guaranteed
    /// to have a destination for incoming bytes) and the feeder task that pumps the
    /// stream into the RPC state machine is spawned immediately. Caller MUST `await
    /// close()` to release resources.
    init(transport: BareTransport, logger: BareRPCLogger? = nil) {
        self.transport = transport
        self.logger = logger
        self.maximumWireMessageBytes = BareRPCFrameReader.defaultMaxFrameSize
        self.maximumBufferedStreamBytes = BareRPCFrameReader.defaultMaxFrameSize
        self.reader = BareRPCFrameReader(
            validatedMaxFrameSize: BareRPCFrameReader.defaultMaxFrameSize
        )
        // Claim the inbound stream NOW so the transport's reader thread has somewhere
        // to deliver bytes. Doing this lazily inside a Task creates a race: if the
        // caller fires a `send` immediately and the worker's response arrives before
        // the lazy Task scheduled the inboundStream() call, the response is dropped.
        let inbound = transport.inboundStream()
        Task { [weak self] in
            await self?.installFeeder(for: inbound)
        }
    }

    /// Construct a client with explicit wire and per-operation buffering ceilings.
    /// Invalid configuration is reported as an error rather than trapping the
    /// host process.
    init(
        transport: BareTransport,
        maximumWireMessageBytes: Int,
        maximumBufferedStreamBytes: Int? = nil,
        logger: BareRPCLogger? = nil
    ) throws {
        guard maximumWireMessageBytes > 0,
              maximumWireMessageBytes <= Int(UInt32.max) else {
            throw BareRPCInvalidArgument(
                "maximumWireMessageBytes must be between 1 and UInt32.max"
            )
        }
        let bufferLimit = maximumBufferedStreamBytes ?? maximumWireMessageBytes
        guard bufferLimit > 0, bufferLimit <= Int(UInt32.max) else {
            throw BareRPCInvalidArgument(
                "maximumBufferedStreamBytes must be between 1 and UInt32.max"
            )
        }
        self.transport = transport
        self.logger = logger
        self.maximumWireMessageBytes = maximumWireMessageBytes
        self.maximumBufferedStreamBytes = bufferLimit
        self.reader = BareRPCFrameReader(validatedMaxFrameSize: maximumWireMessageBytes)
        let inbound = transport.inboundStream()
        Task { [weak self] in
            await self?.installFeeder(for: inbound)
        }
    }

    /// Internal path for callers that have already validated both limits.
    init(
        validatedTransport transport: BareTransport,
        maximumWireMessageBytes: Int,
        maximumBufferedStreamBytes: Int,
        logger: BareRPCLogger?
    ) {
        self.transport = transport
        self.logger = logger
        self.maximumWireMessageBytes = maximumWireMessageBytes
        self.maximumBufferedStreamBytes = maximumBufferedStreamBytes
        self.reader = BareRPCFrameReader(validatedMaxFrameSize: maximumWireMessageBytes)
        let inbound = transport.inboundStream()
        Task { [weak self] in
            await self?.installFeeder(for: inbound)
        }
    }

    private func installFeeder(for inbound: AsyncThrowingStream<Data, Error>) {
        guard feederTask == nil, !closed else { return }
        feederTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await chunk in inbound {
                    try await self.feed(chunk)
                }
                await self.connectionEnded(with: BareRPCConnectionClosed())
            } catch {
                await self.connectionEnded(with: error)
            }
        }
    }

    deinit {
        feederTask?.cancel()
        let transport = self.transport
        Task { await transport.close() }
    }

    // ----------- Public surface -----------

    /// Single-shot RPC: send a REQUEST with `data` inline, await the RESPONSE's data.
    /// Throws on connection failure, server-side error frame, or transport timeout.
    func send(
        command: UInt64,
        data: Data?,
        timeout: Duration? = nil
    ) async throws -> Data? {
        try ensureOpen()
        try validate(timeout: timeout)
        let id = allocateId()
        let frame = try BareRPCCodec.encodeRequestFrame(
            id: id,
            command: command,
            stream: [],
            data: data,
            maximumBodyBytes: maximumWireMessageBytes
        )
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data?, Error>) in
                let pending = PendingSend(continuation: c)
                pendingSends[id] = pending
                if Task.isCancelled {
                    resolveSend(id: id, with: .failure(CancellationError()))
                    return
                }
                if let timeout {
                    pending.timeoutTask = makeTimeoutTask(after: timeout) { [weak self] in
                        await self?.timeoutSend(id: id, timeout: timeout)
                    }
                }
                pending.writeTask = Task { [transport, weak self] in
                    guard await self?.beginSendWrite(id: id) == true else { return }
                    do {
                        try Task.checkCancellation()
                        try await transport.write(frame)
                        await self?.completeSendWrite(id: id)
                    } catch is CancellationError {
                        // Cancellation already resolved and removed the pending entry.
                    } catch {
                        // A write failure means the byte channel can no longer be
                        // trusted for any operation, not merely this request. Make
                        // the generation terminal and fail every in-flight waiter
                        // exactly once; QVACClient may create a fresh generation for
                        // a later (never replayed) request.
                        await self?.connectionEnded(with: error)
                    }
                }
            }
        } onCancel: { [weak self] in
            Task { [weak self] in
                await self?.resolveSend(
                    id: id,
                    with: .failure(CancellationError()),
                    abortIfWriteIncomplete: true
                )
            }
        }
    }

    /// Server-pushed streaming RPC: send a REQUEST + STREAM-OPEN-RESPONSE handshake, then
    /// yield each DATA frame's payload. Terminates on END/CLOSE/DESTROY or error.
    func stream(
        command: UInt64,
        data: Data?,
        timeout: Duration? = nil
    ) async throws -> BareRPCResponseStream {
        try ensureOpen()
        try validate(timeout: timeout)
        let id = allocateId()
        // We need to start awaiting frames BEFORE the request goes out, because the server's
        // RESPONSE(OPEN) may race with our STREAM(RESPONSE|OPEN). Bookkeeping first.
        let (asyncStream, channel) = makeStream {
            Task { [weak self] in await self?.destroyStream(id: id) }
        }
        let pending = PendingStream(id: id, channel: channel)
        pending.timeout = timeout
        // Send REQUEST inline + STREAM(RESPONSE|OPEN) immediately (mirrors what JS
        // bare-rpc's req.createResponseStream({ eagerOpen: true }) does — see the wire
        // capture for Spike-B in docs/spike-validations.md).
        let req = try BareRPCCodec.encodeRequestFrame(
            id: id,
            command: command,
            stream: [],
            data: data,
            maximumBodyBytes: maximumWireMessageBytes
        )
        let openAck = try BareRPCCodec.encodeStreamFrame(
            id: id,
            flags: [.response, .open],
            maximumBodyBytes: maximumWireMessageBytes
        )
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (setup: CheckedContinuation<Void, Error>) in
                pending.setupContinuation = setup
                pendingStreams[id] = pending
                if Task.isCancelled {
                    failStream(id: id, with: CancellationError(), notifyRemote: false)
                    return
                }
                pending.setupWriteTask = Task { [transport, weak self] in
                    guard await self?.beginStreamSetupWrite(id: id) == true else { return }
                    do {
                        try Task.checkCancellation()
                        try await transport.write(req)
                        try Task.checkCancellation()
                        try await transport.write(openAck)
                        try Task.checkCancellation()
                        await self?.completeStreamSetup(id: id)
                    } catch is CancellationError {
                        // The cancellation/timeout path owns continuation resolution and
                        // sends teardown after this writer has stopped.
                    } catch {
                        await self?.connectionEnded(with: error)
                    }
                }
                armStreamTimeout(id: id)
            }
        } onCancel: { [weak self] in
            Task { [weak self] in
                await self?.failStream(id: id, with: CancellationError(), notifyRemote: true)
            }
        }
        let onCancel: @Sendable () -> Void = { [channel] in
            channel.cancel()
        }
        return BareRPCResponseStream(chunks: asyncStream, onCancel: onCancel)
    }

    /// Bidirectional session: emits the canonical 3-step duplex handshake
    /// (REQUEST(stream=OPEN, no data) + STREAM(RESPONSE|OPEN) + STREAM(REQUEST|DATA, payload))
    /// then exposes a session that callers can write to and iterate.
    func duplex(
        command: UInt64,
        initialPayload: Data,
        timeout: Duration? = nil
    ) async throws -> BareRPCDuplexSession {
        try ensureOpen()
        try validate(timeout: timeout)
        let id = allocateId()
        let (asyncStream, channel) = makeStream {
            Task { [weak self] in await self?.destroyDuplex(id: id) }
        }
        let pending = PendingDuplex(id: id, channel: channel)
        pending.timeout = timeout
        let openRequest = try BareRPCCodec.encodeRequestFrame(
            id: id,
            command: command,
            stream: [.open],
            data: nil,
            maximumBodyBytes: maximumWireMessageBytes
        )
        let openResponse = try BareRPCCodec.encodeStreamFrame(
            id: id,
            flags: [.response, .open],
            maximumBodyBytes: maximumWireMessageBytes
        )
        let firstChunk = try BareRPCCodec.encodeStreamFrame(
            id: id,
            flags: [.request, .data],
            payload: .data(initialPayload),
            maximumBodyBytes: maximumWireMessageBytes
        )
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (setup: CheckedContinuation<Void, Error>) in
                pending.setupContinuation = setup
                pendingDuplex[id] = pending
                if Task.isCancelled {
                    failDuplex(id: id, with: CancellationError(), notifyRemote: false)
                    return
                }
                pending.setupWriteTask = Task { [transport, weak self] in
                    guard await self?.beginDuplexSetupWrite(id: id) == true else { return }
                    do {
                        try Task.checkCancellation()
                        try await transport.write(openRequest)
                        try Task.checkCancellation()
                        try await transport.write(openResponse)
                        try Task.checkCancellation()
                        try await transport.write(firstChunk)
                        try Task.checkCancellation()
                        await self?.completeDuplexWrites(id: id)
                    } catch is CancellationError {
                        // The cancellation/timeout path owns continuation resolution and
                        // sends teardown after this writer has stopped.
                    } catch {
                        await self?.connectionEnded(with: error)
                    }
                }
                if let timeout {
                    pending.timeoutTask = makeTimeoutTask(after: timeout) { [weak self] in
                        await self?.timeoutDuplex(id: id, timeout: timeout)
                    }
                }
            }
        } onCancel: { [weak self] in
            Task { [weak self] in
                await self?.failDuplex(id: id, with: CancellationError(), notifyRemote: true)
            }
        }

        let onWrite: @Sendable (Data) async throws -> Void = { [weak self] data in
            guard let self else { throw BareRPCStreamClosed() }
            try await self.sendDuplexChunk(id: id, data: data)
        }
        let onEnd: @Sendable () async throws -> Void = { [weak self] in
            guard let self else { throw BareRPCStreamClosed() }
            try await self.endDuplexOutbound(id: id)
        }
        let onDestroy: @Sendable () -> Void = { [channel] in
            channel.cancel()
        }
        return BareRPCDuplexSession(
            chunks: asyncStream, onWrite: onWrite, onEnd: onEnd, onDestroy: onDestroy
        )
    }

    /// Close the connection and fail any in-flight requests/streams.
    func close() async {
        let task = beginClosing()
        await task.value
    }

    // ----------- Inbound dispatch -----------

    /// Feed a chunk of bytes from the transport. Used by the feeder task; not part of the
    /// API.
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
                armStreamTimeout(id: id)
                return
            }
            if let d = pendingDuplex[id] {
                d.responseOpened = true
                completeDuplexSetupIfReady(id: id)
                return
            }
            // Unrequested RESPONSE(stream=*) — server bug or stale id. Ignore.
            return
        }
        // Single-shot RESPONSE.
        switch payload {
        case .success(let data):
            resolveSend(id: id, with: .success(data))
        case .failure(let err):
            resolveSend(id: id, with: .failure(err))
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
                s.serverOpened = true
                armStreamTimeout(id: id)
                if let overflow = s.channel.yield(d) {
                    failStream(id: id, with: overflow, notifyRemote: true)
                }
            case .error(let err):
                failStream(id: id, with: err, notifyRemote: false)
            case .control:
                if flags.contains(.end) || flags.contains(.close) || flags.contains(.destroy) {
                    finishStream(id: id)
                } else if flags.contains(.open) || flags.contains(.resume) {
                    s.serverOpened = true
                    armStreamTimeout(id: id)
                }
                // OPEN/PAUSE/RESUME are bookkeeping for backpressure; ignore at our layer.
            }
            return
        }
        if let d = pendingDuplex[id] {
            switch payload {
            case .data(let chunk):
                d.responseOpened = true
                completeDuplexSetupIfReady(id: id)
                if let overflow = d.channel.yield(chunk) {
                    failDuplex(id: id, with: overflow, notifyRemote: true)
                }
            case .error(let err):
                failDuplex(id: id, with: err, notifyRemote: false)
            case .control:
                if flags.contains(.end) || flags.contains(.close) || flags.contains(.destroy) {
                    finishDuplex(id: id, notifyRemote: !d.outboundEnded)
                } else if flags.contains(.open) {
                    d.responseOpened = true
                    completeDuplexSetupIfReady(id: id)
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
                completeDuplexSetupIfReady(id: id)
            }
            if flags.contains(.error), case .error(let err) = payload {
                failDuplex(id: id, with: err, notifyRemote: false)
                return
            }
            if flags.contains(.end) || flags.contains(.close) || flags.contains(.destroy) {
                d.outboundEnded = true
                if (d.setupWriteStarted && !d.localWritesComplete)
                    || !d.outboundWrites.isEmpty {
                    // The peer terminated the request half while its setup write or
                    // post-handshake writes were still queued/executing. Cancel every
                    // link and close this transport generation so even a
                    // cancellation-oblivious writer is guaranteed to return.
                    for task in d.outboundWrites.values { task.cancel() }
                    _ = beginClosing()
                }
            }
            // RESUME/PAUSE are transport-level backpressure signals.
        }
    }

    // ----------- Duplex helpers -----------

    private func sendDuplexChunk(id: UInt64, data: Data) async throws {
        guard let d = pendingDuplex[id], !d.finished, !d.outboundEnded else {
            throw BareRPCStreamClosed()
        }
        let frame = try BareRPCCodec.encodeStreamFrame(
            id: id,
            flags: [.request, .data],
            payload: .data(data),
            maximumBodyBytes: maximumWireMessageBytes
        )
        try await performDuplexWrite(id: id, frame: frame)
    }

    private func endDuplexOutbound(id: UInt64) async throws {
        guard let d = pendingDuplex[id], !d.finished, !d.outboundEnded else {
            throw BareRPCStreamClosed()
        }
        d.outboundEnded = true
        let frame = try BareRPCCodec.encodeStreamFrame(
            id: id,
            flags: [.request, .end],
            maximumBodyBytes: maximumWireMessageBytes
        )
        try await performDuplexWrite(id: id, frame: frame)
    }

    private func performDuplexWrite(id: UInt64, frame: Data) async throws {
        guard let duplex = pendingDuplex[id], !duplex.finished else {
            throw BareRPCStreamClosed()
        }
        let predecessor = duplex.outboundWriteTail?.task
        let writeID = duplex.nextOutboundWriteID
        duplex.nextOutboundWriteID &+= 1
        if duplex.nextOutboundWriteID == 0 { duplex.nextOutboundWriteID = 1 }
        let transport = self.transport
        let task = Task<Void, Error> {
            if let predecessor { try await predecessor.value }
            try Task.checkCancellation()
            try await transport.write(frame)
            // BareTransport implementations are required to cooperate with close,
            // but a custom adapter may return normally after cancellation unblocks
            // it. Never report that ambiguous write as successful.
            try Task.checkCancellation()
        }
        duplex.outboundWrites[writeID] = task
        duplex.outboundWriteTail = .init(id: writeID, task: task)
        defer {
            duplex.outboundWrites.removeValue(forKey: writeID)
            if duplex.outboundWriteTail?.id == writeID {
                duplex.outboundWriteTail = nil
            }
        }
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
                Task { [weak self] in await self?.cancelDuplexWrite(id: id) }
            }
        } catch {
            connectionEnded(with: error)
            throw error
        }
    }

    private func cancelDuplexWrite(id: UInt64) {
        guard pendingDuplex[id] != nil else { return }
        _ = beginClosing()
    }

    private func destroyDuplex(id: UInt64) {
        guard let d = takeDuplex(id: id) else { return }
        d.finished = true
        resumeSetup(d, with: .failure(CancellationError()))
        if d.outboundWrites.isEmpty {
            sendDuplexTeardown(
                id: id,
                closeRequest: !d.outboundEnded,
                after: d.setupWriteTask
            )
        } else {
            // A post-handshake transport write may ignore task cancellation. The
            // operation has already been removed, so fail-close this generation to
            // unblock every writer instead of queuing teardown behind a stuck write.
            _ = beginClosing()
        }
        d.channel.finish(discardingBuffered: true)
    }

    private func destroyStream(id: UInt64) {
        guard let s = takeStream(id: id) else { return }
        s.finished = true
        resumeSetup(s, with: .failure(CancellationError()))
        if let frame = try? BareRPCCodec.encodeStreamFrame(
            id: id,
            flags: [.response, .destroy],
            maximumBodyBytes: maximumWireMessageBytes
        ) {
            sendTeardown(frame, after: s.setupWriteTask)
        }
        s.channel.finish(discardingBuffered: true)
    }

    // ----------- Bookkeeping primitives -----------

    private func allocateId() -> UInt64 {
        let id = nextId
        nextId = nextId &+ 1
        // bare-rpc treats id=0 as the events channel. Skip it.
        if nextId == 0 { nextId = 1 }
        return id
    }

    private func beginSendWrite(id: UInt64) -> Bool {
        guard let pending = pendingSends[id] else { return false }
        pending.writeStarted = true
        return true
    }

    private func completeSendWrite(id: UInt64) {
        pendingSends[id]?.writeCompleted = true
    }

    private func beginStreamSetupWrite(id: UInt64) -> Bool {
        guard let stream = pendingStreams[id], !stream.finished else { return false }
        stream.setupWriteStarted = true
        return true
    }

    private func beginDuplexSetupWrite(id: UInt64) -> Bool {
        guard let duplex = pendingDuplex[id], !duplex.finished else { return false }
        duplex.setupWriteStarted = true
        return true
    }

    private func resolveSend(
        id: UInt64,
        with result: Result<Data?, Error>,
        abortIfWriteIncomplete: Bool = false
    ) {
        guard let pending = pendingSends.removeValue(forKey: id) else { return }
        pending.timeoutTask?.cancel()
        pending.writeTask?.cancel()
        switch result {
        case .success(let d): pending.continuation.resume(returning: d)
        case .failure(let e): pending.continuation.resume(throwing: e)
        }
        if abortIfWriteIncomplete && pending.writeStarted && !pending.writeCompleted {
            _ = beginClosing()
        }
    }

    private func timeoutSend(id: UInt64, timeout: Duration) {
        resolveSend(
            id: id,
            with: .failure(BareRPCRequestTimeout(timeout: timeout)),
            abortIfWriteIncomplete: true
        )
    }

    private func completeStreamSetup(id: UInt64) {
        guard let stream = pendingStreams[id], !stream.finished else { return }
        stream.openSent = true
        resumeSetup(stream, with: .success(()))
    }

    private func finishStream(id: UInt64) {
        guard let stream = takeStream(id: id) else { return }
        stream.finished = true
        resumeSetup(stream, with: .success(()))
        stream.channel.finish()
        if stream.setupWriteStarted && !stream.openSent {
            // A peer can terminate as soon as it parses the request, before the
            // async transport write reports completion. Cancellation alone cannot
            // release an arbitrary BareTransport implementation.
            _ = beginClosing()
        }
    }

    private func failStream(id: UInt64, with error: Error, notifyRemote: Bool) {
        guard let stream = takeStream(id: id) else { return }
        stream.finished = true
        resumeSetup(stream, with: .failure(error))
        stream.channel.finish(throwing: error, discardingBuffered: true)
        if stream.setupWriteStarted && !stream.openSent {
            _ = beginClosing()
        } else if notifyRemote, stream.openSent {
                if let frame = try? BareRPCCodec.encodeStreamFrame(
                    id: id,
                    flags: [.response, .destroy],
                    maximumBodyBytes: maximumWireMessageBytes
                ) {
                    sendTeardown(frame, after: stream.setupWriteTask)
                }
        }
    }

    private func timeoutStream(id: UInt64, timeout: Duration, generation: UInt64) {
        guard let stream = pendingStreams[id], stream.timeoutGeneration == generation else { return }
        failStream(id: id, with: BareRPCRequestTimeout(timeout: timeout), notifyRemote: true)
    }

    private func armStreamTimeout(id: UInt64) {
        guard let stream = pendingStreams[id], let timeout = stream.timeout else { return }
        stream.timeoutTask?.cancel()
        stream.timeoutGeneration &+= 1
        let generation = stream.timeoutGeneration
        stream.timeoutTask = makeTimeoutTask(after: timeout) { [weak self] in
            await self?.timeoutStream(id: id, timeout: timeout, generation: generation)
        }
    }

    private func completeDuplexWrites(id: UInt64) {
        guard let duplex = pendingDuplex[id], !duplex.finished else { return }
        duplex.localWritesComplete = true
        completeDuplexSetupIfReady(id: id)
    }

    private func completeDuplexSetupIfReady(id: UInt64) {
        guard let duplex = pendingDuplex[id], !duplex.finished, duplex.localWritesComplete else { return }
        guard duplex.requestOpened && duplex.responseOpened else { return }
        duplex.timeoutTask?.cancel()
        duplex.timeoutTask = nil
        resumeSetup(duplex, with: .success(()))
    }

    private func timeoutDuplex(id: UInt64, timeout: Duration) {
        failDuplex(id: id, with: BareRPCRequestTimeout(timeout: timeout), notifyRemote: true)
    }

    private func finishDuplex(id: UInt64, notifyRemote: Bool) {
        guard let duplex = takeDuplex(id: id) else { return }
        duplex.finished = true
        resumeSetup(duplex, with: .success(()))
        if duplex.setupWriteStarted && !duplex.localWritesComplete {
            // Preserve the removed channel's remote terminal, but fail-close the
            // generation so an incomplete cancellation-oblivious handshake write
            // cannot remain behind it forever.
            _ = beginClosing()
        } else if !duplex.outboundWrites.isEmpty {
            // Remote response termination raced queued/request-direction writes.
            // Their delivery is now ambiguous, and only generation teardown can
            // guarantee that a non-cooperative transport write is released.
            _ = beginClosing()
        } else if notifyRemote {
            sendDuplexTeardown(id: id, closeRequest: true, after: duplex.setupWriteTask)
        }
        duplex.channel.finish()
    }

    private func failDuplex(id: UInt64, with error: Error, notifyRemote: Bool) {
        guard let duplex = takeDuplex(id: id) else { return }
        duplex.finished = true
        resumeSetup(duplex, with: .failure(error))
        if duplex.setupWriteStarted && !duplex.localWritesComplete {
            _ = beginClosing()
        } else if !duplex.outboundWrites.isEmpty {
            _ = beginClosing()
        } else if notifyRemote {
            if duplex.localWritesComplete {
                sendDuplexTeardown(
                    id: id,
                    closeRequest: !duplex.outboundEnded,
                    after: duplex.setupWriteTask
                )
            }
        }
        duplex.channel.finish(throwing: error, discardingBuffered: true)
    }

    private func sendDuplexTeardown(
        id: UInt64,
        closeRequest: Bool,
        after setupWriteTask: Task<Void, Never>?
    ) {
        var frames = Data()
        if closeRequest {
            if let close = try? BareRPCCodec.encodeStreamFrame(
                id: id,
                flags: [.request, .close],
                maximumBodyBytes: maximumWireMessageBytes
            ) {
                frames.append(close)
            }
        }
        if let destroy = try? BareRPCCodec.encodeStreamFrame(
            id: id,
            flags: [.response, .destroy],
            maximumBodyBytes: maximumWireMessageBytes
        ) {
            frames.append(destroy)
        }
        if !frames.isEmpty {
            sendTeardown(frames, after: setupWriteTask)
        }
    }

    private func sendTeardown(_ frames: Data, after setupWriteTask: Task<Void, Never>?) {
        Task { [transport, weak self] in
            if let setupWriteTask { await setupWriteTask.value }
            do {
                try await transport.write(frames)
            } catch {
                await self?.connectionEnded(with: error)
            }
        }
    }

    private func takeStream(id: UInt64) -> PendingStream? {
        guard let stream = pendingStreams.removeValue(forKey: id), !stream.finished else { return nil }
        stream.timeoutTask?.cancel()
        stream.timeoutTask = nil
        stream.setupWriteTask?.cancel()
        return stream
    }

    private func takeDuplex(id: UInt64) -> PendingDuplex? {
        guard let duplex = pendingDuplex.removeValue(forKey: id), !duplex.finished else { return nil }
        duplex.timeoutTask?.cancel()
        duplex.timeoutTask = nil
        duplex.setupWriteTask?.cancel()
        for task in duplex.outboundWrites.values { task.cancel() }
        return duplex
    }

    private func resumeSetup(_ stream: PendingStream, with result: Result<Void, Error>) {
        guard let continuation = stream.setupContinuation else { return }
        stream.setupContinuation = nil
        continuation.resume(with: result)
    }

    private func resumeSetup(_ duplex: PendingDuplex, with result: Result<Void, Error>) {
        guard let continuation = duplex.setupContinuation else { return }
        duplex.setupContinuation = nil
        continuation.resume(with: result)
    }

    private func makeTimeoutTask(
        after timeout: Duration,
        action: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never> {
        Task {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            await action()
        }
    }

    private func makeStream(
        onCancel: @escaping @Sendable () -> Void
    ) -> (AsyncThrowingStream<Data, Error>, BoundedRPCDataChannel) {
        let channel = BoundedRPCDataChannel(
            maximumBufferedBytes: maximumBufferedStreamBytes,
            onCancel: onCancel
        )
        let stream = AsyncThrowingStream<Data, Error>(unfolding: {
            try await channel.next()
        })
        return (stream, channel)
    }

    private func ensureOpen() throws {
        if closed { throw BareRPCConnectionClosed() }
    }

    /// Whether this transport generation can accept a new request.
    ///
    /// EOF, inbound failures, outbound channel failures, and explicit close all
    /// synchronously flip this value before in-flight operations are failed. The
    /// owning QVACClient uses it only before *new* calls; it never retries or
    /// replays an operation that was already assigned to this generation.
    func isOpen() -> Bool {
        !closed
    }

    private func validate(timeout: Duration?) throws {
        if let timeout, timeout <= .zero {
            throw BareRPCInvalidArgument("timeout must be greater than zero")
        }
    }

    private func connectionEnded(with error: Error) {
        guard transportCloseTask == nil else { return }
        _ = beginClosing(failingWith: error)
    }

    /// Starts transport teardown synchronously in actor state and returns the one
    /// joinable task shared by every concurrent `close()` caller.
    @discardableResult
    private func beginClosing(
        failingWith error: Error = BareRPCConnectionClosed()
    ) -> Task<Void, Never> {
        if let transportCloseTask { return transportCloseTask }
        closed = true
        let feeder = feederTask
        feeder?.cancel()
        failAllInFlight(with: error)
        let transport = self.transport
        let task = Task {
            await transport.close()
            if let feeder { await feeder.value }
        }
        transportCloseTask = task
        return task
    }

    private func failAllInFlight(with error: Error) {
        for (_, p) in pendingSends {
            p.timeoutTask?.cancel()
            p.writeTask?.cancel()
            p.continuation.resume(throwing: error)
        }
        pendingSends.removeAll()
        for (_, s) in pendingStreams where !s.finished {
            s.timeoutTask?.cancel()
            s.setupWriteTask?.cancel()
            resumeSetup(s, with: .failure(error))
            s.channel.finish(throwing: error, discardingBuffered: true)
        }
        pendingStreams.removeAll()
        for (_, d) in pendingDuplex where !d.finished {
            d.timeoutTask?.cancel()
            d.setupWriteTask?.cancel()
            for task in d.outboundWrites.values { task.cancel() }
            resumeSetup(d, with: .failure(error))
            d.channel.finish(throwing: error, discardingBuffered: true)
        }
        pendingDuplex.removeAll()
    }

    /// Test-only visibility for proving timeout/cancellation cleanup.
    func __testInFlightCounts() -> (sends: Int, streams: Int, duplexes: Int) {
        (pendingSends.count, pendingStreams.count, pendingDuplex.count)
    }

    /// Test-only visibility for proving that duplex teardown observes every
    /// queued/executing write rather than only the serial tail.
    func __testDuplexOutboundWriteCount(id: UInt64) -> Int? {
        pendingDuplex[id]?.outboundWrites.count
    }

    /// Test-only visibility for proving that timeout configuration changes only
    /// the timer, never the two-OPEN readiness predicate.
    func __testDuplexSetupState(id: UInt64) -> (
        localWritesComplete: Bool,
        requestOpened: Bool,
        responseOpened: Bool,
        awaitingSetup: Bool,
        hasTimeoutTask: Bool
    )? {
        guard let duplex = pendingDuplex[id] else { return nil }
        return (
            duplex.localWritesComplete,
            duplex.requestOpened,
            duplex.responseOpened,
            duplex.setupContinuation != nil,
            duplex.timeoutTask != nil
        )
    }

    /// Test-only visibility for proving that stream activity invalidates an
    /// already-scheduled idle-timeout generation without relying on wall time.
    func __testStreamTimeoutGeneration(id: UInt64) -> UInt64? {
        pendingStreams[id]?.timeoutGeneration
    }

    /// Test-only hook that delivers a previously scheduled timeout generation.
    /// Returns whether a pending timed stream existed; production timeout tasks
    /// use the same generation-checked path.
    func __testFireStreamTimeout(id: UInt64, generation: UInt64) -> Bool {
        guard let stream = pendingStreams[id], let timeout = stream.timeout else {
            return false
        }
        timeoutStream(id: id, timeout: timeout, generation: generation)
        return true
    }
}

// MARK: - Optional logger hook

/// Plug-in for surfacing RPC lifecycle diagnostics from `QVACClient`. Callers
/// who need a custom sink can pass an implementation to the public client
/// initializer; pass `nil` to disable logging.
///
/// Emitted log lines are intentionally raw — they describe frame events, not
/// translated application errors. For application-level errors see `QVACError`.
///
/// Example:
/// ```swift
/// struct StderrRPCLog: BareRPCLogger {
///     func log(_ level: BareRPCLogLevel, _ message: String) {
///         FileHandle.standardError.write(Data("[\(level)] \(message)\n".utf8))
///     }
/// }
/// // Then pass `StderrRPCLog()` as `QVACClient`'s `logger` argument.
/// ```
public protocol BareRPCLogger: Sendable {
    func log(_ level: BareRPCLogLevel, _ message: String)
}

/// Severity bands used by ``BareRPCLogger`` — totally ordered so consumers can
/// drop a filter implementation in front of their sink.
public enum BareRPCLogLevel: Int, Sendable, Comparable {
    case debug, info, warn, error
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}
