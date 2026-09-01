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
    /// Drain the logical terminal response to transport EOF, then surface its
    /// retained domain error. A drain timeout or post-terminal domain value wins.
    case failThenDrain(QVACError)
    case skip
}

/// Single-consumer iterator ownership shared by eager and pull-mapped response drivers.
///
/// Terminal draining has to continue on the exact iterator that decoded the logical
/// terminal response; creating a second iterator would violate `QVACResponseStream`'s
/// contract and cancel the live RPC lease.
final class QVACResponseStreamIteratorBox<Element: Sendable>: @unchecked Sendable {
    private var iterator: QVACResponseStream<Element>.AsyncIterator

    init(_ source: QVACResponseStream<Element>) {
        iterator = source.makeAsyncIterator()
    }

    func next() async throws -> Element? {
        try await iterator.next()
    }
}

extension QVACClient {
    /// Convert an error envelope without throwing before a pull-mapped terminal can
    /// drain. Malformed numeric codes remain protocol violations, but are retained
    /// until the profiling trailer and transport EOF have been consumed.
    static func retainedWireError(_ response: ErrorResponse) -> QVACError {
        do {
            return QVACError.fromWire(
                code: try checkedWireErrorCode(response.code),
                message: response.message
            )
        } catch let error as QVACError {
            return error
        } catch {
            return .protocolViolation("malformed error response: \(error)")
        }
    }

    /// Drain the metadata-only record that can follow a logical terminal response.
    ///
    /// The typed stream driver removes profiling trailers, so `nil` is the only valid
    /// result of this pull. A domain response after terminal is a protocol violation;
    /// a worker that never closes is bounded independently of the request's timeout.
    static func drainResponseStreamAfterTerminal<Element: Sendable>(
        _ iterator: QVACResponseStreamIteratorBox<Element>,
        operation: String,
        timeout: Duration = .seconds(5)
    ) async throws {
        do {
            let trailingValue = try await withThrowingTaskGroup(of: Element?.self) { group in
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
                    "response stream received a domain response after its terminal frame"
                )
            }
        } catch {
            throw publicRPCError(error, operation: operation)
        }
    }

    /// Resolve a recognized logical terminal frame without abandoning its transport.
    ///
    /// Terminal validation is intentionally evaluated before the drain and retained as
    /// a `Result`: this remembers declared server failures, cancellation outcomes, and
    /// malformed terminal payloads while still pulling the *same* iterator to EOF so a
    /// following profiling trailer is decoded. The drain is awaited before the retained
    /// terminal outcome is observed, which makes a post-terminal domain response or a
    /// bounded-drain timeout authoritative over the terminal outcome.
    static func resolveResponseStreamTerminal<Element: Sendable, Output>(
        _ iterator: QVACResponseStreamIteratorBox<Element>,
        operation: String,
        timeout: Duration = .seconds(5),
        resolution: () throws -> Output
    ) async throws -> Output {
        let terminalResult: Result<Output, Error>
        do {
            terminalResult = .success(try resolution())
        } catch {
            terminalResult = .failure(error)
        }

        try await drainResponseStreamAfterTerminal(
            iterator,
            operation: operation,
            timeout: timeout
        )
        return try terminalResult.get()
    }

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
    private let iterator: QVACResponseStreamIteratorBox<Input>
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
        iterator = QVACResponseStreamIteratorBox(source)
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
                try Task.checkCancellation()
                if pendingIndex < pending.count {
                    let output = pending[pendingIndex]
                    pendingIndex += 1
                    if pendingIndex == pending.count {
                        pending.removeAll(keepingCapacity: true)
                        pendingIndex = 0
                    }
                    try Task.checkCancellation()
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
                        try Task.checkCancellation()
                        return output
                    case .emitMany(let outputs):
                        guard let first = outputs.first else { continue }
                        try Task.checkCancellation()
                        if outputs.count > 1 {
                            pending = Array(outputs.dropFirst())
                        }
                        return first
                    case .emitThenDrain(let outputs):
                        try await QVACClient.drainResponseStreamAfterTerminal(
                            iterator,
                            operation: operation,
                            timeout: terminalDrainTimeout
                        )
                        guard let first = outputs.first else {
                            finished = true
                            termination.run()
                            return nil
                        }
                        try Task.checkCancellation()
                        if outputs.count > 1 {
                            pending = Array(outputs.dropFirst())
                        }
                        finishAfterPending = true
                        return first
                    case .failThenDrain(let error):
                        try await QVACClient.drainResponseStreamAfterTerminal(
                            iterator,
                            operation: operation,
                            timeout: terminalDrainTimeout
                        )
                        throw error
                    case .skip:
                        continue
                    }
                }
            } catch {
                finished = true
                pending.removeAll(keepingCapacity: false)
                pendingIndex = 0
                finishAfterPending = false
                termination.run()
                throw QVACClient.publicRPCError(error, operation: operation)
            }
        }, onCancel: {
            termination.run()
        })
    }

    deinit { termination.run() }
}
