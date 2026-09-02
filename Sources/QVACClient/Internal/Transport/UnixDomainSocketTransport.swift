// UnixDomainSocketTransport — macOS path.
//
// Mirrors the JS reference at `packages/sdk/client/rpc/node-rpc-client.ts:ensureRPC`:
//   1. Create a UDS server (we are the server; the worker connects to us as the client).
//   2. Spawn `bare WORKER_PATH JSON.stringify({ QVAC_IPC_SOCKET_PATH, HOME_DIR })`.
//   3. Wait (with a 30s timeout) for the worker to connect.
//   4. Wrap the connected fd as a BareTransport and start reading.
//
// On close: kill the worker process, close the listening socket, unlink the path.

// This implementation is macOS-only because subprocess setup and the socket calls
// below use Darwin-specific APIs.
#if os(macOS)
import Foundation
import Darwin

/// Captures a bounded tail of the worker's startup output so connection failures are
/// actionable without allowing a noisy subprocess to grow memory without limit. Worker
/// output is not copied to the host application's standard handles, where model paths,
/// request details, or plug-in diagnostics could otherwise escape unexpectedly.
private final class WorkerOutputCapture: @unchecked Sendable {
    private static let byteLimitPerStream = 32 * 1024

    let standardOutput = Pipe()
    let standardError = Pipe()
    private let lock = NSLock()
    private var output = Data()
    private var errorOutput = Data()

    init() {
        standardOutput.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.append(handle.availableData, toStandardError: false)
        }
        standardError.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.append(handle.availableData, toStandardError: true)
        }
    }

    /// `Process` duplicates these descriptors into the child during `run()`.
    /// Closing the parent's write ends afterwards is required for the read ends to
    /// observe EOF when the worker exits; retaining them can make Foundation's
    /// process/file-handle machinery wait forever during startup failure cleanup.
    func processDidLaunch() {
        try? standardOutput.fileHandleForWriting.close()
        try? standardError.fileHandleForWriting.close()
    }

    func stop() {
        standardOutput.fileHandleForReading.readabilityHandler = nil
        standardError.fileHandleForReading.readabilityHandler = nil
        try? standardOutput.fileHandleForReading.close()
        try? standardError.fileHandleForReading.close()
        try? standardOutput.fileHandleForWriting.close()
        try? standardError.fileHandleForWriting.close()
    }

    func diagnosticSuffix() -> String {
        lock.lock()
        let stdout = output
        let stderr = errorOutput
        lock.unlock()

        var components: [String] = []
        if !stdout.isEmpty {
            components.append("stdout-tail=\(Self.printable(stdout))")
        }
        if !stderr.isEmpty {
            components.append("stderr-tail=\(Self.printable(stderr))")
        }
        return components.isEmpty ? "no worker output captured" : components.joined(separator: "; ")
    }

    private func append(_ data: Data, toStandardError: Bool) {
        guard !data.isEmpty else { return }
        lock.lock()
        if toStandardError {
            Self.appendBounded(data, to: &errorOutput)
        } else {
            Self.appendBounded(data, to: &output)
        }
        lock.unlock()

    }

    private static func appendBounded(_ data: Data, to buffer: inout Data) {
        buffer.append(data)
        let excess = buffer.count - byteLimitPerStream
        if excess > 0 { buffer.removeFirst(excess) }
    }

    private static func printable(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
            .unicodeScalars
            .map { scalar in
                if scalar == "\n" || scalar == "\r" || scalar == "\t" || scalar.value >= 0x20 {
                    return String(scalar)
                }
                return "�"
            }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Cancellation state shared with the one queue worker that owns `poll`/`accept`.
///
/// The cancellation handler deliberately does not close `listenFD`: another thread
/// could reuse that descriptor number before the polling worker wakes, turning a
/// well-intended wakeup into an unrelated-fd race. Polling in short bounded slices
/// lets the owner observe cancellation promptly and leaves descriptor cleanup on the
/// structured `connect` error path.
private final class UDSAcceptCancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellationRequested = false
    private var completionClaimed = false

    func requestCancellation() {
        lock.withLock {
            guard !completionClaimed else { return }
            cancellationRequested = true
        }
    }

    func isCancellationRequested() -> Bool {
        lock.withLock { cancellationRequested }
    }

    /// Linearize success/failure against task cancellation. The queue worker is the
    /// only result producer; cancellation merely records intent. A `true` result
    /// means cancellation won and the worker must resume with `CancellationError`.
    func claimCompletion() -> Bool {
        lock.withLock {
            precondition(!completionClaimed, "UDS accept completion claimed twice")
            completionClaimed = true
            return cancellationRequested
        }
    }
}

// MARK: - Configuration

struct UDSTransportConfiguration: Sendable {
    /// Absolute path to the `bare` runtime binary (e.g. `/opt/homebrew/bin/bare`).
    var bareExecutable: URL
    /// Absolute path to the QVAC worker.js entrypoint.
    var workerScript: URL
    /// Working directory for the Bare process. Must contain a `node_modules` resolving the
    /// SDK's transitive deps.
    var workingDirectory: URL
    /// Path under which the temp socket file will be created.
    /// Defaults to `$TMPDIR/qvac-worker-<pid>-<ts>-<rand>.sock`.
    var socketPathOverride: String?
    /// Max wait for the worker to connect after spawn.
    var initTimeout: TimeInterval = 30.0
    /// Optional env additions for the spawned worker.
    var environmentOverlay: [String: String] = [:]
    /// HOME_DIR value carried into the worker arg JSON. Defaults to NSHomeDirectory().
    var homeDir: String?

    init(
        bareExecutable: URL,
        workerScript: URL,
        workingDirectory: URL,
        socketPathOverride: String? = nil,
        initTimeout: TimeInterval = 30.0,
        environmentOverlay: [String: String] = [:],
        homeDir: String? = nil
    ) {
        self.bareExecutable = bareExecutable
        self.workerScript = workerScript
        self.workingDirectory = workingDirectory
        self.socketPathOverride = socketPathOverride
        self.initTimeout = initTimeout
        self.environmentOverlay = environmentOverlay
        self.homeDir = homeDir
    }
}

// MARK: - The transport actor

final class UnixDomainSocketTransport: BareTransport, @unchecked Sendable {

    enum SpawnError: Error, CustomStringConvertible {
        case bareNotFound(URL)
        case workerNotFound(URL)
        case invalidConfiguration(reason: String)
        case socketPathOccupied(path: String, reason: String)
        case socketBindFailed(errno: Int32, path: String)
        case socketListenFailed(errno: Int32)
        case socketConfigurationFailed(errno: Int32)
        case workerCouldNotStart(reason: String)
        case acceptTimeout(seconds: TimeInterval)
        case acceptFailed(errno: Int32)
        case writeFailed(errno: Int32)
        case readFailed(errno: Int32)

        var description: String {
            switch self {
            case .bareNotFound(let u):    return "Bare executable not found at \(u.path)"
            case .workerNotFound(let u):  return "Worker script not found at \(u.path)"
            case .invalidConfiguration(let reason): return "Invalid transport configuration: \(reason)"
            case .socketPathOccupied(let path, let reason):
                return "Socket path is unavailable at \(path): \(reason)"
            case .socketBindFailed(let e, let p): return "bind() failed errno=\(e) on \(p)"
            case .socketListenFailed(let e):       return "listen() failed errno=\(e)"
            case .socketConfigurationFailed(let e): return "socket configuration failed errno=\(e)"
            case .workerCouldNotStart(let r):      return "Worker failed to start: \(r)"
            case .acceptTimeout(let s):            return "Worker did not connect within \(s)s"
            case .acceptFailed(let e):             return "accept() failed errno=\(e)"
            case .writeFailed(let e):              return "write() failed errno=\(e)"
            case .readFailed(let e):               return "read() failed errno=\(e)"
            }
        }
    }

    let socketPath: String
    private let listenFD: Int32
    private let listenerIdentity: SocketIdentity
    /// Private 0700 tempdir we own (created via mkdtemp). `nil` if the caller supplied
    /// their own `socketPathOverride` — in that case we don't manage the parent dir.
    private let ownedTempDir: String?
    private var clientFD: Int32 = -1
    private var workerProc: Process?
    private var workerOutputCapture: WorkerOutputCapture?
    private let writeQueue = DispatchQueue(label: "qvac.uds.write")
    private let inbound: BoundedTransportInboundChannel
    private let stateLock = NSLock()
    private var closed = false
    private var closeFinished = false
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var readerThread: Thread?
    private let readerCompletion = DispatchGroup()

    private struct SocketIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private struct CloseSnapshot {
        let fd: Int32
        let process: Process?
        let pid: Int32
        let output: WorkerOutputCapture?
    }

    /// Environment variable names that must never be propagated from the caller's
    /// `environmentOverlay` — they can change the dynamic linker's behavior of the
    /// spawned `bare` subprocess (arbitrary-code-execution vector) or alter the
    /// runtime/allocator behavior in ways that aid heap exploitation or leak data.
    /// Matches Apple's `dyld` sanitization list (`man dyld`) plus the macOS-specific
    /// `Malloc*` allocator-debug vars and the ObjC-runtime debug vars.
    private static let dangerousEnvPrefixes: [String] = [
        // Dynamic linker — code-execution vectors
        "DYLD_",
        "LD_PRELOAD",
        "LD_LIBRARY_PATH",
        "LD_AUDIT",
        // macOS allocator debugging — usable in heap-exploit chains and leaks
        // internal pointers via stack-logging traces.
        "MallocStackLogging",
        "MallocStackLoggingNoCompact",
        "MallocLog",
        "MallocLogFile",
        "MallocCheckHeapStart",
        "MallocCheckHeapEach",
        "MallocGuardEdges",
        "MallocScribble",
        // ObjC runtime debug — info-disclosure on class lookup, method dispatch
        "OBJC_DEBUG_",
        "NSDebug",
        "NSZombie",
        // Foundation/CFNetwork debugging — info-disclosure
        "CFNETWORK_DIAGNOSTICS",
    ]

    /// Spawn the worker and accept its connection. After this returns, the transport is
    /// fully connected and ready to ferry bytes both ways.
    static func connect(
        _ config: UDSTransportConfiguration,
        maximumInboundBufferedBytes: Int = BareRPCFrameReader.defaultMaxFrameSize + 4
    ) async throws -> UnixDomainSocketTransport {
        guard config.initTimeout.isFinite,
              config.initTimeout > 0,
              config.initTimeout <= Double(Int32.max) / 1_000 else {
            throw SpawnError.invalidConfiguration(
                reason: "initTimeout must be finite, positive, and no greater than \(Double(Int32.max) / 1_000) seconds"
            )
        }
        guard maximumInboundBufferedBytes > 0 else {
            throw SpawnError.invalidConfiguration(
                reason: "maximumInboundBufferedBytes must be greater than zero"
            )
        }
        guard FileManager.default.fileExists(atPath: config.bareExecutable.path) else {
            throw SpawnError.bareNotFound(config.bareExecutable)
        }
        guard FileManager.default.fileExists(atPath: config.workerScript.path) else {
            throw SpawnError.workerNotFound(config.workerScript)
        }
        let (socketPath, ownedDir): (String, String?)
        if let override = config.socketPathOverride {
            (socketPath, ownedDir) = (override, nil)
        } else {
            (socketPath, ownedDir) = try Self.allocateOwnedSocketPath()
        }
        let listener: (fd: Int32, identity: SocketIdentity)
        do {
            listener = try Self.makeListener(
                at: socketPath,
                pathIsInOwnedPrivateDirectory: ownedDir != nil
            )
        } catch {
            if let ownedDir { _ = rmdir(ownedDir) }
            throw error
        }
        let transport = UnixDomainSocketTransport(
            socketPath: socketPath,
            listenFD: listener.fd,
            listenerIdentity: listener.identity,
            ownedTempDir: ownedDir,
            maximumInboundBufferedBytes: maximumInboundBufferedBytes
        )

        // Spawn the worker process AFTER the server is listening, so the worker can connect.
        let proc = Process()
        let outputCapture = WorkerOutputCapture()
        proc.executableURL = config.bareExecutable
        proc.currentDirectoryURL = config.workingDirectory
        proc.standardOutput = outputCapture.standardOutput
        proc.standardError = outputCapture.standardError
        let argJSON: [String: String] = [
            "QVAC_IPC_SOCKET_PATH": socketPath,
            "HOME_DIR": config.homeDir ?? NSHomeDirectory(),
        ]
        let argString = try jsonString(argJSON)
        proc.arguments = [config.workerScript.path, argString]

        // Apply the denylist to the inherited process environment as well as the
        // caller overlay. Otherwise a host launched with DYLD_/LD_PRELOAD debug
        // variables would silently propagate them into the worker.
        proc.environment = Self.workerEnvironment(
            inherited: ProcessInfo.processInfo.environment,
            overlay: config.environmentOverlay
        )

        do {
            try proc.run()
            outputCapture.processDidLaunch()
        } catch {
            outputCapture.stop()
            transport.cleanupListener()
            throw SpawnError.workerCouldNotStart(
                reason: "bare=\(config.bareExecutable.path), worker=\(config.workerScript.path), "
                    + "cwd=\(config.workingDirectory.path): \(error)"
            )
        }
        transport.workerProc = proc
        transport.workerOutputCapture = outputCapture

        // Wrap accept in a do/catch so that if the worker never connects within the
        // timeout (or accept() itself fails), we still tear down the worker subprocess
        // and clean up the listener FD + temp dir. Without this, those resources leak
        // on init failure.
        let clientFD: Int32
        do {
            let acceptedFD = try await acceptWithTimeout(
                listenFD: listener.fd,
                timeout: config.initTimeout,
                process: proc,
                diagnostics: { outputCapture.diagnosticSuffix() }
            )
            do {
                // Cancellation can race with the successful accept linearization.
                // Do not publish an otherwise valid descriptor to a canceled caller.
                try Task.checkCancellation()
                try configureConnectedSocket(acceptedFD)
                clientFD = acceptedFD
            } catch {
                _ = Darwin.close(acceptedFD)
                throw error
            }
        } catch {
            await terminateProcess(
                proc,
                terminateGrace: .milliseconds(500),
                killGrace: .seconds(1)
            )
            outputCapture.stop()
            transport.cleanupListener()
            // Prefer structured cancellation when it raced with poll/accept or
            // bounded subprocess cleanup. The original transport error remains
            // correct only for a caller that is still interested in the result.
            try Task.checkCancellation()
            let context = "bare=\(config.bareExecutable.path), worker=\(config.workerScript.path), "
                + "cwd=\(config.workingDirectory.path), pid=\(proc.processIdentifier)"
            if case SpawnError.workerCouldNotStart(let reason) = error {
                throw SpawnError.workerCouldNotStart(reason: "\(reason); \(context)")
            }
            throw error
        }

        // Publish the connected fd under the stateLock so the reader thread (started
        // immediately below) is guaranteed to see it. NSLock acquisition is a memory
        // barrier; without it the reader could otherwise observe the init-time
        // sentinel (-1) and exit before doing any work.
        transport.stateLock.withLock {
            transport.clientFD = clientFD
        }
        transport.startReaderThread()
        return transport
    }

    /// Strip dynamic-linker keys from caller-supplied env overlay before merging into the
    /// spawned worker's environment. Prevents callers from accidentally (or maliciously)
    /// piping `DYLD_INSERT_LIBRARIES`/`LD_PRELOAD` into the worker.
    static func sanitizeOverlay(_ overlay: [String: String]) -> [String: String] {
        overlay.filter { (key, _) in
            !dangerousEnvPrefixes.contains(where: { key.hasPrefix($0) })
        }
    }

    /// Build the exact environment installed on the subprocess. Keeping the inherited
    /// input injectable makes it impossible for this security boundary to regress into
    /// sanitizing only the explicit overlay.
    static func workerEnvironment(
        inherited: [String: String],
        overlay: [String: String]
    ) -> [String: String] {
        var environment = sanitizeOverlay(inherited)
        for (key, value) in sanitizeOverlay(overlay) {
            environment[key] = value
        }
        return environment
    }

    // MARK: - BareTransport

    func inboundStream() -> AsyncThrowingStream<Data, Error> {
        inbound.stream()
    }

    func write(_ data: Data) async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            do {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    // Dispatch onto the serial writeQueue. This also lets close() drain pending
                    // writes by calling writeQueue.sync { } before close() touches the fd.
                    writeQueue.async {
                        // Snapshot fd + closed flag under the state lock. Close() also takes this
                        // lock to flip `closed` before it shuts down the fd, so we either see
                        // closed=true here (and bail), or we see closed=false and a valid fd that
                        // close() will not actually close(2) until writeQueue drains.
                        self.stateLock.lock()
                        if self.closed {
                            self.stateLock.unlock()
                            c.resume(throwing: SpawnError.writeFailed(errno: EBADF))
                            return
                        }
                        let fd = self.clientFD
                        self.stateLock.unlock()
                        if fd < 0 {
                            c.resume(throwing: SpawnError.writeFailed(errno: EBADF))
                            return
                        }
                        let result: Result<Void, Error> = data.withUnsafeBytes { raw in
                            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                                return .success(())
                            }
                            var pointer = base
                            var remaining = data.count
                            while remaining > 0 {
                                // shutdown(fd, SHUT_RDWR) makes a blocked write return EPIPE.
                                let written = Darwin.write(fd, pointer, remaining)
                                if written < 0 {
                                    if errno == EINTR { continue }
                                    return .failure(SpawnError.writeFailed(errno: errno))
                                }
                                if written == 0 {
                                    return .failure(SpawnError.writeFailed(errno: EPIPE))
                                }
                                remaining -= written
                                pointer = pointer.advanced(by: written)
                            }
                            return .success(())
                        }
                        c.resume(with: result)
                    }
                }
            } catch {
                // If cancellation interrupted the descriptor, preserve structured
                // cancellation instead of exposing the resulting EPIPE/EBADF race.
                try Task.checkCancellation()
                throw error
            }
            try Task.checkCancellation()
        } onCancel: {
            // Darwin.write is not Swift-cancellation-aware. Interrupt the socket
            // immediately so a full send buffer cannot poison the serial writer,
            // then run the normal joinable resource teardown.
            self.interruptSocketForCancellation()
        }
    }

    private func interruptSocketForCancellation() {
        let fd = stateLock.withLock { clientFD }
        if fd >= 0 { _ = Darwin.shutdown(fd, SHUT_RDWR) }
        Task { [weak self] in await self?.close() }
    }

    func close() async {
        // Phase 1: under the lock, flip the closed flag and snapshot fd + proc.
        // Subsequent writes will see `closed=true` and bail without touching the fd.
        // The reader checks `closed` each loop iteration via the lock-then-read pattern.
        let snapshot: CloseSnapshot? = stateLock.withLock {
            guard !closed else { return nil }
            closed = true
            let snapshot = CloseSnapshot(
                fd: clientFD,
                process: workerProc,
                pid: workerProc?.processIdentifier ?? 0,
                output: workerOutputCapture
            )
            clientFD = -1
            return snapshot
        }
        guard let snapshot else {
            await waitForCloseCompletion()
            return
        }
        inbound.finish(discardingBuffered: true)

        // Phase 2: interrupt both socket directions before draining the serial writer.
        // A blocking write on a full socket buffer would otherwise prevent close() from
        // ever reaching close(2). shutdown(2) also wakes the reader's dup'd descriptor.
        if snapshot.fd >= 0 { _ = Darwin.shutdown(snapshot.fd, SHUT_RDWR) }

        // Drain any in-flight write. shutdown above guarantees a blocked write returns.
        writeQueue.sync { /* drain */ }

        // Phase 3: close(2) the original fd. The reader thread holds its own dup'd fd
        // referencing the same underlying socket — close(originalFD) decrements the
        // refcount but doesn't tear down the socket while the reader still holds a dup.
        if snapshot.fd >= 0 { _ = Darwin.close(snapshot.fd) }

        // Phase 4: terminate the worker. SIGTERM -> worker handles gracefully (we observed
        // it unloading models + closing sockets cleanly in Spike-A). When the worker exits
        // it closes ITS end of the socket, which makes the reader's dup'd fd return EOF
        // (0 from read(2)) and the reader thread naturally exits on its next iteration.
        if let process = snapshot.process { await Self.terminateProcess(process) }
        snapshot.output?.stop()

        // Do not return while the reader still owns its dup'd descriptor or can
        // execute callbacks against this transport.
        await waitForReaderCompletion()

        // Phase 5: capture the worker PID for test introspection (PID is gone now per
        // waitUntilExit). Then nil out the proc handle.
        stateLock.withLock {
            capturedPidAtClose = snapshot.pid
            workerProc = nil
            workerOutputCapture = nil
        }

        cleanupListener()
        finishClose()
    }

    // MARK: - Lifecycle internals

    private init(
        socketPath: String,
        listenFD: Int32,
        listenerIdentity: SocketIdentity,
        ownedTempDir: String? = nil,
        maximumInboundBufferedBytes: Int
    ) {
        self.socketPath = socketPath
        self.listenFD = listenFD
        self.listenerIdentity = listenerIdentity
        self.ownedTempDir = ownedTempDir
        self.inbound = BoundedTransportInboundChannel(
            maximumBufferedBytes: maximumInboundBufferedBytes
        )
        self.inbound.setCancellationHandler { [weak self] in
            Task { [weak self] in await self?.close() }
        }
    }

    private func cleanupListener() {
        Self.unlinkSocketPathIfOwned(socketPath, identity: listenerIdentity)
        _ = Darwin.close(listenFD)
        if let dir = ownedTempDir {
            // Best-effort rmdir of the 0700 tempdir we created in mkdtemp.
            _ = rmdir(dir)
        }
    }

    private func waitForCloseCompletion() async {
        await withCheckedContinuation { continuation in
            let shouldResume: Bool = stateLock.withLock {
                if closeFinished { return true }
                closeWaiters.append(continuation)
                return false
            }
            if shouldResume { continuation.resume() }
        }
    }

    private func finishClose() {
        let waiters: [CheckedContinuation<Void, Never>] = stateLock.withLock {
            closeFinished = true
            defer { closeWaiters.removeAll() }
            return closeWaiters
        }
        for waiter in waiters { waiter.resume() }
    }

    private func waitForReaderCompletion() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                self.readerCompletion.wait()
                continuation.resume()
            }
        }
    }

    /// Spawn a dedicated reader thread that polls the client FD and yields chunks.
    /// We use a thread rather than `DispatchSource` because the latter can deliver out-of-order
    /// notifications with large buffers; an explicit blocking `read()` per chunk gives us a
    /// strict in-order byte stream.
    private func startReaderThread() {
        readerCompletion.enter()
        let completion = readerCompletion
        let thread = Thread { [weak self] in
            defer { completion.leave() }
            guard let self else { return }
            self.runReader()
        }
        thread.name = "qvac.uds.reader"
        readerThread = thread
        thread.start()
    }

    private func runReader() {
        // Dup the client FD so the reader holds its own descriptor number. close() can
        // then safely shutdown + close the original without race-window risk of fd reuse
        // (between close(N) and another open returning N, our read(N) could otherwise
        // consume bytes from an unrelated resource).
        stateLock.lock()
        let originalFD = clientFD
        stateLock.unlock()
        guard originalFD >= 0 else { return }
        let dupFD = Darwin.dup(originalFD)
        guard dupFD >= 0 else {
            inbound.finish(throwing: SpawnError.readFailed(errno: errno))
            return
        }
        defer { _ = Darwin.close(dupFD) }

        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            stateLock.lock()
            if closed { stateLock.unlock(); return }
            stateLock.unlock()

            let n = buf.withUnsafeMutableBufferPointer { bp -> Int in
                Darwin.read(dupFD, bp.baseAddress, bp.count)
            }
            if n > 0 {
                let chunk = Data(buf.prefix(n))
                if inbound.yield(chunk) != nil {
                    Task { [weak self] in await self?.close() }
                    return
                }
                continue
            }
            if n == 0 {
                // EOF — peer (or our own close()) shut the connection down.
                inbound.finish()
                return
            }
            if errno == EINTR { continue }
            // EBADF / ECONNRESET after shutdown is the normal close path; don't treat as
            // an error if we're shutting down.
            stateLock.lock()
            let isClosing = closed
            stateLock.unlock()
            if isClosing {
                inbound.finish(discardingBuffered: true)
            } else {
                inbound.finish(throwing: SpawnError.readFailed(errno: errno))
            }
            return
        }
    }

    // MARK: - Socket setup (static helpers)

    private static func makeListener(
        at path: String,
        pathIsInOwnedPrivateDirectory: Bool = false
    ) throws -> (fd: Int32, identity: SocketIdentity) {
        try prepareSocketPath(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SpawnError.socketBindFailed(errno: errno, path: path) }
        // Set FD_CLOEXEC so the listener fd is NOT inherited by the spawned `bare`
        // subprocess. Without this, the child process holds a reference to our
        // listening socket, which (a) keeps the socket from being fully closed when
        // we close our copy, and (b) is unnecessary file-descriptor exposure to the
        // worker (it has no business with our listening fd).
        let flags = fcntl(fd, F_GETFD)
        guard flags >= 0, fcntl(fd, F_SETFD, flags | FD_CLOEXEC) == 0 else {
            let error = errno
            _ = Darwin.close(fd)
            throw SpawnError.socketConfigurationFailed(errno: error)
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            _ = Darwin.close(fd)
            throw SpawnError.socketBindFailed(errno: ENAMETOOLONG, path: path)
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in pathBytes.enumerated() { raw[i] = b }
            raw[pathBytes.count] = 0
        }
        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let e = errno; _ = Darwin.close(fd)
            throw SpawnError.socketBindFailed(errno: e, path: path)
        }
        guard let boundIdentity = socketIdentity(at: path) else {
            let error = errno == 0 ? EINVAL : errno
            _ = Darwin.close(fd)
            // Only the atomically-created 0700 directory is safe to clean without
            // a recorded inode. Override paths are caller-owned and are never
            // unlinked without an exact identity match.
            if pathIsInOwnedPrivateDirectory { _ = unlink(path) }
            throw SpawnError.socketConfigurationFailed(errno: error)
        }
        // Defense-in-depth: explicitly lock the socket file to 0600 so even if umask was
        // racy, no other local user can connect(2) to it.
        guard chmod(path, 0o600) == 0 else {
            let error = errno
            unlinkSocketPathIfOwned(path, identity: boundIdentity)
            _ = Darwin.close(fd)
            throw SpawnError.socketConfigurationFailed(errno: error)
        }
        guard listen(fd, 1) == 0 else {
            let e = errno
            unlinkSocketPathIfOwned(path, identity: boundIdentity)
            _ = Darwin.close(fd)
            throw SpawnError.socketListenFailed(errno: e)
        }
        return (fd, boundIdentity)
    }

    /// Never unlink an arbitrary caller-owned path. Generated paths live in a new
    /// private `mkdtemp` directory and are guaranteed absent; override paths are
    /// rejected whenever anything already exists, including a stale socket. The
    /// application that owns an override is responsible for explicit stale cleanup.
    private static func prepareSocketPath(_ path: String) throws {
        var existing = stat()
        guard lstat(path, &existing) == 0 else {
            if errno == ENOENT { return }
            throw SpawnError.socketPathOccupied(path: path, reason: "lstat failed errno=\(errno)")
        }
        let kind = (existing.st_mode & S_IFMT) == S_IFSOCK ? "socket" : "non-socket file"
        throw SpawnError.socketPathOccupied(path: path, reason: "pre-existing \(kind) is caller-owned")
    }

    private static func socketIdentity(at path: String) -> SocketIdentity? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK else { return nil }
        return SocketIdentity(device: info.st_dev, inode: info.st_ino)
    }

    private static func unlinkSocketPathIfOwned(_ path: String, identity: SocketIdentity) {
        guard socketIdentity(at: path) == identity else { return }
        _ = unlink(path)
    }

    private static func configureConnectedSocket(_ fd: Int32) throws {
        var enabled: Int32 = 1
        guard setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &enabled,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            throw SpawnError.socketConfigurationFailed(errno: errno)
        }
        let flags = fcntl(fd, F_GETFD)
        guard flags >= 0, fcntl(fd, F_SETFD, flags | FD_CLOEXEC) == 0 else {
            throw SpawnError.socketConfigurationFailed(errno: errno)
        }
    }

    private static func acceptWithTimeout(
        listenFD: Int32,
        timeout: TimeInterval,
        process: Process,
        diagnostics: @escaping @Sendable () -> String
    ) async throws -> Int32 {
        let cancellation = UDSAcceptCancellationState()

        // One worker owns `listenFD` until it resumes the continuation. Checking
        // process exit from that same worker removes the former two-resolver race in
        // which cleanup could close/reuse the descriptor while poll/accept still used it.
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Int32, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let deadline = ProcessInfo.processInfo.systemUptime + timeout
                    while true {
                        if cancellation.isCancellationRequested() {
                            _ = cancellation.claimCompletion()
                            continuation.resume(throwing: CancellationError())
                            return
                        }

                        let remaining = deadline - ProcessInfo.processInfo.systemUptime
                        if remaining <= 0 {
                            if cancellation.claimCompletion() {
                                continuation.resume(throwing: CancellationError())
                            } else {
                                let reason = "worker did not connect within \(timeout)s; \(diagnostics())"
                                continuation.resume(
                                    throwing: SpawnError.workerCouldNotStart(reason: reason)
                                )
                            }
                            return
                        }
                        if !process.isRunning {
                            if cancellation.claimCompletion() {
                                continuation.resume(throwing: CancellationError())
                            } else {
                                let reason = "worker exited code=\(process.terminationStatus) "
                                    + "before connect; \(diagnostics())"
                                continuation.resume(
                                    throwing: SpawnError.workerCouldNotStart(reason: reason)
                                )
                            }
                            return
                        }

                        var pfd = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
                        // Cancellation is observed within one 25 ms slice without
                        // closing the descriptor from a competing thread.
                        let pollMilliseconds = Int32(min(25, max(1, Int(remaining * 1_000))))
                        let rc = withUnsafeMutablePointer(to: &pfd) { pointer in
                            poll(pointer, 1, pollMilliseconds)
                        }
                        if rc == 0 { continue }
                        if rc < 0 {
                            if errno == EINTR { continue }
                            if cancellation.claimCompletion() {
                                continuation.resume(throwing: CancellationError())
                            } else {
                                continuation.resume(
                                    throwing: SpawnError.acceptFailed(errno: errno)
                                )
                            }
                            return
                        }

                        var clientAddr = sockaddr_un()
                        var len = socklen_t(MemoryLayout<sockaddr_un>.size)
                        let fd = withUnsafeMutablePointer(to: &clientAddr) { address -> Int32 in
                            address.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                                socketAddress in
                                Darwin.accept(listenFD, socketAddress, &len)
                            }
                        }
                        if fd < 0, errno == EINTR { continue }

                        if cancellation.claimCompletion() {
                            if fd >= 0 { _ = Darwin.close(fd) }
                            continuation.resume(throwing: CancellationError())
                        } else if fd < 0 {
                            continuation.resume(throwing: SpawnError.acceptFailed(errno: errno))
                        } else {
                            continuation.resume(returning: fd)
                        }
                        return
                    }
                }
            }
        } onCancel: {
            cancellation.requestCancellation()
        }
    }

    /// Bound subprocess shutdown so an uncooperative worker can never hang client close
    /// or startup-error cleanup forever. SIGTERM gets a grace period, then SIGKILL.
    private static func terminateProcess(
        _ process: Process,
        terminateGrace: Duration = .seconds(2),
        killGrace: Duration = .seconds(1)
    ) async {
        guard process.isRunning else { return }

        process.terminate()
        if await waitForProcessExit(process, for: terminateGrace) {
            return
        }

        _ = Darwin.kill(process.processIdentifier, SIGKILL)
        _ = await waitForProcessExit(process, for: killGrace)
    }

    private static func waitForProcessExit(_ process: Process, for duration: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: duration)
        while process.isRunning, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        return !process.isRunning
    }

    private static func deliverAcceptedFD(
        _ fd: Int32,
        resolve: (Result<Int32, Error>) -> Bool
    ) {
        // If the process-exit watchdog won the race, this accepted descriptor
        // has no owner and must be closed here.
        if !resolve(.success(fd)) { _ = Darwin.close(fd) }
    }

    // Test hooks — exposed to `@testable import` callers so security regression tests
    // can directly assert the file modes set by the path allocator + listener factory
    // without spawning a worker subprocess.
    static func __testAllocateOwnedSocketPath() throws -> (socketPath: String, ownedDir: String) {
        try allocateOwnedSocketPath()
    }
    static func __testMakeListener(at path: String) throws -> Int32 {
        try makeListener(at: path).fd
    }
    static func __testConfigureConnectedSocket(_ fd: Int32) throws {
        try configureConnectedSocket(fd)
    }
    static func __testCloseAcceptedFDWhenResolutionLoses(_ fd: Int32) {
        deliverAcceptedFD(fd) { _ in false }
    }
    static func __testConnectedTransport(
        clientFD: Int32,
        maximumInboundBufferedBytes: Int = 1024 * 1024
    ) throws -> UnixDomainSocketTransport {
        let allocation = try allocateOwnedSocketPath()
        do {
            let listener = try makeListener(at: allocation.socketPath)
            do {
                try configureConnectedSocket(clientFD)
            } catch {
                unlinkSocketPathIfOwned(allocation.socketPath, identity: listener.identity)
                _ = Darwin.close(listener.fd)
                _ = rmdir(allocation.ownedDir)
                throw error
            }
            let transport = UnixDomainSocketTransport(
                socketPath: allocation.socketPath,
                listenFD: listener.fd,
                listenerIdentity: listener.identity,
                ownedTempDir: allocation.ownedDir,
                maximumInboundBufferedBytes: maximumInboundBufferedBytes
            )
            transport.stateLock.withLock { transport.clientFD = clientFD }
            transport.startReaderThread()
            return transport
        } catch {
            _ = rmdir(allocation.ownedDir)
            throw error
        }
    }

    func __testReaderFinished() -> Bool {
        readerThread?.isFinished ?? true
    }

    /// Test-only handle on the spawned worker process. AC-7 integration tests use this to
    /// assert the worker actually exited (and with which status) after `close()`.
    struct WorkerExitInfo: Sendable {
        let isRunning: Bool
        let terminationStatus: Int32
        let terminationReason: Int
        let pid: Int32
    }
    func __testWorkerExitInfo() -> WorkerExitInfo? {
        stateLock.lock(); defer { stateLock.unlock() }
        guard let p = workerProc else { return nil }
        return WorkerExitInfo(
            isRunning: p.isRunning,
            terminationStatus: p.isRunning ? Int32.min : p.terminationStatus,
            terminationReason: p.isRunning ? -1 : p.terminationReason.rawValue,
            pid: p.processIdentifier
        )
    }
    /// Read the worker proc's PID even after close() has nilled out the stored handle.
    /// Used by close-test to verify the OS reports the PID as gone via `kill(pid, 0)`.
    func __testWorkerPID() -> Int32 {
        stateLock.lock(); defer { stateLock.unlock() }
        return workerProc?.processIdentifier ?? capturedPidAtClose
    }
    private var capturedPidAtClose: Int32 = 0

    /// Create a private 0700 tempdir via `mkdtemp(3)` and return (`<dir>/socket`, dir).
    /// mkdtemp's `XXXXXX` slot is replaced by the system with a high-entropy random
    /// suffix (~36 bits on macOS) — far better than the previous 16 bits — and the dir
    /// is created with 0700 mode atomically, so no other local user can traverse it to
    /// reach the socket inside.
    private static func allocateOwnedSocketPath() throws -> (socketPath: String, ownedDir: String) {
        let base = NSTemporaryDirectory()
        let templateStr = (base.hasSuffix("/") ? base : base + "/") + "qvac-worker-XXXXXXXX"
        var templateBytes = Array(templateStr.utf8CString)
        let dirOpt: String? = templateBytes.withUnsafeMutableBufferPointer { bp -> String? in
            guard let baseAddr = bp.baseAddress, mkdtemp(baseAddr) != nil else { return nil }
            return String(cString: baseAddr)
        }
        guard let dir = dirOpt else {
            throw SpawnError.socketBindFailed(errno: errno, path: templateStr)
        }
        return (socketPath: dir + "/socket", ownedDir: dir)
    }
}

// MARK: - Helpers

private func jsonString(_ obj: [String: String]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    return String(data: data, encoding: .utf8) ?? "{}"
}

#endif
