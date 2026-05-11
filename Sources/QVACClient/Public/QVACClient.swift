// QVACClient — the public entry point.
//
// Owns:
//   • A `BareRPCClient` (the codec + multiplexer)
//   • A `BareTransport` (UDS subprocess on macOS, BareKit worklet on iOS)
//   • A monotonic command-id counter (matches QVAC's JS commandCounter)
//
// API methods live in extensions in this same directory, one file per RPC group.
// All methods are isolated to this actor; cross-actor calls are explicit `await`s.

import Foundation

public actor QVACClient {

    /// Configuration for spawning the worker. Use one of the static `.macOS(…)` /
    /// `.iOS(…)` factories rather than constructing this manually.
    public enum Configuration: @unchecked Sendable {
        #if os(macOS) || os(Linux)
        case macOSSubprocess(UDSTransportConfiguration)
        #endif
        #if os(iOS)
        case iOSWorklet(BareIPCTransport.Configuration)
        #endif

        /// macOS convenience — auto-discovers `bare` on $PATH and uses the SDK's worker.js
        /// from the supplied node_modules dir.
        public static func macOS(
            nodeModulesDir: URL,
            bareExecutable: URL? = nil,
            initTimeout: TimeInterval = 30.0,
            environmentOverlay: [String: String] = [:]
        ) throws -> Configuration {
            #if os(macOS) || os(Linux)
            let workerScript = nodeModulesDir
                .appendingPathComponent("@qvac/sdk/dist/server/worker.js")
            let bare = bareExecutable ?? Self.discoverBareOnPath()
                ?? URL(fileURLWithPath: "/opt/homebrew/bin/bare")
            return .macOSSubprocess(UDSTransportConfiguration(
                bareExecutable: bare,
                workerScript: workerScript,
                workingDirectory: nodeModulesDir.deletingLastPathComponent(),
                initTimeout: initTimeout,
                environmentOverlay: environmentOverlay
            ))
            #else
            throw QVACError.transport(reason: "macOS configuration unavailable on this platform")
            #endif
        }

        #if os(iOS)
        /// iOS convenience — point at a `worker.mobile.bundle.js` shipped as a bundle resource.
        public static func iOS(
            workletBundleData: Data,
            entryName: String = "/worker.bundle",
            arguments: [String] = [],
            memoryLimit: UInt = 0
        ) -> Configuration {
            return .iOSWorklet(BareIPCTransport.Configuration(
                workletSource: workletBundleData,
                workletEntryName: entryName,
                arguments: arguments,
                memoryLimit: memoryLimit
            ))
        }

        /// iOS convenience that auto-loads the bundled `worker.mobile.bundle.js` resource
        /// shipped with the SPM package (vendored at release time by `tools/build/release.sh`).
        /// Use this when you depend on QVACClient via SPM and want the default plugin set.
        public static func iOSWithBundledResource(
            entryName: String = "/worker.bundle",
            arguments: [String] = [],
            memoryLimit: UInt = 0
        ) throws -> Configuration {
            guard let url = Bundle.module.url(forResource: "worker.mobile.bundle", withExtension: "js") else {
                throw QVACError.transport(reason: "worker.mobile.bundle.js not bundled in QVACClient resources")
            }
            let data = try Data(contentsOf: url)
            return iOS(
                workletBundleData: data,
                entryName: entryName,
                arguments: arguments,
                memoryLimit: memoryLimit
            )
        }
        #endif

        #if os(macOS) || os(Linux)
        private static func discoverBareOnPath() -> URL? {
            let candidates = [
                "/opt/homebrew/bin/bare",
                "/usr/local/bin/bare",
                "\(NSHomeDirectory())/.nvm/versions/node/current/bin/bare",
            ]
            for c in candidates where FileManager.default.fileExists(atPath: c) {
                return URL(fileURLWithPath: c)
            }
            return nil
        }
        #endif
    }

    // MARK: - State

    let transport: BareTransport
    let rpc: BareRPCClient
    private var commandCounter: UInt64 = 0
    private var initialized = false
    private var closed = false

    // MARK: - Lifecycle

    /// Construct + spawn the worker + perform the `__init_config` handshake.
    /// Equivalent to JS's lazy-init-on-first-call pattern, but explicit.
    public init(
        configuration: Configuration,
        runtimeContext: QVACRuntimeContext? = .current,
        config: JSONValue? = nil
    ) async throws {
        switch configuration {
        #if os(macOS) || os(Linux)
        case .macOSSubprocess(let cfg):
            do {
                self.transport = try await UnixDomainSocketTransport.connect(cfg)
            } catch let e as UnixDomainSocketTransport.SpawnError {
                throw QVACError.transport(reason: e.description, underlying: e)
            }
        #endif
        #if os(iOS)
        case .iOSWorklet(let cfg):
            do {
                self.transport = try BareIPCTransport.connect(cfg)
            } catch let e as BareIPCTransport.Error {
                throw QVACError.transport(reason: e.description, underlying: e)
            }
        #endif
        }
        self.rpc = BareRPCClient(transport: transport)

        do {
            try await QVACHandshake.sendInitConfig(
                on: rpc, config: config, runtimeContext: runtimeContext
            )
            self.initialized = true
        } catch let e as QVACInitConfigFailed {
            await rpc.close()
            throw QVACError.transport(reason: e.description, underlying: e)
        } catch {
            await rpc.close()
            throw error
        }
    }

    /// Tear down the connection and (on macOS) terminate the worker subprocess.
    /// Idempotent. Auto-invoked from `unloadModel` when the last model unloads
    /// (matches the JS client's auto-close behavior).
    public func close() async {
        if closed { return }
        closed = true
        await rpc.close()
    }

    deinit {
        if !closed { Task { [rpc] in await rpc.close() } }
    }

    // MARK: - Internal helpers used by every API method

    /// Allocate the next monotonic command id (mirrors JS `getNextCommandId`).
    func nextCommand() -> UInt64 {
        commandCounter = commandCounter &+ 1
        if commandCounter == 0 { commandCounter = 1 } // skip the events channel
        return commandCounter
    }

    /// Encode `request`, send as single-shot RPC, decode `Response`.
    /// Maps wire-level errors (`type: "error"` payloads) to `QVACError`.
    func sendTyped<Response: Decodable & Sendable>(
        _ request: QVACRequest,
        decoding _: Response.Type = Response.self
    ) async throws -> Response {
        try await assertOpen()
        let payload = try encode(request)
        let respData: Data?
        do {
            respData = try await rpc.send(command: nextCommand(), data: payload)
        } catch let e as BareRPCError {
            throw QVACError.fromWire(code: Int(e.errno), message: e.message)
        } catch {
            throw QVACError.transport(reason: "send failed", underlying: error)
        }
        guard let data = respData else {
            throw QVACError.protocolViolation("empty reply")
        }
        return try decodeOrThrow(Response.self, from: data)
    }

    /// Send `request`, stream NDJSON chunks back, decode each line into `Response`.
    /// Caller iterates the returned stream — errors propagate via throw.
    func streamTyped<Response: Decodable & Sendable>(
        _ request: QVACRequest,
        decoding _: Response.Type = Response.self
    ) async throws -> AsyncThrowingStream<Response, Error> {
        try await assertOpen()
        let payload = try encode(request)
        let cmd = nextCommand()
        let rawStream = try await rpc.stream(command: cmd, data: payload)
        return AsyncThrowingStream<Response, Error> { continuation in
            let task = Task<Void, Never> {
                do {
                    var buffer = Data()
                    for try await chunk in rawStream.chunks {
                        buffer.append(chunk)
                        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                            let lineData = buffer[buffer.startIndex..<newlineIndex]
                            buffer.removeSubrange(buffer.startIndex...newlineIndex)
                            if lineData.isEmpty { continue }
                            do {
                                let decoded: Response = try Self.decodeOrThrowStatic(Response.self, from: Data(lineData))
                                continuation.yield(decoded)
                            } catch {
                                continuation.finish(throwing: error)
                                return
                            }
                        }
                    }
                    // Drain any residual line at EOF.
                    let trimmed = buffer.filter { $0 != 0x20 && $0 != 0x0A && $0 != 0x0D && $0 != 0x09 }
                    if !trimmed.isEmpty {
                        let decoded: Response = try Self.decodeOrThrowStatic(Response.self, from: buffer)
                        continuation.yield(decoded)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                rawStream.destroy()
            }
        }
    }

    /// Open a duplex session, encode + send the initial JSON request, return a session
    /// the caller can `write(_:)` audio bytes to and iterate for NDJSON responses.
    func duplexTyped<Response: Decodable & Sendable>(
        _ request: QVACRequest,
        decoding _: Response.Type = Response.self
    ) async throws -> QVACDuplexSession<Response> {
        try await assertOpen()
        let payload = try encode(request)
        let cmd = nextCommand()
        let raw = try await rpc.duplex(command: cmd, initialPayload: payload)
        return QVACDuplexSession(raw: raw)
    }

    /// Encode a `QVACRequest` into JSON wire bytes.
    private func encode(_ request: QVACRequest) throws -> Data {
        do {
            return try JSONEncoder.qvac.encode(request)
        } catch {
            throw QVACError.encoding("could not encode request: \(error)")
        }
    }

    /// Decode a JSON wire payload into `Response`, checking for the `type: "error"`
    /// pattern that server-side errors travel as.
    private func decodeOrThrow<R: Decodable>(_ type: R.Type, from data: Data) throws -> R {
        return try Self.decodeOrThrowStatic(type, from: data)
    }

    /// Static so streams (which run outside actor isolation) can also use it.
    static func decodeOrThrowStatic<R: Decodable>(_ type: R.Type, from data: Data) throws -> R {
        // First peek at the discriminator: if it's "error", surface as QVACError directly.
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           obj["type"] as? String == "error" {
            let code = (obj["code"] as? Int) ?? 0
            let message = obj["message"] as? String
            throw QVACError.fromWire(code: code, message: message)
        }
        do {
            return try JSONDecoder().decode(R.self, from: data)
        } catch {
            throw QVACError.encoding("could not decode response: \(error)")
        }
    }

    private func assertOpen() async throws {
        if closed {
            throw QVACError.transport(reason: "client is closed")
        }
        if !initialized {
            throw QVACError.protocolViolation("client not initialized")
        }
    }
}

// MARK: - Public duplex session wrapper

/// Bidirectional session for audio APIs (`transcribeStream`, `textToSpeechStream`).
///
/// The session is single-use: iterate `responses` exactly once. Writes can be interleaved
/// with reads — they go on different bare-rpc stream directions, so there's no contention.
public final class QVACDuplexSession<Response: Sendable & Decodable>: @unchecked Sendable {
    private let raw: BareRPCDuplexSession
    private var consumed = false
    private let lock = NSLock()

    init(raw: BareRPCDuplexSession) { self.raw = raw }

    /// Write a chunk of arbitrary binary data to the server. For audio APIs this is
    /// raw PCM/Opus/wav bytes.
    public func write(_ chunk: Data) async {
        await raw.write(chunk)
    }

    /// Signal end-of-stream on the client→server direction. The server will still emit
    /// any pending responses before terminating its side.
    public func end() async {
        await raw.end()
    }

    /// Hard-terminate the whole session.
    public func destroy() {
        raw.destroy()
    }

    /// Async sequence of decoded responses. Single-use.
    public var responses: AsyncThrowingStream<Response, Error> {
        lock.lock(); defer { lock.unlock() }
        precondition(!consumed, "QVACDuplexSession.responses can only be iterated once")
        consumed = true
        let rawSession = raw
        return AsyncThrowingStream<Response, Error> { continuation in
            let task = Task<Void, Never> {
                do {
                    var buffer = Data()
                    for try await chunk in rawSession.chunks {
                        buffer.append(chunk)
                        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                            let lineData = buffer[buffer.startIndex..<newlineIndex]
                            buffer.removeSubrange(buffer.startIndex...newlineIndex)
                            if lineData.isEmpty { continue }
                            do {
                                let decoded: Response = try QVACClient.decodeOrThrowStatic(Response.self, from: Data(lineData))
                                continuation.yield(decoded)
                            } catch {
                                continuation.finish(throwing: error)
                                return
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                rawSession.destroy()
            }
        }
    }
}
