// UnixDomainSocketTransport — macOS path.
//
// Mirrors the JS reference at `packages/sdk/client/rpc/node-rpc-client.ts:ensureRPC`:
//   1. Create a UDS server (we are the server; the worker connects to us as the client).
//   2. Spawn `bare WORKER_PATH JSON.stringify({ QVAC_IPC_SOCKET_PATH, HOME_DIR })`.
//   3. Wait (with a 30s timeout) for the worker to connect.
//   4. Wrap the connected fd as a BareTransport and start reading.
//
// On close: kill the worker process, close the listening socket, unlink the path.

// Subprocess spawning is unavailable on iOS — Foundation.Process is macOS/Linux/Windows-only.
// The grant scope is macOS + iOS, so we only compile this file on macOS. (Linux is not
// supported: every syscall below uses Darwin-specific symbols.)
#if os(macOS)
import Foundation
import Darwin

// MARK: - Configuration

public struct UDSTransportConfiguration: Sendable {
    /// Absolute path to the `bare` runtime binary (e.g. `/opt/homebrew/bin/bare`).
    public var bareExecutable: URL
    /// Absolute path to the QVAC worker.js entrypoint.
    public var workerScript: URL
    /// Working directory for the Bare process. Must contain a `node_modules` resolving the
    /// SDK's transitive deps.
    public var workingDirectory: URL
    /// Path under which the temp socket file will be created.
    /// Defaults to `$TMPDIR/qvac-worker-<pid>-<ts>-<rand>.sock`.
    public var socketPathOverride: String?
    /// Max wait for the worker to connect after spawn.
    public var initTimeout: TimeInterval = 30.0
    /// Optional env additions for the spawned worker.
    public var environmentOverlay: [String: String] = [:]
    /// HOME_DIR value carried into the worker arg JSON. Defaults to NSHomeDirectory().
    public var homeDir: String?

    public init(
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

public final class UnixDomainSocketTransport: BareTransport, @unchecked Sendable {

    public enum SpawnError: Error, CustomStringConvertible {
        case bareNotFound(URL)
        case workerNotFound(URL)
        case socketBindFailed(errno: Int32, path: String)
        case socketListenFailed(errno: Int32)
        case workerCouldNotStart(reason: String)
        case acceptTimeout(seconds: TimeInterval)
        case acceptFailed(errno: Int32)
        case writeFailed(errno: Int32)
        case readFailed(errno: Int32)

        public var description: String {
            switch self {
            case .bareNotFound(let u):    return "Bare executable not found at \(u.path)"
            case .workerNotFound(let u):  return "Worker script not found at \(u.path)"
            case .socketBindFailed(let e, let p): return "bind() failed errno=\(e) on \(p)"
            case .socketListenFailed(let e):       return "listen() failed errno=\(e)"
            case .workerCouldNotStart(let r):      return "Worker failed to start: \(r)"
            case .acceptTimeout(let s):            return "Worker did not connect within \(s)s"
            case .acceptFailed(let e):             return "accept() failed errno=\(e)"
            case .writeFailed(let e):              return "write() failed errno=\(e)"
            case .readFailed(let e):               return "read() failed errno=\(e)"
            }
        }
    }

    public let socketPath: String
    private let listenFD: Int32
    /// Private 0700 tempdir we own (created via mkdtemp). `nil` if the caller supplied
    /// their own `socketPathOverride` — in that case we don't manage the parent dir.
    private let ownedTempDir: String?
    private var clientFD: Int32 = -1
    private var workerProc: Process?
    private let writeQueue = DispatchQueue(label: "qvac.uds.write")
    private var readContinuation: AsyncThrowingStream<Data, Error>.Continuation?
    private let stateLock = NSLock()
    private var closed = false
    private var readerThread: Thread?

    /// Environment variable names that must never be propagated from the caller's
    /// `environmentOverlay` — they can change the dynamic linker's behavior of the spawned
    /// `bare` subprocess and provide an arbitrary-code-execution vector.
    /// Matches Apple's `dyld` sanitization list (`man dyld`).
    private static let dangerousEnvPrefixes: [String] = [
        "DYLD_",
        "LD_PRELOAD",
        "LD_LIBRARY_PATH",
        "LD_AUDIT",
    ]

    /// Spawn the worker and accept its connection. After this returns, the transport is
    /// fully connected and ready to ferry bytes both ways.
    public static func connect(_ config: UDSTransportConfiguration) async throws -> UnixDomainSocketTransport {
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
        let listenFD = try Self.makeListener(at: socketPath)
        let transport = UnixDomainSocketTransport(
            socketPath: socketPath, listenFD: listenFD, ownedTempDir: ownedDir
        )

        // Spawn the worker process AFTER the server is listening, so the worker can connect.
        let proc = Process()
        proc.executableURL = config.bareExecutable
        proc.currentDirectoryURL = config.workingDirectory
        let argJSON: [String: String] = [
            "QVAC_IPC_SOCKET_PATH": socketPath,
            "HOME_DIR": config.homeDir ?? NSHomeDirectory(),
        ]
        let argString = try jsonString(argJSON)
        proc.arguments = [config.workerScript.path, argString]

        var env = ProcessInfo.processInfo.environment
        for (k, v) in Self.sanitizeOverlay(config.environmentOverlay) {
            env[k] = v
        }
        proc.environment = env

        do {
            try proc.run()
        } catch {
            transport.cleanupListener()
            throw SpawnError.workerCouldNotStart(reason: String(describing: error))
        }
        transport.workerProc = proc

        let clientFD = try await acceptWithTimeout(listenFD: listenFD, timeout: config.initTimeout, process: proc)
        // Publish the connected fd under the stateLock so the reader thread (started
        // immediately below) is guaranteed to see it. NSLock acquisition is a memory
        // barrier; without it the reader could otherwise observe the init-time
        // sentinel (-1) and exit before doing any work.
        transport.stateLock.lock()
        transport.clientFD = clientFD
        transport.stateLock.unlock()
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

    // MARK: - BareTransport

    public func inboundStream() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream<Data, Error> { continuation in
            stateLock.lock(); defer { stateLock.unlock() }
            self.readContinuation = continuation
            continuation.onTermination = { [weak self] _ in
                // Hop into a Task with its own weak capture so the Sendable check on the
                // onTermination closure is satisfied without strongly retaining self.
                Task { [weak self] in
                    await self?.close()
                }
            }
        }
    }

    public func write(_ data: Data) async throws {
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
                let result: Result<Void, Error> = data.withUnsafeBytes { raw -> Result<Void, Error> in
                    guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return .success(()) }
                    var ptr = base
                    var remaining = data.count
                    while remaining > 0 {
                        // If close() runs concurrently it will shutdown(fd, SHUT_RDWR) which
                        // makes this write(2) return EPIPE — we treat that as a clean error.
                        let n = Darwin.write(fd, ptr, remaining)
                        if n < 0 {
                            if errno == EINTR { continue }
                            return .failure(SpawnError.writeFailed(errno: errno))
                        }
                        if n == 0 {
                            return .failure(SpawnError.writeFailed(errno: EPIPE))
                        }
                        remaining -= n
                        ptr = ptr.advanced(by: n)
                    }
                    return .success(())
                }
                c.resume(with: result)
            }
        }
    }

    public func close() async {
        // Phase 1: under the lock, flip the closed flag and snapshot fd + proc.
        // Subsequent writes will see `closed=true` and bail without touching the fd.
        // The reader checks `closed` each loop iteration via the lock-then-read pattern.
        stateLock.lock()
        if closed { stateLock.unlock(); return }
        closed = true
        let fd = clientFD
        let proc = workerProc
        let pidForLater: Int32 = proc?.processIdentifier ?? 0
        clientFD = -1
        readContinuation?.finish()
        readContinuation = nil
        stateLock.unlock()

        // Phase 2: drain any in-flight write via the serial writeQueue. Each pending
        // write will acquire the lock, see closed=true, and resume with EBADF. Sync'ing
        // here ensures no Darwin.write call is in flight before we close(2) the fd below.
        writeQueue.sync { /* drain */ }

        // Phase 3: close(2) the original fd. The reader thread holds its own dup'd fd
        // referencing the same underlying socket — close(originalFD) decrements the
        // refcount but doesn't tear down the socket while the reader still holds a dup.
        if fd >= 0 { _ = Darwin.close(fd) }

        // Phase 4: terminate the worker. SIGTERM -> worker handles gracefully (we observed
        // it unloading models + closing sockets cleanly in Spike-A). When the worker exits
        // it closes ITS end of the socket, which makes the reader's dup'd fd return EOF
        // (0 from read(2)) and the reader thread naturally exits on its next iteration.
        if let p = proc, p.isRunning {
            p.terminate()
            p.waitUntilExit()
        }

        // Phase 5: capture the worker PID for test introspection (PID is gone now per
        // waitUntilExit). Then nil out the proc handle.
        stateLock.lock()
        capturedPidAtClose = pidForLater
        workerProc = nil
        stateLock.unlock()

        cleanupListener()
    }

    // MARK: - Lifecycle internals

    private init(socketPath: String, listenFD: Int32, ownedTempDir: String? = nil) {
        self.socketPath = socketPath
        self.listenFD = listenFD
        self.ownedTempDir = ownedTempDir
    }

    private func cleanupListener() {
        _ = Darwin.close(listenFD)
        unlink(socketPath)
        if let dir = ownedTempDir {
            // Best-effort rmdir of the 0700 tempdir we created in mkdtemp.
            _ = rmdir(dir)
        }
    }

    /// Spawn a dedicated reader thread that polls the client FD and yields chunks.
    /// We use a thread rather than `DispatchSource` because the latter can deliver out-of-order
    /// notifications with large buffers; an explicit blocking `read()` per chunk gives us a
    /// strict in-order byte stream.
    private func startReaderThread() {
        let thread = Thread { [weak self] in
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
            stateLock.lock()
            let cont = readContinuation
            stateLock.unlock()
            cont?.finish(throwing: SpawnError.readFailed(errno: errno))
            return
        }
        defer { _ = Darwin.close(dupFD) }

        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            stateLock.lock()
            if closed { stateLock.unlock(); return }
            let cont = readContinuation
            stateLock.unlock()

            let n = buf.withUnsafeMutableBufferPointer { bp -> Int in
                Darwin.read(dupFD, bp.baseAddress, bp.count)
            }
            if n > 0 {
                let chunk = Data(buf.prefix(n))
                cont?.yield(chunk)
                continue
            }
            if n == 0 {
                // EOF — peer (or our own close()) shut the connection down.
                cont?.finish()
                return
            }
            if errno == EINTR { continue }
            // EBADF / ECONNRESET after shutdown is the normal close path; don't treat as
            // an error if we're shutting down.
            stateLock.lock()
            let isClosing = closed
            stateLock.unlock()
            if isClosing {
                cont?.finish()
            } else {
                cont?.finish(throwing: SpawnError.readFailed(errno: errno))
            }
            return
        }
    }

    // MARK: - Socket setup (static helpers)

    private static func makeListener(at path: String) throws -> Int32 {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SpawnError.socketBindFailed(errno: errno, path: path) }
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
        // Briefly tighten umask so the bind(2)-created socket file is 0600 by default.
        // (chmod after bind also works as defense-in-depth — both are below.)
        let oldUmask = umask(0o077)
        defer { _ = umask(oldUmask) }
        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let e = errno; _ = Darwin.close(fd)
            throw SpawnError.socketBindFailed(errno: e, path: path)
        }
        // Defense-in-depth: explicitly lock the socket file to 0600 so even if umask was
        // racy, no other local user can connect(2) to it.
        _ = chmod(path, 0o600)
        guard listen(fd, 1) == 0 else {
            let e = errno; _ = Darwin.close(fd)
            throw SpawnError.socketListenFailed(errno: e)
        }
        return fd
    }

    private static func acceptWithTimeout(listenFD: Int32, timeout: TimeInterval, process: Process) async throws -> Int32 {
        // Spin a dedicated thread to do the blocking accept; expose it as a future.
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Int32, Error>) in
            let q = DispatchQueue.global(qos: .userInitiated)
            var resolved = false
            let lock = NSLock()
            func resolveOnce(_ result: Result<Int32, Error>) {
                lock.lock(); defer { lock.unlock() }
                if resolved { return }
                resolved = true
                c.resume(with: result)
            }
            // accept thread
            q.async {
                var pfd = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
                let rc = withUnsafeMutablePointer(to: &pfd) { p in
                    poll(p, 1, Int32(timeout * 1000))
                }
                if rc == 0 {
                    resolveOnce(.failure(SpawnError.acceptTimeout(seconds: timeout)))
                    return
                }
                if rc < 0 {
                    resolveOnce(.failure(SpawnError.acceptFailed(errno: errno)))
                    return
                }
                var clientAddr = sockaddr_un()
                var len = socklen_t(MemoryLayout<sockaddr_un>.size)
                let fd = withUnsafeMutablePointer(to: &clientAddr) { ap -> Int32 in
                    ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        Darwin.accept(listenFD, sa, &len)
                    }
                }
                if fd < 0 {
                    resolveOnce(.failure(SpawnError.acceptFailed(errno: errno)))
                } else {
                    resolveOnce(.success(fd))
                }
            }
            // worker-exit watchdog
            process.terminationHandler = { p in
                let reason = "worker exited code=\(p.terminationStatus) before connect"
                resolveOnce(.failure(SpawnError.workerCouldNotStart(reason: reason)))
            }
        }
    }

    // Test hooks — exposed to `@testable import` callers so security regression tests
    // can directly assert the file modes set by the path allocator + listener factory
    // without spawning a worker subprocess.
    static func __testAllocateOwnedSocketPath() throws -> (socketPath: String, ownedDir: String) {
        try allocateOwnedSocketPath()
    }
    static func __testMakeListener(at path: String) throws -> Int32 {
        try makeListener(at: path)
    }

    /// Test-only handle on the spawned worker process. AC-7 integration tests use this to
    /// assert the worker actually exited (and with which status) after `close()`.
    public struct WorkerExitInfo: Sendable {
        public let isRunning: Bool
        public let terminationStatus: Int32
        public let terminationReason: Int
        public let pid: Int32
    }
    public func __testWorkerExitInfo() -> WorkerExitInfo? {
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
    public func __testWorkerPID() -> Int32 {
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
