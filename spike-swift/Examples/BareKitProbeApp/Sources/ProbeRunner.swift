import Foundation
import SwiftUI
import BareKitProbeLib

@MainActor
final class ProbeRunner: ObservableObject {
    @Published var log: [String] = []
    @Published var result: ProbeResult? = nil

    struct ProbeResult {
        let passed: Bool
        let summary: String
    }

    func append(_ s: String) {
        let ts = Date().formatted(date: .omitted, time: .standard)
        let line = "[\(ts)] \(s)"
        NSLog("BKPROBE %@", line)
        log.append(line)
    }

    func run() async {
        append("BareKit Probe starting...")
        do {
            let res = try await IOSProbeHarness.run(log: { [weak self] s in
                Task { @MainActor in self?.append(s) }
            })
            result = ProbeResult(passed: res.passed, summary: res.summary)
            append(res.passed ? "✅ probe passed" : "❌ probe failed: \(res.summary)")
            persistResult(passed: res.passed, summary: res.summary)
        } catch {
            result = ProbeResult(passed: false, summary: "exception: \(error)")
            append("❌ exception: \(error)")
            persistResult(passed: false, summary: "exception: \(error)")
        }
    }

    private func persistResult(passed: Bool, summary: String) {
        // Write result.json into the app's Documents dir so the test runner can verify it
        // (xcrun simctl get_app_container booted <bundleId> data).
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = docs.appendingPathComponent("result.json")
        let payload: [String: Any] = [
            "passed": passed,
            "summary": summary,
            "log": log,
            "timestamp": Date().timeIntervalSince1970,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted) {
            try? data.write(to: url)
            NSLog("BKPROBE result.json written to: %@", url.path)
        }
    }
}
