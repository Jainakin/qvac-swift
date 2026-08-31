import Foundation

/// One pull-mapping action for a source element.
enum QVACPullMapDecision<Element: Sendable>: Sendable {
    case emit(Element)
    case emitMany([Element])
    case emitThenFinish([Element])
    case skip
    case finish
}

extension QVACClient {
    /// Map a single public sequence without an eager bridge task or second queue.
    /// Backpressure therefore reaches the byte-bounded transport unchanged.
    static func pullMap<Input: Sendable, Output: Sendable>(
        _ source: QVACResponseStream<Input>,
        onTermination: @escaping @Sendable () -> Void = {},
        endOfSourceError: @escaping @Sendable () -> Error? = { nil },
        transform: @escaping @Sendable (Input) throws -> QVACPullMapDecision<Output>
    ) -> QVACResponseStream<Output> {
        let termination = QVACPullStreamTermination {
            source.cancel()
            onTermination()
        }
        let driver = QVACPullMappedStreamDriver(
            source: source,
            termination: termination,
            endOfSourceError: endOfSourceError,
            transform: transform
        )
        return QVACResponseStream<Output>(unfolding: {
            try await driver.next()
        }, onTermination: {
            termination.run()
        })
    }
}

private final class QVACPullStreamTermination: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable () -> Void)?

    init(_ handler: @escaping @Sendable () -> Void) {
        self.handler = handler
    }

    func run() {
        let current: (@Sendable () -> Void)? = lock.withLock {
            defer { handler = nil }
            return handler
        }
        current?()
    }
}

private actor QVACPullMappedStreamDriver<Input: Sendable, Output: Sendable> {
    private final class IteratorBox: @unchecked Sendable {
        var iterator: QVACResponseStream<Input>.AsyncIterator

        init(_ source: QVACResponseStream<Input>) {
            iterator = source.makeAsyncIterator()
        }

        func next() async throws -> Input? {
            try await iterator.next()
        }
    }

    private let iterator: IteratorBox
    private let termination: QVACPullStreamTermination
    private let endOfSourceError: @Sendable () -> Error?
    private let transform: @Sendable (Input) throws -> QVACPullMapDecision<Output>
    private var finished = false
    private var isReading = false
    private var pending: [Output] = []
    private var pendingIndex = 0
    private var finishAfterPending = false

    init(
        source: QVACResponseStream<Input>,
        termination: QVACPullStreamTermination,
        endOfSourceError: @escaping @Sendable () -> Error?,
        transform: @escaping @Sendable (Input) throws -> QVACPullMapDecision<Output>
    ) {
        iterator = IteratorBox(source)
        self.termination = termination
        self.endOfSourceError = endOfSourceError
        self.transform = transform
    }

    func next() async throws -> Output? {
        guard !isReading else {
            throw QVACError.protocolViolation(
                "mapped response stream does not support concurrent next() calls"
            )
        }
        guard !finished else { return nil }
        isReading = true
        defer { isReading = false }
        let termination = termination
        return try await withTaskCancellationHandler(operation: {
            do {
                if pendingIndex < pending.count {
                    let output = pending[pendingIndex]
                    pendingIndex += 1
                    if pendingIndex == pending.count {
                        pending.removeAll(keepingCapacity: true)
                        pendingIndex = 0
                    }
                    return output
                }
                if finishAfterPending {
                    finished = true
                    termination.run()
                    return nil
                }
                while let input = try await iterator.next() {
                    switch try transform(input) {
                    case .emit(let output):
                        return output
                    case .emitMany(let outputs):
                        guard let first = outputs.first else { continue }
                        if outputs.count > 1 {
                            pending = Array(outputs.dropFirst())
                        }
                        return first
                    case .emitThenFinish(let outputs):
                        guard let first = outputs.first else {
                            finished = true
                            termination.run()
                            return nil
                        }
                        if outputs.count > 1 {
                            pending = Array(outputs.dropFirst())
                        }
                        finishAfterPending = true
                        return first
                    case .skip:
                        continue
                    case .finish:
                        finished = true
                        termination.run()
                        return nil
                    }
                }
                finished = true
                termination.run()
                if let error = endOfSourceError() { throw error }
                return nil
            } catch {
                finished = true
                termination.run()
                throw QVACClient.publicRPCError(error, operation: "stream")
            }
        }, onCancel: {
            termination.run()
        })
    }

    deinit { termination.run() }
}
