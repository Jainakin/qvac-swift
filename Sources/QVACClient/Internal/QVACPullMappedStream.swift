import Foundation

/// One pull-mapping action for a source element.
enum QVACPullMapDecision<Element: Sendable>: Sendable {
    case emit(Element)
    case emitMany([Element])
    /// Drain the source to EOF, then emit the terminal domain values.
    ///
    /// The QVAC worker may append a metadata-only profiling trailer after its
    /// logical terminal response. Bounded eager draining captures that trailer
    /// even when an application stops after the terminal event, without exposing
    /// metadata as another domain value. Any actual domain value observed while
    /// draining is a protocol violation.
    case emitThenDrain([Element])
    case skip
    case finish
}

extension QVACClient {
    /// Map a single public sequence without an eager bridge task or second queue.
    /// Backpressure therefore reaches the byte-bounded transport unchanged.
    static func pullMap<Input: Sendable, Output: Sendable>(
        _ source: QVACResponseStream<Input>,
        operation: String = "stream",
        onTermination: @escaping @Sendable () -> Void = {},
        endOfSourceError: @escaping @Sendable () -> Error? = { nil },
        terminalDrainTimeout: Duration = .seconds(5),
        transform: @escaping @Sendable (Input) throws -> QVACPullMapDecision<Output>
    ) -> QVACResponseStream<Output> {
        let termination = QVACPullStreamTermination {
            source.cancel()
            onTermination()
        }
        let driver = QVACPullMappedStreamDriver(
            source: source,
            termination: termination,
            operation: operation,
            endOfSourceError: endOfSourceError,
            terminalDrainTimeout: terminalDrainTimeout,
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
    private let operation: String
    private let endOfSourceError: @Sendable () -> Error?
    private let terminalDrainTimeout: Duration
    private let transform: @Sendable (Input) throws -> QVACPullMapDecision<Output>
    private var finished = false
    private var isReading = false
    private var pending: [Output] = []
    private var pendingIndex = 0
    private var finishAfterPending = false

    init(
        source: QVACResponseStream<Input>,
        termination: QVACPullStreamTermination,
        operation: String,
        endOfSourceError: @escaping @Sendable () -> Error?,
        terminalDrainTimeout: Duration,
        transform: @escaping @Sendable (Input) throws -> QVACPullMapDecision<Output>
    ) {
        iterator = IteratorBox(source)
        self.termination = termination
        self.operation = operation
        self.endOfSourceError = endOfSourceError
        self.terminalDrainTimeout = terminalDrainTimeout
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
                while true {

                    guard let input = try await iterator.next() else {
                        finished = true
                        termination.run()
                        if let error = endOfSourceError() { throw error }
                        return nil
                    }
                    switch try transform(input) {
                    case .emit(let output):
                        return output
                    case .emitMany(let outputs):
                        guard let first = outputs.first else { continue }
                        if outputs.count > 1 {
                            pending = Array(outputs.dropFirst())
                        }
                        return first
                    case .emitThenDrain(let outputs):
                        try await drainSourceAfterTerminal()
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
            } catch {
                finished = true
                termination.run()
                throw QVACClient.publicRPCError(error, operation: operation)
            }
        }, onCancel: {
            termination.run()
        })
    }

    /// Profiling trailers are metadata-only and immediately follow the worker's
    /// logical terminal record. Bound the final pull so a malformed worker that
    /// sends `done` but never closes the response cannot hang a normal loop.
    private func drainSourceAfterTerminal() async throws {
        let iterator = iterator
        let timeout = terminalDrainTimeout
        let trailingValue = try await withThrowingTaskGroup(of: Input?.self) { group in
            group.addTask { try await iterator.next() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw BareRPCRequestTimeout(timeout: timeout)
            }
            defer { group.cancelAll() }
            guard let firstCompleted = try await group.next() else {
                throw QVACError.protocolViolation(
                    "terminal response drain had no active task"
                )
            }
            return firstCompleted
        }
        if trailingValue != nil {
            throw QVACError.protocolViolation(
                "mapped response stream received a domain response after its terminal frame"
            )
        }
    }

    deinit { termination.run() }
}
