//
//  DmgScriptTests.swift
//  DeFeedbackHostTests
//
//  Covers docs/release-spec.md rules R10–R11 (disk image creation). The release once died in
//  `hdiutil create` with only "No such file or directory"; these check that the packaging step
//  produces a real image, explains itself when the first tool fails, and falls back to the second.
//
//  - Tests initially created with AI with human edits, but all reviewed by human

import Foundation
import Testing

@testable import DeFeedbackHost

private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()

private struct Run {
    let status: Int32
    let output: String
}

private func run(_ arguments: [String], environment: [String: String] = [:]) throws -> Run {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = arguments
    process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"].merging(environment) { $1 }
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return Run(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
}

private func scratch() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "DmgScriptTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeFolder(in dir: URL) throws -> URL {
    let folder = dir.appending(path: "stage")
    try FileManager.default.createDirectory(at: folder.appending(path: "App.app/Contents"), withIntermediateDirectories: true)
    try "hello".write(to: folder.appending(path: "App.app/Contents/file.txt"), atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(atPath: folder.appending(path: "Applications").path,
                                               withDestinationPath: "/Applications")
    return folder
}

private func stubTool(_ name: String, in bin: URL, body: String) throws {
    let url = bin.appending(path: name)
    try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

struct DmgScriptTests {

    private var makeDmg: String { repoRoot.appending(path: "scripts/make-dmg.sh").path }

    @Test("R10: a folder becomes a real, mountable disk image")
    func makesARealImage() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = try makeFolder(in: dir)
        let out = dir.appending(path: "out/App.dmg")           // the output folder doesn't exist yet

        let result = try run([makeDmg, folder.path, out.path, "Test Volume"])
        #expect(result.status == 0, "\(result.output)")
        #expect(FileManager.default.fileExists(atPath: out.path))

        let verify = try run(["-c", "/usr/bin/hdiutil verify '\(out.path)' >/dev/null 2>&1; echo $?"])
        #expect(verify.output.trimmingCharacters(in: .whitespacesAndNewlines) == "0", "the image should verify")
    }

    @Test("R10: a missing source folder fails with a message")
    func missingSourceFails() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = try run([makeDmg, dir.appending(path: "nope").path, dir.appending(path: "x.dmg").path, "V"])
        #expect(result.status != 0)
        #expect(result.output.contains("does not exist"))
    }

    @Test("R11: when hdiutil fails it says why and retries with diskutil")
    func fallsBackToDiskutil() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = try makeFolder(in: dir)
        let bin = dir.appending(path: "bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let calls = dir.appending(path: "calls.txt")
        try stubTool("hdiutil", in: bin, body: "echo 'hdiutil: create failed - No such file or directory' >&2\nexit 1")
        // The stub diskutil records its arguments and creates the output file (its 5th argument).
        try stubTool("diskutil", in: bin, body: "echo \"$@\" >> \"\(calls.path)\"\ntouch \"$5\"")

        let out = dir.appending(path: "App.dmg")
        let result = try run([makeDmg, folder.path, out.path, "Test Volume"],
                             environment: ["PATH": "\(bin.path):/usr/bin:/bin:/usr/sbin:/sbin"])
        #expect(result.status == 0, "\(result.output)")
        #expect(result.output.contains("hdiutil create failed"), "it should say hdiutil failed")
        #expect(result.output.contains("path lengths"), "and print what it needs to diagnose it")
        #expect(result.output.contains("retrying with: diskutil image create from"))
        let recorded = try String(contentsOf: calls, encoding: .utf8)
        #expect(recorded.contains("image create from \(folder.path) \(out.path) --format UDZO --volumeName Test Volume"), "\(recorded)")
        #expect(FileManager.default.fileExists(atPath: out.path))
    }

    @Test("R11: if both tools fail, the script fails clearly")
    func bothToolsFail() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = try makeFolder(in: dir)
        let bin = dir.appending(path: "bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try stubTool("hdiutil", in: bin, body: "exit 1")
        try stubTool("diskutil", in: bin, body: "exit 1")
        let result = try run([makeDmg, folder.path, dir.appending(path: "App.dmg").path, "V"],
                             environment: ["PATH": "\(bin.path):/usr/bin:/bin:/usr/sbin:/sbin"])
        #expect(result.status != 0)
        #expect(result.output.contains("could not create"))
    }

    // MARK: create-dmg.sh without a certificate

    private func createDmgEnvironment(_ dir: URL, allowUnsigned: Bool) throws -> [String: String] {
        // A pretend Xcode install-only build environment around a fake app, with the repo's
        // scripts reachable as ${PROJECT_DIR}/scripts and nothing written into the repo.
        let project = dir.appending(path: "project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: project.appending(path: "scripts"))   // idempotent: called twice
        try FileManager.default.createSymbolicLink(atPath: project.appending(path: "scripts").path,
                                                   withDestinationPath: repoRoot.appending(path: "scripts").path)
        let products = dir.appending(path: "products")
        try FileManager.default.createDirectory(at: products.appending(path: "Fake.app/Contents"), withIntermediateDirectories: true)
        try "x".write(to: products.appending(path: "Fake.app/Contents/x"), atomically: true, encoding: .utf8)
        var env = ["PROJECT_DIR": project.path, "TARGET_BUILD_DIR": products.path, "FULL_PRODUCT_NAME": "Fake.app",
                   "PRODUCT_NAME": "Fake", "MARKETING_VERSION": "9.9.9", "TARGET_TEMP_DIR": dir.appending(path: "temp").path,
                   "DEVELOPMENT_TEAM": "ZZZZZZZZZZ"]
        try FileManager.default.createDirectory(atPath: env["TARGET_TEMP_DIR"]!, withIntermediateDirectories: true)
        if allowUnsigned { env["ALLOW_UNSIGNED_DMG"] = "YES" }
        return env
    }

    @Test("R10: with no Developer ID identity create-dmg.sh refuses, unless an unsigned image is explicitly allowed")
    func unsignedOnlyWhenAllowed() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = repoRoot.appending(path: "scripts/create-dmg.sh").path

        let refused = try run([script], environment: try createDmgEnvironment(dir, allowUnsigned: false))
        #expect(refused.status != 0)
        #expect(refused.output.contains("No \"Developer ID Application\" identity"))
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "project/build/Fake-9.9.9.dmg").path))

        let allowed = try run([script], environment: try createDmgEnvironment(dir, allowUnsigned: true))
        #expect(allowed.status == 0, "\(allowed.output)")
        #expect(allowed.output.contains("UNSIGNED"))
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "project/build/Fake-9.9.9.dmg").path))
    }
}
