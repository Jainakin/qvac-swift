import Foundation

/// A pull-driven, single-consumer stream of live RPC responses.
///
/// The stream owns a server-side RPC operation. Dropping its iterator (including
/// leaving a `for try await` loop with `break`) cancels that operation even when
/// the `QVACResponseStream` value itself remains retained. This differs from
/// `AsyncThrowingStream`, whose termination callback is tied to the sequence's
/// storage rather than to an individual iterator.
///
/// Create exactly one iterator. A second iterator fails on its first `next()`
/// call with ``QVACError/protocolViolation(_:)``. Call ``cancel()`` when the
/// stream must be stopped before iteration starts or when an owner tears down
/// the operation explicitly.
public struct QVACResponseStream<Element: Sendable>: AsyncSequence, Sendable {
    public typealias Failure = Error

    /// The single consumer for a ``QVACResponseStream``.
    public struct AsyncIterator: AsyncIteratorProtocol {
        private let storage: Storage
        private var lifetime: IteratorLifetime?
        private var initialError: Error?

        fileprivate init(
            storage: Storage,
            lifetime: IteratorLifetime?,
            initialError: Error?
        ) {
            self.storage = storage
            self.lifetime = lifetime
            self.initialError = initialError
        }

        public mutating func next() async throws -> Element? {
            if let initialError {
                self.initialError = nil
                throw initialError
            }
            guard lifetime != nil else { return nil }
            do {
                let value = try await storage.next()
                if value == nil {
                    lifetime = nil
                }
                return value
            } catch {
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
            storage.cancel()
        }
    }

    fileprivate final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private let nextOperation: @Sendable () async throws -> Element?
        private var termination: (@Sendable () -> Void)?
        private var iteratorClaimed = false
        private var cancelled = false

        init(
            unfolding nextOperation: @escaping @Sendable () async throws -> Element?,
            onTermination: @escaping @Sendable () -> Void
        ) {
            self.nextOperation = nextOperation
            self.termination = onTermination
        }

        func claimIterator() -> Bool {
            lock.withLock {
                guard !iteratorClaimed else { return false }
                iteratorClaimed = true
                return true
            }
        }

        func next() async throws -> Element? {
            let isCancelled = lock.withLock { cancelled }
            guard !isCancelled else { return nil }
            return try await nextOperation()
        }

        func cancel() {
            let action: (@Sendable () -> Void)? = lock.withLock {
                cancelled = true
                defer { termination = nil }
                return termination
            }
            action?()
        }

        deinit {
            cancel()
        }
    }

    private let storage: Storage

    init(
        unfolding nextOperation: @escaping @Sendable () async throws -> Element?,
        onTermination: @escaping @Sendable () -> Void
    ) {
        storage = Storage(unfolding: nextOperation, onTermination: onTermination)
    }

    public func makeAsyncIterator() -> AsyncIterator {
        guard storage.claimIterator() else {
            return AsyncIterator(
                storage: storage,
                lifetime: nil,
                initialError: QVACError.protocolViolation(
                    "QVACResponseStream supports exactly one iterator"
                )
            )
        }
        return AsyncIterator(
            storage: storage,
            lifetime: IteratorLifetime(storage: storage),
            initialError: nil
        )
    }

    /// Cancel the live RPC operation. This method is idempotent.
    public func cancel() {
        storage.cancel()
    }
}
