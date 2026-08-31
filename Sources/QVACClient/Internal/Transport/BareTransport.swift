// BareTransport — abstraction over the byte-level link between the Swift host
// and the Bare worker. Two concrete implementations exist:
//
//   • UnixDomainSocketTransport  — macOS: spawns `bare worker.js` and connects via UDS.
//   • BareIPCTransport           — iOS: wraps BareKit's `BareIPC` for the in-process worklet.
//
// The contract is intentionally narrow:
//   – inboundStream() yields server bytes as they arrive (any framing handled higher up).
//   – write(_:) sends bytes (caller-managed framing).
//   – close() tears down resources.
//
// All implementations are actors or actor-like (must be Sendable) and produce frames
// suitable for BareRPCClient.

import Foundation

protocol BareTransport: Sendable {
    /// AsyncThrowingStream of raw inbound bytes from the worker. Terminates on EOF or error.
    func inboundStream() -> AsyncThrowingStream<Data, Error>
    /// Write bytes to the worker. Throws on disconnection.
    func write(_ data: Data) async throws
    /// Tear down the link. Idempotent.
    func close() async
}

/// The worker produced bytes faster than the client could parse them. Transport
/// buffering is bounded independently of per-operation stream buffering so a
/// flooding peer cannot exhaust memory before bare-rpc frame demultiplexing.
struct BareTransportInboundBufferOverflow: Error, Sendable, Equatable, CustomStringConvertible {
    let maximumBufferedBytes: Int
    let attemptedBufferedBytes: Int

    var description: String {
        "transport inbound buffer would grow to \(attemptedBufferedBytes) bytes; "
            + "maximum is \(maximumBufferedBytes)"
    }
}

/// Single-consumer, byte-bounded channel shared by both concrete transports.
/// Overflow is terminal and explicit: queued bytes are discarded and the caller
/// closes the connection, so protocol bytes are never silently dropped.
final class BoundedTransportInboundChannel: @unchecked Sendable {
    /// Keep transport delivery granular even when an adapter (notably BareIPC)
    /// returns one very large read. This bounds per-yield decoder work and prevents
    /// a coalesced message from expanding into a huge pending-frame array at once.
    static let maximumDeliveryChunkBytes = 64 * 1024

    private enum Terminal {
        case finished
        case failed(Error)
    }

    private let maximumBufferedBytes: Int
    private let lock = NSLock()
    private var queue: [Data] = []
    private var queueIndex = 0
    private var bufferedBytes = 0
    private var waiter: CheckedContinuation<Data?, Error>?
    private var terminal: Terminal?
    private var claimed = false
    private var cancellationReported = false
    private var cancellationHandler: (@Sendable () -> Void)?

    init(maximumBufferedBytes: Int) {
        self.maximumBufferedBytes = maximumBufferedBytes
    }

    func setCancellationHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { cancellationHandler = handler }
    }

    func stream() -> AsyncThrowingStream<Data, Error> {
        let firstClaim = lock.withLock { () -> Bool in
            guard !claimed else { return false }
            claimed = true
            return true
        }
        guard firstClaim else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: BareRPCProtocolError(
                    "transport inboundStream() may be claimed only once"
                ))
            }
        }
        return AsyncThrowingStream(unfolding: { try await self.next() })
    }

    func yield(_ value: Data) -> BareTransportInboundBufferOverflow? {
        guard value.count > Self.maximumDeliveryChunkBytes else {
            return yieldOne(value)
        }

        var start = value.startIndex
        while start < value.endIndex {
            let remaining = value.distance(from: start, to: value.endIndex)
            let count = min(Self.maximumDeliveryChunkBytes, remaining)
            let end = value.index(start, offsetBy: count)
            if let overflow = yieldOne(Data(value[start..<end])) {
                return overflow
            }
            start = end
        }
        return nil
    }

    private func yieldOne(_ value: Data) -> BareTransportInboundBufferOverflow? {
        var waiting: CheckedContinuation<Data?, Error>?
        var failure: BareTransportInboundBufferOverflow?
        lock.lock()
        guard terminal == nil else {
            lock.unlock()
            return nil
        }
        let (attempted, arithmeticOverflow) = bufferedBytes.addingReportingOverflow(value.count)
        if value.count > maximumBufferedBytes || arithmeticOverflow || attempted > maximumBufferedBytes {
            let error = BareTransportInboundBufferOverflow(
                maximumBufferedBytes: maximumBufferedBytes,
                attemptedBufferedBytes: arithmeticOverflow ? Int.max : attempted
            )
            failure = error
            terminal = .failed(error)
            queue.removeAll(keepingCapacity: false)
            queueIndex = 0
            bufferedBytes = 0
            waiting = waiter
            waiter = nil
        } else if let current = waiter {
            waiter = nil
            waiting = current
        } else {
            queue.append(value)
            bufferedBytes = attempted
        }
        lock.unlock()

        if let failure {
            waiting?.resume(throwing: failure)
            return failure
        }
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
            bufferedBytes = 0
        }
        if queueIndex >= queue.count {
            waiting = waiter
            waiter = nil
        }
        lock.unlock()

        if let error { waiting?.resume(throwing: error) }
        else { waiting?.resume(returning: nil) }
    }

    private func next() async throws -> Data? {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var immediate: Data?
                var completed: Terminal?
                var registered = false
                lock.lock()
                if queueIndex < queue.count {
                    immediate = queue[queueIndex]
                    bufferedBytes -= immediate?.count ?? 0
                    queueIndex += 1
                    if queueIndex >= 64, queueIndex >= queue.count / 2 {
                        queue.removeFirst(queueIndex)
                        queueIndex = 0
                    }
                } else if let terminal {
                    completed = terminal
                } else if waiter != nil {
                    completed = .failed(BareRPCProtocolError(
                        "transport inbound stream supports only one active iterator"
                    ))
                } else {
                    waiter = continuation
                    registered = true
                }
                let cancelled = Task.isCancelled
                lock.unlock()

                if cancelled {
                    if registered { cancelPendingNext() }
                    else { continuation.resume(throwing: CancellationError()) }
                } else if let immediate {
                    continuation.resume(returning: immediate)
                } else if let completed {
                    switch completed {
                    case .finished: continuation.resume(returning: nil)
                    case .failed(let error): continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            self.cancelPendingNext()
        }
    }

    private func cancelPendingNext() {
        let result: (
            CheckedContinuation<Data?, Error>?,
            (@Sendable () -> Void)?
        ) = lock.withLock {
            defer { waiter = nil }
            guard !cancellationReported, terminal == nil else { return (waiter, nil) }
            cancellationReported = true
            terminal = .failed(CancellationError())
            queue.removeAll(keepingCapacity: false)
            queueIndex = 0
            bufferedBytes = 0
            return (waiter, cancellationHandler)
        }
        result.0?.resume(throwing: CancellationError())
        result.1?()
    }
}
