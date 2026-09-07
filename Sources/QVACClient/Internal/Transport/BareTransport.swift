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

/// Single-consumer, retained-memory-bounded channel shared by both concrete
/// transports. Overflow is terminal and explicit: queued bytes are discarded and
/// the caller closes the connection, so protocol bytes are never silently dropped.
final class BoundedTransportInboundChannel: @unchecked Sendable {
    /// Keep transport delivery granular even when an adapter (notably BareIPC)
    /// returns one very large read. This bounds per-yield decoder work and prevents
    /// a coalesced message from expanding into a huge pending-frame array at once.
    static let maximumDeliveryChunkBytes = 64 * 1024

    /// Conservative allowance for each `Data` value, queue slot, spare `Array`
    /// capacity, and allocator bookkeeping. Charging this independently of payload
    /// bytes prevents empty or tiny transport reads from bypassing the memory bound.
    static let retainedValueOverheadBytes = 64

    /// Returns the retained-memory budget required to admit one complete bare-rpc
    /// frame at the configured body limit regardless of nonempty transport callback
    /// fragmentation. The channel adds the four-byte wire prefix, coalesces queued
    /// bytes into bounded delivery chunks, and allows one additional logical value
    /// to be leased to the active consumer. All arithmetic is checked so
    /// configuration cannot wrap into an undersized memory budget.
    static func retainedCapacity(maximumWireMessageBytes: Int) -> Int? {
        guard maximumWireMessageBytes > 0 else { return nil }

        let (wireBytes, prefixOverflowed) = maximumWireMessageBytes
            .addingReportingOverflow(MemoryLayout<UInt32>.size)
        guard !prefixOverflowed else { return nil }

        let fullChunks = wireBytes / maximumDeliveryChunkBytes
        let partialChunk = wireBytes.isMultiple(of: maximumDeliveryChunkBytes) ? 0 : 1
        let (chunkCount, chunkCountOverflowed) = fullChunks.addingReportingOverflow(partialChunk)
        guard !chunkCountOverflowed else { return nil }

        let (retainedValueCount, retainedValueCountOverflowed) = chunkCount
            .addingReportingOverflow(1)
        guard !retainedValueCountOverflowed else { return nil }

        let (structuralBytes, structuralOverflowed) = retainedValueCount
            .multipliedReportingOverflow(by: retainedValueOverheadBytes)
        guard !structuralOverflowed else { return nil }

        let (capacity, capacityOverflowed) = wireBytes.addingReportingOverflow(structuralBytes)
        return capacityOverflowed ? nil : capacity
    }

    /// Fail-closed default used by low-level transports. The configured frame size
    /// is a small UInt32-bounded constant, so zero can only surface if that invariant
    /// is changed without updating the checked capacity calculation.
    static let defaultMaximumBufferedBytes = retainedCapacity(
        maximumWireMessageBytes: BareRPCFrameReader.defaultMaxFrameSize
    ) ?? 0

    private struct RetainedValue {
        var data: Data
        var chargedBytes: Int
    }

    private enum Terminal {
        case finished
        case failed(Error)
    }

    private let maximumBufferedBytes: Int
    private let lock = NSLock()
    /// Consumed slots are cleared immediately so periodic prefix compaction does not
    /// retain their `Data` storage.
    private var queue: [RetainedValue?] = []
    private var queueIndex = 0
    /// Includes queued values and the value leased to the active consumer. The lease
    /// is acknowledged when that consumer asks for its next value.
    private var bufferedBytes = 0
    private var inFlightBytes = 0
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
        // Callback boundaries are not semantic boundaries. When no consumer is
        // waiting, merge nonempty bytes into the active queue tail until it reaches
        // the delivery limit. This keeps retained-value overhead proportional to
        // logical 64 KiB deliveries rather than to arbitrary native read sizes.
        // Empty values remain distinct and fully charged so they cannot bypass the
        // retained-memory bound or be reordered across nonempty data.
        var mergeCount = 0
        var mergeIndex: Int?
        if waiter == nil, !value.isEmpty,
           let lastIndex = queue.indices.last,
           lastIndex >= queueIndex,
           queue[lastIndex]?.data.isEmpty == false {
            let tailCount = queue[lastIndex]!.data.count
            if tailCount < Self.maximumDeliveryChunkBytes {
                mergeIndex = lastIndex
                mergeCount = min(
                    value.count,
                    Self.maximumDeliveryChunkBytes - tailCount
                )
            }
        }
        let createsRetainedValue = mergeCount < value.count || value.isEmpty
        let structuralCharge = createsRetainedValue ? Self.retainedValueOverheadBytes : 0
        let (chargedBytes, chargeOverflowed) = value.count.addingReportingOverflow(
            structuralCharge
        )
        let (attempted, totalOverflowed) = bufferedBytes.addingReportingOverflow(chargedBytes)
        if chargeOverflowed || totalOverflowed || attempted > maximumBufferedBytes {
            let error = BareTransportInboundBufferOverflow(
                maximumBufferedBytes: maximumBufferedBytes,
                attemptedBufferedBytes: chargeOverflowed || totalOverflowed ? Int.max : attempted
            )
            failure = error
            terminal = .failed(error)
            queue.removeAll(keepingCapacity: false)
            queueIndex = 0
            inFlightBytes = 0
            bufferedBytes = 0
            waiting = waiter
            waiter = nil
        } else if let current = waiter {
            waiter = nil
            waiting = current
            inFlightBytes = chargedBytes
        } else {
            if let mergeIndex, mergeCount > 0 {
                // Mutate through Array's modify accessor. Copying the tail to a
                // temporary first would keep the old Data storage alive and force
                // copy-on-write for every tiny callback.
                queue[mergeIndex]!.data.append(contentsOf: value.prefix(mergeCount))
                queue[mergeIndex]!.chargedBytes += mergeCount
            }
            if createsRetainedValue {
                let remainder = mergeCount == 0
                    ? value
                    : Data(value.dropFirst(mergeCount))
                queue.append(RetainedValue(
                    data: remainder,
                    chargedBytes: remainder.count + Self.retainedValueOverheadBytes
                ))
            }
        }
        if failure == nil { bufferedBytes = attempted }
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
            inFlightBytes = 0
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
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let value: Data? = try await withCheckedThrowingContinuation { continuation in
                var immediate: Data?
                var completed: Terminal?
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
                    immediate = retainedValue?.data
                    inFlightBytes = retainedValue?.chargedBytes ?? 0
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
                let cancelledAfterRegistration = registered && Task.isCancelled
                lock.unlock()

                if cancelledAfterRegistration {
                    cancelPendingNext()
                } else if let immediate {
                    continuation.resume(returning: immediate)
                } else if let completed {
                    switch completed {
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

    private func cancelPendingNext() {
        let result: (
            CheckedContinuation<Data?, Error>?,
            (@Sendable () -> Void)?
        ) = lock.withLock {
            defer { waiter = nil }
            let wasActive = terminal == nil
            if wasActive { terminal = .failed(CancellationError()) }
            queue.removeAll(keepingCapacity: false)
            queueIndex = 0
            inFlightBytes = 0
            bufferedBytes = 0
            let shouldReport = !cancellationReported && wasActive
            cancellationReported = true
            return (waiter, shouldReport ? cancellationHandler : nil)
        }
        result.0?.resume(throwing: CancellationError())
        result.1?()
    }

    /// Release the accounting lease for the value returned by the preceding
    /// `next()` call. The channel no longer retains that value after dequeue, but
    /// keeping its charge until the consumer advances bounds producer lead.
    private func acknowledgeInFlightLocked() {
        guard inFlightBytes > 0 else { return }
        if inFlightBytes <= bufferedBytes {
            bufferedBytes -= inFlightBytes
        } else {
            // Fail closed to coherent accounting rather than trapping if internal
            // state is ever corrupted.
            bufferedBytes = 0
        }
        inFlightBytes = 0
    }

    /// Deterministic visibility for retained-memory and cancellation regressions.
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
