import Foundation
import XCTest
@testable import QVACClient

/// Executable coverage for every entry point generated from the pinned 0.17.0 manifest.
///
/// The peer replaces only the byte transport. Calls still cross the production request
/// encoder, bare-rpc framing and multiplexing, NDJSON decoder, response union, and exact
/// generated wrapper. Each plan compares the complete request union value before replying,
/// so a renamed route or incorrectly forwarded request fails rather than merely increasing
/// line coverage.
final class QVACGeneratedContractWrapperTests: XCTestCase {
    private final class InboundPipe: @unchecked Sendable {
        let stream: AsyncThrowingStream<Data, Error>
        let continuation: AsyncThrowingStream<Data, Error>.Continuation

        init() {
            var captured: AsyncThrowingStream<Data, Error>.Continuation!
            stream = AsyncThrowingStream(bufferingPolicy: .unbounded) { captured = $0 }
            continuation = captured
        }
    }

    private enum ReplyShape: Sendable, Equatable {
        case unary
        case serverStream
        case duplex
    }

    private struct ReplyPlan: Sendable {
        let expectedRequest: QVACRequest
        let shape: ReplyShape
        let responses: [QVACResponse]
    }

    private enum PeerFailure: Error, Sendable, CustomStringConvertible {
        case missingPlan(String)
        case requestMismatch(expected: String, actual: String)
        case shapeMismatch(expected: ReplyShape, actual: ReplyShape)
        case invalidUnaryResponseCount(Int)

        var description: String {
            switch self {
            case .missingPlan(let actual):
                return "no reply plan was queued for \(actual)"
            case .requestMismatch(let expected, let actual):
                return "expected request \(expected), received \(actual)"
            case .shapeMismatch(let expected, let actual):
                return "expected \(expected) request, received \(actual) request"
            case .invalidUnaryResponseCount(let count):
                return "unary reply plan contained \(count) responses"
            }
        }
    }

    private actor ContractPeer: BareTransport {
        private struct StagedStreamReply: Sendable {
            let id: UInt64
            let responses: [QVACResponse]
            let includeResponseOpen: Bool
        }

        nonisolated private let inbound = InboundPipe()
        private let reader = BareRPCFrameReader()
        private var plans: [ReplyPlan] = []
        private var stagedStreamReplies: [StagedStreamReply] = []
        private var observed: [QVACRequest] = []
        private var closed = false

        nonisolated func inboundStream() -> AsyncThrowingStream<Data, Error> {
            inbound.stream
        }

        func enqueue(_ plan: ReplyPlan) {
            plans.append(plan)
        }

        func releaseNextStreamReply() throws {
            guard !stagedStreamReplies.isEmpty else {
                throw PeerFailure.missingPlan("staged stream reply")
            }
            let reply = stagedStreamReplies.removeFirst()
            try yieldStream(
                id: reply.id,
                responses: reply.responses,
                includeResponseOpen: reply.includeResponseOpen
            )
        }

        func write(_ data: Data) async throws {
            try reader.append(data)
            while let frame = reader.next() {
                try handle(frame)
            }
        }

        func close() {
            guard !closed else { return }
            closed = true
            inbound.continuation.finish()
        }

        func pendingPlanCount() -> Int { plans.count + stagedStreamReplies.count }
        func observedRequests() -> [QVACRequest] { observed }

        private func handle(_ frame: BareRPCFrame) throws {
            switch frame {
            case .request(let id, _, let flags, nil) where flags.contains(.open):
                var acknowledgement = BareRPCCodec.__testEncodeStreamFrame(
                    id: id,
                    flags: [.request, .open]
                )
                acknowledgement.append(BareRPCCodec.__testEncodeStreamFrame(
                    id: id,
                    flags: [.response, .open]
                ))
                inbound.continuation.yield(acknowledgement)

            case .request(let id, _, _, .some(let payload)):
                let request = try JSONDecoder().decode(QVACRequest.self, from: payload)
                let plan = try claimPlan(for: request, actualShape: requestReplyShape(for: request))
                switch plan.shape {
                case .unary:
                    guard plan.responses.count == 1, let response = plan.responses.first else {
                        throw PeerFailure.invalidUnaryResponseCount(plan.responses.count)
                    }
                    let encoded = try JSONEncoder.qvac.encode(response)
                    inbound.continuation.yield(BareRPCCodec.__testEncodeResponseFrame(
                        id: id,
                        stream: [],
                        payload: .success(encoded)
                    ))
                case .serverStream:
                    stagedStreamReplies.append(.init(
                        id: id,
                        responses: plan.responses,
                        includeResponseOpen: true
                    ))
                case .duplex:
                    throw PeerFailure.shapeMismatch(expected: .duplex, actual: .serverStream)
                }

            case .stream(let id, let flags, .data(let payload)) where flags.contains(.request):
                guard let request = try? JSONDecoder().decode(QVACRequest.self, from: payload) else {
                    // After the initial JSON request, duplex writes are arbitrary binary data.
                    return
                }
                let plan = try claimPlan(for: request, actualShape: .duplex)
                guard case .duplex = plan.shape else {
                    throw PeerFailure.shapeMismatch(expected: plan.shape, actual: .duplex)
                }
                stagedStreamReplies.append(.init(
                    id: id,
                    responses: plan.responses,
                    includeResponseOpen: false
                ))

            default:
                break
            }
        }

        private func requestReplyShape(for request: QVACRequest) -> ReplyShape {
            switch request {
            case .downloadAsset(let value) where value.withProgress == true:
                return .serverStream
            case .finetune(let value) where value.withProgress == true:
                return .serverStream
            case .loadModel(let value) where value.withProgress == true:
                return .serverStream
            case .rag(let value) where value.withProgress == true:
                return .serverStream
            default:
                guard let method = QVACSDKContract.method(named: request.discriminator) else {
                    return .unary
                }
                switch method.callShape {
                case .requestReply:
                    return .unary
                case .serverStream:
                    return .serverStream
                case .duplex:
                    return .duplex
                }
            }
        }

        private func claimPlan(
            for request: QVACRequest,
            actualShape: ReplyShape
        ) throws -> ReplyPlan {
            guard !plans.isEmpty else {
                throw PeerFailure.missingPlan(request.discriminator)
            }
            let plan = plans.removeFirst()
            guard plan.expectedRequest == request else {
                throw PeerFailure.requestMismatch(
                    expected: plan.expectedRequest.discriminator,
                    actual: request.discriminator
                )
            }
            guard plan.shape == actualShape else {
                throw PeerFailure.shapeMismatch(expected: plan.shape, actual: actualShape)
            }
            observed.append(request)
            return plan
        }

        private func yieldStream(
            id: UInt64,
            responses: [QVACResponse],
            includeResponseOpen: Bool
        ) throws {
            var inboundBytes = Data()
            if includeResponseOpen {
                inboundBytes.append(BareRPCCodec.__testEncodeResponseFrame(
                    id: id,
                    stream: [.open],
                    payload: .success(nil)
                ))
            }
            for response in responses {
                var record = try JSONEncoder.qvac.encode(response)
                record.append(0x0A)
                inboundBytes.append(BareRPCCodec.__testEncodeStreamFrame(
                    id: id,
                    flags: [.response, .data],
                    payload: .data(record)
                ))
            }
            inboundBytes.append(BareRPCCodec.__testEncodeStreamFrame(
                id: id,
                flags: [.response, .end]
            ))
            inbound.continuation.yield(inboundBytes)
        }
    }

    private struct Invocation: Sendable {
        let request: QVACRequest
        let run: @Sendable (QVACClient, ContractPeer) async throws -> Void
    }

    private static let workerError = QVACResponse.error(.init(
        message: "generated-contract-worker-error",
        code: Double(QVACErrorCode.modelNotFound.rawValue)
    ))

    private static func only<Element: Sendable>(
        _ stream: QVACResponseStream<Element>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> Element {
        var iterator = stream.makeAsyncIterator()
        guard let value = try await iterator.next() else {
            XCTFail("expected one response, received EOF", file: file, line: line)
            throw QVACError.protocolViolation("test stream ended before its response")
        }
        let trailing = try await iterator.next()
        XCTAssertNil(trailing, "expected EOF after one response", file: file, line: line)
        return value
    }

    private func assertProtocolViolation(
        operation: String,
        _ body: @Sendable () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await body()
            XCTFail("\(operation) accepted a mismatched response", file: file, line: line)
        } catch let QVACError.protocolViolation(message) {
            XCTAssertFalse(message.isEmpty, file: file, line: line)
        } catch {
            XCTFail("\(operation) returned \(error), expected protocolViolation", file: file, line: line)
        }
    }

    private func assertWorkerError(
        operation: String,
        _ body: @Sendable () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await body()
            XCTFail("\(operation) swallowed a worker error", file: file, line: line)
        } catch let QVACError.server(code, message) {
            XCTAssertEqual(code, .modelNotFound, file: file, line: line)
            XCTAssertEqual(message, "generated-contract-worker-error", file: file, line: line)
        } catch {
            XCTFail("\(operation) returned \(error), expected typed worker error", file: file, line: line)
        }
    }

    private func assertConcreteTypeFailure(
        operation: String,
        _ body: @Sendable () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await body()
            XCTFail("\(operation) accepted a mismatched concrete response", file: file, line: line)
        } catch let QVACError.encoding(message) {
            XCTAssertTrue(message.contains("Expected \(operation) discriminator"), file: file, line: line)
        } catch {
            XCTFail("\(operation) returned \(error), expected encoding failure", file: file, line: line)
        }
    }

    private static func wrongResponse(for request: QVACRequest) -> QVACResponse {
        if request.discriminator == "heartbeat" {
            return .state(.init(state: "wrong-response"))
        }
        return .heartbeat(.init(number: -1))
    }

    private func assertPeer(
        _ peer: ContractPeer,
        observed expectedRequests: [QVACRequest],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let observedRequests = await peer.observedRequests()
        let pendingPlanCount = await peer.pendingPlanCount()
        XCTAssertEqual(observedRequests, expectedRequests, file: file, line: line)
        XCTAssertEqual(pendingPlanCount, 0, file: file, line: line)
    }

    private static func unaryInvocations() -> [Invocation] {
        let cancel = CancelRequest(operation: "request", requestId: "cancel-request")
        let deleteCache = DeleteCacheRequest(all: true)
        let downloadAsset = DownloadAssetRequest(assetSrc: "https://example.invalid/model.gguf")
        let embed = EmbedRequest(modelId: "embed-model", text: .string("hello"))
        let finetune = FinetuneRequest(modelId: "finetune-model", operation: "status")
        let getLoadedModelInfo = GetLoadedModelInfoRequest(modelId: "loaded-model")
        let getModelInfo = GetModelInfoRequest(name: "catalog-model")
        let getSystemResources = GetSystemResourcesRequest(sample: true)
        let heartbeat = HeartbeatRequest()
        let loadModel = LoadModelRequest(modelType: "llamacpp-completion", modelId: "model-17")
        let modelRegistryGetModel = ModelRegistryGetModelRequest(
            registryPath: "org/model",
            registrySource: "huggingface"
        )
        let modelRegistryList = ModelRegistryListRequest()
        let modelRegistrySearch = ModelRegistrySearchRequest(filter: "model")
        let pluginInvoke = PluginInvokeRequest(
            handler: "run",
            modelId: "plugin-model",
            params: .object(["input": .string("value")])
        )
        let provide = ProvideRequest(firewall: .object(["allow": .bool(true)]))
        let rag = RagRequest(operation: "listWorkspaces")
        let resume = ResumeRequest()
        let state = StateRequest()
        let stopProvide = StopProvideRequest()
        let suspend = SuspendRequest()
        let unloadModel = UnloadModelRequest(modelId: "model-17", clearStorage: true)

        return [
            .init(request: .cancel(cancel)) { client, peer in
                let value = try await client.wireCancel(cancel)
                XCTAssertTrue(value.success)
            },
            .init(request: .deleteCache(deleteCache)) { client, peer in
                let value = try await client.wireDeleteCache(deleteCache)
                XCTAssertTrue(value.success)
            },
            .init(request: .downloadAsset(downloadAsset)) { client, peer in
                let value = try await client.wireDownloadAsset(downloadAsset)
                XCTAssertEqual(value.assetId, "asset-17")
            },
            .init(request: .embed(embed)) { client, peer in
                let value = try await client.wireEmbed(embed)
                XCTAssertTrue(value.success)
            },
            .init(request: .finetune(finetune)) { client, peer in
                let value = try await client.wireFinetune(finetune)
                XCTAssertEqual(value.status, "COMPLETED")
            },
            .init(request: .getLoadedModelInfo(getLoadedModelInfo)) { client, peer in
                let value = try await client.wireGetLoadedModelInfo(getLoadedModelInfo)
                XCTAssertEqual(value.info, .object(["id": .string("loaded-model")]))
            },
            .init(request: .getModelInfo(getModelInfo)) { client, peer in
                let value = try await client.wireGetModelInfo(getModelInfo)
                XCTAssertEqual(value.modelInfo, .object(["name": .string("catalog-model")]))
            },
            .init(request: .getSystemResources(getSystemResources)) { client, peer in
                let value = try await client.wireGetSystemResources(getSystemResources)
                XCTAssertEqual(value.capabilities, .object(["gpu": .bool(true)]))
            },
            .init(request: .heartbeat(heartbeat)) { client, peer in
                let value = try await client.wireHeartbeat(heartbeat)
                XCTAssertEqual(value.number, 17)
            },
            .init(request: .loadModel(loadModel)) { client, peer in
                let value = try await client.wireLoadModel(loadModel)
                XCTAssertEqual(value.modelId, "model-17")
            },
            .init(request: .modelRegistryGetModel(modelRegistryGetModel)) { client, peer in
                let value = try await client.wireModelRegistryGetModel(modelRegistryGetModel)
                XCTAssertTrue(value.success)
            },
            .init(request: .modelRegistryList(modelRegistryList)) { client, peer in
                let value = try await client.wireModelRegistryList(modelRegistryList)
                XCTAssertEqual(value.models, [])
            },
            .init(request: .modelRegistrySearch(modelRegistrySearch)) { client, peer in
                let value = try await client.wireModelRegistrySearch(modelRegistrySearch)
                XCTAssertEqual(value.models, [])
            },
            .init(request: .pluginInvoke(pluginInvoke)) { client, peer in
                let value = try await client.wirePluginInvoke(pluginInvoke)
                XCTAssertEqual(value.result, .string("plugin-result"))
            },
            .init(request: .provide(provide)) { client, peer in
                let value = try await client.wireProvide(provide)
                XCTAssertEqual(value.publicKey, "public-key")
            },
            .init(request: .rag(rag)) { client, peer in
                let value = try await client.wireRag(rag)
                XCTAssertEqual(value.operation, "listWorkspaces")
            },
            .init(request: .resume(resume)) { client, peer in
                _ = try await client.wireResume(resume)
            },
            .init(request: .state(state)) { client, peer in
                let value = try await client.wireState(state)
                XCTAssertEqual(value.state, "active")
            },
            .init(request: .stopProvide(stopProvide)) { client, peer in
                let value = try await client.wireStopProvide(stopProvide)
                XCTAssertTrue(value.success)
            },
            .init(request: .suspend(suspend)) { client, peer in
                _ = try await client.wireSuspend(suspend)
            },
            .init(request: .unloadModel(unloadModel)) { client, peer in
                let value = try await client.wireUnloadModel(unloadModel)
                XCTAssertTrue(value.success)
            },
        ]
    }

    private static func unaryResponse(for request: QVACRequest) -> QVACResponse {
        switch request {
        case .cancel:
            return .cancel(.init(success: true, cancelled: 1))
        case .deleteCache:
            return .deleteCache(.init(success: true))
        case .downloadAsset:
            return .downloadAsset(.init(success: true, assetId: "asset-17"))
        case .embed:
            return .embed(.init(embedding: .array([.number(0.5)]), success: true))
        case .finetune:
            return .finetune(.init(status: "COMPLETED"))
        case .getLoadedModelInfo:
            return .getLoadedModelInfo(.init(info: .object(["id": .string("loaded-model")])))
        case .getModelInfo:
            return .getModelInfo(.init(modelInfo: .object(["name": .string("catalog-model")])))
        case .getSystemResources:
            return .getSystemResources(.init(capabilities: .object(["gpu": .bool(true)])))
        case .heartbeat:
            return .heartbeat(.init(number: 17))
        case .loadModel:
            return .loadModel(.init(success: true, modelId: "model-17"))
        case .modelRegistryGetModel:
            return .modelRegistryGetModel(.init(success: true, model: .object([:])))
        case .modelRegistryList:
            return .modelRegistryList(.init(success: true, models: []))
        case .modelRegistrySearch:
            return .modelRegistrySearch(.init(success: true, models: []))
        case .pluginInvoke:
            return .pluginInvoke(.init(result: .string("plugin-result")))
        case .provide:
            return .provide(.init(success: true, publicKey: "public-key"))
        case .rag:
            return .rag(.init(operation: "listWorkspaces", success: true, workspaces: []))
        case .resume:
            return .resume(.init())
        case .state:
            return .state(.init(state: "active"))
        case .stopProvide:
            return .stopProvide(.init(success: true))
        case .suspend:
            return .suspend(.init())
        case .unloadModel:
            return .unloadModel(.init(success: true))
        default:
            preconditionFailure("\(request.discriminator) is not a unary contract request")
        }
    }

    private static func serverStreamInvocations() -> [Invocation] {
        let audioGen = AudioGenStreamRequest(caption: "music", modelId: "audio-model")
        let batchCompletion = BatchCompletionStreamRequest(
            modelId: "completion-model",
            prompts: [.object(["history": .array([])])]
        )
        let bci = BciTranscribeRequest(
            modelId: "bci-model",
            neuralData: .object(["type": .string("base64"), "value": .string("AA==")])
        )
        let classify = ClassifyRequest(image: "AA==", modelId: "classifier")
        let completion = CompletionStreamRequest(
            history: [],
            modelId: "completion-model",
            stream: true
        )
        let diffusion = DiffusionStreamRequest(modelId: "diffusion-model", prompt: "mountain")
        let logging = LoggingStreamRequest(id: "sdk-log")
        let ocr = OcrStreamRequest(
            image: .object(["type": .string("base64"), "value": .string("AA==")]),
            modelId: "ocr-model"
        )
        let plugin = PluginInvokeStreamRequest(
            handler: "events",
            modelId: "plugin-model",
            params: .object([:])
        )
        let textToSpeech = TextToSpeechRequest(modelId: "tts-model", text: "hello")
        let transcribe = TranscribeRequest(
            audioChunk: .object(["type": .string("base64"), "value": .string("AA==")]),
            modelId: "asr-model"
        )
        let translate = TranslateRequest(
            modelId: "translation-model",
            modelType: "nmtcpp-translation",
            stream: true,
            text: .one("hello")
        )
        let upscale = UpscaleStreamRequest(image: "AA==", modelId: "upscale-model")
        let video = VideoStreamRequest(mode: "txt2vid", modelId: "video-model", prompt: "ocean")

        return [
            .init(request: .audioGenStream(audioGen)) { client, peer in
                let stream = try await client.wireAudioGenStream(audioGen)
                try await peer.releaseNextStreamReply()
                let value = try await only(stream)
                XCTAssertTrue(value.done)
            },
            .init(request: .batchCompletionStream(batchCompletion)) { client, peer in
                let stream = try await client.wireBatchCompletionStream(batchCompletion)
                try await peer.releaseNextStreamReply()
                let value = try await only(stream)
                XCTAssertTrue(value.done == true)
            },
            .init(request: .bciTranscribe(bci)) { client, peer in
                let stream = try await client.wireBciTranscribe(bci)
                try await peer.releaseNextStreamReply()
                let value = try await only(stream)
                XCTAssertEqual(value.text, "decoded-neural-data")
            },
            .init(request: .classify(classify)) { client, peer in
                let stream = try await client.wireClassify(classify)
                try await peer.releaseNextStreamReply()
                let value = try await only(stream)
                XCTAssertTrue(value.done == true)
            },
            .init(request: .completionStream(completion)) { client, peer in
                let stream = try await client.wireCompletionStream(completion)
                try await peer.releaseNextStreamReply()
                let value = try await only(stream)
                XCTAssertTrue(value.done == true)
            },
            .init(request: .diffusionStream(diffusion)) { client, peer in
                let stream = try await client.wireDiffusionStream(diffusion)
                try await peer.releaseNextStreamReply()
                let value = try await only(stream)
                XCTAssertTrue(value.done == true)
            },
            .init(request: .loggingStream(logging)) { client, peer in
                let stream = try await client.wireLoggingStream(logging)
                try await peer.releaseNextStreamReply()
                let value = try await only(stream)
                XCTAssertEqual(value.message, "generated wrapper")
            },
            .init(request: .ocrStream(ocr)) { client, peer in
                let stream = try await client.wireOcrStream(ocr)
                try await peer.releaseNextStreamReply()
                let value = try await only(stream)
                XCTAssertTrue(value.done == true)
            },
            .init(request: .pluginInvokeStream(plugin)) { client, peer in
                let stream = try await client.wirePluginInvokeStream(plugin)
                try await peer.releaseNextStreamReply()
                let value = try await only(stream)
                XCTAssertEqual(value.result, .string("plugin-event"))
            },
            .init(request: .textToSpeech(textToSpeech)) { client, peer in
                let stream = try await client.wireTextToSpeech(textToSpeech)
                try await peer.releaseNextStreamReply()
                let value = try await only(stream)
                XCTAssertTrue(value.done)
            },
            .init(request: .transcribe(transcribe)) { client, peer in
                let stream = try await client.wireTranscribe(transcribe)
                try await peer.releaseNextStreamReply()
                let value = try await only(stream)
                XCTAssertEqual(value.text, "transcript")
            },
            .init(request: .translate(translate)) { client, peer in
                let stream = try await client.wireTranslate(translate)
                try await peer.releaseNextStreamReply()
                let value = try await only(stream)
                XCTAssertEqual(value.token, "bonjour")
            },
            .init(request: .upscaleStream(upscale)) { client, peer in
                let stream = try await client.wireUpscaleStream(upscale)
                try await peer.releaseNextStreamReply()
                let value = try await only(stream)
                XCTAssertTrue(value.done == true)
            },
            .init(request: .videoStream(video)) { client, peer in
                let stream = try await client.wireVideoStream(video)
                try await peer.releaseNextStreamReply()
                let value = try await only(stream)
                XCTAssertTrue(value.done == true)
            },
        ]
    }

    private static func serverStreamResponse(for request: QVACRequest) -> QVACResponse {
        switch request {
        case .audioGenStream:
            return .audioGenStream(.init(done: true))
        case .batchCompletionStream:
            return .batchCompletionStream(.init(events: [], done: true))
        case .bciTranscribe:
            return .bciTranscribe(.init(done: true, text: "decoded-neural-data"))
        case .classify:
            return .classify(.init(results: [], done: true))
        case .completionStream:
            return .completionStream(.init(events: [], done: true))
        case .diffusionStream:
            return .diffusionStream(.init(done: true))
        case .loggingStream:
            return .loggingStream(.init(
                id: "sdk-log",
                level: "info",
                message: "generated wrapper",
                namespace: "contract",
                timestamp: 17
            ))
        case .ocrStream:
            return .ocrStream(.init(done: true))
        case .pluginInvokeStream:
            return .pluginInvokeStream(.init(result: .string("plugin-event"), done: true))
        case .textToSpeech:
            return .textToSpeech(.init(buffer: [], done: true))
        case .transcribe:
            return .transcribe(.init(done: true, text: "transcript"))
        case .translate:
            return .translate(.init(token: "bonjour", done: true))
        case .upscaleStream:
            return .upscaleStream(.init(done: true))
        case .videoStream:
            return .videoStream(.init(done: true))
        default:
            preconditionFailure("\(request.discriminator) is not a server-stream contract request")
        }
    }

    private static func duplexInvocations() -> [Invocation] {
        let bci = BciTranscribeStreamRequest(modelId: "bci-stream-model")
        let orchestrate = CompletionOrchestrateRequest(
            history: [],
            modelId: "orchestrator-model",
            stream: true
        )
        let textToSpeech = TextToSpeechStreamRequest(modelId: "tts-stream-model")
        let transcribe = TranscribeStreamRequest(modelId: "asr-stream-model")

        return [
            .init(request: .bciTranscribeStream(bci)) { client, peer in
                let session = try await client.wireBciTranscribeStream(bci)
                try await peer.releaseNextStreamReply()
                let value = try await only(session.responses)
                XCTAssertEqual(value.text, "neural-stream")
            },
            .init(request: .completionOrchestrate(orchestrate)) { client, peer in
                let session = try await client.wireCompletionOrchestrate(orchestrate)
                try await peer.releaseNextStreamReply()
                let value = try await only(session.responses)
                XCTAssertTrue(value.done == true)
            },
            .init(request: .textToSpeechStream(textToSpeech)) { client, peer in
                let session = try await client.wireTextToSpeechStream(textToSpeech)
                try await peer.releaseNextStreamReply()
                let value = try await only(session.responses)
                XCTAssertTrue(value.done)
            },
            .init(request: .transcribeStream(transcribe)) { client, peer in
                let session = try await client.wireTranscribeStream(transcribe)
                try await peer.releaseNextStreamReply()
                let value = try await only(session.responses)
                XCTAssertEqual(value.text, "audio-stream")
            },
        ]
    }

    private static func duplexResponse(for request: QVACRequest) -> QVACResponse {
        switch request {
        case .bciTranscribeStream:
            return .bciTranscribeStream(.init(done: true, text: "neural-stream"))
        case .completionOrchestrate:
            return .completionOrchestrate(.init(done: true))
        case .textToSpeechStream:
            return .textToSpeechStream(.init(buffer: [], done: true))
        case .transcribeStream:
            return .transcribeStream(.init(done: true, text: "audio-stream"))
        default:
            preconditionFailure("\(request.discriminator) is not a duplex contract request")
        }
    }

    private static func progressInvocations() -> [(Invocation, QVACResponse)] {
        let download = DownloadAssetRequest(
            assetSrc: "https://example.invalid/progress.gguf",
            withProgress: true
        )
        let finetune = FinetuneRequest(modelId: "finetune-model", withProgress: true)
        let load = LoadModelRequest(modelType: "llamacpp-completion", withProgress: true)
        let rag = RagRequest(
            operation: "ingest",
            documents: .array([.string("document")]),
            withProgress: true,
            workspace: "workspace-17"
        )
        let modelProgress = QVACResponse.modelProgress(.init(
            downloadKey: "weights",
            downloaded: 5,
            percentage: 50,
            total: 10
        ))
        let finetuneProgress = QVACResponse.finetuneProgress(.init(
            accuracy: .number(0.9),
            accuracyUncertainty: .number(0.01),
            currentBatch: 1,
            currentEpoch: 1,
            elapsedMs: 10,
            etaMs: 20,
            globalSteps: 1,
            isTrain: true,
            loss: .number(0.1),
            lossUncertainty: .number(0.01),
            modelId: "finetune-model",
            totalBatches: 2
        ))
        let ragProgress = QVACResponse.ragProgress(.init(
            current: 1,
            operation: "ingest",
            stage: "embedding",
            timestamp: 17,
            total: 2,
            workspace: "workspace-17"
        ))

        return [
            (
                .init(request: .downloadAsset(download)) { client, peer in
                    let stream = try await client.wireDownloadAssetProgress(download)
                    try await peer.releaseNextStreamReply()
                    let value = try await only(stream)
                    XCTAssertEqual(value.discriminator, "modelProgress")
                },
                modelProgress
            ),
            (
                .init(request: .finetune(finetune)) { client, peer in
                    let stream = try await client.wireFinetuneProgress(finetune)
                    try await peer.releaseNextStreamReply()
                    let value = try await only(stream)
                    XCTAssertEqual(value.discriminator, "finetune:progress")
                },
                finetuneProgress
            ),
            (
                .init(request: .loadModel(load)) { client, peer in
                    let stream = try await client.wireLoadModelProgress(load)
                    try await peer.releaseNextStreamReply()
                    let value = try await only(stream)
                    XCTAssertEqual(value.discriminator, "modelProgress")
                },
                modelProgress
            ),
            (
                .init(request: .rag(rag)) { client, peer in
                    let stream = try await client.wireRagProgress(rag)
                    try await peer.releaseNextStreamReply()
                    let value = try await only(stream)
                    XCTAssertEqual(value.discriminator, "rag:progress")
                },
                ragProgress
            ),
        ]
    }

    func test_all_generated_unary_wrappers_route_and_decode_exact_responses() async throws {
        let peer = ContractPeer()
        let client = QVACClient(testing: peer)
        let invocations = Self.unaryInvocations()

        for invocation in invocations {
            await peer.enqueue(.init(
                expectedRequest: invocation.request,
                shape: .unary,
                responses: [Self.unaryResponse(for: invocation.request)]
            ))
            try await invocation.run(client, peer)
        }

        await assertPeer(peer, observed: invocations.map(\.request))
        await client.close()
    }

    func test_all_generated_unary_wrappers_reject_mismatched_response_types() async {
        let peer = ContractPeer()
        let client = QVACClient(testing: peer)
        let invocations = Self.unaryInvocations()

        for invocation in invocations {
            await peer.enqueue(.init(
                expectedRequest: invocation.request,
                shape: .unary,
                responses: [Self.wrongResponse(for: invocation.request)]
            ))
            await assertProtocolViolation(operation: invocation.request.discriminator) {
                try await invocation.run(client, peer)
            }
        }

        await assertPeer(peer, observed: invocations.map(\.request))
        await client.close()
    }

    func test_all_generated_unary_wrappers_surface_typed_worker_errors() async {
        let peer = ContractPeer()
        let client = QVACClient(testing: peer)
        let invocations = Self.unaryInvocations()

        for invocation in invocations {
            await peer.enqueue(.init(
                expectedRequest: invocation.request,
                shape: .unary,
                responses: [Self.workerError]
            ))
            await assertWorkerError(operation: invocation.request.discriminator) {
                try await invocation.run(client, peer)
            }
        }

        await assertPeer(peer, observed: invocations.map(\.request))
        await client.close()
    }

    func test_all_generated_server_stream_wrappers_route_and_decode_exact_responses() async throws {
        let peer = ContractPeer()
        let client = QVACClient(testing: peer)
        let invocations = Self.serverStreamInvocations()

        for invocation in invocations {
            await peer.enqueue(.init(
                expectedRequest: invocation.request,
                shape: .serverStream,
                responses: [Self.serverStreamResponse(for: invocation.request)]
            ))
            try await invocation.run(client, peer)
        }

        await assertPeer(peer, observed: invocations.map(\.request))
        await client.close()
    }

    func test_all_generated_server_stream_wrappers_reject_mismatched_response_types() async {
        let peer = ContractPeer()
        let client = QVACClient(testing: peer)
        let invocations = Self.serverStreamInvocations()

        for invocation in invocations {
            await peer.enqueue(.init(
                expectedRequest: invocation.request,
                shape: .serverStream,
                responses: [Self.wrongResponse(for: invocation.request)]
            ))
            await assertProtocolViolation(operation: invocation.request.discriminator) {
                try await invocation.run(client, peer)
            }
        }

        await assertPeer(peer, observed: invocations.map(\.request))
        await client.close()
    }

    func test_all_generated_server_stream_wrappers_drain_and_surface_worker_errors() async {
        let peer = ContractPeer()
        let client = QVACClient(testing: peer)
        let invocations = Self.serverStreamInvocations()

        for invocation in invocations {
            await peer.enqueue(.init(
                expectedRequest: invocation.request,
                shape: .serverStream,
                responses: [Self.workerError]
            ))
            await assertWorkerError(operation: invocation.request.discriminator) {
                try await invocation.run(client, peer)
            }
        }

        await assertPeer(peer, observed: invocations.map(\.request))
        await client.close()
    }

    func test_all_generated_duplex_wrappers_route_and_decode_exact_responses() async throws {
        let peer = ContractPeer()
        let client = QVACClient(testing: peer)
        let invocations = Self.duplexInvocations()

        for invocation in invocations {
            await peer.enqueue(.init(
                expectedRequest: invocation.request,
                shape: .duplex,
                responses: [Self.duplexResponse(for: invocation.request)]
            ))
            try await invocation.run(client, peer)
        }

        await assertPeer(peer, observed: invocations.map(\.request))
        await client.close()
    }

    func test_all_generated_duplex_wrappers_enforce_concrete_response_types() async {
        let peer = ContractPeer()
        let client = QVACClient(testing: peer)
        let invocations = Self.duplexInvocations()

        for invocation in invocations {
            await peer.enqueue(.init(
                expectedRequest: invocation.request,
                shape: .duplex,
                responses: [Self.wrongResponse(for: invocation.request)]
            ))
            await assertConcreteTypeFailure(operation: invocation.request.discriminator) {
                try await invocation.run(client, peer)
            }
        }

        await assertPeer(peer, observed: invocations.map(\.request))
        await client.close()
    }

    func test_all_generated_duplex_wrappers_surface_typed_worker_errors() async {
        let peer = ContractPeer()
        let client = QVACClient(testing: peer)
        let invocations = Self.duplexInvocations()

        for invocation in invocations {
            await peer.enqueue(.init(
                expectedRequest: invocation.request,
                shape: .duplex,
                responses: [Self.workerError]
            ))
            await assertWorkerError(operation: invocation.request.discriminator) {
                try await invocation.run(client, peer)
            }
        }

        await assertPeer(peer, observed: invocations.map(\.request))
        await client.close()
    }

    func test_all_generated_conditional_progress_wrappers_use_stream_transport() async throws {
        let peer = ContractPeer()
        let client = QVACClient(testing: peer)
        let invocations = Self.progressInvocations()

        for (invocation, response) in invocations {
            await peer.enqueue(.init(
                expectedRequest: invocation.request,
                shape: .serverStream,
                responses: [response]
            ))
            try await invocation.run(client, peer)
        }

        await assertPeer(peer, observed: invocations.map(\.0.request))
        await client.close()
    }

    func test_generated_progress_wrappers_reject_unsatisfied_manifest_conditions_before_io() async {
        let peer = ContractPeer()
        let client = QVACClient(testing: peer)
        let invalidCalls: [(String, @Sendable () async throws -> Void)] = [
            ("downloadAsset", {
                _ = try await client.wireDownloadAssetProgress(.init(
                    assetSrc: "https://example.invalid/no-progress.gguf",
                    withProgress: false
                ))
            }),
            ("finetune", {
                _ = try await client.wireFinetuneProgress(.init(
                    modelId: "finetune-model",
                    operation: "cancel",
                    withProgress: true
                ))
            }),
            ("loadModel", {
                _ = try await client.wireLoadModelProgress(.init(
                    modelType: "llamacpp-completion",
                    withProgress: false
                ))
            }),
            ("rag", {
                _ = try await client.wireRagProgress(.init(
                    operation: "listWorkspaces",
                    withProgress: true
                ))
            }),
        ]

        for (operation, call) in invalidCalls {
            do {
                try await call()
                XCTFail("\(operation) accepted an invalid progress request")
            } catch let QVACError.invalidArgument(message) {
                XCTAssertTrue(message.contains("does not satisfy"))
            } catch {
                XCTFail("\(operation) returned \(error), expected invalidArgument")
            }
        }

        await assertPeer(peer, observed: [])
        await client.close()
    }

    func test_low_level_request_reply_redirects_progress_and_reports_inspection_encoding_errors() async {
        let peer = ContractPeer()
        let client = QVACClient(testing: peer)

        do {
            _ = try await client.wireRequestReply(.downloadAsset(.init(
                assetSrc: "https://example.invalid/progress.gguf",
                withProgress: true
            )))
            XCTFail("request/reply accepted a request requiring the progress transport")
        } catch let QVACError.invalidArgument(message) {
            XCTAssertTrue(message.contains("use wireProgressStream"))
        } catch {
            XCTFail("progress redirect returned \(error), expected invalidArgument")
        }

        do {
            _ = try await client.wireFinetuneProgress(.init(
                modelId: "finetune-model",
                options: .number(.nan),
                withProgress: true
            ))
            XCTFail("progress inspection accepted a non-JSON numeric value")
        } catch let QVACError.encoding(message) {
            XCTAssertTrue(message.contains("could not inspect progress request"))
        } catch {
            XCTFail("progress inspection returned \(error), expected encoding failure")
        }

        await assertPeer(peer, observed: [])
        await client.close()
    }

    func test_low_level_duplex_entry_point_routes_and_decodes_the_union_response() async throws {
        let peer = ContractPeer()
        let client = QVACClient(testing: peer)
        let request = TranscribeStreamRequest(modelId: "low-level-duplex-model")
        let envelope = QVACRequest.transcribeStream(request)
        let response = QVACResponse.transcribeStream(.init(done: true, text: "low-level"))
        await peer.enqueue(.init(
            expectedRequest: envelope,
            shape: .duplex,
            responses: [response]
        ))

        let session = try await client.wireDuplex(envelope)
        try await peer.releaseNextStreamReply()
        let received = try await Self.only(session.responses)
        XCTAssertEqual(received, response)

        await assertPeer(peer, observed: [envelope])
        await client.close()
    }

    func test_low_level_generated_wire_entry_points_reject_wrong_call_shapes_before_io() async {
        let peer = ContractPeer()
        let client = QVACClient(testing: peer)
        let calls: [(String, @Sendable () async throws -> Void)] = [
            ("requestReply", {
                _ = try await client.wireRequestReply(.audioGenStream(.init(
                    caption: "music",
                    modelId: "audio-model"
                )))
            }),
            ("serverStream", {
                _ = try await client.wireServerStream(.heartbeat(.init()))
            }),
            ("duplex", {
                _ = try await client.wireDuplex(.heartbeat(.init()))
            }),
            ("progress", {
                _ = try await client.wireProgressStream(.heartbeat(.init()))
            }),
        ]

        for (name, call) in calls {
            do {
                try await call()
                XCTFail("\(name) accepted a request with the wrong manifest shape")
            } catch let QVACError.invalidArgument(message) {
                XCTAssertFalse(message.isEmpty)
            } catch {
                XCTFail("\(name) returned \(error), expected invalidArgument")
            }
        }

        await assertPeer(peer, observed: [])
        await client.close()
    }
}
