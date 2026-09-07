import Foundation
import XCTest
@testable import QVACClient

/// Contract-boundary tests for the rich diffusion and video wrappers.
///
/// These cases mirror the pinned `@qvac/sdk` 0.17 `sdcpp-config.ts` schemas.
/// Invalid rich-wrapper inputs must fail locally; generated `wire*` calls remain
/// the explicit unchecked transport surface.
final class QVACMediaRequestValidationTests: XCTestCase {
    private typealias DiffusionMutation = @Sendable (inout DiffusionStreamRequest) -> Void
    private typealias VideoMutation = @Sendable (inout VideoStreamRequest) -> Void

    private struct UnexpectedTransportWrite: Error {}

    private final class InboundPipe: @unchecked Sendable {
        let stream: AsyncThrowingStream<Data, Error>
        let continuation: AsyncThrowingStream<Data, Error>.Continuation

        init() {
            var captured: AsyncThrowingStream<Data, Error>.Continuation!
            stream = AsyncThrowingStream { captured = $0 }
            continuation = captured
        }
    }

    private actor NoIOTransport: BareTransport {
        nonisolated private let inbound = InboundPipe()
        private var writeCount = 0

        nonisolated func inboundStream() -> AsyncThrowingStream<Data, Error> {
            inbound.stream
        }

        func write(_ data: Data) async throws {
            writeCount += 1
            throw UnexpectedTransportWrite()
        }

        func close() {
            inbound.continuation.finish()
        }

        func writes() -> Int { writeCount }
    }

    private actor PeerTransport: BareTransport {
        nonisolated private let inbound = InboundPipe()
        private var outboundBytes = Data()

        nonisolated func inboundStream() -> AsyncThrowingStream<Data, Error> {
            inbound.stream
        }

        func write(_ data: Data) async throws {
            outboundBytes.append(data)
        }

        func close() {
            inbound.continuation.finish()
        }

        func outbound() -> Data { outboundBytes }

        func feed(_ data: Data) {
            inbound.continuation.yield(data)
        }
    }

    private struct CapturedRequest {
        let id: UInt64
        let payload: Data
    }

    private func assertDiffusionRejected(
        _ request: DiffusionStreamRequest,
        case name: String,
        containing expectedText: String,
        by client: QVACClient,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await client.diffusion(request)
            XCTFail("\(name): invalid request was accepted", file: file, line: line)
        } catch let QVACError.invalidArgument(message) {
            XCTAssertTrue(
                message.contains(expectedText),
                "\(name): expected '\(expectedText)' in '\(message)'",
                file: file,
                line: line
            )
        } catch {
            XCTFail(
                "\(name): expected QVACError.invalidArgument, got \(error)",
                file: file,
                line: line
            )
        }
    }

    private func assertVideoRejected(
        _ request: VideoStreamRequest,
        case name: String,
        containing expectedText: String,
        by client: QVACClient,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await client.video(request)
            XCTFail("\(name): invalid request was accepted", file: file, line: line)
        } catch let QVACError.invalidArgument(message) {
            XCTAssertTrue(
                message.contains(expectedText),
                "\(name): expected '\(expectedText)' in '\(message)'",
                file: file,
                line: line
            )
        } catch {
            XCTFail(
                "\(name): expected QVACError.invalidArgument, got \(error)",
                file: file,
                line: line
            )
        }
    }

    private static func decodedFrames(in data: Data) throws -> [BareRPCFrame] {
        let reader = BareRPCFrameReader()
        try reader.append(data)
        var frames: [BareRPCFrame] = []
        while let frame = reader.next() { frames.append(frame) }
        return frames
    }

    private static func waitForRequest(
        on transport: PeerTransport,
        timeout: Duration = .seconds(1)
    ) async throws -> CapturedRequest {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            let frames = try decodedFrames(in: await transport.outbound())
            if let request = capturedRequest(in: frames) { return request }
            try await Task.sleep(for: .milliseconds(5))
        }
        let frames = try decodedFrames(in: await transport.outbound())
        if let request = capturedRequest(in: frames) { return request }
        throw QVACError.protocolViolation("test peer did not observe a request")
    }

    private static func capturedRequest(in frames: [BareRPCFrame]) -> CapturedRequest? {
        for frame in frames {
            if case .request(let id, _, _, .some(let payload)) = frame {
                return CapturedRequest(id: id, payload: payload)
            }
        }
        return nil
    }

    private static func finishStream(
        id: UInt64,
        record: String,
        on transport: PeerTransport
    ) async {
        var inbound = BareRPCCodec.__testEncodeResponseFrame(
            id: id,
            stream: [.open],
            payload: .success(nil)
        )
        inbound.append(BareRPCCodec.__testEncodeStreamFrame(
            id: id,
            flags: [.response, .data],
            payload: .data(Data((record + "\n").utf8))
        ))
        inbound.append(BareRPCCodec.__testEncodeStreamFrame(
            id: id,
            flags: [.response, .end]
        ))
        await transport.feed(inbound)
    }

    func test_diffusion_rejects_invalid_integer_finite_range_and_enum_fields_before_io() async {
        let transport = NoIOTransport()
        let client = QVACClient(testing: transport)
        let unsafe = 9_007_199_254_740_992
        let cases: [(name: String, field: String, mutate: DiffusionMutation)] = [
            ("zero width", "width", { $0.width = 0 }),
            ("width grid", "width", { $0.width = 10 }),
            ("unsafe width", "width", { $0.width = unsafe }),
            ("negative height", "height", { $0.height = -8 }),
            ("height grid", "height", { $0.height = 15 }),
            ("unsafe height", "height", { $0.height = unsafe }),
            ("zero steps", "steps", { $0.steps = 0 }),
            ("unsafe steps", "steps", { $0.steps = unsafe }),
            ("NaN cfg", "cfgScale", { $0.cfgScale = .nan }),
            ("infinite guidance", "guidance", { $0.guidance = .infinity }),
            ("negative infinite image cfg", "imgCfgScale", {
                $0.imgCfgScale = -.infinity
            }),
            ("unknown sampler", "samplingMethod", { $0.samplingMethod = "future" }),
            ("unknown scheduler", "scheduler", { $0.scheduler = "future" }),
            ("unsafe positive seed", "seed", { $0.seed = unsafe }),
            ("unsafe negative seed", "seed", { $0.seed = -unsafe }),
            ("zero batch", "batchCount", { $0.batchCount = 0 }),
            ("unsafe batch", "batchCount", { $0.batchCount = unsafe }),
            ("negative strength", "strength", { $0.strength = -0.001 }),
            ("large strength", "strength", { $0.strength = 1.001 }),
            ("NaN strength", "strength", { $0.strength = .nan }),
        ]

        for testCase in cases {
            var request = DiffusionStreamRequest(modelId: "model", prompt: "prompt")
            testCase.mutate(&request)
            await assertDiffusionRejected(
                request,
                case: testCase.name,
                containing: testCase.field,
                by: client
            )
        }

        let writeCount = await transport.writes()
        XCTAssertEqual(writeCount, 0)
        await client.close()
    }

    func test_diffusion_rejects_invalid_base64_paths_and_reference_shapes_before_io() async {
        let transport = NoIOTransport()
        let client = QVACClient(testing: transport)
        let cases: [(name: String, field: String, mutate: DiffusionMutation)] = [
            ("empty init image", "initImage", { $0.initImage = "" }),
            ("short init image", "initImage", { $0.initImage = "AAA" }),
            ("misplaced padding", "initImage", { $0.initImage = "A===" }),
            ("whitespace", "initImage", { $0.initImage = "AA==\n" }),
            ("empty references", "initImages", { $0.initImages = [] }),
            ("empty reference", "initImages[1]", { $0.initImages = ["AA==", ""] }),
            ("invalid reference", "initImages[1]", {
                $0.initImages = ["AA==", "not-base64"]
            }),
            ("both image forms", "mutually exclusive", {
                $0.initImage = "AA=="
                $0.initImages = ["AA=="]
            }),
            ("empty lora", "lora", { $0.lora = "" }),
            ("relative lora", "lora", { $0.lora = "models/adapter.safetensors" }),
            ("single-slash UNC", "lora", { $0.lora = "\\server\\adapter" }),
        ]

        for testCase in cases {
            var request = DiffusionStreamRequest(modelId: "model", prompt: "prompt")
            testCase.mutate(&request)
            await assertDiffusionRejected(
                request,
                case: testCase.name,
                containing: testCase.field,
                by: client
            )
        }

        let writeCount = await transport.writes()
        XCTAssertEqual(writeCount, 0)
        await client.close()
    }

    func test_diffusion_upscale_union_is_strict_and_json_safe_before_io() async {
        let transport = NoIOTransport()
        let client = QVACClient(testing: transport)
        let unsafe = 9_007_199_254_740_992.0
        let cases: [(name: String, value: JSONValue, field: String)] = [
            ("null", .null, "upscale must"),
            ("number", .number(1), "upscale must"),
            ("string", .string("true"), "upscale must"),
            ("array", .array([]), "upscale must"),
            ("unknown key", .object(["unknown": .bool(true)]), "only contain repeats"),
            (
                "unknown companion key",
                .object(["repeats": .number(1), "unknown": .bool(true)]),
                "only contain repeats"
            ),
            ("null repeats", .object(["repeats": .null]), "upscale.repeats"),
            ("boolean repeats", .object(["repeats": .bool(true)]), "upscale.repeats"),
            ("zero repeats", .object(["repeats": .number(0)]), "upscale.repeats"),
            ("negative repeats", .object(["repeats": .number(-1)]), "upscale.repeats"),
            ("fractional repeats", .object(["repeats": .number(1.5)]), "upscale.repeats"),
            ("NaN repeats", .object(["repeats": .number(.nan)]), "upscale.repeats"),
            (
                "infinite repeats",
                .object(["repeats": .number(.infinity)]),
                "upscale.repeats"
            ),
            ("unsafe repeats", .object(["repeats": .number(unsafe)]), "upscale.repeats"),
        ]

        for testCase in cases {
            var request = DiffusionStreamRequest(modelId: "model", prompt: "prompt")
            request.upscale = testCase.value
            await assertDiffusionRejected(
                request,
                case: testCase.name,
                containing: testCase.field,
                by: client
            )
        }

        let writeCount = await transport.writes()
        XCTAssertEqual(writeCount, 0)
        await client.close()
    }

    func test_diffusion_accepts_all_schema_boundaries_enum_members_and_union_variants() throws {
        let maximumSafe = 9_007_199_254_740_991
        let maximumWidth = 9_007_199_254_740_984
        var boundary = DiffusionStreamRequest(modelId: "", prompt: "")
        boundary.width = maximumWidth
        boundary.height = 8
        boundary.steps = maximumSafe
        boundary.seed = -maximumSafe
        boundary.batchCount = maximumSafe
        boundary.cfgScale = -Double.greatestFiniteMagnitude
        boundary.guidance = Double.greatestFiniteMagnitude
        boundary.imgCfgScale = -1
        boundary.cachePreset = ""
        boundary.initImages = ["AAAA", "AA==", "AAA=", "AB=="]
        boundary.lora = "/"
        boundary.strength = 0
        boundary.upscale = .object(["repeats": .number(Double(maximumSafe))])
        XCTAssertNoThrow(try QVACMediaRequestValidator.validate(boundary))

        boundary.strength = 1
        boundary.seed = maximumSafe
        boundary.initImages = nil
        boundary.initImage = "AA=="
        boundary.lora = "C:\\adapter.safetensors"
        boundary.upscale = .object([:])
        XCTAssertNoThrow(try QVACMediaRequestValidator.validate(boundary))

        for path in ["C:/adapter.safetensors", "\\\\server\\adapter.safetensors"] {
            boundary.lora = path
            XCTAssertNoThrow(try QVACMediaRequestValidator.validate(boundary), path)
        }
        for upscale in [JSONValue.bool(true), .bool(false)] {
            boundary.upscale = upscale
            XCTAssertNoThrow(try QVACMediaRequestValidator.validate(boundary))
        }

        let samplers = [
            "euler", "euler_a", "heun", "dpm2", "dpm++2m", "dpm++2mv2",
            "dpm++2s_a", "lcm", "ipndm", "ipndm_v", "ddim_trailing", "tcd",
            "res_multistep", "res_2s",
        ]
        for sampler in samplers {
            boundary.samplingMethod = sampler
            XCTAssertNoThrow(try QVACMediaRequestValidator.validate(boundary), sampler)
        }
        boundary.samplingMethod = nil

        let schedulers = [
            "discrete", "karras", "exponential", "ays", "gits", "sgm_uniform",
            "simple", "lcm", "smoothstep", "kl_optimal", "bong_tangent",
        ]
        for scheduler in schedulers {
            boundary.scheduler = scheduler
            XCTAssertNoThrow(try QVACMediaRequestValidator.validate(boundary), scheduler)
        }
    }

    func test_video_rejects_invalid_integer_range_and_enum_fields_before_io() async {
        let transport = NoIOTransport()
        let client = QVACClient(testing: transport)
        let unsafe = 9_007_199_254_740_992
        let cases: [(name: String, field: String, mutate: VideoMutation)] = [
            ("unknown mode", "mode", { $0.mode = "future" }),
            ("empty request id", "requestId", { $0.requestId = "" }),
            ("zero width", "width", { $0.width = 0 }),
            ("width grid", "width", { $0.width = 17 }),
            ("unsafe width", "width", { $0.width = unsafe }),
            ("negative height", "height", { $0.height = -16 }),
            ("height grid", "height", { $0.height = 24 }),
            ("unsafe height", "height", { $0.height = unsafe }),
            ("too few frames", "videoFrames", { $0.videoFrames = 4 }),
            ("wrong frame shape", "videoFrames", { $0.videoFrames = 6 }),
            ("unsafe frames", "videoFrames", { $0.videoFrames = unsafe }),
            ("zero fps", "fps", { $0.fps = 0 }),
            ("negative fps", "fps", { $0.fps = -1 }),
            ("large fps", "fps", { $0.fps = 120.000_001 }),
            ("NaN fps", "fps", { $0.fps = .nan }),
            ("infinite fps", "fps", { $0.fps = .infinity }),
            ("unsafe positive seed", "seed", { $0.seed = unsafe }),
            ("unsafe negative seed", "seed", { $0.seed = -unsafe }),
            ("zero steps", "steps", { $0.steps = 0 }),
            ("unsafe steps", "steps", { $0.steps = unsafe }),
            ("unknown sampler", "samplingMethod", { $0.samplingMethod = "future" }),
            ("unknown scheduler", "scheduler", { $0.scheduler = "future" }),
            ("zero high-noise steps", "highNoiseSteps", { $0.highNoiseSteps = 0 }),
            ("unsafe high-noise steps", "highNoiseSteps", {
                $0.highNoiseSteps = unsafe
            }),
            ("unknown high-noise sampler", "highNoiseSampler", {
                $0.highNoiseSampler = "future"
            }),
            ("unknown high-noise scheduler", "highNoiseScheduler", {
                $0.highNoiseScheduler = "future"
            }),
            ("unknown cache mode", "cacheMode", { $0.cacheMode = "future" }),
        ]

        for testCase in cases {
            var request = VideoStreamRequest(mode: "txt2vid", modelId: "model", prompt: "prompt")
            testCase.mutate(&request)
            await assertVideoRejected(
                request,
                case: testCase.name,
                containing: testCase.field,
                by: client
            )
        }

        let writeCount = await transport.writes()
        XCTAssertEqual(writeCount, 0)
        await client.close()
    }

    func test_video_rejects_every_nonfinite_and_bounded_double_field_before_io() async {
        let transport = NoIOTransport()
        let client = QVACClient(testing: transport)
        let cases: [(name: String, field: String, mutate: VideoMutation)] = [
            ("NaN cfg", "cfgScale", { $0.cfgScale = .nan }),
            ("infinite flow shift", "flowShift", { $0.flowShift = .infinity }),
            ("negative infinite high cfg", "highNoiseCfgScale", {
                $0.highNoiseCfgScale = -.infinity
            }),
            ("NaN high flow", "highNoiseFlowShift", {
                $0.highNoiseFlowShift = .nan
            }),
            ("NaN MoE boundary", "moeBoundary", { $0.moeBoundary = .nan }),
            ("negative MoE boundary", "moeBoundary", { $0.moeBoundary = -0.001 }),
            ("large MoE boundary", "moeBoundary", { $0.moeBoundary = 1.001 }),
            ("NaN VACE strength", "vaceStrength", { $0.vaceStrength = .nan }),
            ("negative VACE strength", "vaceStrength", { $0.vaceStrength = -0.001 }),
            ("large VACE strength", "vaceStrength", { $0.vaceStrength = 1.001 }),
            ("NaN tile overlap", "vaeTileOverlap", { $0.vaeTileOverlap = .nan }),
            ("infinite cache threshold", "cacheThreshold", {
                $0.cacheThreshold = .infinity
            }),
        ]

        for testCase in cases {
            var request = VideoStreamRequest(mode: "txt2vid", modelId: "model", prompt: "prompt")
            testCase.mutate(&request)
            await assertVideoRejected(
                request,
                case: testCase.name,
                containing: testCase.field,
                by: client
            )
        }

        let strengthValues: [(String, Double)] = [
            ("NaN", .nan),
            ("negative", -0.001),
            ("large", 1.001),
        ]
        for (name, value) in strengthValues {
            var request = VideoStreamRequest(mode: "img2vid", modelId: "model", prompt: "prompt")
            request.initImage = "AA=="
            request.strength = value
            await assertVideoRejected(
                request,
                case: "\(name) strength",
                containing: "strength",
                by: client
            )
        }

        let writeCount = await transport.writes()
        XCTAssertEqual(writeCount, 0)
        await client.close()
    }

    func test_video_rejects_invalid_base64_mode_refinements_and_tile_size_before_io() async {
        let transport = NoIOTransport()
        let client = QVACClient(testing: transport)
        let cases: [(name: String, field: String, mutate: VideoMutation)] = [
            ("empty control array", "controlFrames", { $0.controlFrames = [] }),
            ("empty control frame", "controlFrames[1]", {
                $0.controlFrames = ["AA==", ""]
            }),
            ("invalid control frame", "controlFrames[1]", {
                $0.controlFrames = ["AA==", "not-base64"]
            }),
            ("empty init image", "initImage", {
                $0.mode = "img2vid"
                $0.initImage = ""
            }),
            ("invalid init image", "initImage", {
                $0.mode = "img2vid"
                $0.initImage = "A==="
            }),
            ("img2vid missing image", "required", { $0.mode = "img2vid" }),
            ("txt2vid with image", "only valid", { $0.initImage = "AA==" }),
            ("txt2vid with strength", "only valid", { $0.strength = 0.5 }),
            ("zero numeric tile", "vaeTileSize", { $0.vaeTileSize = .number(0) }),
            ("negative numeric tile", "vaeTileSize", { $0.vaeTileSize = .number(-1) }),
            ("NaN numeric tile", "vaeTileSize", { $0.vaeTileSize = .number(.nan) }),
            ("infinite numeric tile", "vaeTileSize", {
                $0.vaeTileSize = .number(.infinity)
            }),
            ("empty string tile", "vaeTileSize", { $0.vaeTileSize = .string("") }),
            ("null tile", "vaeTileSize", { $0.vaeTileSize = .null }),
            ("boolean tile", "vaeTileSize", { $0.vaeTileSize = .bool(true) }),
            ("array tile", "vaeTileSize", { $0.vaeTileSize = .array([]) }),
            ("object tile", "vaeTileSize", { $0.vaeTileSize = .object([:]) }),
        ]

        for testCase in cases {
            var request = VideoStreamRequest(mode: "txt2vid", modelId: "model", prompt: "prompt")
            testCase.mutate(&request)
            await assertVideoRejected(
                request,
                case: testCase.name,
                containing: testCase.field,
                by: client
            )
        }

        let writeCount = await transport.writes()
        XCTAssertEqual(writeCount, 0)
        await client.close()
    }

    func test_video_accepts_all_schema_boundaries_enum_members_and_tile_variants() throws {
        let maximumSafe = 9_007_199_254_740_991
        let maximumDimension = 9_007_199_254_740_976
        let maximumFrames = 9_007_199_254_740_989
        var boundary = VideoStreamRequest(mode: "img2vid", modelId: "", prompt: "")
        boundary.requestId = "request"
        boundary.width = maximumDimension
        boundary.height = 16
        boundary.videoFrames = maximumFrames
        boundary.fps = Double.leastNonzeroMagnitude
        boundary.seed = -maximumSafe
        boundary.steps = maximumSafe
        boundary.cfgScale = -Double.greatestFiniteMagnitude
        boundary.flowShift = Double.greatestFiniteMagnitude
        boundary.highNoiseSteps = maximumSafe
        boundary.highNoiseCfgScale = -Double.greatestFiniteMagnitude
        boundary.highNoiseFlowShift = Double.greatestFiniteMagnitude
        boundary.moeBoundary = 0
        boundary.vaceStrength = 1
        boundary.controlFrames = ["AAAA", "AA==", "AAA=", "AB=="]
        boundary.initImage = "AA=="
        boundary.strength = 0
        boundary.vaeTileSize = .number(Double.leastNonzeroMagnitude)
        boundary.vaeTileOverlap = -Double.greatestFiniteMagnitude
        boundary.cachePreset = ""
        boundary.cacheThreshold = Double.greatestFiniteMagnitude
        XCTAssertNoThrow(try QVACMediaRequestValidator.validate(boundary))

        boundary.width = 16
        boundary.videoFrames = 5
        boundary.fps = 120
        boundary.seed = maximumSafe
        boundary.moeBoundary = 1
        boundary.vaceStrength = 0
        boundary.strength = 1
        boundary.vaeTileSize = .string(" ")
        XCTAssertNoThrow(try QVACMediaRequestValidator.validate(boundary))

        // Model-dependent LTX/MoE refinements intentionally remain worker-side;
        // these values satisfy the generic videoStream request schema.
        boundary.width = 48
        boundary.videoFrames = 13
        XCTAssertNoThrow(try QVACMediaRequestValidator.validate(boundary))

        let samplers = [
            "euler", "euler_a", "heun", "dpm2", "dpm++2m", "dpm++2mv2",
            "dpm++2s_a", "lcm", "ipndm", "ipndm_v", "ddim_trailing", "tcd",
            "res_multistep", "res_2s",
        ]
        for sampler in samplers {
            boundary.samplingMethod = sampler
            boundary.highNoiseSampler = sampler
            XCTAssertNoThrow(try QVACMediaRequestValidator.validate(boundary), sampler)
        }
        boundary.samplingMethod = nil
        boundary.highNoiseSampler = nil

        let schedulers = [
            "discrete", "karras", "exponential", "ays", "gits", "sgm_uniform",
            "simple", "lcm", "smoothstep", "kl_optimal", "bong_tangent",
        ]
        for scheduler in schedulers {
            boundary.scheduler = scheduler
            boundary.highNoiseScheduler = scheduler
            XCTAssertNoThrow(try QVACMediaRequestValidator.validate(boundary), scheduler)
        }
        boundary.scheduler = nil
        boundary.highNoiseScheduler = nil

        for cacheMode in [
            "disabled", "easycache", "ucache", "dbcache", "taylorseer", "cache-dit",
        ] {
            boundary.cacheMode = cacheMode
            XCTAssertNoThrow(try QVACMediaRequestValidator.validate(boundary), cacheMode)
        }
    }

    func test_configure_closures_cannot_bypass_exact_wrapper_validation() async {
        let transport = NoIOTransport()
        let client = QVACClient(testing: transport)

        do {
            _ = try await client.diffusion(
                modelId: "model",
                prompt: "prompt",
                configure: { request in request.width = 10 }
            )
            XCTFail("diffusion configure mutation was accepted")
        } catch let QVACError.invalidArgument(message) {
            XCTAssertTrue(message.contains("width"))
        } catch {
            XCTFail("unexpected diffusion configure error: \(error)")
        }

        do {
            _ = try await client.video(
                modelId: "model",
                mode: "txt2vid",
                prompt: "prompt",
                configure: { request in request.mode = "img2vid" }
            )
            XCTFail("video configure mutation was accepted")
        } catch let QVACError.invalidArgument(message) {
            XCTAssertTrue(message.contains("required"))
        } catch {
            XCTFail("unexpected video configure error: \(error)")
        }

        let writeCount = await transport.writes()
        XCTAssertEqual(writeCount, 0)
        await client.close()
    }

    func test_rich_exact_wrappers_forward_every_valid_diffusion_and_video_field_byte_exactly() async throws {
        let diffusionTransport = PeerTransport()
        let diffusionClient = QVACClient(testing: diffusionTransport)
        let diffusionRequest = DiffusionStreamRequest(
            modelId: "diffusion-model",
            prompt: "a fox",
            autoResizeRefImage: false,
            batchCount: 2,
            cachePreset: "balanced",
            cfgScale: 7,
            guidance: 3.5,
            height: 512,
            imgCfgScale: -1,
            increaseRefIndex: true,
            initImages: ["AA==", "AQ=="],
            lora: "/models/adapter.safetensors",
            negativePrompt: "blur",
            samplingMethod: "euler",
            scheduler: "karras",
            seed: -42,
            steps: 20,
            strength: 0.75,
            upscale: .object(["repeats": .number(2)]),
            vaeTiling: true,
            width: 768
        )
        let diffusionRun = try await diffusionClient.diffusion(diffusionRequest)
        let capturedDiffusion = try await Self.waitForRequest(on: diffusionTransport)
        XCTAssertEqual(
            capturedDiffusion.payload,
            try JSONEncoder.qvac.encode(QVACRequest.diffusionStream(diffusionRequest))
        )
        await Self.finishStream(
            id: capturedDiffusion.id,
            record: #"{"type":"diffusionStream","done":true}"#,
            on: diffusionTransport
        )
        let diffusionOutputs = try await diffusionRun.outputs.value
        XCTAssertEqual(diffusionOutputs, [])
        await diffusionClient.close()

        let videoTransport = PeerTransport()
        let videoClient = QVACClient(testing: videoTransport)
        let videoRequest = VideoStreamRequest(
            mode: "img2vid",
            modelId: "video-model",
            prompt: "turn slowly",
            cacheMode: "easycache",
            cachePreset: "balanced",
            cacheThreshold: 0.2,
            cfgScale: 6,
            controlFrames: ["AA==", "AQ=="],
            flowShift: 5,
            fps: 24,
            height: 320,
            highNoiseCfgScale: 3,
            highNoiseFlowShift: 4,
            highNoiseSampler: "euler_a",
            highNoiseScheduler: "simple",
            highNoiseSteps: 8,
            initImage: "Ag==",
            moeBoundary: 0.875,
            negativePrompt: "jitter",
            requestId: "video-request",
            samplingMethod: "euler",
            scheduler: "karras",
            seed: -17,
            steps: 24,
            strength: 0.85,
            temporalTiling: true,
            vaceStrength: 0.5,
            vaeTileOverlap: 0.25,
            vaeTileSize: .string("64x64"),
            vaeTiling: true,
            videoFrames: 121,
            width: 512
        )
        let videoRun = try await videoClient.video(videoRequest)
        let capturedVideo = try await Self.waitForRequest(on: videoTransport)
        XCTAssertEqual(videoRun.requestId, "video-request")
        XCTAssertEqual(
            capturedVideo.payload,
            try JSONEncoder.qvac.encode(QVACRequest.videoStream(videoRequest))
        )
        await Self.finishStream(
            id: capturedVideo.id,
            record: #"{"type":"videoStream","done":true}"#,
            on: videoTransport
        )
        let videoOutputs = try await videoRun.outputs.value
        XCTAssertEqual(videoOutputs, [])
        await videoClient.close()
    }

    func test_generated_wire_streams_remain_explicit_unchecked_escape_hatches() async throws {
        let diffusionTransport = PeerTransport()
        let diffusionClient = QVACClient(testing: diffusionTransport)
        let invalidDiffusion = DiffusionStreamRequest(
            modelId: "model",
            prompt: "prompt",
            width: 10
        )
        let diffusionStream = try await diffusionClient.wireDiffusionStream(invalidDiffusion)
        let capturedDiffusion = try await Self.waitForRequest(on: diffusionTransport)
        XCTAssertEqual(
            capturedDiffusion.payload,
            try JSONEncoder.qvac.encode(QVACRequest.diffusionStream(invalidDiffusion))
        )
        await Self.finishStream(
            id: capturedDiffusion.id,
            record: #"{"type":"diffusionStream","done":true}"#,
            on: diffusionTransport
        )
        for try await _ in diffusionStream {}
        await diffusionClient.close()

        let videoTransport = PeerTransport()
        let videoClient = QVACClient(testing: videoTransport)
        let invalidVideo = VideoStreamRequest(
            mode: "future",
            modelId: "model",
            prompt: "prompt"
        )
        let videoStream = try await videoClient.wireVideoStream(invalidVideo)
        let capturedVideo = try await Self.waitForRequest(on: videoTransport)
        XCTAssertEqual(
            capturedVideo.payload,
            try JSONEncoder.qvac.encode(QVACRequest.videoStream(invalidVideo))
        )
        await Self.finishStream(
            id: capturedVideo.id,
            record: #"{"type":"videoStream","done":true}"#,
            on: videoTransport
        )
        for try await _ in videoStream {}
        await videoClient.close()
    }
}
