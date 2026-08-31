import Foundation

/// A bounded public event/progress view could not keep up with its producer.
///
/// QVAC run results continue aggregating independently; only the lagging view is
/// terminated. This makes data loss explicit while keeping memory use bounded.
public struct QVACStreamBufferOverflow: Error, Sendable, Equatable, CustomStringConvertible {
    public let stream: String
    public let capacity: Int

    public init(stream: String, capacity: Int) {
        self.stream = stream
        self.capacity = capacity
    }

    public var description: String {
        "QVAC stream '\(stream)' exceeded its \(capacity)-element buffer"
    }
}

/// Synchronous producer endpoint for a bounded `AsyncThrowingStream`.
/// A dropped element terminates the view with an explicit overflow error; it is never
/// silently discarded. The operation's aggregate result task may continue separately.
final class QVACStreamSink<Element: Sendable>: @unchecked Sendable {
    enum EmissionResult {
        case enqueued
        case overflowed
        case terminated
    }

    private let continuation: AsyncThrowingStream<Element, Error>.Continuation
    private let terminationRelay: QVACStreamTerminationRelay
    private let streamName: String
    private let capacity: Int
    private let lock = NSLock()
    private var terminated = false

    init(
        continuation: AsyncThrowingStream<Element, Error>.Continuation,
        terminationRelay: QVACStreamTerminationRelay,
        streamName: String,
        capacity: Int
    ) {
        self.continuation = continuation
        self.terminationRelay = terminationRelay
        self.streamName = streamName
        self.capacity = capacity
    }

    /// Register cleanup for consumer cancellation/deallocation. Registration is safe
    /// after termination; in that case the cleanup runs immediately.
    func onTermination(_ handler: @escaping @Sendable () -> Void) {
        terminationRelay.register(handler)
    }

    @discardableResult
    func yield(_ value: Element) -> EmissionResult {
        lock.lock()
        guard !terminated else {
            lock.unlock()
            return .terminated
        }
        let result = continuation.yield(value)
        switch result {
        case .enqueued:
            lock.unlock()
            return .enqueued
        case .dropped:
            terminated = true
            lock.unlock()
            continuation.finish(throwing: QVACStreamBufferOverflow(
                stream: streamName,
                capacity: capacity
            ))
            return .overflowed
        case .terminated:
            terminated = true
            lock.unlock()
            return .terminated
        @unknown default:
            terminated = true
            lock.unlock()
            continuation.finish(throwing: QVACStreamBufferOverflow(
                stream: streamName,
                capacity: capacity
            ))
            return .overflowed
        }
    }

    func finish() {
        finish(throwing: nil)
    }

    func finish(throwing error: Error?) {
        lock.lock()
        guard !terminated else {
            lock.unlock()
            return
        }
        terminated = true
        lock.unlock()
        continuation.finish(throwing: error)
    }
}

final class QVACStreamTerminationRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable () -> Void)?
    private var terminated = false

    func register(_ newHandler: @escaping @Sendable () -> Void) {
        lock.lock()
        if terminated {
            lock.unlock()
            newHandler()
            return
        }
        handler = newHandler
        lock.unlock()
    }

    func signal() {
        lock.lock()
        guard !terminated else {
            lock.unlock()
            return
        }
        terminated = true
        let current = handler
        handler = nil
        lock.unlock()
        current?()
    }
}
