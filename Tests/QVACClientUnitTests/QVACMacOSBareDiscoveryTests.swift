#if os(macOS)
import Foundation
import XCTest
@testable import QVACClient

final class QVACMacOSBareDiscoveryTests: XCTestCase {
    func test_discovery_prefers_first_executable_static_candidate() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let nonExecutable = root.appendingPathComponent("static-a/bare")
        let executable = root.appendingPathComponent("static-b/bare")
        let nvmBare = root.appendingPathComponent("nvm/v99.0.0/bin/bare")
        let pathBare = root.appendingPathComponent("path/bare")
        try makeFile(at: nonExecutable, executable: false)
        try makeFile(at: executable, executable: true)
        try makeFile(at: nvmBare, executable: true)
        try makeFile(at: pathBare, executable: true)

        let selected = QVACClient.Configuration.__testDiscoverBare(
            staticCandidates: [nonExecutable, executable],
            nvmRoot: root.appendingPathComponent("nvm", isDirectory: true),
            pathCandidate: pathBare
        )

        XCTAssertEqual(selected?.standardizedFileURL, executable.standardizedFileURL)
    }

    func test_discovery_orders_nvm_versions_numerically_and_skips_invalid_candidates() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let nvmRoot = root.appendingPathComponent("nvm", isDirectory: true)
        let v9 = nvmRoot.appendingPathComponent("v9.99.99/bin/bare")
        let v22dot9 = nvmRoot.appendingPathComponent("v22.9.0/bin/bare")
        let v22dot10 = nvmRoot.appendingPathComponent("v22.10.0/bin/bare")
        let v100NonExecutable = nvmRoot.appendingPathComponent("v100.0.0/bin/bare")
        let directoryNamedBare = nvmRoot.appendingPathComponent(
            "v101.0.0/bin/bare",
            isDirectory: true
        )
        try makeFile(at: v9, executable: true)
        try makeFile(at: v22dot9, executable: true)
        try makeFile(at: v22dot10, executable: true)
        try makeFile(at: v100NonExecutable, executable: false)
        try FileManager.default.createDirectory(
            at: directoryNamedBare,
            withIntermediateDirectories: true
        )

        let selected = QVACClient.Configuration.__testDiscoverBare(
            staticCandidates: [],
            nvmRoot: nvmRoot,
            pathCandidate: nil
        )

        XCTAssertEqual(selected?.standardizedFileURL, v22dot10.standardizedFileURL)
    }

    func test_discovery_uses_only_an_executable_regular_path_candidate() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let absentNVM = root.appendingPathComponent("absent-nvm", isDirectory: true)
        let executable = root.appendingPathComponent("executable/bare")
        let nonExecutable = root.appendingPathComponent("non-executable/bare")
        let directory = root.appendingPathComponent("directory/bare", isDirectory: true)
        try makeFile(at: executable, executable: true)
        try makeFile(at: nonExecutable, executable: false)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        XCTAssertEqual(
            QVACClient.Configuration.__testDiscoverBare(
                staticCandidates: [],
                nvmRoot: absentNVM,
                pathCandidate: executable
            )?.standardizedFileURL,
            executable.standardizedFileURL
        )
        XCTAssertNil(QVACClient.Configuration.__testDiscoverBare(
            staticCandidates: [],
            nvmRoot: absentNVM,
            pathCandidate: nonExecutable
        ))
        XCTAssertNil(QVACClient.Configuration.__testDiscoverBare(
            staticCandidates: [],
            nvmRoot: absentNVM,
            pathCandidate: directory
        ))
        XCTAssertNil(QVACClient.Configuration.__testDiscoverBare(
            staticCandidates: [],
            nvmRoot: absentNVM,
            pathCandidate: nil
        ))
    }

    func test_which_fallback_uses_the_supplied_path_and_rejects_missing_bare() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let bare = bin.appendingPathComponent("bare")
        try makeFile(at: bare, executable: true)

        let selected = QVACClient.Configuration.__testWhichBare(searchPath: bin.path)
        XCTAssertEqual(selected?.standardizedFileURL, bare.standardizedFileURL)
        XCTAssertNil(QVACClient.Configuration.__testWhichBare(
            searchPath: root.appendingPathComponent("missing", isDirectory: true).path
        ))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "qvac-bare-discovery-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        return root
    }

    private func makeFile(at url: URL, executable: Bool) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: executable ? 0o700 : 0o600],
            ofItemAtPath: url.path
        )
    }
}
#endif
