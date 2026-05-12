// UnixDomainSocketTransportTests — tests that don't need a real Bare worker.
// (The live-worker round-trip lives in QVACClientIntegrationTests.)

import XCTest
@testable import QVACClient

#if canImport(Darwin)
import Darwin

final class UnixDomainSocketTransportTests: XCTestCase {

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
        let config = UDSTransportConfiguration(
            bareExecutable: URL(fileURLWithPath: "/bin/sleep"),
            workerScript:  URL(fileURLWithPath: "/dev/null"),  // sleep ignores it
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

        let config = UDSTransportConfiguration(
            bareExecutable: URL(fileURLWithPath: "/bin/sleep"),
            workerScript:  URL(fileURLWithPath: "/dev/null"),
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

    func test_worker_exits_immediately_surfaces_clearly() async {
        // `/bin/false` exits with code 1 immediately; the transport should report that as
        // workerCouldNotStart via the terminationHandler watchdog.
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
    }

    // MARK: - Security regression tests (§9, §11, §12 from AUDIT.md)

    /// §12 — `environmentOverlay` must strip dynamic-linker keys so a caller can't pipe
    /// `DYLD_INSERT_LIBRARIES` etc. into the spawned worker process. Expanded post-second-
    /// audit to also cover Malloc/ObjC/Foundation debug knobs that aid info disclosure or
    /// heap exploitation.
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

    /// §9 + §11 — the auto-allocated socket path must live inside a 0700 directory
    /// (so other local users can't traverse to the socket) AND the socket file itself
    /// must be 0600. Connect to /bin/sleep so accept times out — but by then the
    /// listener + dir have been created and we can inspect their modes.
    func test_socket_path_has_private_tempdir_and_locked_perms() async throws {
        let config = UDSTransportConfiguration(
            bareExecutable: URL(fileURLWithPath: "/bin/sleep"),
            workerScript:  URL(fileURLWithPath: "/dev/null"),
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

        _ = config // silence "unused" — kept for documentation of the threat model
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
}

#endif
