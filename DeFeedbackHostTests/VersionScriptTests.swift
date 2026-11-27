//
//  VersionScriptTests.swift
//  DeFeedbackHostTests
//
//  Covers docs/versioning-spec.md rules V1–V10. Each test builds a throwaway git repository with
//  chosen tags and runs the real scripts/compute-version.sh in it, with a fixed timestamp.
//
//  - Tests initially created with AI with human edits, but all reviewed by human

import Foundation
import Testing

@testable import DeFeedbackHost

private let scriptPath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "scripts/compute-version.sh").path

private struct Run {
    let status: Int32
    let output: String
    let error: String

    /// The key=value lines of a successful run.
    var values: [String: String] {
        Dictionary(uniqueKeysWithValues: output.split(separator: "\n").compactMap { line in
            guard let eq = line.firstIndex(of: "=") else { return nil }
            return (String(line[..<eq]), String(line[line.index(after: eq)...]))
        })
    }
}

private func process(_ executable: String, _ arguments: [String], in directory: URL,
                     environment: [String: String] = [:]) throws -> Run {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = directory
    // Clean environment: a developer's own VERSION_* or git config must not leak in.
    process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                           "GIT_CONFIG_GLOBAL": "/dev/null",
                           "GIT_CONFIG_SYSTEM": "/dev/null"].merging(environment) { $1 }
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    try process.run()
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return Run(status: process.terminationStatus,
               output: String(decoding: outData, as: UTF8.self),
               error: String(decoding: errData, as: UTF8.self))
}

private func git(_ arguments: [String], in directory: URL) throws {
    let run = try process("/usr/bin/git", ["-c", "user.name=t", "-c", "user.email=t@example.com"] + arguments, in: directory)
    #expect(run.status == 0, "git \(arguments) failed: \(run.error)")
}

/// A repo with one commit and the given tags.
private func makeRepo(tags: [String]) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "VersionScriptTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try git(["init", "-q"], in: dir)
    try git(["commit", "-q", "--allow-empty", "-m", "first"], in: dir)
    for tag in tags { try git(["tag", tag], in: dir) }
    return dir
}

private let fixedStamp = "20261125030000"

private func compute(in repo: URL, kind: String? = nil, bump: String? = nil,
                     extra: [String: String] = [:], arguments: [String] = []) throws -> Run {
    var env = ["VERSION_TIMESTAMP": fixedStamp, "VERSION_SHA": "ab12cd3"]
    if let kind { env["VERSION_KIND"] = kind }
    if let bump { env["VERSION_BUMP"] = bump }
    return try process("/bin/sh", [scriptPath] + arguments, in: repo, environment: env.merging(extra) { $1 })
}

struct VersionScriptTests {

    @Test("V1: the highest tag wins by number, not by text")
    func latestTagIsNumeric() throws {
        let repo = try makeRepo(tags: ["v0.9.0", "v0.10.0", "v0.2.5"])
        defer { try? FileManager.default.removeItem(at: repo) }
        let run = try compute(in: repo)
        #expect(run.status == 0, "\(run.error)")
        #expect(run.values["base_tag"] == "v0.10.0")
        #expect(run.values["marketing_version"] == "0.10.1")
    }

    @Test("V2: bare and v-prefixed tags both count; new tags use the v")
    func bareAndPrefixedTags() throws {
        let repo = try makeRepo(tags: ["0.1.0", "0.1.1", "0.1.2"])
        defer { try? FileManager.default.removeItem(at: repo) }
        var run = try compute(in: repo)
        #expect(run.values["base_tag"] == "0.1.2")
        #expect(run.values["marketing_version"] == "0.1.3")
        #expect(run.values["tag"] == "v0.1.3")

        try git(["tag", "v0.1.3"], in: repo)
        run = try compute(in: repo)
        #expect(run.values["base_tag"] == "v0.1.3")
        #expect(run.values["marketing_version"] == "0.1.4")
    }

    @Test("V3: release bumps patch by default; minor and major reset the lower parts")
    func releaseBumps() throws {
        let repo = try makeRepo(tags: ["v1.4.7"])
        defer { try? FileManager.default.removeItem(at: repo) }
        #expect(try compute(in: repo).values["marketing_version"] == "1.4.8")
        #expect(try compute(in: repo, bump: "patch").values["marketing_version"] == "1.4.8")
        #expect(try compute(in: repo, bump: "minor").values["marketing_version"] == "1.5.0")
        #expect(try compute(in: repo, bump: "major").values["marketing_version"] == "2.0.0")
        let release = try compute(in: repo, kind: "release").values
        #expect(release["full_version"] == "1.4.8")
        #expect(release["channel"] == "release")
    }

    @Test("V4: a nightly is the latest with patch + 1 plus a timestamp and hash")
    func nightlyVersion() throws {
        let repo = try makeRepo(tags: ["v1.0.0"])
        defer { try? FileManager.default.removeItem(at: repo) }
        let run = try compute(in: repo, kind: "nightly", bump: "major")   // bump is ignored for nightlies
        #expect(run.status == 0, "\(run.error)")
        #expect(run.values["marketing_version"] == "1.0.1")
        #expect(run.values["full_version"] == "1.0.1-20261125030000.ab12cd3")
        #expect(run.values["tag"] == "nightly-1.0.1-20261125030000.ab12cd3")
        #expect(run.values["channel"] == "nightly")
    }

    @Test("V5: nightly and pre-release tags never count as the latest version")
    func nightlyAndPrereleaseTagsIgnored() throws {
        let repo = try makeRepo(tags: ["v1.0.0", "nightly-1.0.1-20261101000000.aaaaaaa", "v1.1.0-beta.1", "v2.0", "latest"])
        defer { try? FileManager.default.removeItem(at: repo) }
        let run = try compute(in: repo)
        #expect(run.values["base_tag"] == "v1.0.0")
        #expect(run.values["marketing_version"] == "1.0.1")
    }

    @Test("V6: with no tags a release is 1.0.0 and a nightly is 1.0.1-…")
    func noTags() throws {
        let repo = try makeRepo(tags: [])
        defer { try? FileManager.default.removeItem(at: repo) }
        let release = try compute(in: repo)
        #expect(release.values["marketing_version"] == "1.0.0")
        #expect(release.values["tag"] == "v1.0.0")
        #expect(release.values["base_tag"] == "")
        #expect(try compute(in: repo, kind: "nightly").values["full_version"] == "1.0.1-20261125030000.ab12cd3")
    }

    @Test("V7: outputs are plain, well formed and ordered by the build number")
    func outputShapes() throws {
        let repo = try makeRepo(tags: ["v3.2.1"])
        defer { try? FileManager.default.removeItem(at: repo) }
        for kind in ["release", "nightly"] {
            let values = try compute(in: repo, kind: kind).values
            let marketing = try #require(values["marketing_version"])
            #expect(marketing.split(separator: ".").count == 3 && marketing.allSatisfy { $0.isNumber || $0 == "." },
                    "marketing version must be plain X.Y.Z, got \(marketing)")
            let build = try #require(values["build_number"])
            #expect(build == fixedStamp && build.allSatisfy(\.isNumber))
        }
        // The default stamp is the current UTC time: 14 digits.
        let live = try process("/bin/sh", [scriptPath], in: repo).values
        #expect(live["build_number"]?.count == 14)
        #expect(live["build_number"]?.allSatisfy(\.isNumber) == true)
    }

    @Test("V8: an unknown kind, bump or timestamp fails with a message")
    func badInputs() throws {
        let repo = try makeRepo(tags: ["v1.0.0"])
        defer { try? FileManager.default.removeItem(at: repo) }
        for (run, text) in [(try compute(in: repo, kind: "weekly"), "VERSION_KIND"),
                            (try compute(in: repo, bump: "huge"), "VERSION_BUMP"),
                            (try compute(in: repo, extra: ["VERSION_TIMESTAMP": "2026-11-25"]), "VERSION_TIMESTAMP")] {
            #expect(run.status != 0)
            #expect(run.error.contains(text), "\(run.error)")
            #expect(run.output.isEmpty)
        }
    }

    @Test("V9: a shallow clone with no tags fails instead of quietly returning 1.0.0")
    func shallowCloneWithoutTagsFails() throws {
        let source = try makeRepo(tags: [])
        defer { try? FileManager.default.removeItem(at: source) }
        let clone = FileManager.default.temporaryDirectory.appending(path: "VersionScriptTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: clone) }
        let cloned = try process("/usr/bin/git", ["clone", "-q", "--depth", "1", "file://\(source.path)", clone.path],
                                 in: FileManager.default.temporaryDirectory)
        #expect(cloned.status == 0, "\(cloned.error)")

        let run = try compute(in: clone)
        #expect(run.status != 0)
        #expect(run.error.contains("shallow"))
        #expect(run.error.contains("fetch-depth: 0"))
    }

    @Test("V10: --github-output appends the same keys to $GITHUB_OUTPUT")
    func githubOutput() throws {
        let repo = try makeRepo(tags: ["v1.0.0"])
        defer { try? FileManager.default.removeItem(at: repo) }
        let file = repo.appending(path: "github-output.txt")
        try "existing=1\n".write(to: file, atomically: true, encoding: .utf8)

        let run = try compute(in: repo, extra: ["GITHUB_OUTPUT": file.path], arguments: ["--github-output"])
        #expect(run.status == 0, "\(run.error)")
        let written = try String(contentsOf: file, encoding: .utf8)
        #expect(written.hasPrefix("existing=1\n"), "must append, not overwrite")
        for (key, value) in run.values {
            #expect(written.contains("\(key)=\(value)\n"), "missing \(key) in $GITHUB_OUTPUT")
        }

        let missing = try compute(in: repo, arguments: ["--github-output"])
        #expect(missing.status != 0)
        #expect(missing.error.contains("GITHUB_OUTPUT"))
    }

    // MARK: pre-releases (docs/prerelease-spec.md PRE2, PRE3, PRE4, PRE6)

    private func prerelease(_ repo: URL, bump: String? = nil, label: String? = nil) throws -> Run {
        var extra: [String: String] = [:]
        if let label { extra["VERSION_LABEL"] = label }
        return try compute(in: repo, kind: "prerelease", bump: bump, extra: extra)
    }

    @Test("PRE2: the first pre-release leads to the next release and is numbered 1")
    func firstPrerelease() throws {
        let repo = try makeRepo(tags: ["v0.1.2"])
        defer { try? FileManager.default.removeItem(at: repo) }
        let run = try prerelease(repo, bump: "minor")
        #expect(run.status == 0, "\(run.error)")
        #expect(run.values["marketing_version"] == "0.2.0", "the app's own version stays plain X.Y.Z")
        #expect(run.values["full_version"] == "0.2.0-beta.1")
        #expect(run.values["tag"] == "v0.2.0-beta.1")
        #expect(run.values["channel"] == "prerelease")
        #expect(run.values["build_number"] == fixedStamp)
        #expect(run.values["base_tag"] == "v0.1.2")
    }

    @Test("PRE2: numbering counts up for the same release and label, and restarts for another")
    func prereleaseNumbering() throws {
        let repo = try makeRepo(tags: ["v0.1.2", "v0.2.0-beta.1", "v0.2.0-beta.2", "v0.2.0-rc.1", "v0.3.0-beta.7"])
        defer { try? FileManager.default.removeItem(at: repo) }
        #expect(try prerelease(repo, bump: "minor").values["full_version"] == "0.2.0-beta.3")
        #expect(try prerelease(repo, bump: "minor", label: "rc").values["full_version"] == "0.2.0-rc.2")
        #expect(try prerelease(repo, bump: "minor", label: "alpha").values["full_version"] == "0.2.0-alpha.1")
        #expect(try prerelease(repo, bump: "patch").values["full_version"] == "0.1.3-beta.1", "another release restarts at 1")
        #expect(try prerelease(repo, bump: "major").values["full_version"] == "1.0.0-beta.1")
        // Numbers compare as numbers, not as text: beta.10 follows beta.9.
        try git(["tag", "v0.2.0-beta.9"], in: repo)
        #expect(try prerelease(repo, bump: "minor").values["full_version"] == "0.2.0-beta.10")
    }

    @Test("PRE4: pre-release and nightly tags never count as the latest release")
    func prereleaseTagsDontMoveTheRelease() throws {
        let repo = try makeRepo(tags: ["v0.1.2", "v0.9.0-beta.1", "nightly-0.1.3-20261101030000.abc1234"])
        defer { try? FileManager.default.removeItem(at: repo) }
        let run = try prerelease(repo, bump: "minor")
        #expect(run.values["base_tag"] == "v0.1.2")
        #expect(run.values["full_version"] == "0.2.0-beta.1")
        // And an ordinary release is unaffected by the beta tags.
        #expect(try compute(in: repo).values["full_version"] == "0.1.3")
    }

    @Test("PRE6: the label must be lowercase letters only")
    func prereleaseLabelIsValidated() throws {
        let repo = try makeRepo(tags: ["v0.1.2"])
        defer { try? FileManager.default.removeItem(at: repo) }
        for label in ["Beta", "be-ta", "beta2", "b eta", "BETA"] {
            let run = try prerelease(repo, label: label)
            #expect(run.status != 0, "label '\(label)' should be refused")
            #expect(run.error.contains("VERSION_LABEL"), "\(run.error)")
            #expect(run.output.isEmpty)
        }
        #expect(try prerelease(repo, label: "rc").status == 0)
    }

    @Test("PRE2: with no tags a pre-release leads to 1.0.0")
    func prereleaseWithNoTags() throws {
        let repo = try makeRepo(tags: [])
        defer { try? FileManager.default.removeItem(at: repo) }
        #expect(try prerelease(repo).values["full_version"] == "1.0.0-beta.1")
    }
}

/// The Stream Deck plugin's version (issue #64): docs/versioning-spec.md V14.
struct PluginVersionOutputTests {

    @Test("V14: plugin_version is the marketing version plus the commit count, and rises with every commit")
    func pluginVersionRisesWithCommits() throws {
        let repo = try makeRepo(tags: ["v1.4.7"])
        defer { try? FileManager.default.removeItem(at: repo) }
        #expect(try compute(in: repo).values["plugin_version"] == "1.4.8.1")

        try git(["commit", "-q", "--allow-empty", "-m", "second"], in: repo)
        #expect(try compute(in: repo).values["plugin_version"] == "1.4.8.2")
        // A nightly shares the release's X.Y.Z, so only the commit count tells them apart.
        #expect(try compute(in: repo, kind: "nightly").values["plugin_version"] == "1.4.8.2")
        #expect(try compute(in: repo, kind: "prerelease").values["plugin_version"] == "1.4.8.2")
    }

    @Test("V14: VERSION_COMMIT_COUNT overrides the count; anything but digits is refused")
    func commitCountOverride() throws {
        let repo = try makeRepo(tags: ["v1.4.7"])
        defer { try? FileManager.default.removeItem(at: repo) }
        #expect(try compute(in: repo, extra: ["VERSION_COMMIT_COUNT": "77"]).values["plugin_version"] == "1.4.8.77")

        let bad = try compute(in: repo, extra: ["VERSION_COMMIT_COUNT": "7x"])
        #expect(bad.status != 0)
        #expect(bad.error.contains("VERSION_COMMIT_COUNT"), "\(bad.error)")
        #expect(bad.output.isEmpty)
    }

    @Test("V14: a shallow clone can't count commits, so it fails instead of stamping a wrong number")
    func shallowCloneFails() throws {
        let repo = try makeRepo(tags: [])
        defer { try? FileManager.default.removeItem(at: repo) }
        try git(["commit", "-q", "--allow-empty", "-m", "second"], in: repo)
        try git(["tag", "v1.0.0"], in: repo)
        let clone = FileManager.default.temporaryDirectory.appending(path: "VersionScriptTests-clone-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: clone) }
        try git(["clone", "-q", "--depth", "1", "file://\(repo.path)", clone.path], in: repo)

        let run = try compute(in: clone)
        #expect(run.status != 0)
        #expect(run.error.contains("shallow"), "\(run.error)")
        #expect(run.output.isEmpty)
        // With the count supplied there is nothing to get wrong.
        #expect(try compute(in: clone, extra: ["VERSION_COMMIT_COUNT": "5"]).values["plugin_version"] == "1.0.1.5")
    }
}
