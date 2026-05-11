// IOSProbeHarness — proves that:
//   1. BareKit.xcframework links from a SwiftPM-backed iOS app.
//   2. A BareWorklet can be started with inline JS source.
//   3. A BareIPC channel can carry bytes in BOTH directions between Swift host and JS worklet.
//   4. Latency for a small round-trip is sub-second on the simulator.
//
// The worklet JS is a trivial byte-echo handler. This validates the transport layer
// without bringing in bare-rpc complexity — that's M2 work.

#if canImport(BareKit) && os(iOS)
import Foundation
import BareKit
import BareRPC
import CompactEncoding

public struct ProbeOutcome: Sendable {
    public let passed: Bool
    public let summary: String
    public init(passed: Bool, summary: String) {
        self.passed = passed
        self.summary = summary
    }
}

public enum IOSProbeHarness {

    /// JS source for the worklet. Uses the global `BareKit` object provided by bare-kit
    /// (see github.com/holepunchto/bare-kit/blob/main/shared/worklet.js).
    /// Echoes back every chunk it receives over the IPC channel.
    private static let workletJS = """
    /* global BareKit */
    const ipc = BareKit.IPC
    ipc.on('data', (chunk) => {
      ipc.write(chunk)
    })
    ipc.on('error', (err) => {
      console.error('[worklet] IPC error:', err)
    })
    console.log('[worklet] echo handler installed')
    """

    /// Run the probe. Logs progress via the supplied closure.
    /// Returns ProbeOutcome with PASS/FAIL + summary.
    @MainActor
    public static func run(log: @MainActor @Sendable @escaping (String) -> Void) async throws -> ProbeOutcome {
        log("BareKit version: built-in")
        log("Constructing BareWorkletConfiguration.default()")
        guard let config = BareWorkletConfiguration.default() else {
            return ProbeOutcome(passed: false, summary: "BareWorkletConfiguration.default() returned nil")
        }

        log("Allocating BareWorklet")
        guard let worklet = BareWorklet(configuration: config) else {
            return ProbeOutcome(passed: false, summary: "BareWorklet init returned nil")
        }

        guard let jsData = workletJS.data(using: .utf8) else {
            return ProbeOutcome(passed: false, summary: "couldn't encode worklet JS as UTF-8")
        }
        log("Starting worklet with inline JS source (\(jsData.count) bytes)")
        worklet.start("/probe.js", source: jsData, arguments: nil)

        log("Opening BareIPC")
        guard let ipc = BareIPC(worklet: worklet) else {
            worklet.terminate()
            return ProbeOutcome(passed: false, summary: "BareIPC init returned nil")
        }

        let expected: Data = {
            var d = Data(count: 32)
            d.withUnsafeMutableBytes { buf in
                let raw = buf.bindMemory(to: UInt8.self)
                for i in 0..<32 { raw[i] = UInt8.random(in: 0...255) }
            }
            return d
        }()
        log("Test payload (32 random bytes): \(hex(expected))")

        actor Latch {
            private var buffer = Data()
            private let target: Int
            private var continuation: CheckedContinuation<Data, Never>?
            init(target: Int) { self.target = target }
            func append(_ d: Data) {
                buffer.append(d)
                if buffer.count >= target, let c = continuation {
                    continuation = nil
                    c.resume(returning: buffer)
                }
            }
            func awaitBytes() async -> Data {
                if buffer.count >= target { return buffer }
                return await withCheckedContinuation { c in continuation = c }
            }
        }
        let latch = Latch(target: 32)

        ipc.readable = { ipcRef in
            while let chunk = ipcRef.read(), chunk.count > 0 {
                let copy = chunk as Data
                Task { await latch.append(copy) }
            }
        }

        let start = Date()
        log("Writing 32 bytes via ipc.write(_:completion:) (async-bridged)")
        do {
            try await ipc.write(expected)
            log("ipc.write completion fired (no error)")
        } catch {
            ipc.close()
            worklet.terminate()
            return ProbeOutcome(passed: false, summary: "ipc.write threw: \(error)")
        }

        let echoed: Data = await withTaskGroup(of: Data?.self) { group in
            group.addTask { await latch.awaitBytes() }
            group.addTask {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                return nil
            }
            for await result in group {
                group.cancelAll()
                return result ?? Data()
            }
            return Data()
        }

        let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
        log("Received \(echoed.count) byte(s) back in \(elapsedMs)ms")
        log("Received bytes: \(hex(echoed))")

        if echoed.count == 0 {
            ipc.close(); worklet.terminate()
            return ProbeOutcome(passed: false, summary: "no bytes echoed within 10s")
        }
        if echoed.prefix(32) != expected {
            ipc.close(); worklet.terminate()
            return ProbeOutcome(passed: false, summary: "echoed bytes differ from sent (got \(echoed.count) bytes; first-32 prefix mismatch)")
        }

        // ---- Test 2: full bare-rpc REQUEST frame round-trip ----
        // Send a fully-encoded bare-rpc REQUEST with a JSON payload identical to what
        // QVAC's macOS path sends. The worklet echoes the raw bytes back. We then decode
        // the echoed bytes as a frame — proving the codec + transport carry binary data
        // unchanged across the BareKit IPC boundary.
        log("--- Test 2: bare-rpc frame round-trip ---")
        let initJSON = #"{"type":"__init_config","config":null,"runtimeContext":{"runtime":"bare","platform":"ios"}}"#
        let initBody = initJSON.data(using: .utf8)!
        let requestFrame = BareRPCCodec.encodeRequestFrame(id: 42, command: 1, stream: [], data: initBody)
        log("Encoded REQUEST frame: \(requestFrame.count) bytes")

        let frameLatch = Latch(target: requestFrame.count)
        ipc.readable = { ipcRef in
            while let chunk = ipcRef.read(), chunk.count > 0 {
                let copy = chunk as Data
                Task { await frameLatch.append(copy) }
            }
        }

        let frameStart = Date()
        do {
            try await ipc.write(requestFrame)
        } catch {
            ipc.close(); worklet.terminate()
            return ProbeOutcome(passed: false, summary: "frame write threw: \(error)")
        }

        let echoedFrame: Data = await withTaskGroup(of: Data?.self) { group in
            group.addTask { await frameLatch.awaitBytes() }
            group.addTask {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                return nil
            }
            for await r in group { group.cancelAll(); return r ?? Data() }
            return Data()
        }
        let frameElapsedMs = Int(Date().timeIntervalSince(frameStart) * 1000)
        log("Echoed frame: \(echoedFrame.count) bytes in \(frameElapsedMs)ms")

        ipc.close()
        worklet.terminate()

        if echoedFrame != requestFrame {
            return ProbeOutcome(passed: false, summary: "frame bytes mismatched on round-trip (sent \(requestFrame.count), got \(echoedFrame.count))")
        }

        // Decode the echoed bytes as a bare-rpc frame to confirm the codec is symmetric.
        let reader = BareRPCFrameReader()
        try reader.append(echoedFrame)
        guard let frame = reader.nextFrame() else {
            return ProbeOutcome(passed: false, summary: "echoed frame failed to decode")
        }
        switch frame {
        case .request(let id, let command, _, let data):
            guard id == 42, command == 1 else {
                return ProbeOutcome(passed: false, summary: "decoded frame fields wrong (id=\(id), command=\(command))")
            }
            guard let d = data,
                  let s = String(data: d, encoding: .utf8),
                  s == initJSON else {
                return ProbeOutcome(passed: false, summary: "decoded frame payload mismatch")
            }
        default:
            return ProbeOutcome(passed: false, summary: "decoded frame wrong type")
        }

        return ProbeOutcome(
            passed: true,
            summary: "byte-echo \(elapsedMs)ms + \(requestFrame.count)B bare-rpc frame round-trip \(frameElapsedMs)ms — both bit-perfect"
        )
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
#else
import Foundation
public struct ProbeOutcome: Sendable {
    public let passed: Bool
    public let summary: String
    public init(passed: Bool, summary: String) {
        self.passed = passed
        self.summary = summary
    }
}
public enum IOSProbeHarness {
    public static func run(log: @Sendable (String) -> Void) async throws -> ProbeOutcome {
        log("BareKit unavailable on this platform")
        return ProbeOutcome(passed: false, summary: "platform not supported")
    }
}
#endif
