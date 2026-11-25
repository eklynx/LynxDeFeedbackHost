//
//  UpdateScriptTests.swift
//  DeFeedbackHostTests
//
//  Covers docs/updates-spec.md rules U23 (build number script) and U24 (publish script channels).
//  Runs the real shell scripts against temp folders and a stub `sign_update`, so no key, network
//  or Sparkle install is needed.
//
//  - Tests initially created with AI with human edits, but all reviewed by human

import Foundation
import Testing

@testable import DeFeedbackHost

private struct ScriptResult {
    let status: Int32
    let output: String
}

private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()

private func run(_ script: String, _ arguments: [String], environment: [String: String]) throws -> ScriptResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [repoRoot.appending(path: "scripts/\(script)").path] + arguments
    // Start from a clean environment so a developer's own BUILD_NUMBER or signing key can't leak in.
    process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"].merging(environment) { $1 }
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return ScriptResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
}

private func scratchDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "UpdateScriptTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

struct UpdateScriptTests {

    // MARK: U23 build number

    private func stampedBuild(_ environment: [String: String]) throws -> (ScriptResult, String?) {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let plist = dir.appending(path: "Info.plist")
        try """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict><key>CFBundleVersion</key><string>1</string></dict></plist>
            """.write(to: plist, atomically: true, encoding: .utf8)

        let result = try run("set-build-number.sh", [], environment: [
            "TARGET_BUILD_DIR": dir.path, "INFOPLIST_PATH": "Info.plist", "SRCROOT": repoRoot.path,
        ].merging(environment) { $1 })
        let stamped = (NSDictionary(contentsOf: plist)?["CFBundleVersion"]) as? String
        return (result, stamped)
    }

    @Test("U23: the build number is the UTC build time, 14 digits")
    func buildNumberIsTimestamp() throws {
        let (result, stamped) = try stampedBuild([:])
        #expect(result.status == 0, "\(result.output)")
        let value = try #require(stamped)
        #expect(value.count == 14 && value.allSatisfy(\.isNumber), "got \(value)")
        #expect(value.hasPrefix("20"))
    }

    @Test("U23: BUILD_NUMBER overrides the timestamp; non-digits are rejected")
    func buildNumberOverride() throws {
        let (ok, stamped) = try stampedBuild(["BUILD_NUMBER": "20261125030000"])
        #expect(ok.status == 0, "\(ok.output)")
        #expect(stamped == "20261125030000")

        let (bad, unchanged) = try stampedBuild(["BUILD_NUMBER": "1.2-abc"])
        #expect(bad.status != 0)
        #expect(unchanged == "1", "a rejected number must leave the plist alone")
    }

    // MARK: U24 publish script

    /// A directory holding a `sign_update` that prints a fixed signature, and a fake DMG.
    private func publishFixture() throws -> (dir: URL, bin: URL, dmg: URL, site: URL) {
        let dir = try scratchDirectory()
        let bin = dir.appending(path: "bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let stub = bin.appending(path: "sign_update")
        try "#!/bin/sh\necho FAKESIGNATURE==\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let dmg = dir.appending(path: "App.dmg")
        try Data("dmg".utf8).write(to: dmg)
        return (dir, bin, dmg, dir.appending(path: "site"))
    }

    private func publish(_ fixture: (dir: URL, bin: URL, dmg: URL, site: URL),
                         version: String, build: String, extra: [String] = []) throws -> ScriptResult {
        try run("publish-update.sh",
                ["--dmg", fixture.dmg.path, "--version", version, "--build", build,
                 "--site-dir", fixture.site.path] + extra,
                environment: ["SPARKLE_BIN": fixture.bin.path, "SPARKLE_ED_PRIVATE_KEY": "unused"])
    }

    private func feed(_ fixture: (dir: URL, bin: URL, dmg: URL, site: URL)) throws -> String {
        try String(contentsOf: fixture.site.appending(path: "appcast.xml"), encoding: .utf8)
    }

    @Test("U24: a release item has no channel tag; nightly and pre-release items do")
    func publishTagsChannels() throws {
        let fixture = try publishFixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }

        var result = try publish(fixture, version: "1.0.0", build: "20261101000000")
        #expect(result.status == 0, "\(result.output)")
        result = try publish(fixture, version: "1.1.0-beta.1", build: "20261110000000",
                             extra: ["--channel", "prerelease", "--tag", "v1.1.0-beta.1"])
        #expect(result.status == 0, "\(result.output)")
        result = try publish(fixture, version: "1.0.1-20261125030000.ab12cd3", build: "20261125030000",
                             extra: ["--channel", "nightly"])
        #expect(result.status == 0, "\(result.output)")

        let text = try feed(fixture)
        let items = text.components(separatedBy: "<item>").dropFirst()
        #expect(items.count == 3)

        // Newest first.
        let nightly = try #require(items.first)
        #expect(nightly.contains("<sparkle:channel>nightly</sparkle:channel>"))
        #expect(nightly.contains("<sparkle:shortVersionString>1.0.1-20261125030000.ab12cd3</sparkle:shortVersionString>"))
        #expect(nightly.contains("<link>https://github.com/eklynx/LynxDeFeedbackHost/releases/tag/nightly-1.0.1-20261125030000.ab12cd3</link>"))
        #expect(nightly.contains("/releases/download/nightly-1.0.1-20261125030000.ab12cd3/App.dmg"))

        let pre = items.dropFirst().first ?? ""
        #expect(pre.contains("<sparkle:channel>prerelease</sparkle:channel>"))
        #expect(pre.contains("/releases/tag/v1.1.0-beta.1</link>"))

        let release = try #require(items.last)
        #expect(!release.contains("<sparkle:channel>"), "release items must be untagged")
        #expect(release.contains("/releases/tag/v1.0.0</link>"))
    }

    @Test("U24: republishing a build replaces its item; an unknown channel is rejected")
    func publishDedupAndValidation() throws {
        let fixture = try publishFixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }

        _ = try publish(fixture, version: "1.0.0", build: "20261101000000")
        _ = try publish(fixture, version: "1.0.0", build: "20261101000000")
        #expect(try feed(fixture).components(separatedBy: "<item>").count - 1 == 1)

        let bad = try publish(fixture, version: "1.0.0", build: "20261102000000", extra: ["--channel", "beta"])
        #expect(bad.status != 0)
        #expect(bad.output.contains("--channel must be"))
    }
}
