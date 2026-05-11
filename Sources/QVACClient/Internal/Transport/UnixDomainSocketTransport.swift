// UnixDomainSocketTransport — macOS path.
//
// Mirrors the JS reference at `packages/sdk/client/rpc/node-rpc-client.ts:ensureRPC`:
//   1. Create a UDS server (we are the server; the worker connects to us as the client).
//   2. Spawn `bare WORKER_PATH JSON.stringify({ QVAC_IPC_SOCKET_PATH, HOME_DIR })`.
//   3. Wait (with a 30s timeout) for the worker to connect.
//   4. Wrap the connected fd as a BareTransport and start reading.
//
// On close: kill the worker process, close the listening socket, unlink the path.

// Subprocess spawning is unavailable on iOS — Foundation.Process is gated to macOS/Linux/Windows.
// This whole file compiles only on platforms that have it.
#if os(macOS) || os(Linux)
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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
    private var clientFD: Int32 = -1
    private var workerProc: Process?
    private let writeQueue = DispatchQueue(label: "qvac.uds.write")
    private var readContinuation: AsyncThrowingStream<Data, Error>.Continuation?
    private let stateLock = NSLock()
    private var closed = false
    private var readerThread: Thread?

    /// Spawn the worker and accept its connection. After this returns, the transport is
    /// fully connected and ready to ferry bytes both ways.
    public static func connect(_ config: UDSTransportConfiguration) async throws -> UnixDomainSocketTransport {
        guard FileManager.default.fileExists(atPath: config.bareExecutable.path) else {
            throw SpawnError.bareNotFound(config.bareExecutable)
        }
        guard FileManager.default.fileExists(atPath: config.workerScript.path) else {
            throw SpawnError.workerNotFound(config.workerScript)
        }
        let socketPath = config.socketPathOverride ?? defaultSocketPath()
        let listenFD = try Self.makeListener(at: socketPath)
        let transport = UnixDomainSocketTransport(socketPath: socketPath, listenFD: listenFD)

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
        for (k, v) in config.environmentOverlay { env[k] = v }
        proc.environment = env

        do {
            try proc.run()
        } catch {
            transport.cleanupListener()
            throw SpawnError.workerCouldNotStart(reason: String(describing: error))
        }
        transport.workerProc = proc

        let clientFD = try await acceptWithTimeout(listenFD: listenFD, timeout: config.initTimeout, process: proc)
        transport.clientFD = clientFD
        transport.startReaderThread()
        return transport
    }

    // MARK: - BareTransport

    public func inboundStream() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream<Data, Error> { continuation in
            stateLock.lock(); defer { stateLock.unlock() }
            self.readContinuation = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.close() }
            }
        }
    }

    public func write(_ data: Data) async throws {
        let fd = clientFD
        if fd < 0 { throw SpawnError.writeFailed(errno: EBADF) }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            writeQueue.async {
                let result: Result<Void, Error> = data.withUnsafeBytes { raw -> Result<Void, Error> in
                    guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return .success(()) }
                    var ptr = base
                    var remaining = data.count
                    while remaining > 0 {
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
        stateLock.lock()
        if closed { stateLock.unlock(); return }
        closed = true
        let fd = clientFD
        let proc = workerProc
        readContinuation?.finish()
        readContinuation = nil
        clientFD = -1
        workerProc = nil
        stateLock.unlock()

        if fd >= 0 { _ = Darwin.close(fd) }
        if let p = proc, p.isRunning {
            p.terminate()
            // Give it a brief moment; the worker handles SIGTERM gracefully (we observed
            // it unloading models + closing sockets cleanly in Spike-A).
            p.waitUntilExit()
        }
        cleanupListener()
    }

    // MARK: - Lifecycle internals

    private init(socketPath: String, listenFD: Int32) {
        self.socketPath = socketPath
        self.listenFD = listenFD
    }

    private func cleanupListener() {
        _ = Darwin.close(listenFD)
        unlink(socketPath)
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
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            stateLock.lock()
            if closed { stateLock.unlock(); return }
            let fd = clientFD
            let cont = readContinuation
            stateLock.unlock()
            if fd < 0 { cont?.finish(); return }

            let n = buf.withUnsafeMutableBufferPointer { bp -> Int in
                Darwin.read(fd, bp.baseAddress, bp.count)
            }
            if n > 0 {
                let chunk = Data(buf.prefix(n))
                cont?.yield(chunk)
                continue
            }
            if n == 0 {
                // EOF — peer closed.
                cont?.finish()
                return
            }
            if errno == EINTR { continue }
            cont?.finish(throwing: SpawnError.readFailed(errno: errno))
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
        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let e = errno; _ = Darwin.close(fd)
            throw SpawnError.socketBindFailed(errno: e, path: path)
        }
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

    private static func defaultSocketPath() -> String {
        let tmp = NSTemporaryDirectory()
        let pid = ProcessInfo.processInfo.processIdentifier
        let ts = String(Int(Date().timeIntervalSince1970 * 1000), radix: 36)
        var randBytes = [UInt8](repeating: 0, count: 2)
        _ = SecRandomCopyBytes(kSecRandomDefault, 2, &randBytes)
        let rand = randBytes.map { String(format: "%02x", $0) }.joined()
        return tmp + "qvac-worker-\(pid)-\(ts)-\(rand).sock"
    }
}

// MARK: - Helpers

private func jsonString(_ obj: [String: String]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    return String(data: data, encoding: .utf8) ?? "{}"
}

#endif
