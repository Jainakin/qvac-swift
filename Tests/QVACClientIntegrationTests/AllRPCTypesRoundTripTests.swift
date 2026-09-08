// Exercises every public operation against a live Bare worker. Both successful
// responses and typed application errors demonstrate a complete request/response
// round trip. Encoding errors and protocol violations fail the suite.
//
// Requires `QVAC_BARE_BIN` and `QVAC_NODE_MODULES`. Required CI wrappers reject
// missing configuration or skipped tests.

import XCTest
@testable import QVACClient

#if canImport(Darwin)
import Darwin

final class AllRPCTypesRoundTripTests: XCTestCase {

    private struct DuplexProbeTimeout: Error, Sendable, CustomStringConvertible {
        let operation: String
        let timeout: Duration

        var description: String {
            "\(operation) did not return its missing-model response within \(timeout)"
        }
    }

    private struct DuplexProbeFailure: Error, Sendable, CustomStringConvertible {
        let operation: String
        let diagnostic: String

        var description: String {
            "\(operation) failed with an unexpected error: \(diagnostic)"
        }
    }

    private enum DuplexProbeOutcome: Sendable {
        case completed
        case failed(QVACError)
        case failedUnexpectedly(String)
        case timedOut
        case cancelled
    }

    /// A single-consumer race whose first resolution resumes the waiter exactly once.
    /// The lock is the synchronization boundary for both the buffered outcome and the
    /// continuation. Losing unstructured tasks may finish later, but the caller does not
    /// await them and subsequent resolutions are ignored.
    private final class DuplexProbeRace: @unchecked Sendable {
        private let lock = NSLock()
        private var outcome: DuplexProbeOutcome?
        private var continuation: CheckedContinuation<DuplexProbeOutcome, Never>?

        func wait() async -> DuplexProbeOutcome {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let immediate: DuplexProbeOutcome? = lock.withLock {
                        if let outcome { return outcome }
                        self.continuation = continuation
                        return nil
                    }
                    if let immediate {
                        continuation.resume(returning: immediate)
                    }
                }
            } onCancel: {
                self.resolve(.cancelled)
            }
        }

        func resolve(_ outcome: DuplexProbeOutcome) {
            let continuation: CheckedContinuation<DuplexProbeOutcome, Never>? = lock.withLock {
                guard self.outcome == nil else { return nil }
                self.outcome = outcome
                let continuation = self.continuation
                self.continuation = nil
                return continuation
            }
            continuation?.resume(returning: outcome)
        }
    }

    /// Cancellation-oblivious one-shot gate used to prove that the probe deadline never
    /// waits for a losing drain task. Tests explicitly open every gate before returning.
    private final class DuplexProbeGate: @unchecked Sendable {
        private let lock = NSLock()
        private var isOpen = false
        private var continuation: CheckedContinuation<Void, Never>?

        var hasOpened: Bool { lock.withLock { isOpen } }

        func wait() async {
            await withCheckedContinuation { continuation in
                let resumeImmediately: Bool = lock.withLock {
                    guard !isOpen else { return true }
                    precondition(self.continuation == nil, "DuplexProbeGate supports one waiter")
                    self.continuation = continuation
                    return false
                }
                if resumeImmediately { continuation.resume() }
            }
        }

        func open() {
            let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
                guard !isOpen else { return nil }
                isOpen = true
                let continuation = self.continuation
                self.continuation = nil
                return continuation
            }
            continuation?.resume()
        }
    }

    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0

        var value: Int { lock.withLock { storage } }

        func increment() {
            lock.withLock { storage += 1 }
        }
    }

    private static let bareBin: URL? = {
        if let p = ProcessInfo.processInfo.environment["QVAC_BARE_BIN"] {
            return URL(fileURLWithPath: p)
        }
        let p = "/opt/homebrew/bin/bare"
        return FileManager.default.fileExists(atPath: p) ? URL(fileURLWithPath: p) : nil
    }()

    private static let nodeModulesDir: URL? = {
        if let p = ProcessInfo.processInfo.environment["QVAC_NODE_MODULES"] {
            return URL(fileURLWithPath: p)
        }
        return nil
    }()

    override func setUpWithError() throws {
        try XCTSkipUnless(Self.bareBin != nil, "set QVAC_BARE_BIN")
        try XCTSkipUnless(Self.nodeModulesDir != nil, "set QVAC_NODE_MODULES")
        guard FileManager.default.isExecutableFile(atPath: Self.bareBin!.path) else {
            throw IntegrationPrerequisiteError("QVAC_BARE_BIN is not executable")
        }
        let packageJSON = Self.nodeModulesDir!.appendingPathComponent("@qvac/sdk/package.json")
        guard let data = try? Data(contentsOf: packageJSON),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["version"] as? String == "0.17.0" else {
            throw IntegrationPrerequisiteError(
                "QVAC_NODE_MODULES must contain exact @qvac/sdk 0.17.0 from tools/runtime/package-lock.json"
            )
        }
    }

    /// Decide whether a thrown error from the public API counts as a successful
    /// round-trip. We accept:
    ///   - the call did not throw at all (worker processed the request, we decoded the response)
    ///   - `QVACError.server(...)` / `.serverUntyped(...)` — worker returned a typed
    ///      or addon-defined error envelope; wire format OK
    /// We FAIL on:
    ///   - `QVACError.encoding(...)` — Swift couldn't decode the worker's response
    ///   - `QVACError.protocolViolation(...)` — wire-format invariant violated
    ///   - local timeout / transport / cancellation — the call did not complete a
    ///     bounded exchange with the live worker
    private func assertWireRoundTrip(
        _ name: String,
        file: StaticString = #file, line: UInt = #line,
        block: () async throws -> Void
    ) async {
        do {
            try await block()
        } catch let e as QVACError {
            switch e {
            case .encoding(let msg):
                XCTFail("\(name): wire decode failure — \(msg)", file: file, line: line)
            case .protocolViolation(let msg):
                XCTFail("\(name): protocol violation — \(msg)", file: file, line: line)
            case .server, .serverUntyped, .inferenceCancelled:
                // Application-level error; wire format succeeded. AC-4 met.
                break
            case .client(let code, let message):
                XCTFail(
                    "\(name): local SDK failure \(code.name) — \(message ?? "no message")",
                    file: file,
                    line: line
                )
            case .transport(let reason, let underlying):
                XCTFail(
                    "\(name): transport failure — \(reason); "
                        + "underlying=\(String(reflecting: underlying))",
                    file: file,
                    line: line
                )
            case .connectionReset:
                XCTFail("\(name): worker reconnected and lost in-memory state", file: file, line: line)
            case .requestTimedOut:
                XCTFail("\(name): request unexpectedly timed out", file: file, line: line)
            case .invalidArgument(let message):
                XCTFail("\(name): invalid local argument — \(message)", file: file, line: line)
            case .streamBufferOverflow(let operation, let maximumBytes, let attemptedBytes):
                XCTFail(
                    "\(name): \(operation) buffered \(attemptedBytes) bytes, limit \(maximumBytes)",
                    file: file,
                    line: line
                )
            case .resourceLimitExceeded(
                let operation,
                let resource,
                let maximumBytes,
                let attemptedBytes
            ):
                XCTFail(
                    "\(name): \(operation) \(resource) reached \(attemptedBytes) bytes, "
                        + "limit \(maximumBytes)",
                    file: file,
                    line: line
                )
            }
        } catch {
            XCTFail("\(name): unexpected error type — \(error)", file: file, line: line)
        }
    }

    /// The pinned QVAC 0.17 missing-model paths return without awaiting additional
    /// request-stream input or a local half-close. Completion orchestration starts its
    /// background tool-result reader first, but model resolution does not await it.
    /// Starting `end()` here would race the worker's own request-half teardown and could
    /// correctly fail-close the transport while a write is in flight. Drain first, bound
    /// the probe independently, and always destroy the session so a worker regression
    /// cannot leave this required suite hanging.
    private static func drainRejectedDuplexProbe(
        operation: String,
        timeout: Duration = .seconds(10),
        destroy: @escaping @Sendable () -> Void,
        drainResponses: @escaping @Sendable () async throws -> Void
    ) async throws {
        let race = DuplexProbeRace()
        let drainTask = Task {
            do {
                try await drainResponses()
                race.resolve(.completed)
            } catch let error as QVACError {
                race.resolve(.failed(error))
            } catch is CancellationError {
                race.resolve(.cancelled)
            } catch {
                race.resolve(.failedUnexpectedly(String(reflecting: error)))
            }
        }
        let timeoutTask = Task {
            do {
                try await Task.sleep(for: timeout)
                race.resolve(.timedOut)
            } catch {
                // The probe resolved through its response or caller cancellation.
            }
        }

        let outcome = await race.wait()
        destroy()
        drainTask.cancel()
        timeoutTask.cancel()

        switch outcome {
        case .completed:
            return
        case .failed(let error):
            throw error
        case .failedUnexpectedly(let diagnostic):
            throw DuplexProbeFailure(operation: operation, diagnostic: diagnostic)
        case .timedOut:
            throw DuplexProbeTimeout(operation: operation, timeout: timeout)
        case .cancelled:
            throw CancellationError()
        }
    }

    /// Exercise both deadline and caller-cancellation paths with a drain that deliberately
    /// ignores cancellation. The safety tasks bound a broken implementation; the assertions
    /// prove that a correct implementation returns before either losing drain can finish.
    private func assertDuplexProbeWatchdogSemantics(
        file: StaticString = #file,
        line: UInt = #line
    ) async {
        let timeoutRelease = DuplexProbeGate()
        let timeoutDrainFinished = DuplexProbeGate()
        let timeoutDestroyCount = LockedCounter()
        let timeoutSafety = Task {
            do {
                try await Task.sleep(for: .seconds(2))
                timeoutRelease.open()
            } catch {}
        }
        do {
            try await Self.drainRejectedDuplexProbe(
                operation: "watchdog-timeout-self-test",
                timeout: .zero,
                destroy: { timeoutDestroyCount.increment() },
                drainResponses: {
                    await timeoutRelease.wait()
                    timeoutDrainFinished.open()
                }
            )
            XCTFail("deadline probe unexpectedly completed", file: file, line: line)
        } catch is DuplexProbeTimeout {
            // expected
        } catch {
            XCTFail("deadline probe returned \(error)", file: file, line: line)
        }
        XCTAssertFalse(
            timeoutDrainFinished.hasOpened,
            "deadline waited for a cancellation-oblivious drain task",
            file: file,
            line: line
        )
        timeoutRelease.open()
        await timeoutDrainFinished.wait()
        timeoutSafety.cancel()
        _ = await timeoutSafety.result
        XCTAssertEqual(timeoutDestroyCount.value, 1, file: file, line: line)

        let cancellationRelease = DuplexProbeGate()
        let cancellationDrainFinished = DuplexProbeGate()
        let cancellationDestroyCount = LockedCounter()
        let cancellationSafety = Task {
            do {
                try await Task.sleep(for: .seconds(2))
                cancellationRelease.open()
            } catch {}
        }
        let cancellationOperation: @Sendable () async -> String = {
            do {
                try await Self.drainRejectedDuplexProbe(
                    operation: "watchdog-cancellation-self-test",
                    timeout: .seconds(10),
                    destroy: { cancellationDestroyCount.increment() },
                    drainResponses: {
                        await cancellationRelease.wait()
                        cancellationDrainFinished.open()
                    }
                )
                return "completed"
            } catch is CancellationError {
                return "cancelled"
            } catch {
                return "failed: \(String(reflecting: error))"
            }
        }
        let cancelledProbe = Task(operation: cancellationOperation)
        cancelledProbe.cancel()
        let cancellationResult = await cancelledProbe.value
        XCTAssertFalse(
            cancellationDrainFinished.hasOpened,
            "caller cancellation waited for a cancellation-oblivious drain task",
            file: file,
            line: line
        )
        cancellationRelease.open()
        await cancellationDrainFinished.wait()
        cancellationSafety.cancel()
        _ = await cancellationSafety.result
        XCTAssertEqual(cancellationResult, "cancelled", file: file, line: line)
        XCTAssertEqual(cancellationDestroyCount.value, 1, file: file, line: line)
    }

    /// The pinned worker must report the typed application error and keep the shared
    /// process usable; either a transport substitute or an implicit reconnect is a failure.
    private func assertMissingModelDuplexRoundTrip(
        _ name: String,
        client: QVACClient,
        file: StaticString = #file,
        line: UInt = #line,
        block: () async throws -> Void
    ) async {
        var receivedExpectedError = false
        do {
            try await block()
            XCTFail("\(name): missing-model probe unexpectedly succeeded", file: file, line: line)
        } catch let error as QVACError {
            switch error {
            case .server(let code, let message):
                XCTAssertEqual(code, .modelNotFound, file: file, line: line)
                XCTAssertFalse(
                    message?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true,
                    "\(name): worker returned an empty missing-model diagnostic",
                    file: file,
                    line: line
                )
                receivedExpectedError = code == .modelNotFound
            case .transport(let reason, let underlying):
                XCTFail(
                    "\(name): transport failure — \(reason); "
                        + "underlying=\(String(reflecting: underlying))",
                    file: file,
                    line: line
                )
            default:
                XCTFail("\(name): expected modelNotFound, got \(error)", file: file, line: line)
            }
        } catch {
            XCTFail("\(name): unexpected error type — \(error)", file: file, line: line)
        }

        guard receivedExpectedError else { return }
        do {
            let heartbeat = try await client.heartbeat(
                rpcOptions: .init(timeout: .seconds(5))
            )
            XCTAssertGreaterThan(
                heartbeat.number,
                0,
                "\(name): worker generation was not reusable after rejection",
                file: file,
                line: line
            )
        } catch {
            XCTFail(
                "\(name): worker generation was not reusable after rejection — \(error)",
                file: file,
                line: line
            )
        }
    }

    /// Build a fresh client, run the closure, close.
    private func withClient(_ body: (QVACClient) async throws -> Void) async throws {
        let cfg = try QVACClient.Configuration.macOS(
            nodeModulesDir: Self.nodeModulesDir!,
            bareExecutable: Self.bareBin!,
            initTimeout: 60.0
        )
        let client = try await QVACClient(
            configuration: cfg,
            initHandshakeTimeout: .seconds(60)
        )
        do {
            try await body(client)
        } catch {
            await client.close()
            throw error
        }
        await client.close()
    }

    // MARK: - The actual round-trip

    func test_all_public_apis_round_trip_at_the_wire_level() async throws {
        await assertDuplexProbeWatchdogSemantics()

        try await withClient { client in
            let rpc = QVACRPCOptions(timeout: .seconds(5))
            let registryRPC = QVACRPCOptions(timeout: .seconds(60))
            let providerRPC = QVACRPCOptions(timeout: .seconds(60))
            let missingModel = "__qvac_017_wire_probe_missing__"
            let missingAsset = "/__qvac_017_wire_probe_missing__.gguf"
            var exercised: [String] = []

            exercised.append("heartbeat")
            await self.assertWireRoundTrip("heartbeat") {
                let heartbeat = try await client.heartbeat(rpcOptions: rpc)
                XCTAssertGreaterThan(heartbeat.number, 0)
            }

            // The 0.17 worker retains global startup logs for five seconds. Open
            // this stream immediately after init/heartbeat so the probe observes
            // real buffered data instead of timing out after unrelated calls.
            exercised.append("loggingStream")
            await self.assertWireRoundTrip("loggingStream") {
                let stream = try await client.loggingStream(id: "__all__", rpcOptions: rpc)
                var iterator = stream.makeAsyncIterator()
                let firstLog = try await iterator.next()
                XCTAssertNotNil(firstLog, "global SDK log stream should emit a buffered startup log")
            }

            exercised.append("cancel")
            await self.assertWireRoundTrip("cancel") {
                try await client.cancel(
                    .request(requestId: "__qvac_017_no_such_request__"),
                    rpcOptions: rpc
                )
            }

            exercised.append("getSystemResources")
            await self.assertWireRoundTrip("getSystemResources") {
                _ = try await client.getSystemResources(sample: false, rpcOptions: rpc)
            }

            exercised.append("state")
            await self.assertWireRoundTrip("state") {
                _ = try await client.state(rpcOptions: rpc)
            }

            exercised.append("modelRegistryList")
            await self.assertWireRoundTrip("modelRegistryList") {
                _ = try await client.modelRegistryList(rpcOptions: registryRPC)
            }

            exercised.append("modelRegistrySearch")
            await self.assertWireRoundTrip("modelRegistrySearch") {
                _ = try await client.modelRegistrySearch(
                    filter: "__qvac_017_no_match__",
                    rpcOptions: registryRPC
                )
            }

            exercised.append("modelRegistryGetModel")
            await self.assertWireRoundTrip("modelRegistryGetModel") {
                _ = try await client.modelRegistryGetModel(
                    registryPath: "__qvac_017_no_match__",
                    registrySource: "huggingface",
                    rpcOptions: registryRPC
                )
            }

            exercised.append("getModelInfo")
            await self.assertWireRoundTrip("getModelInfo") {
                _ = try await client.getModelInfo(name: missingModel, rpcOptions: rpc)
            }

            exercised.append("getLoadedModelInfo")
            await self.assertWireRoundTrip("getLoadedModelInfo") {
                _ = try await client.getLoadedModelInfo(modelId: missingModel, rpcOptions: rpc)
            }

            exercised.append("downloadAsset")
            await self.assertWireRoundTrip("downloadAsset") {
                let run = try await client.downloadAsset(
                    assetSrc: missingAsset,
                    seed: false,
                    rpcOptions: rpc
                )
                _ = try await run.result.value
            }

            exercised.append("loadModel")
            await self.assertWireRoundTrip("loadModel") {
                let run = try await client.loadModel(
                    modelSrc: missingAsset,
                    modelType: "llamacpp-completion",
                    rpcOptions: rpc
                )
                _ = try await run.result.value
            }

            exercised.append("embed")
            await self.assertWireRoundTrip("embed") {
                let run = try await client.embed(
                    modelId: missingModel,
                    text: "hello",
                    rpcOptions: rpc
                )
                _ = try await run.result.value
            }

            exercised.append("completionStream")
            await self.assertWireRoundTrip("completionStream") {
                let run = try await client.completion(
                    modelId: missingModel,
                    history: [.user("hello")],
                    rpcOptions: rpc
                )
                _ = try await run.final.value
            }

            exercised.append("diffusionStream")
            await self.assertWireRoundTrip("diffusionStream") {
                let run = try await client.diffusion(
                    modelId: missingModel,
                    prompt: "wire probe",
                    rpcOptions: rpc
                )
                _ = try await run.outputs.value
            }

            exercised.append("ocrStream")
            await self.assertWireRoundTrip("ocrStream") {
                let run = try await client.ocr(
                    modelId: missingModel,
                    imageBytes: Data([0x89, 0x50, 0x4E, 0x47]),
                    options: nil,
                    rpcOptions: rpc
                )
                _ = try await run.blocks.value
            }

            exercised.append("textToSpeech")
            await self.assertWireRoundTrip("textToSpeech") {
                let run = try await client.textToSpeech(
                    modelId: missingModel,
                    text: "hello",
                    rpcOptions: rpc
                )
                _ = try await run.buffer.value
            }

            exercised.append("transcribe")
            await self.assertWireRoundTrip("transcribe") {
                let run = try await client.transcribe(
                    modelId: missingModel,
                    audioBytes: Data([0, 1, 2]),
                    prompt: nil,
                    rpcOptions: rpc
                )
                _ = try await run.result.value
            }

            exercised.append("translate")
            await self.assertWireRoundTrip("translate") {
                let run = try await client.translate(
                    modelId: missingModel,
                    modelType: "nmtcpp-translation",
                    text: "hello",
                    stream: false,
                    rpcOptions: rpc
                )
                _ = try await run.text.value
            }

            exercised.append("upscaleStream")
            await self.assertWireRoundTrip("upscaleStream") {
                let run = try await client.upscale(
                    modelId: missingModel,
                    image: Data([0x89, 0x50, 0x4E, 0x47]),
                    rpcOptions: rpc
                )
                _ = try await run.outputs.value
            }

            exercised.append("videoStream")
            await self.assertWireRoundTrip("videoStream") {
                let run = try await client.video(
                    modelId: missingModel,
                    mode: "txt2vid",
                    prompt: "wire probe",
                    rpcOptions: rpc
                )
                _ = try await run.outputs.value
            }

            exercised.append("classify")
            await self.assertWireRoundTrip("classify") {
                _ = try await client.classify(
                    modelId: missingModel,
                    image: Data([0x89, 0x50, 0x4E, 0x47]),
                    rpcOptions: rpc
                )
            }

            exercised.append("audioGenStream")
            await self.assertWireRoundTrip("audioGenStream") {
                let run = try await client.audioGen(
                    modelId: missingModel,
                    caption: "wire probe",
                    rpcOptions: rpc
                )
                _ = try await run.audio.value
            }

            exercised.append("batchCompletionStream")
            await self.assertWireRoundTrip("batchCompletionStream") {
                let run = try await client.batchCompletion(
                    modelId: missingModel,
                    prompts: [.init(id: "p1", history: [.user("hello")])],
                    rpcOptions: rpc
                )
                _ = try await run.results.value
            }

            exercised.append("bciTranscribe")
            await self.assertWireRoundTrip("bciTranscribe") {
                let run = try await client.bciTranscribe(
                    modelId: missingModel,
                    neuralData: .data(Data([0, 1, 2])),
                    rpcOptions: rpc
                )
                _ = try await run.result.value
            }

            exercised.append("pluginInvoke")
            await self.assertWireRoundTrip("pluginInvoke") {
                _ = try await client.invokePlugin(
                    modelId: missingModel,
                    handler: "__qvac_017_no_handler__",
                    params: ["probe": true],
                    as: JSONValue.self,
                    rpcOptions: rpc
                )
            }

            exercised.append("pluginInvokeStream")
            await self.assertWireRoundTrip("pluginInvokeStream") {
                let stream = try await client.invokePluginStream(
                    modelId: missingModel,
                    handler: "__qvac_017_no_handler__",
                    params: ["probe": true],
                    as: JSONValue.self,
                    rpcOptions: rpc
                )
                for try await _ in stream {}
            }

            exercised.append("rag")
            await self.assertWireRoundTrip("rag") {
                _ = try await client.ragListWorkspaces(rpcOptions: rpc)
            }

            exercised.append("finetune")
            await self.assertWireRoundTrip("finetune") {
                _ = try await client.finetune(
                    .init(modelId: missingModel, operation: "cancel"),
                    rpcOptions: rpc
                )
            }

            exercised.append("deleteCache")
            await self.assertWireRoundTrip("deleteCache") {
                _ = try await client.deleteCache(
                    .init(modelId: missingModel),
                    rpcOptions: rpc
                )
            }

            exercised.append("bciTranscribeStream")
            await self.assertMissingModelDuplexRoundTrip(
                "bciTranscribeStream",
                client: client
            ) {
                let session = try await client.bciTranscribeStream(
                    modelId: missingModel,
                    rpcOptions: rpc
                )
                try await Self.drainRejectedDuplexProbe(
                    operation: "bciTranscribeStream",
                    destroy: { session.destroy() },
                    drainResponses: { for try await _ in session.events {} }
                )
            }

            exercised.append("completionOrchestrate")
            await self.assertMissingModelDuplexRoundTrip(
                "completionOrchestrate",
                client: client
            ) {
                let session = try await client.completionOrchestrate(
                    modelId: missingModel,
                    history: [.user("hello")],
                    tools: [],
                    rpcOptions: rpc
                )
                try await Self.drainRejectedDuplexProbe(
                    operation: "completionOrchestrate",
                    destroy: { session.destroy() },
                    drainResponses: { for try await _ in session.events {} }
                )
            }

            exercised.append("textToSpeechStream")
            await self.assertMissingModelDuplexRoundTrip(
                "textToSpeechStream",
                client: client
            ) {
                let session = try await client.textToSpeechStream(
                    modelId: missingModel,
                    rpcOptions: rpc
                )
                try await Self.drainRejectedDuplexProbe(
                    operation: "textToSpeechStream",
                    destroy: { session.destroy() },
                    drainResponses: { for try await _ in session.chunks {} }
                )
            }

            exercised.append("transcribeStream")
            await self.assertMissingModelDuplexRoundTrip(
                "transcribeStream",
                client: client
            ) {
                let session = try await client.transcribeStream(
                    modelId: missingModel,
                    rpcOptions: rpc
                )
                try await Self.drainRejectedDuplexProbe(
                    operation: "transcribeStream",
                    destroy: { session.destroy() },
                    drainResponses: { for try await _ in session.events {} }
                )
            }

            exercised.append("provide")
            await self.assertWireRoundTrip("provide") {
                _ = try await client.startQVACProvider(rpcOptions: providerRPC)
            }

            exercised.append("stopProvide")
            await self.assertWireRoundTrip("stopProvide") {
                _ = try await client.stopQVACProvider(rpcOptions: providerRPC)
            }

            exercised.append("suspend")
            await self.assertWireRoundTrip("suspend") {
                try await client.suspend(rpcOptions: rpc)
            }

            exercised.append("resume")
            await self.assertWireRoundTrip("resume") {
                try await client.resume(rpcOptions: rpc)
            }

            // Last only to keep lifecycle-sensitive calls grouped at the end; 0.17
            // keeps the client open after unloading its final model.
            exercised.append("unloadModel")
            await self.assertWireRoundTrip("unloadModel") {
                _ = try await client.unloadModel(modelId: missingModel, rpcOptions: rpc)
            }

            XCTAssertEqual(exercised.count, 39)
            XCTAssertEqual(
                Set(exercised),
                Set(QVACSDKContract.methods.map(\.name)),
                "live public-API coverage must exactly equal the published 0.17 manifest"
            )
        }
    }
}

#endif
