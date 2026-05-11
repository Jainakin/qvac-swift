import Foundation
import CompactEncoding
import BareRPC

setbuf(stdout, nil)  // unbuffered stdout for prompt log visibility

// MacOSProbe — end-to-end round-trip against a real Bare worker.
// Mirrors what `packages/sdk/client/rpc/node-rpc-client.ts` does on macOS.

// MARK: - Configuration

let BARE_BIN = "/opt/homebrew/bin/bare"
let SPIKE_JS_DIR = "/Users/hardik/Projects/qvac-swift/spike-js"
let WORKER_PATH = "\(SPIKE_JS_DIR)/node_modules/@qvac/sdk/dist/server/worker.js"
let FIXTURES_DIR = "/Users/hardik/Projects/qvac-swift/spike-js/fixtures-from-probe"

// MARK: - Helpers

func makeSocketPath() -> String {
    let pid = ProcessInfo.processInfo.processIdentifier
    let ts = String(Int(Date().timeIntervalSince1970 * 1000), radix: 36)
    var randBytes = [UInt8](repeating: 0, count: 2)
    _ = SecRandomCopyBytes(kSecRandomDefault, 2, &randBytes)
    let rand = randBytes.map { String(format: "%02x", $0) }.joined()
    let dir = ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp"
    return "\(dir.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/qvac-worker-\(pid)-\(ts)-\(rand).sock"
        .replacingOccurrences(of: "//", with: "/")
        .replacingOccurrences(of: "/private", with: "")  // macOS resolves /tmp → /private/tmp; keep paths sane
}

func makeSocketPathAbsolute() -> String {
    let tmp = NSTemporaryDirectory()
    let pid = ProcessInfo.processInfo.processIdentifier
    let ts = String(Int(Date().timeIntervalSince1970 * 1000), radix: 36)
    var randBytes = [UInt8](repeating: 0, count: 2)
    _ = SecRandomCopyBytes(kSecRandomDefault, 2, &randBytes)
    let rand = randBytes.map { String(format: "%02x", $0) }.joined()
    return tmp + "qvac-worker-\(pid)-\(ts)-\(rand).sock"
}

func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

func saveFixture(_ name: String, _ data: Data) {
    let url = URL(fileURLWithPath: FIXTURES_DIR).appendingPathComponent(name)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: url)
}

func log(_ s: String) {
    print("[\(Date().formatted(date: .omitted, time: .standard))] \(s)")
}

// MARK: - One-shot RPC helper

final class OneShotRPC {
    let fd: Int32
    let reader = BareRPCFrameReader()
    var nextId: UInt64 = 1

    init(fd: Int32) { self.fd = fd }

    func sendRequest(command: UInt64, json: String, fixtureName: String) throws -> UInt64 {
        let id = nextId; nextId += 1
        let body = json.data(using: .utf8)!
        let frame = BareRPCCodec.encodeRequestFrame(id: id, command: command, stream: [], data: body)
        log("→ REQUEST id=\(id) command=\(command) json=\(json)")
        log("  wire (\(frame.count) bytes): \(hex(frame).prefix(80))…")
        saveFixture("request_\(fixtureName).bin", frame)
        try PosixIO.writeAll(fd: fd, data: frame)
        return id
    }

    /// Open a duplex session: REQUEST(stream=OPEN, no data) + STREAM(RESPONSE|OPEN)
    /// + STREAM(REQUEST|DATA, data=JSON). Mirrors what node-rpc-client.ts createDuplexSession does.
    func openDuplex(command: UInt64, initialJSON: String, fixtureName: String) throws -> UInt64 {
        let id = nextId; nextId += 1
        let body = initialJSON.data(using: .utf8)!

        // (1) REQUEST with stream=OPEN — opens the outgoing request stream
        let req = BareRPCCodec.encodeRequestFrame(id: id, command: command, stream: [.open], data: nil)
        log("→ REQUEST id=\(id) command=\(command) stream=OPEN (open outbound)")
        saveFixture("duplex_\(fixtureName)_req_open.bin", req)
        try PosixIO.writeAll(fd: fd, data: req)

        // (2) STREAM with RESPONSE|OPEN — opens the incoming response stream
        let respOpen = BareRPCCodec.encodeStreamFrame(id: id, flags: [.response, .open])
        log("→ STREAM   id=\(id) flags=RESPONSE|OPEN")
        saveFixture("duplex_\(fixtureName)_resp_open.bin", respOpen)
        try PosixIO.writeAll(fd: fd, data: respOpen)

        // (3) STREAM with REQUEST|DATA carrying the initial JSON payload
        let payload = BareRPCCodec.encodeStreamFrame(id: id, flags: [.request, .data], data: body)
        log("→ STREAM   id=\(id) flags=REQUEST|DATA bytes=\(body.count) json=\(initialJSON)")
        saveFixture("duplex_\(fixtureName)_first_chunk.bin", payload)
        try PosixIO.writeAll(fd: fd, data: payload)

        return id
    }

    /// Open a streaming response: send REQUEST + immediately STREAM|RESPONSE|OPEN
    /// (mimics what JS bare-rpc's `req.createResponseStream({ eagerOpen: true })` does).
    func sendStreamingRequest(command: UInt64, json: String, fixtureName: String) throws -> UInt64 {
        let id = try sendRequest(command: command, json: json, fixtureName: fixtureName)
        let openFrame = BareRPCCodec.encodeStreamFrame(id: id, flags: [.response, .open], data: nil)
        log("→ STREAM   id=\(id) flags=RESPONSE|OPEN (open downstream)")
        log("  wire (\(openFrame.count) bytes): \(hex(openFrame))")
        saveFixture("request_\(fixtureName)_streamopen.bin", openFrame)
        try PosixIO.writeAll(fd: fd, data: openFrame)
        return id
    }

    /// Drains all frames for `expected` until a terminal one (RESPONSE for non-streamers,
    /// or STREAM with END/CLOSE for streamers). Returns every payload that arrived.
    func collectStream(
        expected: UInt64,
        terminalJSONType: String,
        fixtureName: String,
        timeoutMs: Int = 60_000
    ) throws -> [Data] {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMs) / 1000.0)
        var accumulated = Data()
        var payloads: [Data] = []
        var rawFrameIndex = 0
        while true {
            if let frame = reader.nextFrame() {
                switch frame {
                case .response(let id, let flags, let payload):
                    log("← frame#\(rawFrameIndex) RESPONSE id=\(id) flags=0x\(String(flags.rawValue, radix: 16))")
                    rawFrameIndex += 1
                    if id != expected { continue }
                    switch payload {
                    case .success(let data):
                        if let d = data, !d.isEmpty {
                            // RESPONSE with stream==0 → single-shot (not streaming)
                            payloads.append(d)
                            return payloads
                        }
                        // RESPONSE with stream≠0 → header for upcoming STREAM frames; keep reading
                    case .failure(let err): throw err
                    }
                case .stream(let id, let flags, let payload):
                    log("← frame#\(rawFrameIndex) STREAM   id=\(id) flags=0x\(String(flags.rawValue, radix: 16))")
                    rawFrameIndex += 1
                    if id != expected { continue }
                    switch payload {
                    case .data(let d):
                        // NDJSON: split on \n, push each line
                        if let s = String(data: d, encoding: .utf8) {
                            let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
                            for line in lines {
                                guard !line.isEmpty else { continue }
                                let bytes = Data(line.utf8)
                                payloads.append(bytes)
                                // peek at the type
                                if let obj = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                                   let t = obj["type"] as? String, t == terminalJSONType {
                                    saveFixture("stream_\(fixtureName)_assembled.bin", accumulated)
                                    return payloads
                                }
                            }
                        }
                    case .control:
                        if flags.contains(.end) || flags.contains(.close) || flags.contains(.destroy) {
                            saveFixture("stream_\(fixtureName)_assembled.bin", accumulated)
                            return payloads
                        }
                    case .error(let err): throw err
                    }
                case .request: continue
                }
                continue
            }
            let remainingMs = max(0, Int(deadline.timeIntervalSinceNow * 1000))
            if remainingMs == 0 { throw PosixError(errno: ETIMEDOUT, op: "stream-timeout") }
            let readable = try PosixIO.waitReadable(fd: fd, timeoutMs: min(1000, remainingMs))
            if !readable { continue }
            let chunk = try PosixIO.readSome(fd: fd)
            if chunk.isEmpty { throw PosixError(errno: ECONNRESET, op: "stream-eof") }
            log("  raw recv \(chunk.count) bytes: \(hex(chunk).prefix(120))")
            accumulated.append(chunk)
            try reader.append(chunk)
        }
    }

    /// Waits for a RESPONSE frame, returns its JSON payload bytes (or throws on error frame).
    func waitForResponse(matchingId expected: UInt64, fixtureName: String, timeoutMs: Int = 30_000) throws -> Data {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMs) / 1000.0)
        var accumulated = Data()
        while true {
            if let frame = reader.nextFrame() {
                switch frame {
                case .response(let id, _, let payload):
                    if id != expected {
                        log("⚠ Got RESPONSE id=\(id), expected \(expected). Continuing.")
                        continue
                    }
                    saveFixture("response_\(fixtureName)_assembled.bin", accumulated)
                    switch payload {
                    case .success(let data):
                        let d = data ?? Data()
                        log("← RESPONSE id=\(id) bytes=\(d.count)")
                        return d
                    case .failure(let err):
                        throw err
                    }
                case .stream, .request:
                    log("⚠ Unexpected frame: \(frame)")
                    continue
                }
            }
            let remainingMs = max(0, Int(deadline.timeIntervalSinceNow * 1000))
            if remainingMs == 0 {
                throw PosixError(errno: ETIMEDOUT, op: "rpc-response-timeout")
            }
            let readable = try PosixIO.waitReadable(fd: fd, timeoutMs: min(1000, remainingMs))
            if !readable { continue }
            let chunk = try PosixIO.readSome(fd: fd)
            if chunk.isEmpty {
                throw PosixError(errno: ECONNRESET, op: "rpc-eof-before-response")
            }
            log("  raw recv (\(chunk.count) bytes): \(hex(chunk).prefix(160))")
            accumulated.append(chunk)
            try reader.append(chunk)
        }
    }
}

// MARK: - Main

func run() throws {
    guard FileManager.default.fileExists(atPath: BARE_BIN) else {
        fatalError("bare not found at \(BARE_BIN)")
    }
    guard FileManager.default.fileExists(atPath: WORKER_PATH) else {
        fatalError("worker.js not found at \(WORKER_PATH)")
    }

    let socketPath = makeSocketPathAbsolute()
    log("Socket path: \(socketPath)")

    let listener = try PosixUDSListener(path: socketPath)
    log("Listening on UDS.")

    // Spawn bare worker
    let workerProc = Process()
    workerProc.executableURL = URL(fileURLWithPath: BARE_BIN)
    workerProc.currentDirectoryURL = URL(fileURLWithPath: SPIKE_JS_DIR)
    let initArg: [String: String] = [
        "QVAC_IPC_SOCKET_PATH": socketPath,
        "HOME_DIR": NSHomeDirectory(),
    ]
    let initArgJSON = String(data: try JSONSerialization.data(withJSONObject: initArg), encoding: .utf8)!
    workerProc.arguments = [WORKER_PATH, initArgJSON]

    let stderrPipe = Pipe()
    workerProc.standardError = stderrPipe
    let stdoutPipe = Pipe()
    workerProc.standardOutput = stdoutPipe
    log("Spawning bare worker: \(BARE_BIN) \(WORKER_PATH) <argv1>")
    try workerProc.run()
    log("Worker pid=\(workerProc.processIdentifier)")

    // Drain stdout/stderr asynchronously
    stdoutPipe.fileHandleForReading.readabilityHandler = { h in
        let d = h.availableData
        if !d.isEmpty, let s = String(data: d, encoding: .utf8) {
            FileHandle.standardError.write("[worker:stdout] \(s)".data(using: .utf8)!)
        }
    }
    stderrPipe.fileHandleForReading.readabilityHandler = { h in
        let d = h.availableData
        if !d.isEmpty, let s = String(data: d, encoding: .utf8) {
            FileHandle.standardError.write("[worker:stderr] \(s)".data(using: .utf8)!)
        }
    }

    defer {
        if workerProc.isRunning {
            log("Killing worker pid=\(workerProc.processIdentifier)")
            workerProc.terminate()
            workerProc.waitUntilExit()
        }
        listener.close()
    }

    let connFD = try listener.accept(timeoutMs: 30_000)
    log("Worker connected. fd=\(connFD)")
    defer { close(connFD) }

    let rpc = OneShotRPC(fd: connFD)

    // ---- __init_config ----
    let initJSON: [String: Any] = [
        "type": "__init_config",
        "config": NSNull(),
        "runtimeContext": [
            "runtime": "node",
            "platform": "darwin",
        ] as [String: Any],
    ]
    let initJSONString = String(
        data: try JSONSerialization.data(withJSONObject: initJSON, options: [.fragmentsAllowed]),
        encoding: .utf8
    )!
    let initId = try rpc.sendRequest(command: 1, json: initJSONString, fixtureName: "init_config")
    let initRespBytes = try rpc.waitForResponse(matchingId: initId, fixtureName: "init_config")
    let initRespJSON = try JSONSerialization.jsonObject(with: initRespBytes) as? [String: Any] ?? [:]
    log("__init_config response: \(initRespJSON)")
    guard initRespJSON["success"] as? Bool == true else {
        log("✗ init_config did not succeed")
        return
    }

    // ---- heartbeat ----
    let hbJSON: [String: Any] = ["type": "heartbeat"]
    let hbJSONString = String(
        data: try JSONSerialization.data(withJSONObject: hbJSON, options: [.fragmentsAllowed]),
        encoding: .utf8
    )!
    let hbId = try rpc.sendRequest(command: 2, json: hbJSONString, fixtureName: "heartbeat")
    let hbRespBytes = try rpc.waitForResponse(matchingId: hbId, fixtureName: "heartbeat")
    let hbRespJSON = try JSONSerialization.jsonObject(with: hbRespBytes) as? [String: Any] ?? [:]
    log("heartbeat response: \(hbRespJSON)")
    guard hbRespJSON["type"] as? String == "heartbeat" else {
        log("✗ heartbeat response wrong type")
        return
    }

    // ---- downloadAsset (streaming with withProgress: true) ----
    // Tiny public URL — bare-rpc-readme markdown, ~few KB.
    let daJSON: [String: Any] = [
        "type": "downloadAsset",
        "assetSrc": "https://raw.githubusercontent.com/holepunchto/bare-rpc/main/README.md",
        "withProgress": true,
    ]
    let daJSONString = String(
        data: try JSONSerialization.data(withJSONObject: daJSON, options: [.fragmentsAllowed]),
        encoding: .utf8
    )!
    let daId = try rpc.sendStreamingRequest(command: 3, json: daJSONString, fixtureName: "download_asset")
    let payloads = try rpc.collectStream(
        expected: daId,
        terminalJSONType: "downloadAsset",
        fixtureName: "download_asset",
        timeoutMs: 30_000
    )
    log("downloadAsset produced \(payloads.count) JSON payload(s):")
    for (i, p) in payloads.enumerated() {
        if let obj = try? JSONSerialization.jsonObject(with: p) as? [String: Any] {
            log("  [\(i)] type=\(obj["type"] ?? "?") keys=\(Array(obj.keys).sorted())")
        }
    }

    // ---- cancel (one-shot RPC) — send cancel for a non-existent inference ----
    let cancelJSON: [String: Any] = [
        "type": "cancel",
        "operation": "inference",
        "modelId": "this-model-id-does-not-exist",
    ]
    let cancelJSONString = String(
        data: try JSONSerialization.data(withJSONObject: cancelJSON, options: [.fragmentsAllowed]),
        encoding: .utf8
    )!
    let cancelId = try rpc.sendRequest(command: 4, json: cancelJSONString, fixtureName: "cancel")
    let cancelResp: Data
    do {
        cancelResp = try rpc.waitForResponse(matchingId: cancelId, fixtureName: "cancel", timeoutMs: 5_000)
        let obj = try JSONSerialization.jsonObject(with: cancelResp) as? [String: Any] ?? [:]
        log("cancel response (success path): \(obj)")
    } catch let e as BareRPCError {
        log("cancel returned error frame (expected for nonexistent model): code=\(e.code) message=\(e.message) errno=\(e.errno)")
    }

    // ---- duplex: transcribeStream with a non-existent model — observe error path ----
    let tsJSON: [String: Any] = [
        "type": "transcribeStream",
        "modelId": "no-such-whisper",
    ]
    let tsJSONString = String(
        data: try JSONSerialization.data(withJSONObject: tsJSON, options: [.fragmentsAllowed]),
        encoding: .utf8
    )!
    let tsId = try rpc.openDuplex(command: 5, initialJSON: tsJSONString, fixtureName: "transcribe_stream")
    do {
        let duplexPayloads = try rpc.collectStream(
            expected: tsId,
            terminalJSONType: "transcribeStream",
            fixtureName: "transcribe_stream",
            timeoutMs: 5_000
        )
        log("duplex produced \(duplexPayloads.count) payload(s):")
        for (i, p) in duplexPayloads.enumerated() {
            if let obj = try? JSONSerialization.jsonObject(with: p) as? [String: Any] {
                log("  [\(i)] type=\(obj["type"] ?? "?") keys=\(Array(obj.keys).sorted()) error=\(obj["error"] ?? "<none>")")
            }
        }
    } catch let e as BareRPCError {
        log("duplex returned error frame: code=\(e.code) message=\(e.message)")
    } catch let e as PosixError {
        log("duplex timed out (still validates that the duplex didn't reject the setup): \(e)")
    }

    log("✓ All round-trips succeeded.")
}

let runStart = Date()
do {
    try run()
} catch {
    log("ERROR: \(error)")
    exit(1)
}
log(String(format: "Total elapsed: %.3fs", Date().timeIntervalSince(runStart)))
