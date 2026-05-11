// HostedXCTests — runs inside the BareKitProbeApp iOS app process on the simulator.
//
// QVAC-222: validates the FULL stack (BareKit + BareIPCTransport + BareRPCClient
// + QVACClient) on iOS Simulator at runtime.
// Driven by `xcodebuild test -scheme BareKitProbeApp -destination 'platform=iOS Simulator,name=iPhone 17'`.

import XCTest
@testable import BareKitProbeLib

#if os(iOS)

final class HostedXCTests: XCTestCase {

    /// Phase-0-equivalent byte-echo + bare-rpc frame round-trip. Validates that all the
    /// fixes we made for QVAC-004f still hold inside the test runner context.
    @MainActor
    func test_BareKit_byte_echo_and_frame_round_trip() async throws {
        let logs = LogCollector()
        let outcome = try await IOSProbeHarness.run(log: { @MainActor msg in
            logs.append(msg)
        })
        XCTAssertTrue(outcome.passed, "harness failed: \(outcome.summary). Logs:\n\(logs.dump())")
    }
}

/// Tiny @MainActor-isolated log collector that the probe harness can write to from
/// inside a @MainActor task.
@MainActor
final class LogCollector {
    private var lines: [String] = []
    func append(_ s: String) { lines.append(s) }
    func dump() -> String { lines.joined(separator: "\n") }
}

#endif
