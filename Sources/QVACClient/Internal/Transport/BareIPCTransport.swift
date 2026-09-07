// BareIPCTransport — iOS path.
//
// Wraps BareKit's `BareWorklet` + `BareIPC` Objective-C objects as a `BareTransport`.
// The Bare worker runs in-process as a libuv pthread inside the host iOS app
// (no subprocess on iOS — Apple forbids it). All IPC is over the socketpair that
// BareKit's `BareIPC` wraps under the hood; we never touch the fd directly.
//
// The iOS package integration suite covers the BareKit worklet and BareIPC path
// end to end. See docs/protocol-notes.md.

#if canImport(BareKit) && os(iOS)
import Foundation
import BareKit
import OSLog

private let _bareKitLogger = Logger(subsystem: "io.qvac.client", category: "barekit")

final class BareIPCTransport: BareTransport, @unchecked Sendable {

    private struct PendingWrite {
        let data: Data
        let continuation: CheckedContinuation<Void, Swift.Error>
    }

    private enum WriteRegistration {
        case rejected(Error)
        case queued
        case start(identifier: UUID, data: Data)
    }

    /// Narrow adapter around the Objective-C objects. Keeping the transport state
    /// machine behind closures lets the iOS test target deterministically exercise
    /// cancellation, overflow, and concurrent close without subclassing BareKit
    /// objects whose initializers and methods are not designed as mock points.
    private struct Backend {
        let read: () throws -> Data?
        let installReadable: (@escaping () -> Void) -> Void
        let clearReadable: () -> Void
        let write: (Data) -> Int
        let closeIPC: () -> Void
        let terminateWorklet: () -> Void
    }

    enum ReadableDrainResult: Sendable, Equatable {
        case wouldBlock
        case peerEOF
        case readFailed
        case inboundOverflow
        case transportClosed
    }

    enum Error: Swift.Error, CustomStringConvertible {
        case workletInitFailed
        case ipcInitFailed
        case invalidConfiguration(String)
        case readFailed(underlying: Swift.Error)
        case writeFailedBecauseTransportClosed
        case writeQueueCapacityExceeded
        case writeFailed(underlying: Swift.Error)

        var description: String {
            switch self {
            case .workletInitFailed: return "BareWorklet init returned nil"
            case .ipcInitFailed:     return "BareIPC init returned nil"
            case .invalidConfiguration(let reason): return "Invalid BareIPC configuration: \(reason)"
            case .readFailed(let u): return "BareIPC.read failed: \(u)"
            case .writeFailedBecauseTransportClosed: return "BareIPC.write failed: transport is closed"
            case .writeQueueCapacityExceeded: return "BareIPC.write failed: pending write queue capacity exceeded"
            case .writeFailed(let u): return "BareIPC.write failed: \(u)"
            }
        }
    }

    /// Internal artifact-ABI selector for the patched BareKit method. The canonical
    /// r1 header cannot declare `readWithError:` while its immutable binary remains
    /// active, so selection happens once when the native transport is created. The
    /// r2 selector follows Objective-C's +0 return convention. The r1 branch only
    /// balances that artifact's incorrect +1 ownership; it cannot repair r1's
    /// native error, callback, or close-race semantics. Production activation
    /// therefore requires the patched r2 artifact.
    private enum NativeReadAdapter {
        private static let checkedReadSelector = NSSelectorFromString("readWithError:")
        private typealias CheckedReadImplementation = @convention(c) (
            AnyObject,
            Selector,
            AutoreleasingUnsafeMutablePointer<NSError?>?
        ) -> Unmanaged<NSData>?

        static func makeReader(for ipc: BareIPC) throws -> () throws -> Data? {
            guard ipc.responds(to: checkedReadSelector) else {
                return {
                    ipc.perform(NSSelectorFromString("read"))?
                        .takeRetainedValue() as? Data
                }
            }
            return try makeCheckedReader(for: ipc)
        }

        /// Constructs the r2 reader through the same typed IMP used in production.
        /// Its NSObject parameter also permits an iOS test double to prove the +0
        /// return and NSError-out conventions without substituting the BareIPC ABI.
        static func makeCheckedReader(for object: NSObject) throws -> () throws -> Data? {
            guard object.responds(to: checkedReadSelector),
                  let implementation = object.method(for: checkedReadSelector) else {
                throw BareRPCProtocolError(
                    "BareIPC advertises readWithError: without an Objective-C implementation"
                )
            }
            let checkedRead = unsafeBitCast(
                implementation,
                to: CheckedReadImplementation.self
            )
            return {
                var nativeError: NSError?
                let value = checkedRead(object, checkedReadSelector, &nativeError)
                if let nativeError {
                    throw Error.readFailed(underlying: nativeError)
                }
                return value?.takeUnretainedValue() as Data?
            }
        }
    }

    struct Configuration: Sendable {
        /// Inline raw bare-bundle binary for the worklet (length-prefix + JSON header + assets).
        /// Typical use: the QVAC `worker.mobile.bundle` resource shipped in `QVACClient.bundle`
        /// (produced by `tools/bundle/unwrap-bundle.mjs` from `qvac bundle sdk` output).
        /// NOTE: pass raw bundle bytes here, not a JS wrapper — bare-module's `.bundle`
        /// extension handler parses this verbatim and rejects JS source.
        var workletSource: Data
        /// Virtual file name used by the worklet's module loader for stack traces / require resolution.
        var workletEntryName: String
        /// Arguments passed as `process.argv` inside the worklet (mirrors QVAC's JSON-arg pattern).
        var arguments: [String]
        /// Optional memory ceiling (in bytes). 0 = use BareKit default.
        var memoryLimit: UInt = 0
        /// Optional path to a bundle of assets for the worklet to access.
        var assets: String?

        init(
            workletSource: Data,
            workletEntryName: String = "/worker.bundle",
            arguments: [String] = [],
            memoryLimit: UInt = 0,
            assets: String? = nil
        ) {
            self.workletSource = workletSource
            self.workletEntryName = workletEntryName
            self.arguments = arguments
            self.memoryLimit = memoryLimit
            self.assets = assets
        }
    }

    private let backend: Backend
    private let inbound: BoundedTransportInboundChannel
    private let maximumPendingWriteCount: Int
    private let maximumPendingWriteBytes: Int
    private var closed = false
    private var closeFinished = false
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var activeReadableDrains = 0
    private var readableDrainWaiters: [CheckedContinuation<Void, Never>] = []
    private var activeWrites = 0
    private var writeWaiters: [CheckedContinuation<Void, Never>] = []
    private var activeNativeWriteCalls = 0
    private var nativeWriteCallWaiters: [CheckedContinuation<Void, Never>] = []
    private var pendingWrites: [UUID: PendingWrite] = [:]
    private var writeQueue: [UUID] = []
    private var pendingWriteBytes = 0
    private var activeNativeWrite: UUID?
    private var readableHandlerCleared = false
    private let lock = NSLock()

    static func connect(
        _ config: Configuration,
        maximumInboundBufferedBytes: Int = BoundedTransportInboundChannel
            .defaultMaximumBufferedBytes
    ) throws -> BareIPCTransport {
        guard maximumInboundBufferedBytes > 0 else {
            throw Error.invalidConfiguration("maximumInboundBufferedBytes must be greater than zero")
        }
        _bareKitLogger.info("BareIPCTransport.connect: building BareWorkletConfiguration")
        guard let configObj = BareWorkletConfiguration.default() else {
            _bareKitLogger.error("BareWorkletConfiguration.default() returned nil")
            throw Error.workletInitFailed
        }
        if config.memoryLimit > 0 { configObj.memoryLimit = config.memoryLimit }
        if let assets = config.assets { configObj.assets = assets }

        _bareKitLogger.info("BareIPCTransport.connect: allocating BareWorklet")
        guard let worklet = BareWorklet(configuration: configObj) else {
            _bareKitLogger.error("BareWorklet(configuration:) returned nil")
            throw Error.workletInitFailed
        }

        _bareKitLogger.info("BareIPCTransport.connect: starting worklet bundleBytes=\(config.workletSource.count, privacy: .public) argumentCount=\(config.arguments.count, privacy: .public)")
        worklet.start(config.workletEntryName, source: config.workletSource, arguments: config.arguments)
        _bareKitLogger.info("BareIPCTransport.connect: worklet.start returned (fire-and-forget); allocating IPC")

        guard let ipc = BareIPC(worklet: worklet) else {
            _bareKitLogger.error("BareIPC(worklet:) returned nil — terminating worklet")
            worklet.terminate()
            throw Error.ipcInitFailed
        }
        _bareKitLogger.info("BareIPCTransport.connect: IPC ready")
        let nativeRead: () throws -> Data?
        do {
            nativeRead = try NativeReadAdapter.makeReader(for: ipc)
        } catch {
            ipc.close()
            worklet.terminate()
            throw error
        }
        let backend = Backend(
            read: nativeRead,
            installReadable: { handler in
                ipc.readable = { _ in handler() }
            },
            clearReadable: { ipc.readable = nil },
            write: { data in ipc.write(data) },
            closeIPC: { ipc.close() },
            terminateWorklet: { worklet.terminate() }
        )
        return BareIPCTransport(
            backend: backend,
            maximumInboundBufferedBytes: maximumInboundBufferedBytes,
            maximumPendingWriteCount: 1_024,
            // QVACClient derives this value from its configured maximum wire body
            // plus the four-byte frame prefix, so every publicly legal frame fits.
            maximumPendingWriteBytes: maximumInboundBufferedBytes
        )
    }

    private init(
        backend: Backend,
        maximumInboundBufferedBytes: Int,
        maximumPendingWriteCount: Int,
        maximumPendingWriteBytes: Int
    ) {
        self.backend = backend
        self.maximumPendingWriteCount = maximumPendingWriteCount
        self.maximumPendingWriteBytes = maximumPendingWriteBytes
        self.inbound = BoundedTransportInboundChannel(
            maximumBufferedBytes: maximumInboundBufferedBytes
        )
        self.inbound.setCancellationHandler { [weak self] in
            Task { [weak self] in await self?.close() }
        }
        // Install the readable callback right away. BareIPC fires it on its internal GCD
        // queue (`to.holepunch.bare.kit.ipc`) so we marshal back via the continuation,
        // which is thread-safe per AsyncThrowingStream contract.
        backend.installReadable { [weak self] in
            guard let self, self.beginReadableDrain() else { return }
            defer { self.endReadableDrain() }
            // Drain everything available on this fire. BareIPC's synchronous API
            // distinguishes would-block (`nil`) from peer EOF (a successful,
            // non-nil zero-byte read). Treat EOF as terminal immediately so the
            // bare-rpc generation fails its waiters and a later API call can
            // reconnect instead of hanging on an apparently open worklet.
            let result = Self.drainReadable(
                read: { try self.backend.read() },
                shouldContinue: { self.readableDrainMayContinue() },
                onChunk: { self.inbound.yield($0) == nil },
                onEOF: {
                    // Stop poll delivery before publishing EOF. The bare-rpc
                    // feeder drains any chunks already queued above, observes
                    // the channel finish, and then owns transport/worklet close.
                    self.clearReadableOnce()
                    self.inbound.finish(discardingBuffered: false)
                },
                onReadFailure: { error in
                    _bareKitLogger.error("BareIPC <- worker read failed: \(String(describing: error), privacy: .public)")
                    self.clearReadableOnce()
                    self.inbound.finish(throwing: error, discardingBuffered: false)
                }
            )
            if result == .inboundOverflow || result == .readFailed {
                Task { [weak self] in await self?.close() }
            }
        }
    }

    /// Drain one readable notification while preserving the three distinct native
    /// outcomes: bytes, would-block, and zero-byte peer EOF. Keeping this logic in a
    /// dependency-free seam lets the iOS test target prove response-before-EOF order
    /// without pretending BareKit always reports worklet self-exit as EOF.
    private static func drainReadable(
        read: () throws -> Data?,
        shouldContinue: () -> Bool,
        onChunk: (Data) -> Bool,
        onEOF: () -> Void,
        onReadFailure: (Swift.Error) -> Void
    ) -> ReadableDrainResult {
        while shouldContinue() {
            let chunk: Data?
            do {
                chunk = try read()
            } catch {
                onReadFailure(error)
                return .readFailed
            }
            guard let chunk else { return .wouldBlock }
            guard !chunk.isEmpty else {
                onEOF()
                return .peerEOF
            }
            guard onChunk(chunk) else { return .inboundOverflow }
        }
        return .transportClosed
    }

    static func __testDrainReadable(
        read: () throws -> Data?,
        into channel: BoundedTransportInboundChannel
    ) -> ReadableDrainResult {
        drainReadable(
            read: read,
            shouldContinue: { true },
            onChunk: { channel.yield($0) == nil },
            onEOF: { channel.finish(discardingBuffered: false) },
            onReadFailure: { channel.finish(throwing: $0, discardingBuffered: false) }
        )
    }

    static func __testCheckedNativeReader(
        for object: NSObject
    ) throws -> () throws -> Data? {
        try NativeReadAdapter.makeCheckedReader(for: object)
    }

    /// iOS-only deterministic backend seam. The returned transport runs the same
    /// callback, write, cancellation, and close state machine as the native path;
    /// only the Objective-C side effects are supplied by the test.
    static func __testTransport(
        maximumInboundBufferedBytes: Int = BoundedTransportInboundChannel
            .defaultMaximumBufferedBytes,
        maximumPendingWriteCount: Int = 1_024,
        maximumPendingWriteBytes: Int = 64 * 1_024 * 1_024,
        read: @escaping () throws -> Data? = { nil },
        installReadable: @escaping (@escaping () -> Void) -> Void = { _ in },
        clearReadable: @escaping () -> Void = {},
        write: @escaping @Sendable (Data) -> Int = { $0.count },
        closeIPC: @escaping () -> Void = {},
        terminateWorklet: @escaping () -> Void = {}
    ) -> BareIPCTransport {
        BareIPCTransport(
            backend: Backend(
                read: read,
                installReadable: installReadable,
                clearReadable: clearReadable,
                write: write,
                closeIPC: closeIPC,
                terminateWorklet: terminateWorklet
            ),
            maximumInboundBufferedBytes: maximumInboundBufferedBytes,
            maximumPendingWriteCount: maximumPendingWriteCount,
            maximumPendingWriteBytes: maximumPendingWriteBytes
        )
    }

    func __testCloseState() -> (closed: Bool, finished: Bool, waiterCount: Int) {
        lock.withLock { (closed, closeFinished, closeWaiters.count) }
    }

    func __testWriteState() -> (pendingCount: Int, activeNativeCallCount: Int, closed: Bool) {
        lock.withLock { (pendingWrites.count, activeNativeWriteCalls, closed) }
    }

    /// Single-use — see UnixDomainSocketTransport.inboundStream() for the same
    /// invariant. Calling twice would silently abandon the first continuation.
    func inboundStream() -> AsyncThrowingStream<Data, Swift.Error> {
        inbound.stream()
    }

    func write(_ data: Data) async throws {
        try Task.checkCancellation()
        // Admission is linearized against close, but the lock never spans the
        // synchronous native call. The SDK-owned pump observes close between
        // nonblocking attempts; writes admitted afterward are rejected.
        guard beginWrite() else {
            throw Error.writeFailedBecauseTransportClosed
        }
        defer { endWrite() }
        let identifier = UUID()
        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation { continuation in
                    switch registerWrite(identifier, data: data, continuation: continuation) {
                    case .rejected(let error):
                        continuation.resume(throwing: error)
                    case .queued:
                        break
                    case .start(let startIdentifier, let startData):
                        startNativeWrite(startIdentifier, data: startData)
                    }
                }
                try Task.checkCancellation()
            } onCancel: {
                Task { [weak self] in await self?.close() }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch Error.writeFailedBecauseTransportClosed {
            if Task.isCancelled { throw CancellationError() }
            throw Error.writeFailedBecauseTransportClosed
        } catch Error.writeQueueCapacityExceeded {
            throw Error.writeQueueCapacityExceeded
        } catch let error {
            if Task.isCancelled { throw CancellationError() }
            _bareKitLogger.error("BareIPC -> worker write failed")
            throw Error.writeFailed(underlying: error)
        }
    }

    func close() async {
        let ownsClose = lock.withLock { () -> Bool in
            guard !closed else { return false }
            closed = true
            return true
        }
        guard ownsClose else {
            await waitForCloseCompletion()
            return
        }

        await finishOwnedClose()
    }

    private func finishOwnedClose() async {
        inbound.finish(discardingBuffered: true)
        await waitForReadableDrains()
        await waitForNativeWriteCalls()
        backend.closeIPC()
        failPendingWritesBecauseClosed()
        await waitForWrites()
        backend.terminateWorklet()
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            closeFinished = true
            defer { closeWaiters.removeAll() }
            return closeWaiters
        }
        for waiter in waiters { waiter.resume() }
    }

    /// Admit a native readable callback only while the transport is open. Close uses
    /// the matching drain count as a quiescence barrier before touching BareIPC, so a
    /// callback that BareKit copied before `readable` was cleared still cannot read a
    /// closed native object.
    private func beginReadableDrain() -> Bool {
        lock.withLock {
            guard !closed else { return false }
            activeReadableDrains += 1
            return true
        }
    }

    /// Re-check close admission between native reads. An already-admitted callback
    /// may observe an indefinitely readable IPC after the inbound channel has been
    /// terminated; without this boundary, close would wait forever for that drain.
    /// The lock is deliberately released before calling into BareKit.
    private func readableDrainMayContinue() -> Bool {
        lock.withLock { !closed }
    }

    private func endReadableDrain() {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            precondition(activeReadableDrains > 0, "unbalanced BareIPC readable drain")
            activeReadableDrains -= 1
            guard activeReadableDrains == 0 else { return [] }
            defer { readableDrainWaiters.removeAll() }
            return readableDrainWaiters
        }
        for waiter in waiters { waiter.resume() }
    }

    private func beginWrite() -> Bool {
        lock.withLock {
            guard !closed else { return false }
            activeWrites += 1
            return true
        }
    }

    private func registerWrite(
        _ identifier: UUID,
        data: Data,
        continuation: CheckedContinuation<Void, Swift.Error>
    ) -> WriteRegistration {
        lock.withLock {
            guard !closed else { return .rejected(.writeFailedBecauseTransportClosed) }
            guard writeQueue.count < maximumPendingWriteCount,
                  data.count <= maximumPendingWriteBytes - pendingWriteBytes else {
                return .rejected(.writeQueueCapacityExceeded)
            }
            pendingWrites[identifier] = PendingWrite(data: data, continuation: continuation)
            writeQueue.append(identifier)
            pendingWriteBytes += data.count
            guard activeNativeWrite == nil, let first = writeQueue.first else { return .queued }
            activeNativeWrite = first
            return .start(identifier: first, data: pendingWrites[first]!.data)
        }
    }

    private func startNativeWrite(_ identifier: UUID, data: Data) {
        Task { [weak self] in
            guard let self else { return }
            var offset = 0
            var retryMilliseconds = 1
            while offset < data.count {
                guard beginNativeWriteCall() else {
                    completeWrite(identifier, error: Error.writeFailedBecauseTransportClosed)
                    return
                }
                let length = min(64 * 1_024, data.count - offset)
                let startIndex = data.index(data.startIndex, offsetBy: offset)
                let endIndex = data.index(startIndex, offsetBy: length)
                let written = backend.write(Data(data[startIndex..<endIndex]))
                let writeErrno = errno
                endNativeWriteCall()
                if written == 0 {
                    do { try await Task.sleep(for: .milliseconds(retryMilliseconds)) }
                    catch {
                        await failWriteAndClose(identifier, error: error)
                        return
                    }
                    retryMilliseconds = min(retryMilliseconds * 2, 32)
                    continue
                }
                if written < 0 {
                    await failWriteAndClose(identifier, error: NSError(
                        domain: NSPOSIXErrorDomain,
                        code: Int(writeErrno)
                    ))
                    return
                }
                guard written <= length else {
                    await failWriteAndClose(
                        identifier,
                        error: BareRPCProtocolError("BareIPC.write returned an invalid byte count")
                    )
                    return
                }
                offset += written
                retryMilliseconds = 1
            }
            completeWrite(identifier, error: nil)
        }
    }

    private func completeWrite(
        _ identifier: UUID,
        error: Swift.Error?,
        startNext: Bool = true
    ) {
        let result: (PendingWrite?, (identifier: UUID, data: Data)?) = lock.withLock {
            guard activeNativeWrite == identifier,
                  let completed = pendingWrites.removeValue(forKey: identifier) else {
                return (nil, nil)
            }
            if writeQueue.first == identifier { writeQueue.removeFirst() }
            pendingWriteBytes -= completed.data.count
            activeNativeWrite = nil
            guard startNext, !closed,
                  let next = writeQueue.first, let pending = pendingWrites[next] else {
                return (completed, nil)
            }
            activeNativeWrite = next
            return (completed, (next, pending.data))
        }
        guard let completed = result.0 else { return }
        if let error { completed.continuation.resume(throwing: error) }
        else { completed.continuation.resume() }
        if let next = result.1 { startNativeWrite(next.identifier, data: next.data) }
    }

    private func failWriteAndClose(_ identifier: UUID, error: Swift.Error) async {
        let result: (PendingWrite?, ownsClose: Bool) = lock.withLock {
            let completed = pendingWrites.removeValue(forKey: identifier)
            if writeQueue.first == identifier { writeQueue.removeFirst() }
            if let completed { pendingWriteBytes -= completed.data.count }
            if activeNativeWrite == identifier { activeNativeWrite = nil }
            let ownsClose = !closed
            closed = true
            return (completed, ownsClose)
        }
        result.0?.continuation.resume(throwing: error)
        if result.ownsClose { await finishOwnedClose() }
        else { await waitForCloseCompletion() }
    }

    private func failPendingWritesBecauseClosed() {
        let continuations = lock.withLock {
            defer {
                pendingWrites.removeAll()
                writeQueue.removeAll()
                pendingWriteBytes = 0
                activeNativeWrite = nil
            }
            return pendingWrites.values.map(\.continuation)
        }
        for continuation in continuations {
            continuation.resume(throwing: Error.writeFailedBecauseTransportClosed)
        }
    }

    private func endWrite() {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            precondition(activeWrites > 0, "unbalanced BareIPC write")
            activeWrites -= 1
            guard activeWrites == 0 else { return [] }
            defer { writeWaiters.removeAll() }
            return writeWaiters
        }
        for waiter in waiters { waiter.resume() }
    }

    /// EOF clears the callback from BareKit's own poll queue. Explicit close leaves
    /// the nonatomic property untouched and relies on `poll_destroy` to disable and
    /// drain that queue; the guard keeps duplicate EOF delivery harmless.
    private func clearReadableOnce() {
        let shouldClear = lock.withLock { () -> Bool in
            guard !readableHandlerCleared else { return false }
            readableHandlerCleared = true
            return true
        }
        if shouldClear { backend.clearReadable() }
    }

    private func waitForReadableDrains() async {
        await withCheckedContinuation { continuation in
            let completed = lock.withLock { () -> Bool in
                if activeReadableDrains == 0 { return true }
                readableDrainWaiters.append(continuation)
                return false
            }
            if completed { continuation.resume() }
        }
    }

    private func waitForWrites() async {
        await withCheckedContinuation { continuation in
            let completed = lock.withLock { () -> Bool in
                if activeWrites == 0 { return true }
                writeWaiters.append(continuation)
                return false
            }
            if completed { continuation.resume() }
        }
    }

    private func beginNativeWriteCall() -> Bool {
        lock.withLock {
            guard !closed else { return false }
            activeNativeWriteCalls += 1
            return true
        }
    }

    private func endNativeWriteCall() {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            precondition(activeNativeWriteCalls > 0, "unbalanced native BareIPC write call")
            activeNativeWriteCalls -= 1
            guard activeNativeWriteCalls == 0 else { return [] }
            defer { nativeWriteCallWaiters.removeAll() }
            return nativeWriteCallWaiters
        }
        for waiter in waiters { waiter.resume() }
    }

    private func waitForNativeWriteCalls() async {
        await withCheckedContinuation { continuation in
            let completed = lock.withLock { () -> Bool in
                if activeNativeWriteCalls == 0 { return true }
                nativeWriteCallWaiters.append(continuation)
                return false
            }
            if completed { continuation.resume() }
        }
    }

    private func waitForCloseCompletion() async {
        await withCheckedContinuation { continuation in
            let completed = lock.withLock { () -> Bool in
                if closeFinished { return true }
                closeWaiters.append(continuation)
                return false
            }
            if completed { continuation.resume() }
        }
    }
}

#endif
