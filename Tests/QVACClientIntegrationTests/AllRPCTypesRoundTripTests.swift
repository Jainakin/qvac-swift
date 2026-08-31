// AllRPCTypesRoundTripTests — AC-4 evidence.
//
// The grant requires: "All RPC message types round-trip correctly (encode → send →
// receive → decode) against the Bare worker." The other live-worker tests only cover
// init, heartbeat, downloadAsset stream, cancel error, and close. This file fires every
// public QVACClient method at a real worker and asserts the wire format is intact:
//
//   - Success path: the worker decoded our request and we decoded its response — done.
//   - Application error path: the worker decoded our request and returned a typed error
//     envelope (e.g. "model not loaded", "asset URL invalid"). Wire format is good.
//   - Wire/protocol error path: encoding/decoding failed on either side. THIS is what
//     the test guards against — we count any thrown `QVACError.encoding` or `.protocolViolation`
//     as a hard failure.
//
// Requires `QVAC_BARE_BIN` + `QVAC_NODE_MODULES` set (CI sets these in the
// `integration-macos` job). Skipped otherwise.

import XCTest
@testable import QVACClient

#if canImport(Darwin)
import Darwin

final class AllRPCTypesRoundTripTests: XCTestCase {

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
            case .transport(let reason, _):
                XCTFail("\(name): transport failure — \(reason)", file: file, line: line)
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
            }
        } catch {
            XCTFail("\(name): unexpected error type — \(error)", file: file, line: line)
        }
    }

    /// A missing model can make the worker fail a duplex response immediately after
    /// opening both half-streams. In that ordering the remote error has already closed
    /// the request half by the time `end()` runs, so `end()` reports a local closed-stream
    /// error even though the authoritative application error remains available from the
    /// response half. Always drain that response before deciding which failure to report.
    private func finishDuplexProbe(
        end: () async throws -> Void,
        drainResponses: () async throws -> Void
    ) async throws {
        let endError: Error?
        do {
            try await end()
            endError = nil
        } catch {
            endError = error
        }

        do {
            try await drainResponses()
        } catch {
            throw error
        }
        if let endError { throw endError }
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
            await self.assertWireRoundTrip("bciTranscribeStream") {
                let session = try await client.bciTranscribeStream(
                    modelId: missingModel,
                    rpcOptions: rpc
                )
                try await self.finishDuplexProbe(
                    end: { try await session.end() },
                    drainResponses: { for try await _ in session.events {} }
                )
            }

            exercised.append("completionOrchestrate")
            await self.assertWireRoundTrip("completionOrchestrate") {
                let session = try await client.completionOrchestrate(
                    modelId: missingModel,
                    history: [.user("hello")],
                    tools: [],
                    rpcOptions: rpc
                )
                try await self.finishDuplexProbe(
                    end: { try await session.end() },
                    drainResponses: { for try await _ in session.events {} }
                )
            }

            exercised.append("textToSpeechStream")
            await self.assertWireRoundTrip("textToSpeechStream") {
                let session = try await client.textToSpeechStream(
                    modelId: missingModel,
                    rpcOptions: rpc
                )
                try await self.finishDuplexProbe(
                    end: { try await session.end() },
                    drainResponses: { for try await _ in session.chunks {} }
                )
            }

            exercised.append("transcribeStream")
            await self.assertWireRoundTrip("transcribeStream") {
                let session = try await client.transcribeStream(
                    modelId: missingModel,
                    rpcOptions: rpc
                )
                try await self.finishDuplexProbe(
                    end: { try await session.end() },
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
