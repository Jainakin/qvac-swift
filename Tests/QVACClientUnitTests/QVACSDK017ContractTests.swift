import XCTest
@testable import QVACClient

final class QVACSDK017ContractTests: XCTestCase {
    func test_published_contract_provenance_and_exact_manifest() {
        XCTAssertEqual(QVACSDKContract.sdkVersion, "0.17.0")
        XCTAssertEqual(
            QVACSDKContract.upstreamCommit,
            "e8b440665a053a9efe852f04c3601da44f0d55d8"
        )
        XCTAssertEqual(QVACSDKContract.methods.count, 39)
        XCTAssertEqual(QVACSDKContract.methodCount, 39)

        let expected: [String: QVACSDKContract.CallShape] = [
            "audioGenStream": .serverStream,
            "batchCompletionStream": .serverStream,
            "bciTranscribe": .serverStream,
            "bciTranscribeStream": .duplex,
            "cancel": .requestReply,
            "classify": .serverStream,
            "completionOrchestrate": .duplex,
            "completionStream": .serverStream,
            "deleteCache": .requestReply,
            "diffusionStream": .serverStream,
            "downloadAsset": .requestReply,
            "embed": .requestReply,
            "finetune": .requestReply,
            "getLoadedModelInfo": .requestReply,
            "getModelInfo": .requestReply,
            "getSystemResources": .requestReply,
            "heartbeat": .requestReply,
            "loadModel": .requestReply,
            "loggingStream": .serverStream,
            "modelRegistryGetModel": .requestReply,
            "modelRegistryList": .requestReply,
            "modelRegistrySearch": .requestReply,
            "ocrStream": .serverStream,
            "pluginInvoke": .requestReply,
            "pluginInvokeStream": .serverStream,
            "provide": .requestReply,
            "rag": .requestReply,
            "resume": .requestReply,
            "state": .requestReply,
            "stopProvide": .requestReply,
            "suspend": .requestReply,
            "textToSpeech": .serverStream,
            "textToSpeechStream": .duplex,
            "transcribe": .serverStream,
            "transcribeStream": .duplex,
            "translate": .serverStream,
            "unloadModel": .requestReply,
            "upscaleStream": .serverStream,
            "videoStream": .serverStream,
        ]
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: QVACSDKContract.methods.map { ($0.name, $0.callShape) }),
            expected
        )
    }

    func test_all_39_request_union_cases_round_trip() throws {
        let value = JSONValue.string("x")
        let requests: [QVACRequest] = [
            .audioGenStream(.init(caption: "music", modelId: "m")),
            .batchCompletionStream(.init(modelId: "m", prompts: [.object(["history": .array([])])])),
            .bciTranscribe(.init(modelId: "m", neuralData: .object(["type": .string("base64"), "value": .string("AA==")]))),
            .bciTranscribeStream(.init(modelId: "m")),
            .cancel(.init(operation: "request", requestId: "r")),
            .classify(.init(image: "AA==", modelId: "m")),
            .completionOrchestrate(.init(history: [], modelId: "m", stream: true)),
            .completionStream(.init(history: [], modelId: "m", stream: true)),
            .deleteCache(.init(all: true)),
            .diffusionStream(.init(modelId: "m", prompt: "p")),
            .downloadAsset(.init(assetSrc: "https://example.invalid/model")),
            .embed(.init(modelId: "m", text: value)),
            .finetune(.init(modelId: "m")),
            .getLoadedModelInfo(.init(modelId: "m")),
            .getModelInfo(.init(name: "m")),
            .getSystemResources(.init(sample: true)),
            .heartbeat(.init()),
            .loadModel(.init(modelType: "llamacpp-completion")),
            .loggingStream(.init(id: "sdk")),
            .modelRegistryGetModel(.init(registryPath: "org/model", registrySource: "huggingface")),
            .modelRegistryList(.init()),
            .modelRegistrySearch(.init(filter: "model")),
            .ocrStream(.init(image: .object(["type": .string("base64"), "value": .string("AA==")]), modelId: "m")),
            .pluginInvoke(.init(handler: "run", modelId: "m", params: value)),
            .pluginInvokeStream(.init(handler: "run", modelId: "m", params: value)),
            .provide(.init()),
            .rag(.init(operation: "listWorkspaces")),
            .resume(.init()),
            .state(.init()),
            .stopProvide(.init()),
            .suspend(.init()),
            .textToSpeech(.init(modelId: "m", text: "hello")),
            .textToSpeechStream(.init(modelId: "m")),
            .transcribe(.init(audioChunk: .object(["type": .string("base64"), "value": .string("AA==")]), modelId: "m")),
            .transcribeStream(.init(modelId: "m")),
            .translate(.init(modelId: "m", modelType: "nmtcpp-translation", stream: true, text: "hello")),
            .unloadModel(.init(modelId: "m")),
            .upscaleStream(.init(image: "AA==", modelId: "m")),
            .videoStream(.init(mode: "txt2vid", modelId: "m", prompt: "p")),
        ]

        XCTAssertEqual(Set(requests.map(\.discriminator)), Set(QVACSDKContract.methods.map(\.name)))
        for request in requests {
            let encoded = try JSONEncoder.qvac.encode(request)
            let decoded = try JSONDecoder().decode(QVACRequest.self, from: encoded)
            XCTAssertEqual(decoded, request, "round trip failed for \(request.discriminator)")
        }
    }

    func test_new_017_response_cases_decode_from_wire() throws {
        let fixtures: [(String, String)] = [
            ("audioGenStream", #"{"type":"audioGenStream","done":true}"#),
            ("batchCompletionStream", #"{"type":"batchCompletionStream","events":[],"done":true}"#),
            ("bciTranscribe", #"{"type":"bciTranscribe","done":true}"#),
            ("bciTranscribeStream", #"{"type":"bciTranscribeStream","done":true}"#),
            ("classify", #"{"type":"classify","results":[],"done":true}"#),
            ("completionOrchestrate", #"{"type":"completionOrchestrate","done":true}"#),
            ("getSystemResources", #"{"type":"getSystemResources","capabilities":{}}"#),
            ("upscaleStream", #"{"type":"upscaleStream","done":true}"#),
            ("videoStream", #"{"type":"videoStream","done":true}"#),
        ]
        for (expected, fixture) in fixtures {
            let response = try JSONDecoder().decode(QVACResponse.self, from: Data(fixture.utf8))
            XCTAssertEqual(response.discriminator, expected)
        }
    }

    func test_video_and_upscale_wire_keys_match_017_schema() throws {
        var video = VideoStreamRequest(mode: "img2vid", modelId: "m", prompt: "move")
        video.initImage = "AA=="
        video.controlFrames = ["AQ=="]
        video.videoFrames = 17
        video.cfgScale = 7
        video.highNoiseSteps = 4
        let data = try JSONEncoder.qvac.encode(QVACRequest.videoStream(video))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "videoStream")
        XCTAssertEqual(object["init_image"] as? String, "AA==")
        XCTAssertEqual(object["control_frames"] as? [String], ["AQ=="])
        XCTAssertEqual(object["video_frames"] as? Int, 17)
        XCTAssertEqual(object["cfg_scale"] as? Double, 7)
        XCTAssertEqual(object["high_noise_steps"] as? Int, 4)

        let upscale = UpscaleStreamRequest(image: "AA==", modelId: "u", repeats: 2)
        let upscaleData = try JSONEncoder.qvac.encode(QVACRequest.upscaleStream(upscale))
        let upscaleObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: upscaleData) as? [String: Any]
        )
        XCTAssertEqual(upscaleObject["type"] as? String, "upscaleStream")
        XCTAssertEqual(upscaleObject["repeats"] as? Int, 2)
    }

    func test_error_code_values_exhaustively_match_published_contract() {
        let expected = [
            19001, 19002, 19003,
            50001, 50002, 50003, 50004, 50005, 50006, 50007, 50008, 50009, 50010,
            50200, 50201, 50202, 50203, 50204, 50205, 50206,
            50400, 50401, 50402, 50403, 50404,
            50600, 50601, 50602, 50603, 50604, 50605, 50606, 50607, 50608, 50609,
            50610, 50611, 50612, 50613, 50614, 50800,
            52001, 52002, 52003, 52004, 52005,
            52200, 52201, 52202, 52203, 52204, 52205, 52208, 52209, 52210, 52211,
            52400, 52401, 52402, 52403, 52404, 52405, 52406, 52407, 52408, 52409,
            52410, 52411, 52412, 52413, 52414, 52415, 52416, 52417, 52418, 52419,
            52420, 52421,
            52800, 52801, 52802, 52803, 52804, 52805, 52806, 52807, 52808, 52809,
            52810, 52811,
            53000, 53001, 53002, 53003, 53004, 53005, 53006, 53007, 53008, 53009,
            53010, 53011, 53012, 53013, 53014, 53015,
            53200, 53201, 53202, 53203, 53350, 53351,
            53500, 53501, 53502, 53503,
            53600, 53601, 53602,
            53700, 53701, 53702, 53703, 53704,
            53850, 53851, 53852, 53853, 53854, 53855, 53856, 53857, 53858, 53859,
            53900, 53950,
        ]
        XCTAssertEqual(QVACErrorCode.allCases.count, 136)
        XCTAssertEqual(QVACErrorCode.allCases.map(\.rawValue).sorted(), expected)
        XCTAssertEqual(QVACErrorCode.registryFailedToConnect.category, .registry)
        XCTAssertEqual(QVACErrorCode.registryModelNotFound.category, .registry)
        XCTAssertEqual(QVACErrorCode.qvacModelRegistryQueryFailed.category, .modelRegistry)

        // Swift case names are collision-safe, while the public QVAC name remains exact.
        XCTAssertEqual(QVACErrorCode.ocrFailed.name, "OCR_FAILED")
        XCTAssertEqual(QVACErrorCode.ocrFailedServer.name, "OCR_FAILED")
        XCTAssertEqual(QVACErrorCode.invalidAudioChunkTypeServer.name, "INVALID_AUDIO_CHUNK_TYPE")
        XCTAssertEqual(QVACErrorCode.delegateProviderErrorServer.name, "DELEGATE_PROVIDER_ERROR")
    }
}
