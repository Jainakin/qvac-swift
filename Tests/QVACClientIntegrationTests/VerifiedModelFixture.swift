#if canImport(Darwin)
import CryptoKit
import Foundation

struct IntegrationPrerequisiteError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct VerifiedModelFixture: Sendable {
    let name: String
    let source: URL
    let byteCount: UInt64
    let sha256: String

    static let realModelDefault = VerifiedModelFixture(
        name: "SmolLM2-135M-Instruct-Q4_K_M.gguf",
        source: URL(string: "https://huggingface.co/bartowski/SmolLM2-135M-Instruct-GGUF/resolve/d255afaffd3441b95abca9b5cc4c819b93f66936/SmolLM2-135M-Instruct-Q4_K_M.gguf")!,
        byteCount: 105_454_432,
        sha256: "2e8040ceae7815abe0dcb3540b9995eaa1fa0d2ca9e797d0a635ae4433c68c2d"
    )

    static let embeddingModelDefault = VerifiedModelFixture(
        name: "all-MiniLM-L6-v2.Q4_K_M.gguf",
        source: URL(string: "https://huggingface.co/leliuga/all-MiniLM-L6-v2-GGUF/resolve/ddf2e25d5b8530422e7b14aa39f33a657ff9aec0/all-MiniLM-L6-v2.Q4_K_M.gguf")!,
        byteCount: 20_999_104,
        sha256: "53533e550397f2ba4e627bd5833d2c791097372d861a52022a8586282c2178cc"
    )

    /// Official Real-ESRGAN v0.1.0 release asset. The size and checksum also
    /// match `contract/models.json` at the authoritative QVAC 0.17.0 commit.
    static let upscaleModelDefault = VerifiedModelFixture(
        name: "RealESRGAN_x4plus.pth",
        source: URL(string: "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth")!,
        byteCount: 67_040_989,
        sha256: "4fa0d38905f75ac06eb49a7951b426670021be3018265fd191d2125df9d682f1"
    )

    /// Tiny public network fixture used by downloadAsset live tests. The source
    /// commit is npm `bare-rpc@1.3.8`'s published gitHead, rather than mutable
    /// `main`; tests verify all 4,127 bytes before asking the worker to fetch it.
    static let downloadAssetProbe = VerifiedModelFixture(
        name: "bare-rpc-1.3.8-README.md",
        source: URL(string: "https://raw.githubusercontent.com/holepunchto/bare-rpc/a28d3b8fcd13b7dd7de3e6872e4f95dfdf27deb8/README.md")!,
        byteCount: 4_127,
        sha256: "efd48351bf9cb09ee592951f5b6e5c0f30c9aa1e7f25f9bbbcb3a161b47dbb8c"
    )

    static func fromEnvironment(
        default fixture: VerifiedModelFixture,
        urlKey: String,
        sha256Key: String,
        sizeKey: String
    ) throws -> VerifiedModelFixture {
        let environment = ProcessInfo.processInfo.environment
        guard let override = environment[urlKey], !override.isEmpty else {
            if environment[sha256Key] != nil || environment[sizeKey] != nil {
                throw IntegrationPrerequisiteError("\(sha256Key)/\(sizeKey) require \(urlKey)")
            }
            return fixture
        }
        guard let source = URL(string: override), source.isFileURL || source.scheme == "https" else {
            throw IntegrationPrerequisiteError("\(urlKey) must be an https or file URL")
        }
        guard let hash = environment[sha256Key], hash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw IntegrationPrerequisiteError("custom \(urlKey) requires a lowercase 64-hex \(sha256Key)")
        }
        guard let sizeText = environment[sizeKey], let size = UInt64(sizeText), size > 0 else {
            throw IntegrationPrerequisiteError("custom \(urlKey) requires a positive integer \(sizeKey)")
        }
        return VerifiedModelFixture(name: source.lastPathComponent, source: source, byteCount: size, sha256: hash)
    }

    func localURL() async throws -> URL {
        try await VerifiedModelFixtureCache.shared.materialize(self)
    }
}

private actor VerifiedModelFixtureCache {
    static let shared = VerifiedModelFixtureCache()
    private var verified: [String: URL] = [:]

    func materialize(_ fixture: VerifiedModelFixture) async throws -> URL {
        if let cached = verified[fixture.sha256] { return cached }
        let root: URL
        if let override = ProcessInfo.processInfo.environment["QVAC_MODEL_FIXTURE_CACHE"], !override.isEmpty {
            root = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("qvac-swift-model-fixtures", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("\(fixture.sha256)-\(fixture.name)")

        if FileManager.default.fileExists(atPath: target.path) {
            do {
                try verify(target, fixture: fixture)
                verified[fixture.sha256] = target
                return target
            } catch {
                try FileManager.default.removeItem(at: target)
            }
        }

        let temporary: URL
        if fixture.source.isFileURL {
            temporary = root.appendingPathComponent(".\(fixture.sha256)-\(UUID().uuidString).download")
            try FileManager.default.copyItem(at: fixture.source, to: temporary)
        } else {
            var request = URLRequest(url: fixture.source)
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            request.timeoutInterval = 1_800
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 120
            configuration.timeoutIntervalForResource = 1_800
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let (download, response) = try await session.download(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw IntegrationPrerequisiteError("fixture download did not return HTTP 200: \(response)")
            }
            temporary = root.appendingPathComponent(".\(fixture.sha256)-\(UUID().uuidString).download")
            try FileManager.default.moveItem(at: download, to: temporary)
        }

        do {
            try verify(temporary, fixture: fixture)
            try FileManager.default.moveItem(at: temporary, to: target)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        verified[fixture.sha256] = target
        return target
    }

    private func verify(_ url: URL, fixture: VerifiedModelFixture) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let actualSize = (attributes[.size] as? NSNumber)?.uint64Value
        guard actualSize == fixture.byteCount else {
            throw IntegrationPrerequisiteError(
                "\(fixture.name) size mismatch: expected \(fixture.byteCount), got \(actualSize.map { String($0) } ?? "unknown")"
            )
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        let actualHash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actualHash == fixture.sha256 else {
            throw IntegrationPrerequisiteError(
                "\(fixture.name) SHA-256 mismatch: expected \(fixture.sha256), got \(actualHash)"
            )
        }
    }
}
#endif
