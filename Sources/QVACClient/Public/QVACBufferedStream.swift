import Foundation

struct QVACBufferedStreamBatchLease<Element: Sendable>: Sendable {
    let id: UInt64
    let values: [Element]
}

/// A bounded, single-consumer stream that preserves producer batches atomically.
///
/// QVAC 0.17 can place many logical values in one wire record—for example, a
/// complete non-streaming completion or thousands of PCM samples. Buffering those
/// values one by one can overflow before Swift schedules even an active consumer.
/// `QVACBufferedStream` retains whole producer batches, then flattens them lazily
/// for callers. Queued batches are bounded by count, while queued plus partially
/// consumed batches are bounded by estimated retained bytes. A waiting consumer
/// receives the next batch directly without bypassing that byte budget.
///
/// Create exactly one iterator. A second iterator fails on its first `next()`.
/// Value copies of the claimed iterator share one cursor and can be handed off
/// sequentially; concurrent `next()` calls are rejected.
public struct QVACBufferedStream<Element: Sendable>: AsyncSequence, Sendable {
    public typealias Failure = Error

    public struct AsyncIterator: AsyncIteratorProtocol {
        /// Reference-backed so ordinary value copies of an iterator advance one
        /// shared cursor instead of replaying a partially consumed producer batch.
        private let cursor: IteratorCursor

        fileprivate init(cursor: IteratorCursor) {
            self.cursor = cursor
        }

        public mutating func next() async throws -> Element? {
            try await cursor.next()
        }
    }

    /// One logical cursor shared by every value copy of the claimed iterator.
    /// The lock claims one complete async `next()` operation at a time; batch
    /// traversal then stays local and avoids an actor hop for every flattened PCM
    /// sample or completion event.
    fileprivate final class IteratorCursor: @unchecked Sendable {
        private let storage: Storage
        private let lock = NSLock()
        private var lifetime: IteratorLifetime?
        private var currentBatch: [Element] = []
        private var currentIndex = 0
        private var currentLeaseID: UInt64?
        private var initialError: Error?
        private var isReading = false

        fileprivate init(
            storage: Storage,
            lifetime: IteratorLifetime?,
            initialError: Error?
        ) {
            self.storage = storage
            self.lifetime = lifetime
            self.initialError = initialError
        }

        func next() async throws -> Element? {
            let claimed = lock.withLock {
                guard !isReading else { return false }
                isReading = true
                return true
            }
            guard claimed else {
                throw QVACError.protocolViolation(
                    "QVACBufferedStream iterator does not support concurrent next() calls"
                )
            }
            defer { lock.withLock { isReading = false } }
            do {
                try Task.checkCancellation()
                if let initialError {
                    self.initialError = nil
                    throw initialError
                }
                guard lifetime != nil else { return nil }

                while currentIndex >= currentBatch.count {
                    let lease = try await storage.nextBatch()
                    try Task.checkCancellation()
                    guard let lease else {
                        lifetime = nil
                        return nil
                    }
                    currentBatch = lease.values
                    currentIndex = 0
                    currentLeaseID = lease.id
                }

                let value = currentBatch[currentIndex]
                currentIndex += 1
                if currentIndex == currentBatch.count {
                    currentBatch.removeAll(keepingCapacity: false)
                    currentIndex = 0
                    if let completedLeaseID = currentLeaseID {
                        currentLeaseID = nil
                        storage.acknowledgeBatch(completedLeaseID)
                    }
                }
                return value
            } catch {
                currentBatch.removeAll(keepingCapacity: false)
                currentIndex = 0
                currentLeaseID = nil
                lifetime = nil
                throw error
            }
        }
    }

    fileprivate final class IteratorLifetime: @unchecked Sendable {
        private let storage: Storage

        init(storage: Storage) {
            self.storage = storage
        }

        deinit {
            storage.cancelConsumer()
        }
    }

    fileprivate final class Storage: @unchecked Sendable {
        private let channel: QVACBufferedStreamChannel<Element>
        private let lock = NSLock()
        private var iteratorClaimed = false

        init(channel: QVACBufferedStreamChannel<Element>) {
            self.channel = channel
        }

        func claimIterator() -> Bool {
            lock.withLock {
                guard !iteratorClaimed else { return false }
                iteratorClaimed = true
                return true
            }
        }

        func nextBatch() async throws -> QVACBufferedStreamBatchLease<Element>? {
            try await channel.next()
        }

        func acknowledgeBatch(_ leaseID: UInt64) {
            channel.acknowledge(leaseID: leaseID)
        }

        func cancelConsumer() {
            channel.cancelConsumer()
        }

        deinit {
            cancelConsumer()
        }
    }

    private let storage: Storage

    fileprivate init(channel: QVACBufferedStreamChannel<Element>) {
        storage = Storage(channel: channel)
    }

    public func makeAsyncIterator() -> AsyncIterator {
        guard storage.claimIterator() else {
            return AsyncIterator(
                cursor: IteratorCursor(
                    storage: storage,
                    lifetime: nil,
                    initialError: QVACError.protocolViolation(
                        "QVACBufferedStream supports exactly one iterator"
                    )
                )
            )
        }
        return AsyncIterator(
            cursor: IteratorCursor(
                storage: storage,
                lifetime: IteratorLifetime(storage: storage),
                initialError: nil
            )
        )
    }
}

/// Synchronous producer endpoint for `QVACBufferedStream`.
final class QVACBufferedStreamSink<Element: Sendable>: @unchecked Sendable {
    typealias EmissionResult = QVACBufferedStreamChannel<Element>.EmissionResult

    private let channel: QVACBufferedStreamChannel<Element>

    init(channel: QVACBufferedStreamChannel<Element>) {
        self.channel = channel
    }

    /// Enqueue one indivisible producer batch. `estimatedBytes` must describe the
    /// retained decoded representation conservatively enough for resource limiting.
    @discardableResult
    func yield(contentsOf values: [Element], estimatedBytes: Int) -> EmissionResult {
        channel.yield(values, estimatedBytes: estimatedBytes)
    }

    func finish() {
        channel.finish(throwing: nil)
    }

    func finish(throwing error: Error?) {
        channel.finish(throwing: error)
    }

    func hasPendingWaiterForTesting() -> Bool {
        channel.hasPendingWaiterForTesting()
    }

    func retainedBytesForTesting() -> Int {
        channel.retainedBytesForTesting()
    }
}

/// Lock-protected, demand-aware queue shared by the producer and one iterator.
final class QVACBufferedStreamChannel<Element: Sendable>: @unchecked Sendable {
    enum EmissionResult {
        case enqueued
        case coalesced
        case overflowed
        case terminated
    }

    private struct Batch: Sendable {
        let values: [Element]
        let estimatedBytes: Int
    }

    private struct InFlightBatch: Sendable {
        let leaseID: UInt64
        let estimatedBytes: Int
    }

    private enum Terminal {
        case finished
        case failed(Error)
    }

    private let streamName: String
    private let maximumBufferedBatches: Int
    private let maximumBufferedBytes: Int
    private let dropBehavior: QVACStreamDropBehavior
    private let lock = NSLock()
    private var queue: [Batch] = []
    /// Total bytes retained by both queued batches and the iterator's current
    /// partially consumed batch.
    private var retainedBytes = 0
    private var inFlightBatch: InFlightBatch?
    private var nextLeaseID: UInt64 = 1
    private var waiter: CheckedContinuation<QVACBufferedStreamBatchLease<Element>?, Error>?
    private var terminal: Terminal?

    init(
        streamName: String,
        maximumBufferedBatches: Int,
        maximumBufferedBytes: Int,
        dropBehavior: QVACStreamDropBehavior = .fail
    ) {
        precondition(maximumBufferedBatches > 0)
        precondition(maximumBufferedBytes > 0)
        self.streamName = streamName
        self.maximumBufferedBatches = maximumBufferedBatches
        self.maximumBufferedBytes = maximumBufferedBytes
        self.dropBehavior = dropBehavior
    }

    func yield(_ values: [Element], estimatedBytes: Int) -> EmissionResult {
        guard !values.isEmpty else { return .enqueued }
        let cost = max(1, estimatedBytes)
        var waiting: CheckedContinuation<QVACBufferedStreamBatchLease<Element>?, Error>?
        var directLease: QVACBufferedStreamBatchLease<Element>?

        lock.lock()
        guard terminal == nil else {
            lock.unlock()
            return .terminated
        }

        // No eviction can make one indivisible batch fit. Reject it without
        // discarding any previously accepted snapshots.
        if cost > maximumBufferedBytes {
            let (attemptedBytes, bytesOverflowed) = retainedBytes.addingReportingOverflow(cost)
            let overflow = QVACStreamBufferOverflow(
                stream: streamName,
                capacity: maximumBufferedBatches,
                maximumBufferedBytes: maximumBufferedBytes,
                attemptedBufferedBytes: bytesOverflowed ? Int.max : attemptedBytes
            )
            terminal = .failed(overflow)
            waiting = waiter
            waiter = nil
            lock.unlock()
            waiting?.resume(throwing: overflow)
            return .overflowed
        }

        if let current = waiter {
            let (attemptedBytes, bytesOverflowed) = retainedBytes.addingReportingOverflow(cost)
            guard !bytesOverflowed, attemptedBytes <= maximumBufferedBytes else {
                let overflow = QVACStreamBufferOverflow(
                    stream: streamName,
                    capacity: maximumBufferedBatches,
                    maximumBufferedBytes: maximumBufferedBytes,
                    attemptedBufferedBytes: bytesOverflowed ? Int.max : attemptedBytes
                )
                terminal = .failed(overflow)
                waiter = nil
                lock.unlock()
                current.resume(throwing: overflow)
                return .overflowed
            }
            waiter = nil
            waiting = current
            retainedBytes = attemptedBytes
            directLease = makeLeaseLocked(values: values, estimatedBytes: cost)
            lock.unlock()
            waiting?.resume(returning: directLease)
            return .enqueued
        }

        if dropBehavior == .coalesceNewest,
           let inFlightBatch {
            let (inFlightAndIncoming, overflowed) =
                inFlightBatch.estimatedBytes.addingReportingOverflow(cost)
            if overflowed || inFlightAndIncoming > maximumBufferedBytes {
                // The iterator's current batch cannot be revoked safely. Dropping
                // this observational snapshot keeps the stream healthy without
                // evicting already-accepted queued snapshots that still fit beside
                // the lease. A later snapshot can replace them once the lease is
                // acknowledged.
                lock.unlock()
                return .coalesced
            }
        }

        var coalesced = false
        if dropBehavior == .coalesceNewest {
            while !queue.isEmpty {
                let (attemptedBytes, bytesOverflowed) = retainedBytes.addingReportingOverflow(cost)
                let exceedsCount = queue.count >= maximumBufferedBatches
                let exceedsBytes = bytesOverflowed || attemptedBytes > maximumBufferedBytes
                guard exceedsCount || exceedsBytes else { break }
                let evicted = queue.removeFirst()
                retainedBytes -= evicted.estimatedBytes
                coalesced = true
            }
        }

        let (attemptedBytes, bytesOverflowed) = retainedBytes.addingReportingOverflow(cost)
        if queue.count >= maximumBufferedBatches
            || bytesOverflowed
            || attemptedBytes > maximumBufferedBytes {
            terminal = .failed(QVACStreamBufferOverflow(
                stream: streamName,
                capacity: maximumBufferedBatches,
                maximumBufferedBytes: maximumBufferedBytes,
                attemptedBufferedBytes: bytesOverflowed ? Int.max : attemptedBytes
            ))
            lock.unlock()
            return .overflowed
        }

        queue.append(.init(values: values, estimatedBytes: cost))
        retainedBytes = attemptedBytes
        lock.unlock()
        return coalesced ? .coalesced : .enqueued
    }

    func finish(throwing error: Error?) {
        var waiting: CheckedContinuation<QVACBufferedStreamBatchLease<Element>?, Error>?
        lock.lock()
        guard terminal == nil else {
            lock.unlock()
            return
        }
        terminal = error.map(Terminal.failed) ?? .finished
        if queue.isEmpty {
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

    func next() async throws -> QVACBufferedStreamBatchLease<Element>? {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var immediateLease: QVACBufferedStreamBatchLease<Element>?
                var immediateTerminal: Terminal?
                var registered = false

                lock.lock()
                if inFlightBatch != nil {
                    immediateTerminal = .failed(QVACError.protocolViolation(
                        "QVACBufferedStream cannot request another batch before acknowledging the current batch"
                    ))
                } else if !queue.isEmpty {
                    let batch = queue.removeFirst()
                    immediateLease = makeLeaseLocked(
                        values: batch.values,
                        estimatedBytes: batch.estimatedBytes
                    )
                } else if let terminal {
                    immediateTerminal = terminal
                } else if waiter != nil {
                    immediateTerminal = .failed(QVACError.protocolViolation(
                        "QVACBufferedStream supports only one active next() call"
                    ))
                } else {
                    waiter = continuation
                    registered = true
                }
                let cancelledAfterRegistration = registered && Task.isCancelled
                lock.unlock()

                if cancelledAfterRegistration {
                    cancelPendingNext()
                } else if let immediateLease {
                    continuation.resume(returning: immediateLease)
                } else if let immediateTerminal {
                    switch immediateTerminal {
                    case .finished:
                        continuation.resume(returning: nil)
                    case .failed(let error):
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            self.cancelPendingNext()
        }
    }

    func acknowledge(leaseID: UInt64) {
        lock.lock()
        guard let inFlightBatch, inFlightBatch.leaseID == leaseID else {
            lock.unlock()
            return
        }
        self.inFlightBatch = nil
        if inFlightBatch.estimatedBytes <= retainedBytes {
            retainedBytes -= inFlightBatch.estimatedBytes
        } else {
            // Defensive recovery for an impossible accounting invariant. Avoid an
            // integer trap or stale positive charge in production builds.
            retainedBytes = 0
        }
        lock.unlock()
    }

    func cancelConsumer() {
        var waiting: CheckedContinuation<QVACBufferedStreamBatchLease<Element>?, Error>?
        lock.lock()
        if terminal == nil { terminal = .finished }
        queue.removeAll(keepingCapacity: false)
        inFlightBatch = nil
        retainedBytes = 0
        waiting = waiter
        waiter = nil
        lock.unlock()
        waiting?.resume(returning: nil)
    }

    private func cancelPendingNext() {
        var waiting: CheckedContinuation<QVACBufferedStreamBatchLease<Element>?, Error>?
        lock.lock()
        if terminal == nil { terminal = .finished }
        queue.removeAll(keepingCapacity: false)
        inFlightBatch = nil
        retainedBytes = 0
        waiting = waiter
        waiter = nil
        lock.unlock()
        waiting?.resume(throwing: CancellationError())
    }

    /// Deterministic synchronization seam for concurrency tests. The channel is
    /// internal and this state is never exposed through the public stream API.
    func hasPendingWaiterForTesting() -> Bool {
        lock.withLock { waiter != nil }
    }

    func retainedBytesForTesting() -> Int {
        lock.withLock { retainedBytes }
    }

    private func makeLeaseLocked(
        values: [Element],
        estimatedBytes: Int
    ) -> QVACBufferedStreamBatchLease<Element> {
        precondition(inFlightBatch == nil)
        let leaseID = nextLeaseID
        nextLeaseID &+= 1
        if nextLeaseID == 0 { nextLeaseID = 1 }
        inFlightBatch = .init(leaseID: leaseID, estimatedBytes: estimatedBytes)
        return .init(id: leaseID, values: values)
    }
}

extension QVACClient {
    internal static func makeBufferedStream<T: Sendable>(
        of: T.Type,
        name: String,
        maximumBufferedBytes: Int
    ) -> (QVACBufferedStream<T>, QVACBufferedStreamSink<T>) {
        let channel = QVACBufferedStreamChannel<T>(
            streamName: name,
            maximumBufferedBatches: publicStreamBufferCapacity,
            maximumBufferedBytes: maximumBufferedBytes
        )
        return (
            QVACBufferedStream(channel: channel),
            QVACBufferedStreamSink(channel: channel)
        )
    }

    /// Creates a byte-bounded observational stream that retains the newest
    /// snapshots. Eviction affects this view only; operation owners must keep the
    /// authoritative aggregate/result on an independent path.
    internal static func makeCoalescingProgressStream<T: Sendable>(
        of: T.Type,
        name: String,
        maximumBufferedBytes: Int
    ) -> (QVACBufferedStream<T>, QVACBufferedStreamSink<T>) {
        let channel = QVACBufferedStreamChannel<T>(
            streamName: name,
            maximumBufferedBatches: publicProgressBufferCapacity,
            maximumBufferedBytes: maximumBufferedBytes,
            dropBehavior: .coalesceNewest
        )
        return (
            QVACBufferedStream(channel: channel),
            QVACBufferedStreamSink(channel: channel)
        )
    }

    /// Fail-closed fallback for a decoded value without an allocation-free retained-
    /// size specialization. Buffer admission must never JSON-encode an untrusted
    /// value merely to measure it: that would allocate before the byte ceiling is
    /// enforced. Known wire/public types use the overloads below; an accidental new
    /// call site is rejected by charging one byte beyond its supplied budget.
    internal static func conservativeBufferedJSONBytes<T>(
        _ value: T,
        elementCount: Int,
        fallback: Int
    ) -> Int {
        _ = value
        _ = elementCount
        return QVACBufferedJSONRetainedSizeEstimator.saturatingAdd(
            max(1, fallback),
            1
        )
    }

    /// JSON values are measured from their already-decoded storage. A deeply nested
    /// tree of tiny containers can retain far more memory than its compact wire
    /// representation suggests, so encoded length is neither necessary nor safe as
    /// the admission metric.
    internal static func conservativeBufferedJSONBytes(
        _ value: JSONValue,
        elementCount: Int,
        fallback: Int
    ) -> Int {
        _ = fallback
        let retainedBytes = QVACBufferedJSONRetainedSizeEstimator.estimate(value)
        guard retainedBytes != Int.max else { return Int.max }
        return conservativeKnownBufferedBytes(
            JSONValue.self,
            elementCount: max(1, elementCount),
            variableBytes: retainedBytes
        )
    }

    /// Specialization for the JSON event arrays used by completion, OCR, and
    /// batch-completion streams. The actual array count wins over a smaller
    /// caller-provided logical count so internal misuse cannot under-account it.
    internal static func conservativeBufferedJSONBytes(
        _ value: [JSONValue],
        elementCount: Int,
        fallback: Int
    ) -> Int {
        _ = fallback
        let retainedBytes = QVACBufferedJSONRetainedSizeEstimator.estimate(value)
        guard retainedBytes != Int.max else { return Int.max }
        return conservativeKnownBufferedBytes(
            [JSONValue].self,
            elementCount: max(value.count, elementCount),
            variableBytes: retainedBytes
        )
    }

    /// Allocation-free specialization for terminal batch identifiers.
    internal static func conservativeBufferedJSONBytes(
        _ value: [String],
        elementCount: Int,
        fallback: Int
    ) -> Int {
        _ = fallback
        let retainedBytes = QVACBufferedJSONRetainedSizeEstimator.estimate(value)
        guard retainedBytes != Int.max else { return Int.max }
        return conservativeKnownBufferedBytes(
            [String].self,
            elementCount: max(value.count, elementCount),
            variableBytes: retainedBytes
        )
    }

    internal static func conservativeBufferedJSONBytes(
        _ value: ModelProgressResponse,
        elementCount: Int,
        fallback: Int
    ) -> Int {
        _ = fallback
        var variableBytes = QVACBufferedJSONRetainedSizeEstimator.retainedStringBytes(
            value.downloadKey
        )
        if let fileSetInfo = value.fileSetInfo {
            variableBytes = QVACBufferedJSONRetainedSizeEstimator.saturatingAdd(
                variableBytes,
                QVACBufferedJSONRetainedSizeEstimator.estimate(fileSetInfo)
            )
        }
        if let shardInfo = value.shardInfo {
            variableBytes = QVACBufferedJSONRetainedSizeEstimator.saturatingAdd(
                variableBytes,
                QVACBufferedJSONRetainedSizeEstimator.estimate(shardInfo)
            )
        }
        return conservativeKnownBufferedBytes(
            ModelProgressResponse.self,
            elementCount: elementCount,
            variableBytes: variableBytes
        )
    }

    internal static func conservativeBufferedJSONBytes(
        _ value: FinetuneProgressResponse,
        elementCount: Int,
        fallback: Int
    ) -> Int {
        _ = fallback
        var variableBytes = QVACBufferedJSONRetainedSizeEstimator.retainedStringBytes(
            value.modelId
        )
        for json in [value.accuracy, value.accuracyUncertainty, value.loss, value.lossUncertainty] {
            variableBytes = QVACBufferedJSONRetainedSizeEstimator.saturatingAdd(
                variableBytes,
                QVACBufferedJSONRetainedSizeEstimator.estimate(json)
            )
        }
        return conservativeKnownBufferedBytes(
            FinetuneProgressResponse.self,
            elementCount: elementCount,
            variableBytes: variableBytes
        )
    }

    internal static func conservativeBufferedJSONBytes(
        _ value: RagProgressResponse,
        elementCount: Int,
        fallback: Int
    ) -> Int {
        _ = fallback
        let strings = [value.operation, value.stage, value.workspace]
        return conservativeKnownBufferedBytes(
            RagProgressResponse.self,
            elementCount: elementCount,
            variableBytes: QVACBufferedJSONRetainedSizeEstimator.estimate(strings)
        )
    }

    internal static func conservativeBufferedJSONBytes(
        _ value: TextToSpeechResponse,
        elementCount: Int,
        fallback: Int
    ) -> Int {
        _ = fallback
        var variableBytes = QVACBufferedJSONRetainedSizeEstimator.saturatingMultiply(
            value.buffer.count,
            64
        )
        if let sentenceChunk = value.sentenceChunk {
            variableBytes = QVACBufferedJSONRetainedSizeEstimator.saturatingAdd(
                variableBytes,
                QVACBufferedJSONRetainedSizeEstimator.retainedStringBytes(sentenceChunk)
            )
        }
        if let stats = value.stats {
            variableBytes = QVACBufferedJSONRetainedSizeEstimator.saturatingAdd(
                variableBytes,
                QVACBufferedJSONRetainedSizeEstimator.estimate(stats)
            )
        }
        return conservativeKnownBufferedBytes(
            TextToSpeechResponse.self,
            elementCount: elementCount,
            variableBytes: variableBytes
        )
    }

    internal static func conservativeBufferedJSONBytes(
        _ value: TranslateResponse,
        elementCount: Int,
        fallback: Int
    ) -> Int {
        _ = fallback
        var variableBytes = QVACBufferedJSONRetainedSizeEstimator.retainedStringBytes(value.token)
        if let error = value.error {
            variableBytes = QVACBufferedJSONRetainedSizeEstimator.saturatingAdd(
                variableBytes,
                QVACBufferedJSONRetainedSizeEstimator.retainedStringBytes(error)
            )
        }
        if let stats = value.stats {
            variableBytes = QVACBufferedJSONRetainedSizeEstimator.saturatingAdd(
                variableBytes,
                QVACBufferedJSONRetainedSizeEstimator.estimate(stats)
            )
        }
        return conservativeKnownBufferedBytes(
            TranslateResponse.self,
            elementCount: elementCount,
            variableBytes: variableBytes
        )
    }

    internal static func conservativeBufferedJSONBytes(
        _ value: DiffusionProgressTick,
        elementCount: Int,
        fallback: Int
    ) -> Int {
        _ = value
        _ = fallback
        return conservativeKnownBufferedBytes(
            DiffusionProgressTick.self,
            elementCount: elementCount,
            variableBytes: 0
        )
    }

    internal static func conservativeBufferedJSONBytes(
        _ value: VideoProgressTick,
        elementCount: Int,
        fallback: Int
    ) -> Int {
        _ = value
        _ = fallback
        return conservativeKnownBufferedBytes(
            VideoProgressTick.self,
            elementCount: elementCount,
            variableBytes: 0
        )
    }

    internal static func conservativeBufferedJSONBytes(
        _ value: AudioGenProgress,
        elementCount: Int,
        fallback: Int
    ) -> Int {
        _ = fallback
        return conservativeKnownBufferedBytes(
            AudioGenProgress.self,
            elementCount: elementCount,
            variableBytes: QVACBufferedJSONRetainedSizeEstimator.retainedStringBytes(value.stage)
        )
    }

    private static func conservativeKnownBufferedBytes<T>(
        _ type: T.Type,
        elementCount: Int,
        variableBytes: Int
    ) -> Int {
        let elementOverhead = QVACBufferedJSONRetainedSizeEstimator.saturatingMultiply(
            max(0, elementCount),
            128
        )
        // This covers the public batch/element containers plus the decoded response
        // and transport-envelope objects alive during handoff. The previous
        // encoder-based estimate implicitly included those copies via a second JSON
        // buffer; keep the ceiling conservative without performing that allocation.
        let rootOverhead = QVACBufferedJSONRetainedSizeEstimator.saturatingAdd(
            MemoryLayout<T>.stride,
            512
        )
        return max(
            1,
            QVACBufferedJSONRetainedSizeEstimator.saturatingAdd(
                QVACBufferedJSONRetainedSizeEstimator.saturatingAdd(variableBytes, elementOverhead),
                rootOverhead
            )
        )
    }
}

/// Conservative retained-memory accounting for decoded JSON trees.
///
/// Every enum node, collection backing store, dictionary entry, key, and scalar
/// contributes to the estimate. Arithmetic saturates at `Int.max`; overestimating
/// is intentional because this value enforces a resource ceiling, not telemetry.
enum QVACBufferedJSONRetainedSizeEstimator {
    /// Decoded worker JSON is shallower than this in practice. Failing closed at
    /// this boundary also protects callers that construct public `JSONValue`
    /// instances directly from untrusted recursive input.
    static let maximumNestingDepth = 256

    private static let collectionAllocationOverhead = 64
    private static let dictionaryEntryOverhead = 64
    private static let stringAllocationOverhead = 32

    static func estimate(_ value: JSONValue) -> Int {
        estimate(value, nestingDepth: 0)
    }

    private static func estimate(_ value: JSONValue, nestingDepth: Int) -> Int {
        guard nestingDepth <= maximumNestingDepth else { return Int.max }
        let nodeBytes = MemoryLayout<JSONValue>.stride
        switch value {
        case .null:
            return saturatingAdd(nodeBytes, 1)
        case .bool:
            return saturatingAdd(nodeBytes, MemoryLayout<Bool>.stride)
        case .number:
            return saturatingAdd(nodeBytes, MemoryLayout<Double>.stride)
        case .string(let string):
            return saturatingAdd(nodeBytes, retainedStringBytes(string))
        case .array(let values):
            return saturatingAdd(
                nodeBytes,
                estimate(values, childNestingDepth: nestingDepth + 1)
            )
        case .object(let values):
            var total = saturatingAdd(
                nodeBytes,
                MemoryLayout<[String: JSONValue]>.stride
            )
            total = saturatingAdd(total, collectionAllocationOverhead)
            total = saturatingAdd(
                total,
                saturatingMultiply(values.count, dictionaryEntryOverhead)
            )
            for (key, child) in values {
                total = saturatingAdd(total, retainedStringBytes(key))
                total = saturatingAdd(
                    total,
                    estimate(child, nestingDepth: nestingDepth + 1)
                )
                if total == Int.max { return Int.max }
            }
            return total
        }
    }

    static func estimate(_ values: [JSONValue]) -> Int {
        estimate(values, childNestingDepth: 1)
    }

    private static func estimate(
        _ values: [JSONValue],
        childNestingDepth: Int
    ) -> Int {
        var total = saturatingAdd(
            MemoryLayout<[JSONValue]>.stride,
            collectionAllocationOverhead
        )
        // Decoded arrays may retain spare capacity. Charging one additional enum
        // slot per live element safely covers ordinary geometric capacity growth.
        total = saturatingAdd(
            total,
            saturatingMultiply(values.count, MemoryLayout<JSONValue>.stride)
        )
        for value in values {
            total = saturatingAdd(
                total,
                estimate(value, nestingDepth: childNestingDepth)
            )
            if total == Int.max { return Int.max }
        }
        return total
    }

    static func estimate(_ values: [String]) -> Int {
        var total = saturatingAdd(
            MemoryLayout<[String]>.stride,
            collectionAllocationOverhead
        )
        total = saturatingAdd(
            total,
            saturatingMultiply(values.count, MemoryLayout<String>.stride * 2)
        )
        for value in values {
            total = saturatingAdd(total, retainedStringBytes(value))
            if total == Int.max { return Int.max }
        }
        return total
    }

    static func retainedStringBytes(_ value: String) -> Int {
        saturatingAdd(
            saturatingAdd(MemoryLayout<String>.stride, stringAllocationOverhead),
            saturatingMultiply(value.utf8.count, 2)
        )
    }

    static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        guard lhs >= 0, rhs >= 0 else { return Int.max }
        let (sum, overflowed) = lhs.addingReportingOverflow(rhs)
        return overflowed ? Int.max : sum
    }

    static func saturatingMultiply(_ lhs: Int, _ rhs: Int) -> Int {
        guard lhs >= 0, rhs >= 0 else { return Int.max }
        let (product, overflowed) = lhs.multipliedReportingOverflow(by: rhs)
        return overflowed ? Int.max : product
    }
}
