//
//  PluginVersionStampTests.swift
//  DeFeedbackHostTests
//
//  Covers docs/versioning-spec.md rule V15: scripts/stamp-plugin-version.sh writes the release's version into
//  a Stream Deck plugin manifest. Each test stamps a copy of the real manifest in a temporary folder, never
//  the one in the repository.
//
//  - Tests initially created with AI with human edits, but all reviewed by human

import Foundation
import Testing

@testable import DeFeedbackHost

private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
private let stampScript = repoRoot.appending(path: "scripts/stamp-plugin-version.sh").path
private let realManifest = repoRoot
    .appending(path: "streamdeck/com.eklynx.sound.defeedback.sdPlugin/manifest.json")

private struct StampRun {
    let status: Int32
    let error: String
}

private func stamp(_ version: String, manifest: URL) throws -> StampRun {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [stampScript, version, manifest.path]
    process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
    let err = Pipe()
    process.standardOutput = Pipe()
    process.standardError = err
    try process.run()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return StampRun(status: process.terminationStatus, error: String(decoding: errData, as: UTF8.self))
}

/// A throwaway copy of the real manifest.
private func makeManifestCopy(_ contents: String? = nil) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "PluginVersionStampTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appending(path: "manifest.json")
    if let contents {
        try contents.write(to: url, atomically: true, encoding: .utf8)
    } else {
        try FileManager.default.copyItem(at: realManifest, to: url)
    }
    return url
}

private func version(of manifest: URL) throws -> String? {
    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any]
    return json?["Version"] as? String
}

struct PluginVersionStampTests {

    @Test("V15: the top-level Version is replaced and nothing else in the manifest changes")
    func stampsOnlyTheTopLevelVersion() throws {
        let manifest = try makeManifestCopy()
        defer { try? FileManager.default.removeItem(at: manifest.deletingLastPathComponent()) }
        let before = try String(contentsOf: manifest, encoding: .utf8)
        let original = try #require(try version(of: manifest))

        let run = try stamp("3.4.5.678", manifest: manifest)
        #expect(run.status == 0, "\(run.error)")
        #expect(try version(of: manifest) == "3.4.5.678")

        // Only that one line differs; the Node.js runtime's own "Version": "20" is untouched.
        let after = try String(contentsOf: manifest, encoding: .utf8)
        let changed = zip(before.split(separator: "\n", omittingEmptySubsequences: false),
                          after.split(separator: "\n", omittingEmptySubsequences: false)).filter { $0 != $1 }
        #expect(changed.count == 1, "\(changed)")
        #expect(after.replacingOccurrences(of: "3.4.5.678", with: original) == before)
    }

    @Test("V15: a malformed version is refused and the manifest is left alone")
    func malformedVersionIsRefused() throws {
        let manifest = try makeManifestCopy()
        defer { try? FileManager.default.removeItem(at: manifest.deletingLastPathComponent()) }
        let before = try String(contentsOf: manifest, encoding: .utf8)

        for bad in ["1.2.3", "1.2.3.4.5", "1.2.3.x", "1..3.4", ".1.2.3", "1.2.3.", "v1.2.3.4", "1.2.3.4-beta", ""] {
            let run = try stamp(bad, manifest: manifest)
            #expect(run.status != 0, "'\(bad)' should be refused")
            #expect(try String(contentsOf: manifest, encoding: .utf8) == before)
        }
    }

    @Test("V15: a missing manifest, or one without a top-level Version, is an error")
    func unusableManifestIsAnError() throws {
        let missing = FileManager.default.temporaryDirectory.appending(path: "nope-\(UUID().uuidString).json")
        #expect(try stamp("1.2.3.4", manifest: missing).status != 0)

        let manifest = try makeManifestCopy("{\n\t\"Name\": \"x\"\n}\n")
        defer { try? FileManager.default.removeItem(at: manifest.deletingLastPathComponent()) }
        let run = try stamp("1.2.3.4", manifest: manifest)
        #expect(run.status != 0)
        #expect(run.error.contains("Version"), "\(run.error)")
    }
}
