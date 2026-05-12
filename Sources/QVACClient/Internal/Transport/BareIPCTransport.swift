// BareIPCTransport — iOS path.
//
// Wraps BareKit's `BareWorklet` + `BareIPC` Objective-C objects as a `BareTransport`.
// The Bare worker runs in-process as a libuv pthread inside the host iOS app
// (no subprocess on iOS — Apple forbids it). All IPC is over the socketpair that
// BareKit's `BareIPC` wraps under the hood; we never touch the fd directly.
//
// Tested end-to-end in Examples/BareKitProbeApp on iPhone 17 simulator
// (see docs/spike-validations.md Spike-E and QVAC-004f).

#if canImport(BareKit) && os(iOS)
import Foundation
import BareKit
import OSLog

private let _bareKitLogger = Logger(subsystem: "io.qvac.client", category: "barekit")

public final class BareIPCTransport: BareTransport, @unchecked Sendable {

    public enum Error: Swift.Error, CustomStringConvertible {
        case workletInitFailed
        case ipcInitFailed
        case writeFailed(underlying: Swift.Error)

        public var description: String {
            switch self {
            case .workletInitFailed: return "BareWorklet init returned nil"
            case .ipcInitFailed:     return "BareIPC init returned nil"
            case .writeFailed(let u): return "BareIPC.write failed: \(u)"
            }
        }
    }

    public struct Configuration {
        /// Inline raw bare-bundle binary for the worklet (length-prefix + JSON header + assets).
        /// Typical use: the QVAC `worker.mobile.bundle` resource shipped in `QVACClient.bundle`
        /// (produced by `tools/bundle/unwrap-bundle.mjs` from `qvac bundle sdk` output).
        /// NOTE: pass raw bundle bytes here, not a JS wrapper — bare-module's `.bundle`
        /// extension handler parses this verbatim and rejects JS source.
        public var workletSource: Data
        /// Virtual file name used by the worklet's module loader for stack traces / require resolution.
        public var workletEntryName: String
        /// Arguments passed as `process.argv` inside the worklet (mirrors QVAC's JSON-arg pattern).
        public var arguments: [String]
        /// Optional memory ceiling (in bytes). 0 = use BareKit default.
        public var memoryLimit: UInt = 0
        /// Optional path to a bundle of assets for the worklet to access.
        public var assets: String?

        public init(
            workletSource: Data,
            workletEntryName: String = "/worker.bundle",
            arguments: [String] = [],
            memoryLimit: UInt = 0,
            assets: String? = nil
        ) {
            self.workletSource = workletSource
            self.workletEntryName = workletEntryName
            self.arguments = arguments
            self.memoryLimit = memoryLimit
            self.assets = assets
        }
    }

    private let worklet: BareWorklet
    private let ipc: BareIPC
    private var readContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation?
    private var closed = false
    private let lock = NSLock()

    public static func connect(_ config: Configuration) throws -> BareIPCTransport {
        _bareKitLogger.info("BareIPCTransport.connect: building BareWorkletConfiguration")
        guard let configObj = BareWorkletConfiguration.default() else {
            _bareKitLogger.error("BareWorkletConfiguration.default() returned nil")
            throw Error.workletInitFailed
        }
        if config.memoryLimit > 0 { configObj.memoryLimit = config.memoryLimit }
        if let assets = config.assets { configObj.assets = assets }

        _bareKitLogger.info("BareIPCTransport.connect: allocating BareWorklet")
        guard let worklet = BareWorklet(configuration: configObj) else {
            _bareKitLogger.error("BareWorklet(configuration:) returned nil")
            throw Error.workletInitFailed
        }

        _bareKitLogger.info("BareIPCTransport.connect: starting worklet entry=\(config.workletEntryName, privacy: .public) bundleBytes=\(config.workletSource.count, privacy: .public) argv=\(config.arguments, privacy: .public)")
        worklet.start(config.workletEntryName, source: config.workletSource, arguments: config.arguments)
        _bareKitLogger.info("BareIPCTransport.connect: worklet.start returned (fire-and-forget); allocating IPC")

        guard let ipc = BareIPC(worklet: worklet) else {
            _bareKitLogger.error("BareIPC(worklet:) returned nil — terminating worklet")
            worklet.terminate()
            throw Error.ipcInitFailed
        }
        _bareKitLogger.info("BareIPCTransport.connect: IPC ready")
        return BareIPCTransport(worklet: worklet, ipc: ipc)
    }

    private init(worklet: BareWorklet, ipc: BareIPC) {
        self.worklet = worklet
        self.ipc = ipc
        // Install the readable callback right away. BareIPC fires it on its internal GCD
        // queue (`to.holepunch.bare.kit.ipc`) so we marshal back via the continuation,
        // which is thread-safe per AsyncThrowingStream contract.
        ipc.readable = { [weak self] ipcRef in
            guard let self = self else { return }
            // Drain everything available on this fire — read() returns nil when empty.
            while let chunk = ipcRef.read(), chunk.count > 0 {
                _bareKitLogger.info("BareIPC <- worker: \(chunk.count, privacy: .public) bytes (first16=\((chunk as Data).prefix(16).map { String(format: "%02x", $0) }.joined(separator: " "), privacy: .public))")
                self.lock.lock()
                let cont = self.readContinuation
                self.lock.unlock()
                cont?.yield(chunk as Data)
            }
        }
    }

    /// Single-use — see UnixDomainSocketTransport.inboundStream() for the same
    /// invariant. Calling twice would silently abandon the first continuation.
    public func inboundStream() -> AsyncThrowingStream<Data, Swift.Error> {
        AsyncThrowingStream<Data, Swift.Error> { continuation in
            lock.lock()
            precondition(readContinuation == nil,
                         "BareIPCTransport.inboundStream() may be called only once per transport instance")
            readContinuation = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in await self?.close() }
            }
        }
    }

    public func write(_ data: Data) async throws {
        _bareKitLogger.info("BareIPC -> worker: \(data.count, privacy: .public) bytes (first16=\(data.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " "), privacy: .public))")
        do {
            try await ipc.write(data)
        } catch let err {
            _bareKitLogger.error("BareIPC -> worker FAILED: \(err.localizedDescription, privacy: .public)")
            throw Error.writeFailed(underlying: err)
        }
    }

    public func close() async {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        let cont = readContinuation
        readContinuation = nil
        lock.unlock()

        cont?.finish()
        ipc.close()
        worklet.terminate()
    }
}

#endif
