// End-to-end proof for the reviewer-requested 0.17 standalone upscale operation.
// Opt-in is the only allowed skip. Once enabled, every missing prerequisite,
// download mismatch, load/upscale error, or cleanup error fails the test.

import XCTest
@testable import QVACClient

#if canImport(Darwin)
final class UpscaleIntegrationTests: XCTestCase {
    private static let bareBin = ProcessInfo.processInfo.environment["QVAC_BARE_BIN"].map {
        URL(fileURLWithPath: $0)
    }
    private static let nodeModulesDir = ProcessInfo.processInfo.environment["QVAC_NODE_MODULES"].map {
        URL(fileURLWithPath: $0, isDirectory: true)
    }
    private var workerHome: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["QVAC_RUN_UPSCALE_TESTS"] == "1",
            "set QVAC_RUN_UPSCALE_TESTS=1 to opt into the pinned ESRGAN integration test"
        )
        guard let bare = Self.bareBin, FileManager.default.isExecutableFile(atPath: bare.path) else {
            throw IntegrationPrerequisiteError("QVAC_RUN_UPSCALE_TESTS=1 but QVAC_BARE_BIN is missing or not executable")
        }
        guard let modules = Self.nodeModulesDir, FileManager.default.fileExists(atPath: modules.path) else {
            throw IntegrationPrerequisiteError("QVAC_RUN_UPSCALE_TESTS=1 but QVAC_NODE_MODULES is missing")
        }
        let packageJSON = modules.appendingPathComponent("@qvac/sdk/package.json")
        guard let data = try? Data(contentsOf: packageJSON),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["version"] as? String == "0.17.0" else {
            throw IntegrationPrerequisiteError("upscale integration requires exact @qvac/sdk 0.17.0 from tools/runtime/package-lock.json")
        }
        _ = try Self.fixture()
        workerHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("qvac-upscale-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workerHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workerHome { try? FileManager.default.removeItem(at: workerHome) }
    }

    private static func fixture() throws -> VerifiedModelFixture {
        try VerifiedModelFixture.fromEnvironment(
            default: .upscaleModelDefault,
            urlKey: "QVAC_TEST_UPSCALE_MODEL_URL",
            sha256Key: "QVAC_TEST_UPSCALE_MODEL_SHA256",
            sizeKey: "QVAC_TEST_UPSCALE_MODEL_SIZE"
        )
    }

    private func makeClient() async throws -> QVACClient {
        let modules = Self.nodeModulesDir!
        return try await QVACClient(
            configuration: .macOSSubprocess(UDSTransportConfiguration(
                bareExecutable: Self.bareBin!,
                workerScript: modules.appendingPathComponent("@qvac/sdk/dist/server/worker.js"),
                workingDirectory: modules.deletingLastPathComponent(),
                initTimeout: 30,
                homeDir: workerHome.path
            )),
            initHandshakeTimeout: .seconds(30)
        )
    }

    func test_pinned_ESRGAN_upscales_sixteen_by_sixteen_PNG_to_sixty_four_by_sixty_four() async throws {
        let client = try await makeClient()
        do {
            let modelURL = try await Self.fixture().localURL()
            let load = try await client.loadModel(
                modelSrc: modelURL.path,
                // Exercise the published 0.17 JS-facing alias. The Swift client
                // must normalize it to the canonical wire value
                // `sdcpp-generation` before the worker sees the request.
                modelType: "diffusion",
                modelConfig: .object([
                    "mode": .string("upscale"),
                    "device": .string("cpu"),
                    "upscaler": .object(["tile_size": .number(64)]),
                ]),
                rpcOptions: .init(timeout: .seconds(600))
            )
            let modelID: String
            do {
                modelID = try await load.result.value
            } catch {
                throw IntegrationPrerequisiteError(
                    "pinned ESRGAN model failed to load in standalone-upscale mode: \(error)"
                )
            }
            do {
                let input = try XCTUnwrap(Data(base64Encoded:
                    "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAABlklEQVR4nBXRURVEIQhFUSMYgQhGMAIRiGCEE8EIRiACEYhABCLMG7/ZrMt1jMEcyGAN9kAHNjgDBnfwBj6IQQ5q0IMxJnMikzXZE53Y5EyY3Mmb+CQmOalJzw8IUxBhCVtQwYQjIFzhCS6EkEIJLR9YzIUs1mIvdGGLs2BxF2/hi1jkoha9PrCZG9mszd7oxjZnw+Zu3sY3sclNbXp/QJmKKEvZiiqmHAXlKk9xJZRUSmn9gDENMZaxDTXMOAbGNZ7hRhhplNH2gcM8yGEd9kEPdjgHDvfwDn6IQx7q0OcD/wK/Sr4jv9hfkG/1N/x/Fx44BCQU9Pc94zIvclmXfdGLXc79j9/Lu/glLnmpS98PPOZDHuuxH/qwx3n/5ffxHv6IRz7q0e8DznTEWc521DHn+D/KdZ7jTjjplNP+gWAGEqxgBxpYcOIf/AYv8CCCDCro+EAyE0lWshNNLDn5P/MmL/Ekkkwq6fxAMQspVrELLaw49S/lFq/wIoosquj6QDMbaVazG22sOf2v8Dav8SaabKrp5geIAnAQEbP2+wAAAABJRU5ErkJggg=="
                ))
                XCTAssertEqual(try pngDimensions(input), [16, 16])

                let run = try await client.upscale(
                    modelId: modelID,
                    image: input,
                    repeats: 1,
                    rpcOptions: .init(timeout: .seconds(120))
                )
                let outputs: [Data]
                do {
                    outputs = try await run.outputs.value
                } catch {
                    throw IntegrationPrerequisiteError(
                        "standalone upscale rejected the verified input PNG: \(error)"
                    )
                }
                XCTAssertEqual(outputs.count, 1)
                let output = try XCTUnwrap(outputs.first)
                XCTAssertEqual(try pngDimensions(output), [64, 64])
                try await client.unloadModel(
                    modelId: modelID,
                    rpcOptions: .init(timeout: .seconds(10))
                )
            } catch let operationError {
                do {
                    try await client.unloadModel(
                        modelId: modelID,
                        rpcOptions: .init(timeout: .seconds(10))
                    )
                } catch {
                    XCTFail("upscale failure cleanup could not unload model: \(error)")
                }
                throw operationError
            }
            await client.close()
        } catch {
            await client.close()
            throw error
        }
    }

    private func pngDimensions(_ data: Data) throws -> [Int] {
        let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        guard data.count >= 24, Array(data.prefix(8)) == signature,
              String(data: data[12..<16], encoding: .ascii) == "IHDR" else {
            throw IntegrationPrerequisiteError("upscale output is not a structurally valid PNG")
        }
        func uint32(at offset: Int) -> Int {
            data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
        }
        return [uint32(at: 16), uint32(at: 20)]
    }
}
#endif
