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
}

#endif
