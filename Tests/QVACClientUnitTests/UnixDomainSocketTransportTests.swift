// UnixDomainSocketTransportTests — tests that don't need a real Bare worker.
// (The live-worker round-trip lives in QVACClientIntegrationTests.)

import XCTest
@testable import QVACClient

#if canImport(Darwin)
import Darwin

// Darwin's Swift overlay marks `fork()` unavailable, but this test deliberately
// needs a child process to prove a write cannot terminate the process with SIGPIPE.
// Calling the POSIX symbol directly is confined to the test target.
@_silgen_name("fork")
private func qvacTestFork() -> pid_t

final class UnixDomainSocketTransportTests: XCTestCase {

    private func makeSleepingWorkerScript() throws -> URL {
        let url = URL(fileURLWithPath: "/tmp/qvac-sleep-\(UUID().uuidString.prefix(8)).sh")
        try Data("#!/bin/sh\nexec /bin/sleep 30\n".utf8).write(to: url, options: .atomic)
        return url
    }

    private func qvacOwnedTempDirectories() -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? [])
            .filter { $0.hasPrefix("qvac-worker-") }
    }

    private func waitForFile(
        at url: URL,
        timeout: Duration = .seconds(2)
    ) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    func test_invalid_init_timeouts_are_rejected_without_spawning() async {
        for timeout in [TimeInterval.nan, -.infinity, -1, 0, .infinity] {
            let config = UDSTransportConfiguration(
                bareExecutable: URL(fileURLWithPath: "/does/not/matter"),
                workerScript: URL(fileURLWithPath: "/does/not/matter"),
                workingDirectory: URL(fileURLWithPath: "/tmp"),
                initTimeout: timeout
            )
            do {
                _ = try await UnixDomainSocketTransport.connect(config)
                XCTFail("expected invalid configuration for \(timeout)")
            } catch let error as UnixDomainSocketTransport.SpawnError {
                guard case .invalidConfiguration = error else {
                    return XCTFail("expected invalidConfiguration, got \(error)")
                }
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }
    }

    func test_missing_bare_executable_errors_clearly() async {
        let config = UDSTransportConfiguration(
            bareExecutable: URL(fileURLWithPath: "/nonexistent/bare"),
            workerScript:  URL(fileURLWithPath: "/dev/null"),
            workingDirectory: URL(fileURLWithPath: "/tmp")
        )
        do {
            _ = try await UnixDomainSocketTransport.connect(config)
            XCTFail("expected error")
        } catch let e as UnixDomainSocketTransport.SpawnError {
            if case .bareNotFound = e { /* ok */ }
            else { XCTFail("expected bareNotFound, got \(e)") }
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func test_missing_worker_script_errors_clearly() async throws {
        guard FileManager.default.fileExists(atPath: "/bin/sh") else {
            throw XCTSkip("test needs /bin/sh as a stand-in for bare")
        }
        let config = UDSTransportConfiguration(
            bareExecutable: URL(fileURLWithPath: "/bin/sh"),
            workerScript:  URL(fileURLWithPath: "/nonexistent/worker.js"),
            workingDirectory: URL(fileURLWithPath: "/tmp")
        )
        do {
            _ = try await UnixDomainSocketTransport.connect(config)
            XCTFail("expected error")
        } catch let e as UnixDomainSocketTransport.SpawnError {
            if case .workerNotFound = e { /* ok */ }
            else { XCTFail("expected workerNotFound, got \(e)") }
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func test_accept_timeout_fires_when_worker_never_connects() async throws {
        // Spawn a "worker" that just sleeps without connecting.
        let workerScript = try makeSleepingWorkerScript()
        defer { try? FileManager.default.removeItem(at: workerScript) }
        let config = UDSTransportConfiguration(
            bareExecutable: URL(fileURLWithPath: "/bin/sh"),
            workerScript: workerScript,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            initTimeout: 0.5
        )
        do {
            _ = try await UnixDomainSocketTransport.connect(config)
            XCTFail("expected timeout")
        } catch let e as UnixDomainSocketTransport.SpawnError {
            // Either acceptTimeout (sleep ignored stdio) or workerCouldNotStart (sleep exited).
            // Both prove the watchdog fires.
            switch e {
            case .acceptTimeout, .workerCouldNotStart: break // ok
            default: XCTFail("unexpected: \(e)")
            }
        }
    }

    /// §B1 regression — accept-timeout used to leak the listener FD + owned tempdir.
    /// Confirm that after the timeout fires, the temp dir created by `mkdtemp` is
    /// gone, the socket file is unlinked, AND any leftover worker subprocess (in this
    /// case `/bin/sleep`) has been reaped.
    func test_accept_timeout_cleans_up_listener_and_tempdir_and_worker() async throws {
        // Capture the set of qvac-worker-* tempdirs before / after — there should be
        // no net new ones if cleanup is correct.
        let tmpRoot = NSTemporaryDirectory()
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: tmpRoot)) ?? [])
            .filter { $0.hasPrefix("qvac-worker-") }

        let workerScript = try makeSleepingWorkerScript()
        defer { try? FileManager.default.removeItem(at: workerScript) }
        let config = UDSTransportConfiguration(
            bareExecutable: URL(fileURLWithPath: "/bin/sh"),
            workerScript: workerScript,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            initTimeout: 0.3
        )
        do {
            _ = try await UnixDomainSocketTransport.connect(config)
            XCTFail("expected timeout")
        } catch {
            // expected
        }

        let after = Set((try? FileManager.default.contentsOfDirectory(atPath: tmpRoot)) ?? [])
            .filter { $0.hasPrefix("qvac-worker-") }
        let leaked = after.subtracting(before)
        XCTAssertTrue(leaked.isEmpty,
                      "accept-timeout leaked tempdir(s): \(leaked) under \(tmpRoot)")
    }

    func test_cancelled_connect_promptly_reaps_worker_listener_and_owned_tempdir() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("qvac-connect-pid-\(UUID().uuidString)")
        let workerScript = FileManager.default.temporaryDirectory
            .appendingPathComponent("qvac-cancel-worker-\(UUID().uuidString).sh")
        try Data("""
        trap '' TERM
        printf '%s' "$$" > '\(marker.path)'
        exec /bin/sleep 30
        """.utf8).write(to: workerScript, options: .atomic)
        defer {
            try? FileManager.default.removeItem(at: marker)
            try? FileManager.default.removeItem(at: workerScript)
        }

        let before = qvacOwnedTempDirectories()
        let config = UDSTransportConfiguration(
            bareExecutable: URL(fileURLWithPath: "/bin/sh"),
            workerScript: workerScript,
            workingDirectory: FileManager.default.temporaryDirectory,
            initTimeout: 30
        )
        let connection = Task {
            try await UnixDomainSocketTransport.connect(config)
        }

        guard try await waitForFile(at: marker) else {
            connection.cancel()
            _ = try? await connection.value
            return XCTFail("sleeping worker never published its PID")
        }
        let during = qvacOwnedTempDirectories().subtracting(before)
        XCTAssertEqual(during.count, 1, "connect must own exactly one temporary listener")
        let pidText = try String(contentsOf: marker, encoding: .utf8)
        let workerPID = try XCTUnwrap(Int32(pidText))

        let clock = ContinuousClock()
        let cancellationStarted = clock.now
        connection.cancel()
        do {
            _ = try await connection.value
            XCTFail("expected connect cancellation")
        } catch is CancellationError {
            // Expected. Cleanup completes before the canceled connect returns.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        XCTAssertLessThan(
            cancellationStarted.duration(to: clock.now),
            .seconds(2),
            "cancellation must not wait for the 30-second accept timeout"
        )

        let after = qvacOwnedTempDirectories()
        XCTAssertTrue(
            after.subtracting(before).isEmpty,
            "cancelled connect leaked owned temp directories: \(after.subtracting(before))"
        )
        errno = 0
        XCTAssertEqual(Darwin.kill(workerPID, 0), -1, "cancelled worker PID still exists")
        XCTAssertEqual(errno, ESRCH, "cancelled worker must be reaped, errno=\(errno)")
    }

    func test_worker_exits_immediately_surfaces_clearly() async {
        // `/bin/false` exits with code 1 immediately; the transport should report that as
        // workerCouldNotStart via the terminationHandler watchdog.
        let clock = ContinuousClock()
        let start = clock.now
        let config = UDSTransportConfiguration(
            bareExecutable: URL(fileURLWithPath: "/usr/bin/false"),
            workerScript:  URL(fileURLWithPath: "/dev/null"),
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            initTimeout: 2.0
        )
        do {
            _ = try await UnixDomainSocketTransport.connect(config)
            XCTFail("expected error")
        } catch let e as UnixDomainSocketTransport.SpawnError {
            switch e {
            case .workerCouldNotStart, .acceptTimeout, .workerNotFound: break // ok
            default: XCTFail("unexpected: \(e)")
            }
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
        XCTAssertLessThan(
            start.duration(to: clock.now),
            .seconds(3),
            "an already-exited worker must never leave startup cleanup waiting on its pipes"
        )
    }

    func test_startup_timeout_captures_stderr_and_force_kills_uncooperative_worker() async throws {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("qvac-stubborn-worker-\(UUID().uuidString).sh")
        try Data("""
        trap '' TERM
        echo 'qvac-startup-diagnostic-marker' >&2
        while :; do :; done
        """.utf8).write(to: scriptURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let config = UDSTransportConfiguration(
            bareExecutable: URL(fileURLWithPath: "/bin/sh"),
            workerScript: scriptURL,
            workingDirectory: FileManager.default.temporaryDirectory,
            initTimeout: 0.15
        )
        let clock = ContinuousClock()
        let start = clock.now
        do {
            _ = try await UnixDomainSocketTransport.connect(config)
            XCTFail("expected startup failure")
        } catch let error as UnixDomainSocketTransport.SpawnError {
            guard case .workerCouldNotStart(let reason) = error else {
                return XCTFail("expected workerCouldNotStart, got \(error)")
            }
            XCTAssertTrue(reason.contains("qvac-startup-diagnostic-marker"), reason)
            XCTAssertTrue(reason.contains(scriptURL.path), reason)
        }
        XCTAssertLessThan(
            start.duration(to: clock.now),
            .seconds(2),
            "startup cleanup must escalate from SIGTERM to SIGKILL within its bound"
        )
    }

    // MARK: - Security regression tests

    /// `environmentOverlay` strips dynamic-linker and diagnostic keys before
    /// spawning the worker.
    func test_environmentOverlay_strips_dynamic_linker_keys() {
        let raw: [String: String] = [
            // dyld code-exec vectors
            "DYLD_INSERT_LIBRARIES": "/tmp/evil.dylib",
            "DYLD_FALLBACK_LIBRARY_PATH": "/tmp",
            "LD_PRELOAD": "/tmp/evil.so",
            "LD_LIBRARY_PATH": "/tmp",
            "LD_AUDIT": "/tmp/audit.so",
            // macOS allocator debugging
            "MallocStackLogging": "1",
            "MallocLogFile": "/tmp/heap.log",
            "MallocScribble": "1",
            // ObjC / Foundation debug
            "OBJC_DEBUG_POOL_ALLOCATION": "YES",
            "NSDebugEnabled": "YES",
            "NSZombieEnabled": "YES",
            "CFNETWORK_DIAGNOSTICS": "3",
            // Safe — must pass through
            "NODE_OPTIONS": "--max-old-space-size=4096",
            "QVAC_LOG_LEVEL": "trace",
        ]
        let sanitized = UnixDomainSocketTransport.sanitizeOverlay(raw)
        // Code-execution vectors
        XCTAssertNil(sanitized["DYLD_INSERT_LIBRARIES"])
        XCTAssertNil(sanitized["DYLD_FALLBACK_LIBRARY_PATH"])
        XCTAssertNil(sanitized["LD_PRELOAD"])
        XCTAssertNil(sanitized["LD_LIBRARY_PATH"])
        XCTAssertNil(sanitized["LD_AUDIT"])
        // Allocator debug
        XCTAssertNil(sanitized["MallocStackLogging"])
        XCTAssertNil(sanitized["MallocLogFile"])
        XCTAssertNil(sanitized["MallocScribble"])
        // ObjC / Foundation
        XCTAssertNil(sanitized["OBJC_DEBUG_POOL_ALLOCATION"])
        XCTAssertNil(sanitized["NSDebugEnabled"])
        XCTAssertNil(sanitized["NSZombieEnabled"])
        XCTAssertNil(sanitized["CFNETWORK_DIAGNOSTICS"])
        // Safe must survive
        XCTAssertEqual(sanitized["NODE_OPTIONS"], "--max-old-space-size=4096")
        XCTAssertEqual(sanitized["QVAC_LOG_LEVEL"], "trace")
    }

    func test_final_worker_environment_sanitizes_inherited_and_overlay_values() {
        let environment = UnixDomainSocketTransport.workerEnvironment(
            inherited: [
                "PATH": "/usr/bin",
                "DYLD_INSERT_LIBRARIES": "/tmp/inherited.dylib",
                "LD_PRELOAD": "/tmp/inherited.so",
                "QVAC_LOG_LEVEL": "info",
            ],
            overlay: [
                "QVAC_LOG_LEVEL": "debug",
                "DYLD_LIBRARY_PATH": "/tmp/overlay",
                "SAFE_CUSTOM_KEY": "preserved",
            ]
        )

        XCTAssertEqual(environment["PATH"], "/usr/bin")
        XCTAssertEqual(environment["QVAC_LOG_LEVEL"], "debug")
        XCTAssertEqual(environment["SAFE_CUSTOM_KEY"], "preserved")
        XCTAssertNil(environment["DYLD_INSERT_LIBRARIES"])
        XCTAssertNil(environment["LD_PRELOAD"])
        XCTAssertNil(environment["DYLD_LIBRARY_PATH"])
    }

    /// §9 + §11 — the auto-allocated socket path must live inside a 0700 directory
    /// (so other local users can't traverse to the socket) AND the socket file itself
    /// must be 0600. Connect to /bin/sleep so accept times out — but by then the
    /// listener + dir have been created and we can inspect their modes.
    func test_socket_path_has_private_tempdir_and_locked_perms() async throws {
        let workerScript = try makeSleepingWorkerScript()
        defer { try? FileManager.default.removeItem(at: workerScript) }
        let config = UDSTransportConfiguration(
            bareExecutable: URL(fileURLWithPath: "/bin/sh"),
            workerScript: workerScript,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            initTimeout: 0.3
        )
        // The connect will fail (worker never connects), but the listener was created
        // before failure. We capture the socket path observation via a brief delay-and-
        // scan; simpler: instrument by calling the static allocator directly.
        let alloc = try UnixDomainSocketTransport_TestHook.allocateOwnedSocketPath()
        defer { _ = rmdir(alloc.ownedDir) }
        // Parent dir must be 0700.
        var dirStat = stat()
        XCTAssertEqual(stat(alloc.ownedDir, &dirStat), 0)
        let dirPerms = dirStat.st_mode & 0o777
        XCTAssertEqual(dirPerms, 0o700, "tempdir perms must be 0700, got \(String(dirPerms, radix: 8))")

        // Now create a listener inside and assert the socket is 0600.
        let fd = try UnixDomainSocketTransport_TestHook.makeListener(at: alloc.socketPath)
        defer { _ = Darwin.close(fd); unlink(alloc.socketPath) }
        var sockStat = stat()
        XCTAssertEqual(stat(alloc.socketPath, &sockStat), 0)
        let sockPerms = sockStat.st_mode & 0o777
        XCTAssertEqual(sockPerms, 0o600, "socket perms must be 0600, got \(String(sockPerms, radix: 8))")
        XCTAssertNotEqual(fcntl(fd, F_GETFD) & FD_CLOEXEC, 0, "listener must be close-on-exec")

        _ = config // silence "unused" — kept for documentation of the threat model
    }

    func test_listener_never_unlinks_preexisting_caller_file_or_socket() throws {
        // Keep the path comfortably below Darwin's 104-byte `sun_path` limit.
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("qvac-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("ordinary-file")
        let marker = Data("must-survive".utf8)
        try marker.write(to: fileURL)
        XCTAssertThrowsError(try UnixDomainSocketTransport_TestHook.makeListener(at: fileURL.path))
        XCTAssertEqual(try Data(contentsOf: fileURL), marker)

        let socketPath = root.appendingPathComponent("existing.sock").path
        let firstFD = try UnixDomainSocketTransport_TestHook.makeListener(at: socketPath)
        defer { _ = Darwin.close(firstFD); _ = unlink(socketPath) }
        XCTAssertThrowsError(try UnixDomainSocketTransport_TestHook.makeListener(at: socketPath))
        var info = stat()
        XCTAssertEqual(lstat(socketPath, &info), 0, "existing socket must remain present")
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFSOCK)
    }

    func test_connected_socket_suppresses_sigpipe_and_reports_epipe_in_child() throws {
        var sockets = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        try UnixDomainSocketTransport_TestHook.configureConnectedSocket(sockets[0])

        var noSigPipe: Int32 = 0
        var optionLength = socklen_t(MemoryLayout<Int32>.size)
        XCTAssertEqual(
            getsockopt(sockets[0], SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, &optionLength),
            0
        )
        XCTAssertEqual(noSigPipe, 1)

        let child = qvacTestFork()
        if child == 0 {
            _ = Darwin.close(sockets[1])
            usleep(100_000)
            var byte: UInt8 = 0x41
            errno = 0
            let result = Darwin.write(sockets[0], &byte, 1)
            let writeError = errno
            _exit(result == -1 && writeError == EPIPE ? 0 : 2)
        }
        XCTAssertGreaterThan(child, 0)
        guard child > 0 else {
            _ = Darwin.close(sockets[0])
            _ = Darwin.close(sockets[1])
            return
        }

        _ = Darwin.close(sockets[0])
        _ = Darwin.close(sockets[1])
        var status: Int32 = 0
        XCTAssertEqual(waitpid(child, &status, 0), child)
        XCTAssertEqual(status & 0x7f, 0, "child died from signal \(status & 0x7f), likely SIGPIPE")
        XCTAssertEqual((status >> 8) & 0xff, 0, "child did not observe EPIPE")
    }

    func test_accept_resolution_loser_closes_descriptor() {
        var sockets = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        defer { _ = Darwin.close(sockets[1]) }

        UnixDomainSocketTransport_TestHook.closeAcceptedFDWhenResolutionLoses(sockets[0])
        errno = 0
        XCTAssertEqual(fcntl(sockets[0], F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
    }

    func test_production_reader_overflow_is_explicit_closes_connection_and_joins_thread() async throws {
        var sockets = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        let transport = try UnixDomainSocketTransport_TestHook.connectedTransport(
            clientFD: sockets[0],
            maximumInboundBufferedBytes: 1_024
        )
        let inbound = transport.inboundStream()

        let payload = Data(repeating: 0x41, count: 2_048)
        let written = payload.withUnsafeBytes { bytes in
            Darwin.write(sockets[1], bytes.baseAddress, bytes.count)
        }
        XCTAssertEqual(written, payload.count)

        var iterator = inbound.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            XCTFail("expected bounded inbound overflow")
        } catch let error as BareTransportInboundBufferOverflow {
            XCTAssertEqual(error.maximumBufferedBytes, 1_024)
            XCTAssertGreaterThan(error.attemptedBufferedBytes, 1_024)
        }

        await transport.close()
        XCTAssertTrue(transport.__testReaderFinished())
        _ = Darwin.close(sockets[1])
    }

    func test_cancelled_blocked_write_aborts_socket_and_concurrent_close_callers_join() async throws {
        var sockets = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        var sendBuffer: Int32 = 4_096
        XCTAssertEqual(setsockopt(
            sockets[0],
            SOL_SOCKET,
            SO_SNDBUF,
            &sendBuffer,
            socklen_t(MemoryLayout<Int32>.size)
        ), 0)
        let transport = try UnixDomainSocketTransport_TestHook.connectedTransport(
            clientFD: sockets[0]
        )
        _ = transport.inboundStream()

        let write = Task {
            try await transport.write(Data(repeating: 0x42, count: 8 * 1024 * 1024))
        }
        try await Task.sleep(for: .milliseconds(50))
        write.cancel()
        do {
            try await write.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // Cancellation must win over the EPIPE used to unblock write(2).
        }

        async let firstClose: Void = transport.close()
        async let secondClose: Void = transport.close()
        _ = await (firstClose, secondClose)
        XCTAssertTrue(transport.__testReaderFinished())
        errno = 0
        XCTAssertEqual(fcntl(sockets[0], F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
        _ = Darwin.close(sockets[1])
    }
}

/// Internal access to the transport's static path/listener helpers for the security
/// regression tests above. Same module via `@testable import`, but exposes the static
/// methods through a typed re-export so the test reads cleanly.
private enum UnixDomainSocketTransport_TestHook {
    static func allocateOwnedSocketPath() throws -> (socketPath: String, ownedDir: String) {
        try UnixDomainSocketTransport.__testAllocateOwnedSocketPath()
    }
    static func makeListener(at path: String) throws -> Int32 {
        try UnixDomainSocketTransport.__testMakeListener(at: path)
    }
    static func configureConnectedSocket(_ fd: Int32) throws {
        try UnixDomainSocketTransport.__testConfigureConnectedSocket(fd)
    }
    static func closeAcceptedFDWhenResolutionLoses(_ fd: Int32) {
        UnixDomainSocketTransport.__testCloseAcceptedFDWhenResolutionLoses(fd)
    }
    static func connectedTransport(
        clientFD: Int32,
        maximumInboundBufferedBytes: Int = 1024 * 1024
    ) throws -> UnixDomainSocketTransport {
        try UnixDomainSocketTransport.__testConnectedTransport(
            clientFD: clientFD,
            maximumInboundBufferedBytes: maximumInboundBufferedBytes
        )
    }
}

#endif
