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

/// The Stream Deck plugin's version (issue #64): docs/versioning-spec.md V17 to V19.
struct PluginVersionOutputTests {

    /// A repo whose `streamdeck/` holds a manifest and one source file, committed and tagged.
    private func makePluginRepo(tags: [String] = ["v1.4.7"]) throws -> URL {
        let repo = try makeRepo(tags: [])
        try writePlugin(source: "one", version: "0.1.0.0", in: repo)
        try git(["add", "."], in: repo)
        try git(["commit", "-q", "-m", "plugin"], in: repo)
        for tag in tags { try git(["tag", tag], in: repo) }
        return repo
    }

    private func ledger(_ lines: [String]) throws -> URL {
        let file = FileManager.default.temporaryDirectory.appending(path: "plugin-ledger-\(UUID().uuidString).txt")
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    @Test("V18: with no ledger the plugin is new, so it gets the build's X.Y.Z with 4th number 0")
    func noLedgerMeansNew() throws {
        let repo = try makePluginRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let run = try compute(in: repo)
        #expect(run.values["plugin_version"] == "1.4.8.0", "\(run.error)")
        #expect(run.values["plugin_hash"]?.count == 64)
    }

    @Test("V18: a plugin whose hash is in the ledger keeps its version, on any channel and after other commits")
    func knownHashKeepsItsVersion() throws {
        let repo = try makePluginRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let hash = try #require(try compute(in: repo).values["plugin_hash"])
        let file = try ledger(["\(hash) 0.9.9.7"])
        defer { try? FileManager.default.removeItem(at: file) }
        let extra = ["PLUGIN_LEDGER": file.path]

        #expect(try compute(in: repo, extra: extra).values["plugin_version"] == "0.9.9.7")
        // Non-plugin commits and the other channels change neither the hash nor the answer.
        try git(["commit", "-q", "--allow-empty", "-m", "app only"], in: repo)
        #expect(try compute(in: repo, kind: "nightly", extra: extra).values["plugin_version"] == "0.9.9.7")
        #expect(try compute(in: repo, kind: "prerelease", extra: extra).values["plugin_version"] == "0.9.9.7")
    }

    @Test("V19: a new plugin gets one more than the highest 4th number the ledger has for this X.Y.Z")
    func newHashGetsNextNumber() throws {
        let repo = try makePluginRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let file = try ledger(["aaa 1.4.8.2", "bbb 1.4.8.9", "ccc 1.4.7.40", "ddd 1.4.80.5"])
        defer { try? FileManager.default.removeItem(at: file) }
        let run = try compute(in: repo, extra: ["PLUGIN_LEDGER": file.path])
        #expect(run.values["plugin_version"] == "1.4.8.10", "\(run.error)")
    }

    @Test("V19: a missing or empty ledger file is no history, not an error")
    func missingLedgerIsFine() throws {
        let repo = try makePluginRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let missing = try compute(in: repo, extra: ["PLUGIN_LEDGER": "/nonexistent/ledger.txt"])
        #expect(missing.values["plugin_version"] == "1.4.8.0", "\(missing.error)")
        let empty = try ledger([])
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(try compute(in: repo, extra: ["PLUGIN_LEDGER": empty.path]).values["plugin_version"] == "1.4.8.0")
    }

    @Test("V17: the plugin hash changes with plugin code, not with the manifest version or editor files")
    func hashIgnoresVersionAndEditorFiles() throws {
        let repo = try makePluginRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let base = try hash(in: repo)

        // Only the manifest's version number: same hash.
        try writePlugin(source: "one", version: "7.7.7.7", in: repo)
        try git(["commit", "-qam", "version only"], in: repo)
        #expect(try hash(in: repo) == base)

        // Editor files (.idea, .vscode) aren't plugin code: same hash.
        try write("x", to: "streamdeck/.idea/misc.xml", in: repo)
        try write("x", to: "streamdeck/.vscode/launch.json", in: repo)
        try git(["add", "."], in: repo)
        try git(["commit", "-qm", "editor files"], in: repo)
        #expect(try hash(in: repo) == base)

        // Source change: different hash. Another manifest change (not the version line): different too.
        try writePlugin(source: "two", version: "7.7.7.7", in: repo)
        try git(["commit", "-qam", "source"], in: repo)
        let changed = try hash(in: repo)
        #expect(changed != base)
        try writePlugin(source: "two", version: "7.7.7.7", name: "Renamed", in: repo)
        try git(["commit", "-qam", "manifest name"], in: repo)
        #expect(try hash(in: repo) != changed)
    }

    @Test("V17: the hash reads what is committed, not the working copy, so stamping the manifest can't change it")
    func hashReadsHead() throws {
        let repo = try makePluginRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let base = try hash(in: repo)
        try writePlugin(source: "uncommitted change", version: "9.9.9.9", in: repo)
        #expect(try hash(in: repo) == base)
    }

    // MARK: - helpers

    private func hash(in repo: URL) throws -> String {
        let hashScript = URL(fileURLWithPath: scriptPath).deletingLastPathComponent().appending(path: "plugin-hash.sh").path
        let run = try process("/bin/sh", [hashScript], in: repo)
        #expect(run.status == 0, "\(run.error)")
        return run.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func write(_ text: String, to path: String, in repo: URL) throws {
        let url = repo.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// The same shape as the real manifest: the top-level Version has one tab of indent, the nested runtime's two.
    private func writePlugin(source: String, version: String, name: String = "Plugin", in repo: URL) throws {
        try write(source, to: "streamdeck/src/plugin.ts", in: repo)
        try write("{\n\t\"Name\": \"\(name)\",\n\t\"Version\": \"\(version)\",\n\t\"Nodejs\": {\n\t\t\"Version\": \"20\"\n\t}\n}\n",
                  to: "streamdeck/com.example.sdPlugin/manifest.json", in: repo)
    }
}

/// Where the changelog of a build starts: docs/versioning-spec.md V21 and V22.
struct NotesStartTagTests {

    private func repo(tags: [String]) throws -> URL {
        let dir = try makeRepo(tags: [])
        // One commit per tag, in the given order, so tag dates differ and rise.
        for (index, tag) in tags.enumerated() {
            try git(["commit", "-q", "--allow-empty", "-m", "c\(index)", "--date", "2026-01-\(10 + index)T00:00:00"], in: dir)
            try git(["tag", tag], in: dir)
        }
        return dir
    }

    private func released(_ tags: [String]) throws -> URL {
        let file = FileManager.default.temporaryDirectory.appending(path: "released-\(UUID().uuidString).txt")
        try (tags.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private func start(_ repo: URL, kind: String, released: URL? = nil) throws -> String? {
        var extra: [String: String] = [:]
        if let released { extra["RELEASED_TAGS"] = released.path }
        let run = try compute(in: repo, kind: kind, bump: "minor", extra: extra)
        #expect(run.status == 0, "\(run.error)")
        return run.values["notes_start_tag"]
    }

    @Test("V21: a nightly starts at the newest nightly tag by timestamp; a pre-release at the newest pre-release of any label")
    func sameKindIsPrevious() throws {
        let dir = try repo(tags: ["v0.1.2", "nightly-0.1.3-20261125030000.aaaaaaa", "v0.2.0-beta.1",
                                  "nightly-0.1.3-20261126030000.bbbbbbb", "v0.2.0-rc.1", "nightly-0.1.3-20261124030000.ccccccc"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let list = try released(["v0.1.2"])
        defer { try? FileManager.default.removeItem(at: list) }
        #expect(try start(dir, kind: "nightly", released: list) == "nightly-0.1.3-20261126030000.bbbbbbb")
        #expect(try start(dir, kind: "prerelease", released: list) == "v0.2.0-rc.1")
    }

    @Test("V21: a release starts at the latest published release, so a marker tag without a Release doesn't count")
    func releaseSkipsTagsWithoutARelease() throws {
        let dir = try repo(tags: ["0.1.2", "v0.2.0", "v0.3.0-beta.1"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let list = try released(["0.1.0", "0.1.2", "v0.3.0-beta.1"])
        defer { try? FileManager.default.removeItem(at: list) }
        #expect(try start(dir, kind: "release", released: list) == "0.1.2")
        // Without the list the latest tag is used (the marker included).
        #expect(try start(dir, kind: "release") == "v0.2.0")
    }

    @Test("V22: with no earlier build of the kind the changelog starts at the latest release; with no release at all it is empty")
    func fallbacks() throws {
        let dir = try repo(tags: ["0.1.2", "v0.2.0"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let list = try released(["0.1.2"])
        defer { try? FileManager.default.removeItem(at: list) }
        #expect(try start(dir, kind: "nightly", released: list) == "0.1.2")
        #expect(try start(dir, kind: "prerelease", released: list) == "0.1.2")

        let bare = try repo(tags: [])
        defer { try? FileManager.default.removeItem(at: bare) }
        #expect(try start(bare, kind: "nightly") == "")
    }
}
