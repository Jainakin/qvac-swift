// Grant KR-2 — real streaming-completion latency, Swift versus JavaScript.
//
// `bench/run.sh` executes this release-built test in ten adjacent process pairs
// with execution-order allocation balanced against the exact @qvac/sdk 0.17
// JavaScript client. It is opt-in and requires the checksum-pinned model in
// `bench/workload.json`.
// Every process performs two fixed workload-representative preconditioning
// completions and then records all three fixed measurement completions.

import CryptoKit
import QVACClient
import XCTest

#if canImport(Darwin)
import Darwin

final class BenchmarkTests: XCTestCase {
    private struct Workload: Decodable {
        struct Model: Decodable {
            struct Configuration: Decodable {
                let ctxSize: Int
                let gpuLayers: Int
                let device: String
                let parallel: Int
                let verbosity: Int

                enum CodingKeys: String, CodingKey {
                    case ctxSize = "ctx_size"
                    case gpuLayers = "gpu_layers"
                    case device, parallel, verbosity
                }
            }

            let name: String
            let source: String
            let revision: String
            let byteCount: UInt64
            let sha256: String
            let modelType: String
            let config: Configuration

            enum CodingKeys: String, CodingKey {
                case name, source, revision, sha256, config
                case byteCount = "byte_count"
                case modelType = "model_type"
            }
        }

        struct Generation: Decodable {
            let temp: Double
            let topK: Int
            let topP: Double
            let seed: Int
            let frequencyPenalty: Double
            let presencePenalty: Double
            let repeatPenalty: Double

            enum CodingKeys: String, CodingKey {
                case temp
                case topK = "top_k"
                case topP = "top_p"
                case seed
                case frequencyPenalty = "frequency_penalty"
                case presencePenalty = "presence_penalty"
                case repeatPenalty = "repeat_penalty"
            }
        }

        struct Completion: Decodable {
            let prompt: String
            let stream: Bool
            let emitRawDeltas: Bool
            let captureThinking: Bool
            let kvCache: Bool
            let generation: Generation

            enum CodingKeys: String, CodingKey {
                case prompt, stream, generation
                case emitRawDeltas = "emit_raw_deltas"
                case captureThinking = "capture_thinking"
                case kvCache = "kv_cache"
            }
        }

        struct Preconditioning: Decodable {
            let predict: Int
            let completions: Int

            enum CodingKeys: String, CodingKey {
                case predict, completions
            }
        }

        struct Measurement: Decodable {
            let predict: Int
            let completionsPerProcess: Int
            let processPairs: Int
            let bootstrapIterations: Int
            let maximumOverheadRatio: Double
            let normalizedMeanFactorFormula: String
            let normalizedMeanProcessAggregation: String

            enum CodingKeys: String, CodingKey {
                case predict
                case completionsPerProcess = "completions_per_process"
                case processPairs = "process_pairs"
                case bootstrapIterations = "bootstrap_iterations"
                case maximumOverheadRatio = "maximum_overhead_ratio"
                case normalizedMeanFactorFormula = "normalized_mean_factor_formula"
                case normalizedMeanProcessAggregation = "normalized_mean_process_aggregation"
            }
        }

        struct Timeouts: Decodable {
            let modelLoadMS: Int64
            let completionRPCTimeout: String
            let processWatchdogSeconds: Int

            enum CodingKeys: String, CodingKey {
                case modelLoadMS = "model_load_ms"
                case completionRPCTimeout = "completion_rpc_timeout"
                case processWatchdogSeconds = "process_watchdog_seconds"
            }
        }

        let schemaVersion: Int
        let criterion: String
        let model: Model
        let completion: Completion
        let preconditioning: Preconditioning
        let measurement: Measurement
        let timeouts: Timeouts

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case criterion, model, completion, preconditioning, measurement, timeouts
        }
    }

    private struct CompletionSample {
        let predict: Int
        let ttftMS: Double
        let terminalMS: Double
        let arrivalsMS: [Double]
        let intervalsMS: [Double]
        let meanIntervalMS: Double
        let contentSHA256: String
        let rawOutputSHA256: String
        let contentMatchesFinal: Bool
        let stopReason: String
        let stats: QVACClient.CompletionStats

        var measurementJSON: [String: Any] {
            [
                "predict": predict,
                "ttft_ms": ttftMS,
                "terminal_ms": terminalMS,
                "token_arrival_offsets_ms": arrivalsMS,
                "token_intervals_ms": intervalsMS,
                "mean_token_interval_ms": meanIntervalMS,
                "content_sha256": contentSHA256,
                "raw_output_sha256": rawOutputSHA256,
                "content_matches_final": contentMatchesFinal,
                "stop_reason": stopReason,
                "stats": statsJSON,
            ]
        }

        var preconditioningJSON: [String: Any] {
            [
                "predict": predict,
                "token_count": arrivalsMS.count,
                "stop_reason": stopReason,
                "generated_tokens": BenchmarkTests.jsonValue(stats.generatedTokens),
                "emitted_tokens": BenchmarkTests.jsonValue(stats.emittedTokens),
                "content_matches_final": contentMatchesFinal,
                "mean_token_interval_ms": meanIntervalMS,
                "content_sha256": contentSHA256,
                "raw_output_sha256": rawOutputSHA256,
                "backend_device": BenchmarkTests.jsonValue(stats.backendDevice?.rawValue),
            ]
        }

        private var statsJSON: [String: Any] {
            [
                "timeToFirstToken": BenchmarkTests.jsonValue(stats.timeToFirstToken),
                "tokensPerSecond": BenchmarkTests.jsonValue(stats.tokensPerSecond),
                "cacheTokens": BenchmarkTests.jsonValue(stats.cacheTokens),
                "promptTokens": BenchmarkTests.jsonValue(stats.promptTokens),
                "generatedTokens": BenchmarkTests.jsonValue(stats.generatedTokens),
                "emittedTokens": BenchmarkTests.jsonValue(stats.emittedTokens),
                "avgConcurrentSeq": BenchmarkTests.jsonValue(stats.avgConcurrentSeq),
                "backendDevice": BenchmarkTests.jsonValue(stats.backendDevice?.rawValue),
            ]
        }
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["QVAC_RUN_BENCH"] == "1",
            "set QVAC_RUN_BENCH=1 and use bench/run.sh for the KR-2 benchmark"
        )
        for key in [
            "QVAC_BARE_BIN", "QVAC_NODE_MODULES", "QVAC_BENCH_WORKLOAD",
            "QVAC_BENCH_MODEL_PATH", "QVAC_BENCH_RESULT", "QVAC_BENCH_HOME",
            "QVAC_BENCH_NODE_VERSION", "QVAC_BENCH_BARE_VERSION",
            "QVAC_BENCH_SWIFT_VERSION", "QVAC_BENCH_HOST",
            "QVAC_BENCH_SOURCE_COMMIT", "QVAC_BENCH_POSITION",
            "QVAC_BENCH_PAIR", "QVAC_BENCH_PAIR_ORDER",
        ] {
            guard ProcessInfo.processInfo.environment[key]?.isEmpty == false else {
                throw IntegrationPrerequisiteError("benchmark requires \(key)")
            }
        }
    }

    func test_streaming_completion_latency() async throws {
        let environment = ProcessInfo.processInfo.environment
        let (sourceCommit, orchestration) = try Self.benchmarkIdentity(
            client: "swift",
            environment: environment
        )
        let workloadURL = try Self.requiredFileURL("QVAC_BENCH_WORKLOAD", environment: environment)
        let modelURL = try Self.requiredFileURL("QVAC_BENCH_MODEL_PATH", environment: environment)
        let resultURL = try Self.requiredOutputURL("QVAC_BENCH_RESULT", environment: environment)
        let bareURL = try Self.requiredExecutableURL("QVAC_BARE_BIN", environment: environment)
        let modulesURL = URL(fileURLWithPath: try Self.required("QVAC_NODE_MODULES", environment))

        let workloadData = try Data(contentsOf: workloadURL)
        let workload = try JSONDecoder().decode(Workload.self, from: workloadData)
        try Self.validate(workload)
        let workloadSHA256 = Self.sha256(workloadData)

        let attributes = try FileManager.default.attributesOfItem(atPath: modelURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw IntegrationPrerequisiteError("model fixture must be a regular non-symlink file")
        }
        guard (attributes[.size] as? NSNumber)?.uint64Value == workload.model.byteCount else {
            throw IntegrationPrerequisiteError("model fixture size does not match bench/workload.json")
        }
        let modelSHA256 = try Self.sha256File(modelURL)
        guard modelSHA256 == workload.model.sha256 else {
            throw IntegrationPrerequisiteError("model fixture SHA-256 does not match bench/workload.json")
        }

        let sdkPackage = modulesURL.appendingPathComponent("@qvac/sdk/package.json")
        let runtimePackage = modulesURL.deletingLastPathComponent().appendingPathComponent("package.json")
        guard try Self.packageVersion(at: sdkPackage) == "0.17.0" else {
            throw IntegrationPrerequisiteError("benchmark requires exact @qvac/sdk 0.17.0")
        }
        guard try Self.packageDependency("bare-runtime", at: runtimePackage) == "1.31.0" else {
            throw IntegrationPrerequisiteError("benchmark requires exact bare-runtime 1.31.0")
        }
        let expectedBare = modulesURL.appendingPathComponent("bare-runtime/bin/bare").standardizedFileURL
        guard bareURL.standardizedFileURL == expectedBare else {
            throw IntegrationPrerequisiteError("benchmark must use the package-owned Bare launcher")
        }

        let configuration = try QVACClient.Configuration.macOS(
            nodeModulesDir: modulesURL,
            bareExecutable: bareURL,
            initTimeout: Double(workload.timeouts.modelLoadMS) / 1_000,
            homeDirectory: URL(
                fileURLWithPath: try Self.required("QVAC_BENCH_HOME", environment),
                isDirectory: true
            )
        )
        let client = try await QVACClient(
            configuration: configuration,
            initHandshakeTimeout: .milliseconds(workload.timeouts.modelLoadMS),
            logger: nil
        )

        let timeoutPolicy: [String: Any] = [
            "model_load_ms": workload.timeouts.modelLoadMS,
            "completion_rpc_timeout": workload.timeouts.completionRPCTimeout,
            "process_watchdog_seconds": workload.timeouts.processWatchdogSeconds,
        ]
        let toolchain: [String: Any] = [
            "node": try Self.required("QVAC_BENCH_NODE_VERSION", environment),
            "bare": try Self.required("QVAC_BENCH_BARE_VERSION", environment),
            "swift": try Self.required("QVAC_BENCH_SWIFT_VERSION", environment),
            "host": try Self.required("QVAC_BENCH_HOST", environment),
            "sdk": "0.17.0",
            "configuration": "release",
        ]
        var loadedModelID: String?
        var preconditioning: [CompletionSample] = []
        var measurements: [CompletionSample] = []
        var phase = "model_load"
        do {
            let modelConfig = workload.model.config
            let load = try await client.loadModel(
                modelSrc: modelURL.path,
                modelType: workload.model.modelType,
                modelConfig: .object([
                    "ctx_size": .number(Double(modelConfig.ctxSize)),
                    "gpu_layers": .number(Double(modelConfig.gpuLayers)),
                    "device": .string(modelConfig.device),
                    "parallel": .number(Double(modelConfig.parallel)),
                    "verbosity": .number(Double(modelConfig.verbosity)),
                ]),
                rpcOptions: .init(timeout: .milliseconds(workload.timeouts.modelLoadMS))
            )
            let modelID = try await load.result.value
            loadedModelID = modelID

            phase = "preconditioning"
            for _ in 0..<workload.preconditioning.completions {
                preconditioning.append(try await Self.runCompletion(
                    client: client,
                    modelID: modelID,
                    predict: workload.preconditioning.predict,
                    workload: workload
                ))
            }

            phase = "measurement"
            for _ in 0..<workload.measurement.completionsPerProcess {
                measurements.append(try await Self.runCompletion(
                    client: client,
                    modelID: modelID,
                    predict: workload.measurement.predict,
                    workload: workload
                ))
            }
            phase = "unload_model"
            try await client.unloadModel(
                modelId: modelID,
                rpcOptions: .init(timeout: .milliseconds(workload.timeouts.modelLoadMS))
            )
            loadedModelID = nil
            await client.close()
            phase = "complete"

            let result: [String: Any] = [
                "schema_version": 2,
                "status": "sample",
                "client": "swift",
                "api_surface": "QVACClient.completion(...).events",
                "source_commit": sourceCommit,
                "orchestration": orchestration,
                "workload_sha256": workloadSHA256,
                "model_sha256": modelSHA256,
                "preconditioning": preconditioning.map(\.preconditioningJSON),
                "measurements": measurements.map(\.measurementJSON),
                "timeout_policy": timeoutPolicy,
                "toolchain": toolchain,
            ]
            let data = try JSONSerialization.data(
                withJSONObject: result,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: resultURL, options: .atomic)
        } catch {
            // Preserve every completed request for diagnosis while remaining
            // fail-closed: bench/run.sh accepts only status=sample evidence.
            let errorResult: [String: Any] = [
                "schema_version": 2,
                "status": "error",
                "client": "swift",
                "api_surface": "QVACClient.completion(...).events",
                "source_commit": sourceCommit,
                "orchestration": orchestration,
                "workload_sha256": workloadSHA256,
                "model_sha256": modelSHA256,
                "reason": String(describing: error),
                "preconditioning": preconditioning.map(\.preconditioningJSON),
                "measurements": measurements.map(\.measurementJSON),
                "progress": [
                    "phase": phase,
                    "expected_preconditioning_completions": workload.preconditioning.completions,
                    "completed_preconditioning_completions": preconditioning.count,
                    "expected_measurement_completions": workload.measurement.completionsPerProcess,
                    "completed_measurement_completions": measurements.count,
                ],
                "timeout_policy": timeoutPolicy,
                "toolchain": toolchain,
            ]
            if let errorData = try? JSONSerialization.data(
                withJSONObject: errorResult,
                options: [.prettyPrinted, .sortedKeys]
            ) {
                try? errorData.write(to: resultURL, options: .atomic)
            }
            if let loadedModelID {
                _ = try? await client.unloadModel(
                    modelId: loadedModelID,
                    rpcOptions: .init(timeout: .milliseconds(workload.timeouts.modelLoadMS))
                )
            }
            await client.close()
            throw error
        }
    }

    private static func runCompletion(
        client: QVACClient,
        modelID: String,
        predict: Int,
        workload: Workload
    ) async throws -> CompletionSample {
        let generation = workload.completion.generation
        let clock = ContinuousClock()
        let start = clock.now
        let run = try await client.completion(
            modelId: modelID,
            history: [.user(workload.completion.prompt)],
            stream: workload.completion.stream,
            generationParams: .object([
                "predict": .number(Double(predict)),
                "temp": .number(generation.temp),
                "top_k": .number(Double(generation.topK)),
                "top_p": .number(generation.topP),
                "seed": .number(Double(generation.seed)),
                "frequency_penalty": .number(generation.frequencyPenalty),
                "presence_penalty": .number(generation.presencePenalty),
                "repeat_penalty": .number(generation.repeatPenalty),
            ]),
            kvCache: .bool(workload.completion.kvCache),
            captureThinking: workload.completion.captureThinking,
            emitRawDeltas: workload.completion.emitRawDeltas,
            // The benchmark's owned process watchdog is the symmetric deadline
            // for both the Swift and JavaScript clients. Opt out of the SDK's
            // production default so timeout policy cannot bias either arm.
            rpcOptions: .init(timeout: nil)
        )

        var arrivals: [Double] = []
        var content = ""
        var terminalMS: Double?
        var terminalReason: QVACClient.CompletionStopReason?
        var previousSequence = -1
        for try await event in run.events {
            let now = clock.now
            let sequence: Int
            switch event {
            case .contentDelta(let seq, let text):
                sequence = seq
                guard !text.isEmpty else {
                    throw IntegrationPrerequisiteError("completion emitted an empty content delta")
                }
                arrivals.append(milliseconds(start.duration(to: now)))
                content += text
            case .stats(let seq, _):
                sequence = seq
            case .done(let seq, let stopReason, _):
                sequence = seq
                terminalMS = milliseconds(start.duration(to: now))
                terminalReason = stopReason
            case .rawDelta(let seq, _), .thinkingDelta(let seq, _),
                 .toolCall(let seq, _), .toolError(let seq, _):
                throw IntegrationPrerequisiteError("unexpected event type at sequence \(seq)")
            case .failure(let seq, let message, _):
                throw IntegrationPrerequisiteError("benchmark completion failed at \(seq): \(message)")
            }
            guard sequence == previousSequence + 1 else {
                throw IntegrationPrerequisiteError(
                    "completion event sequence is not contiguous: \(previousSequence) -> \(sequence)"
                )
            }
            previousSequence = sequence
        }

        let final = try await run.final.value
        guard let stats = final.stats else {
            throw IntegrationPrerequisiteError("benchmark completion did not report stats")
        }
        guard arrivals.count == predict else {
            throw IntegrationPrerequisiteError(
                "expected \(predict) non-empty content deltas, got \(arrivals.count)"
            )
        }
        guard terminalReason == .length, final.stopReason == .length else {
            throw IntegrationPrerequisiteError("completion did not stop at the fixed token limit")
        }
        guard stats.generatedTokens == Double(predict),
              stats.emittedTokens == Double(predict),
              stats.backendDevice != nil else {
            throw IntegrationPrerequisiteError("completion stats do not match the fixed workload")
        }
        guard let tokensPerSecond = stats.tokensPerSecond,
              tokensPerSecond.isFinite,
              tokensPerSecond > 0 else {
            throw IntegrationPrerequisiteError(
                "completion must report finite positive tokensPerSecond"
            )
        }
        guard content == final.contentText else {
            throw IntegrationPrerequisiteError("streamed content does not match CompletionFinal")
        }
        guard let terminal = terminalMS, let lastArrival = arrivals.last,
              terminal.isFinite, terminal >= lastArrival else {
            throw IntegrationPrerequisiteError("completion did not expose a valid terminal event latency")
        }
        let intervals = zip(arrivals.dropFirst(), arrivals).map { $0 - $1 }
        guard intervals.count == predict - 1,
              intervals.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw IntegrationPrerequisiteError("completion produced invalid token intervals")
        }
        return CompletionSample(
            predict: predict,
            ttftMS: arrivals[0],
            terminalMS: terminal,
            arrivalsMS: arrivals,
            intervalsMS: intervals,
            meanIntervalMS: intervals.reduce(0, +) / Double(intervals.count),
            contentSHA256: sha256(Data(content.utf8)),
            rawOutputSHA256: sha256(Data(final.raw.fullText.utf8)),
            contentMatchesFinal: true,
            stopReason: "length",
            stats: stats
        )
    }

    private static func validate(_ workload: Workload) throws {
        guard workload.schemaVersion == 3,
              workload.criterion == "Streaming completion latency overhead (Swift client vs. JS client on same machine) < 5%.",
              workload.model.byteCount > 0,
              workload.model.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              workload.model.modelType == "llamacpp-completion",
              workload.model.config.ctxSize == 2_048,
              workload.model.config.parallel == 1,
              workload.completion.stream,
              !workload.completion.emitRawDeltas,
              !workload.completion.captureThinking,
              !workload.completion.kvCache,
              workload.preconditioning.predict == 1_000,
              workload.preconditioning.completions == 2,
              workload.measurement.predict == 1_000,
              workload.measurement.completionsPerProcess == 3,
              workload.measurement.processPairs == 10,
              workload.measurement.bootstrapIterations == 20_000,
              workload.measurement.maximumOverheadRatio == 1.05,
              workload.measurement.normalizedMeanFactorFormula
                == "mean_token_interval_ms / (1000 / stats.tokensPerSecond)",
              workload.measurement.normalizedMeanProcessAggregation
                == "arithmetic_mean(exactly_3_completion_factors)",
              workload.timeouts.modelLoadMS == 180_000,
              workload.timeouts.completionRPCTimeout == "none",
              workload.timeouts.processWatchdogSeconds == 240 else {
            throw IntegrationPrerequisiteError("bench/workload.json violates the fixed KR-2 protocol")
        }
    }

    private static func benchmarkIdentity(
        client: String,
        environment: [String: String]
    ) throws -> (sourceCommit: String, orchestration: [String: Any]) {
        let sourceCommit = try required("QVAC_BENCH_SOURCE_COMMIT", environment)
        let position = try required("QVAC_BENCH_POSITION", environment)
        let pair = try required("QVAC_BENCH_PAIR", environment)
        let pairOrder = try required("QVAC_BENCH_PAIR_ORDER", environment)
        guard sourceCommit.range(
            of: "^[0-9a-f]{40}$",
            options: .regularExpression
        ) != nil else {
            throw IntegrationPrerequisiteError(
                "QVAC_BENCH_SOURCE_COMMIT must be an exact 40-hex commit"
            )
        }
        guard position.range(
            of: "^(0[1-9]|1[0-9]|20)$",
            options: .regularExpression
        ) != nil,
        pair.range(of: "^(0[1-9]|10)$", options: .regularExpression) != nil,
        let positionNumber = Int(position),
        let pairNumber = Int(pair) else {
            throw IntegrationPrerequisiteError("benchmark position/pair identity is invalid")
        }
        let expectedPair = (positionNumber + 1) / 2
        let expectedOrder = pairNumber.isMultiple(of: 2) ? "node/swift" : "swift/node"
        let pairMembers = pairOrder.split(separator: "/").map(String.init)
        guard pairNumber == expectedPair,
              pairOrder == expectedOrder,
              pairMembers.count == 2,
              pairMembers[(positionNumber - 1) % 2] == client else {
            throw IntegrationPrerequisiteError(
                "benchmark client, position, pair, and execution order are inconsistent"
            )
        }
        return (
            sourceCommit,
            ["position": position, "pair": pair, "pair_order": pairOrder]
        )
    }

    private static func required(
        _ key: String,
        _ environment: [String: String]
    ) throws -> String {
        guard let value = environment[key], !value.isEmpty else {
            throw IntegrationPrerequisiteError("benchmark requires \(key)")
        }
        return value
    }

    private static func requiredFileURL(
        _ key: String,
        environment: [String: String]
    ) throws -> URL {
        let url = URL(fileURLWithPath: try required(key, environment)).standardizedFileURL
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw IntegrationPrerequisiteError("\(key) must name a regular non-symlink file")
        }
        return url
    }

    private static func requiredExecutableURL(
        _ key: String,
        environment: [String: String]
    ) throws -> URL {
        let url = try requiredFileURL(key, environment: environment)
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw IntegrationPrerequisiteError("\(key) is not executable")
        }
        return url
    }

    private static func requiredOutputURL(
        _ key: String,
        environment: [String: String]
    ) throws -> URL {
        let url = URL(fileURLWithPath: try required(key, environment)).standardizedFileURL
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw IntegrationPrerequisiteError("\(key) must not already exist")
        }
        let parent = url.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw IntegrationPrerequisiteError("\(key) parent directory does not exist")
        }
        return url
    }

    private static func packageVersion(at url: URL) throws -> String? {
        guard let package = try JSONSerialization.jsonObject(
            with: Data(contentsOf: url)
        ) as? [String: Any] else { return nil }
        return package["version"] as? String
    }

    private static func packageDependency(_ name: String, at url: URL) throws -> String? {
        guard let package = try JSONSerialization.jsonObject(
            with: Data(contentsOf: url)
        ) as? [String: Any],
        let dependencies = package["dependencies"] as? [String: Any] else { return nil }
        return dependencies[name] as? String
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func jsonValue(_ value: Double?) -> Any {
        value.map { $0 as Any } ?? NSNull()
    }

    private static func jsonValue(_ value: String?) -> Any {
        value.map { $0 as Any } ?? NSNull()
    }

    private static func sha256File(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { _ = try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty {
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
#endif
