//
//  NightlyScriptTests.swift
//  DeFeedbackHostTests
//
//  Covers docs/nightly-spec.md rules N1–N10: when a nightly is built, which nightlies are pruned,
//  what pruning does to the appcast, and the shape of the nightly workflow. Throwaway git
//  repositories and appcast files stand in for the real ones; nothing touches GitHub.
//
//  - Tests initially created with AI with human edits, but all reviewed by human

import Foundation
import Testing

@testable import DeFeedbackHost

private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()

private struct Run {
    let status: Int32
    let stdout: String
    let stderr: String
    var all: String { stdout + stderr }
    var values: [String: String] {
        Dictionary(uniqueKeysWithValues: stdout.split(separator: "\n").compactMap { line in
            guard let eq = line.firstIndex(of: "=") else { return nil }
            return (String(line[..<eq]), String(line[line.index(after: eq)...]))
        })
    }
}

private func run(_ executable: String, _ arguments: [String], environment: [String: String] = [:],
                 in directory: URL? = nil, input: String? = nil) throws -> Run {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let directory { process.currentDirectoryURL = directory }
    process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "GIT_CONFIG_GLOBAL": "/dev/null",
                           "GIT_CONFIG_SYSTEM": "/dev/null"].merging(environment) { $1 }
    let out = Pipe(), err = Pipe(), stdin = Pipe()
    process.standardOutput = out
    process.standardError = err
    process.standardInput = stdin
    try process.run()
    if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
    try? stdin.fileHandleForWriting.close()
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return Run(status: process.terminationStatus,
               stdout: String(decoding: outData, as: UTF8.self),
               stderr: String(decoding: errData, as: UTF8.self))
}

private func scratch() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "NightlyScriptTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func script(_ name: String) -> String { repoRoot.appending(path: "scripts/ci/\(name)").path }

private func git(_ arguments: [String], in dir: URL) throws {
    let result = try run("/usr/bin/git", ["-c", "user.name=t", "-c", "user.email=t@example.com"] + arguments, in: dir)
    #expect(result.status == 0, "git \(arguments) failed: \(result.stderr)")
}

private func commit(_ message: String, in dir: URL) throws {
    try git(["commit", "-q", "--allow-empty", "-m", message], in: dir)
}

private func makeRepo() throws -> URL {
    let dir = try scratch()
    try git(["init", "-q"], in: dir)
    try commit("first", in: dir)
    return dir
}

private func decide(in dir: URL, force: Bool = false, arguments: [String] = [],
                    extra: [String: String] = [:]) throws -> Run {
    var env = extra
    if force { env["FORCE"] = "true" }
    return try run("/bin/sh", [script("should-build-nightly.sh")] + arguments, environment: env, in: dir)
}

struct NightlyScriptTests {

    // MARK: N2 / N3: when to build

    @Test("N2: the very first nightly is built when there is no earlier nightly or release")
    func firstNightlyBuilds() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let result = try decide(in: repo)
        #expect(result.status == 0, "\(result.all)")
        #expect(result.values["build"] == "true")
        #expect(result.values["reason"] == "no earlier nightly or release")
    }

    @Test("N2: skipped when main is still at the commit of the newest nightly")
    func sameCommitAsNightlySkips() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try git(["tag", "nightly-0.1.1-20261101030000.aaaaaaa"], in: repo)
        try commit("newer", in: repo)
        try git(["tag", "nightly-0.1.1-20261102030000.bbbbbbb"], in: repo)    // the NEWEST nightly, at HEAD

        let result = try decide(in: repo)
        #expect(result.values["build"] == "false", "\(result.all)")
        #expect(result.values["reason"] == "main has not changed since nightly-0.1.1-20261102030000.bbbbbbb")
    }

    @Test("N2: skipped when main is at the newest release, even with older nightlies")
    func sameCommitAsReleaseSkips() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try git(["tag", "nightly-0.1.1-20261101030000.aaaaaaa"], in: repo)
        try commit("release commit", in: repo)
        try git(["tag", "v0.2.0"], in: repo)
        try git(["tag", "0.1.9"], in: repo)         // an older bare tag must not win

        let result = try decide(in: repo)
        #expect(result.values["build"] == "false", "\(result.all)")
        #expect(result.values["reason"] == "main is at release v0.2.0")
    }

    @Test("N2: built when main has new commits since the last nightly and release")
    func newCommitsBuild() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try git(["tag", "v0.2.0"], in: repo)
        try git(["tag", "nightly-0.2.1-20261101030000.aaaaaaa"], in: repo)
        try commit("a new change", in: repo)
        let result = try decide(in: repo)
        #expect(result.values["build"] == "true", "\(result.all)")
        #expect(result.values["reason"] == "main has new commits since the last nightly or release")
    }

    @Test("N3: force builds even when nothing changed")
    func forceBuilds() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try git(["tag", "nightly-0.1.1-20261101030000.aaaaaaa"], in: repo)
        #expect(try decide(in: repo).values["build"] == "false")
        let forced = try decide(in: repo, force: true)
        #expect(forced.values["build"] == "true")
        #expect(forced.values["reason"] == "forced")
    }

    @Test("N2: a shallow clone without tags fails instead of guessing")
    func shallowCloneFails() throws {
        let source = try makeRepo()
        defer { try? FileManager.default.removeItem(at: source) }
        let clone = FileManager.default.temporaryDirectory.appending(path: "NightlyScriptTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: clone) }
        let cloned = try run("/usr/bin/git", ["clone", "-q", "--depth", "1", "file://\(source.path)", clone.path],
                             in: FileManager.default.temporaryDirectory)
        #expect(cloned.status == 0, "\(cloned.stderr)")
        let result = try decide(in: clone)
        #expect(result.status != 0)
        #expect(result.stderr.contains("shallow") && result.stderr.contains("fetch-depth: 0"))
    }

    @Test("N2: --github-output appends the decision to $GITHUB_OUTPUT")
    func decisionGoesToGithubOutput() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let file = repo.appending(path: "out.txt")
        try "existing=1\n".write(to: file, atomically: true, encoding: .utf8)
        let result = try decide(in: repo, arguments: ["--github-output"], extra: ["GITHUB_OUTPUT": file.path])
        #expect(result.status == 0, "\(result.all)")
        let written = try String(contentsOf: file, encoding: .utf8)
        #expect(written.hasPrefix("existing=1\n") && written.contains("build=true\n") && written.contains("reason="))
        #expect(try decide(in: repo, arguments: ["--github-output"]).status != 0, "needs GITHUB_OUTPUT")
    }

    // MARK: N7 / N8: pruning

    private func select(_ lines: [String], keep: String) throws -> Run {
        try run("/bin/sh", [script("prune-builds.sh"), "select", "--kind", "nightly", "--keep", keep], input: lines.joined(separator: "\n") + "\n")
    }

    @Test("N7: only the newest N nightlies are kept; the rest are listed, newest of them first")
    func selectKeepsTheNewest() throws {
        let lines = (1...9).map { "nightly-0.1.1-2026110\($0)030000.abc\t2026-11-0\($0)T03:00:00Z" }
        let result = try select(lines, keep: "7")
        #expect(result.status == 0, "\(result.all)")
        #expect(result.stdout.split(separator: "\n").map(String.init)
                == ["nightly-0.1.1-20261102030000.abc", "nightly-0.1.1-20261101030000.abc"], "\(result.stdout)")
        #expect(try select(Array(lines.prefix(7)), keep: "7").stdout.isEmpty, "exactly N: nothing to prune")
    }

    @Test("N8: select never names a release, a pre-release or any non-nightly tag")
    func selectIgnoresOtherTags() throws {
        let lines = ["v1.0.0\t2026-01-01T00:00:00Z", "v1.1.0-beta.1\t2026-01-02T00:00:00Z", "0.1.2\t2026-01-03T00:00:00Z",
                     "nightly-0.1.1-20261101030000.abc\t2026-11-01T03:00:00Z",
                     "nightly-0.1.1-20261102030000.abc\t2026-11-02T03:00:00Z"]
        let result = try select(lines, keep: "1")
        #expect(result.stdout == "nightly-0.1.1-20261101030000.abc\n", "\(result.stdout)")
    }

    @Test("N7: keep must be a whole number of 1 or more")
    func selectRefusesBadKeep() throws {
        for keep in ["0", "-1", "many", ""] {
            let result = try select(["nightly-0.1.1-20261101030000.abc\t2026-11-01T03:00:00Z"], keep: keep)
            #expect(result.status != 0, "keep=\(keep) should be refused")
        }
    }

    private func item(version: String, tag: String, channel: String?) -> String {
        let channelLine = channel.map { "      <sparkle:channel>\($0)</sparkle:channel>\n" } ?? ""
        return """
            \u{20}   <item>
                  <title>Version \(version)</title>
            \(channelLine)      <sparkle:version>1</sparkle:version>
                  <enclosure url="https://github.com/o/r/releases/download/\(tag)/App-\(version).dmg" length="1" type="application/octet-stream" sparkle:edSignature="sig"/>
                </item>

            """
    }

    private func appcast(_ items: [String]) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel>
            <title>Test</title>
        \(items.joined())  </channel>
        </rss>

        """
    }

    @Test("N7: feed removes exactly the named nightly items and keeps the XML well formed")
    func feedRemovesNamedNightlies() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "appcast.xml")
        let keepers = [item(version: "0.2.0", tag: "v0.2.0", channel: nil),
                       item(version: "0.1.5-beta.1", tag: "v0.1.5-beta.1", channel: "prerelease"),
                       item(version: "0.1.2-20261103030000.ccc", tag: "nightly-0.1.2-20261103030000.ccc", channel: "nightly")]
        let doomed = [item(version: "0.1.2-20261101030000.aaa", tag: "nightly-0.1.2-20261101030000.aaa", channel: "nightly"),
                      item(version: "0.1.2-20261102030000.bbb", tag: "nightly-0.1.2-20261102030000.bbb", channel: "nightly")]
        try appcast(keepers + doomed).write(to: file, atomically: true, encoding: .utf8)

        let result = try run("/bin/sh", [script("prune-builds.sh"), "feed", "--kind", "nightly", file.path,
                                         "nightly-0.1.2-20261101030000.aaa", "nightly-0.1.2-20261102030000.bbb"])
        #expect(result.status == 0, "\(result.all)")
        #expect(result.stdout.contains("removed 2 item(s)"))
        let after = try String(contentsOf: file, encoding: .utf8)
        #expect(after == appcast(keepers), "only the doomed nightlies may disappear, byte for byte:\n\(after)")
        let lint = try run("/usr/bin/xmllint", ["--noout", file.path])
        #expect(lint.status == 0, "the feed must stay well formed: \(lint.all)")
    }

    @Test("N8: feed never removes a release or pre-release item, and leaves the file untouched when nothing matches")
    func feedProtectsReleases() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "appcast.xml")
        let original = appcast([item(version: "0.2.0", tag: "v0.2.0", channel: nil),
                                item(version: "0.1.2-20261101030000.aaa", tag: "nightly-0.1.2-20261101030000.aaa", channel: "nightly")])
        try original.write(to: file, atomically: true, encoding: .utf8)

        // Naming a release tag is refused outright.
        let refused = try run("/bin/sh", [script("prune-builds.sh"), "feed", "--kind", "nightly", file.path, "v0.2.0"])
        #expect(refused.status != 0)
        #expect(refused.stderr.contains("only nightly tags may be pruned"))
        #expect(try String(contentsOf: file, encoding: .utf8) == original)

        // A nightly tag that is not in the feed changes nothing at all.
        let missing = try run("/bin/sh", [script("prune-builds.sh"), "feed", "--kind", "nightly", file.path, "nightly-9.9.9-20990101000000.zzz"])
        #expect(missing.status == 0)
        #expect(missing.stdout.contains("removed 0 item(s)"))
        #expect(try String(contentsOf: file, encoding: .utf8) == original, "byte-identical when nothing matches")

        // A nightly-tagged URL on an item that is NOT on the nightly channel is also protected.
        let odd = appcast([item(version: "0.3.0", tag: "nightly-0.3.0-20261105030000.ddd", channel: nil)])
        try odd.write(to: file, atomically: true, encoding: .utf8)
        let kept = try run("/bin/sh", [script("prune-builds.sh"), "feed", "--kind", "nightly", file.path, "nightly-0.3.0-20261105030000.ddd"])
        #expect(kept.stdout.contains("removed 0 item(s)"))
        #expect(try String(contentsOf: file, encoding: .utf8) == odd)
    }

    // MARK: N4 / N5 / N6: version, notes, file name (through the real scripts)

    @Test("N4: a nightly gets the next patch, a stamp and a hash, on the nightly channel")
    func nightlyVersionShape() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try git(["tag", "v0.2.0"], in: repo)
        let result = try run("/bin/sh", [repoRoot.appending(path: "scripts/compute-version.sh").path],
                             environment: ["VERSION_KIND": "nightly", "VERSION_TIMESTAMP": "20261125030000", "VERSION_SHA": "ab12cd3"],
                             in: repo)
        #expect(result.status == 0, "\(result.all)")
        #expect(result.values["marketing_version"] == "0.2.1")
        #expect(result.values["full_version"] == "0.2.1-20261125030000.ab12cd3")
        #expect(result.values["tag"] == "nightly-0.2.1-20261125030000.ab12cd3")
        #expect(result.values["channel"] == "nightly")
        #expect(result.values["build_number"] == "20261125030000")
    }

    private func releaseCreateCall(channel: String, notes: String?) throws -> String {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bin = dir.appending(path: "bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let calls = dir.appending(path: "gh-calls.txt")
        func stub(_ name: String, _ body: String) throws {
            let url = bin.appending(path: name)
            try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try stub("sign_update", "echo FAKESIGNATURE==")
        try stub("gh", "echo \"$@\" >> \"\(calls.path)\"\n[ \"$2\" = view ] && exit 1\nexit 0")
        let dmg = dir.appending(path: "App.dmg")
        try Data("dmg".utf8).write(to: dmg)
        var env = ["SPARKLE_BIN": bin.path, "SPARKLE_ED_PRIVATE_KEY": "unused",
                   "PATH": "\(bin.path):/usr/bin:/bin:/usr/sbin:/sbin"]
        if let notes { env["RELEASE_NOTES"] = notes }
        let result = try run("/bin/sh", [repoRoot.appending(path: "scripts/publish-update.sh").path, "--dmg", dmg.path,
                                         "--version", "0.2.1-20261125030000.ab12cd3", "--build", "20261125030000",
                                         "--channel", channel, "--site-dir", dir.appending(path: "site").path, "--upload"],
                             environment: env)
        #expect(result.status == 0, "\(result.all)")
        let all = (try? String(contentsOf: calls, encoding: .utf8)) ?? ""
        return all.split(separator: "\n").first { $0.hasPrefix("release create") }.map(String.init) ?? ""
    }

    @Test("N5: a nightly release is a pre-release with the fixed note; a release still gets generated notes")
    func nightlyReleaseNotes() throws {
        let nightly = try releaseCreateCall(channel: "nightly", notes: "Automatic nightly build. Not a release.")
        #expect(nightly.contains("--prerelease") && nightly.contains("--latest=false"), "\(nightly)")
        #expect(nightly.contains("--notes Automatic nightly build. Not a release."))
        #expect(!nightly.contains("--generate-notes"))
        #expect(nightly.contains("nightly-0.2.1-20261125030000.ab12cd3"), "the tag is nightly-<full version>")

        let release = try releaseCreateCall(channel: "release", notes: nil)
        #expect(release.contains("--generate-notes") && !release.contains("--prerelease"), "\(release)")
    }

    @Test("N6: DMG_VERSION names the image with the full version; without it the marketing version is used")
    func dmgNamedWithTheFullVersion() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        func buildEnvironment(_ suffix: String, dmgVersion: String?) throws -> [String: String] {
            let root = dir.appending(path: suffix)
            let project = root.appending(path: "project")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: project.appending(path: "scripts").path,
                                                       withDestinationPath: repoRoot.appending(path: "scripts").path)
            let products = root.appending(path: "products")
            try FileManager.default.createDirectory(at: products.appending(path: "Fake.app/Contents"), withIntermediateDirectories: true)
            try "x".write(to: products.appending(path: "Fake.app/Contents/x"), atomically: true, encoding: .utf8)
            let temp = root.appending(path: "temp")
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            var env = ["PROJECT_DIR": project.path, "TARGET_BUILD_DIR": products.path, "FULL_PRODUCT_NAME": "Fake.app",
                       "PRODUCT_NAME": "Fake", "MARKETING_VERSION": "0.2.1", "TARGET_TEMP_DIR": temp.path,
                       "DEVELOPMENT_TEAM": "ZZZZZZZZZZ", "ALLOW_UNSIGNED_DMG": "YES"]
            if let dmgVersion { env["DMG_VERSION"] = dmgVersion }
            return env
        }
        let script = repoRoot.appending(path: "scripts/create-dmg.sh").path

        let named = try run("/bin/sh", [script], environment: try buildEnvironment("a", dmgVersion: "0.2.1-20261125030000.ab12cd3"))
        #expect(named.status == 0, "\(named.all)")
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "a/project/build/Fake-0.2.1-20261125030000.ab12cd3.dmg").path))

        let plain = try run("/bin/sh", [script], environment: try buildEnvironment("b", dmgVersion: nil))
        #expect(plain.status == 0, "\(plain.all)")
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "b/project/build/Fake-0.2.1.dmg").path))
    }

    // MARK: N1 / N7 / N9 / N10: the workflows

    private func text(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appending(path: path), encoding: .utf8)
    }

    @Test("N1: nightly runs daily at 03:00 UTC and by hand, never for a pull request, from main only")
    func nightlyTriggers() throws {
        let nightly = try text(".github/workflows/nightly.yml")
        let header = try #require(nightly.components(separatedBy: "\npermissions:").first)
        #expect(header.contains("cron: \"0 3 * * *\""))
        #expect(header.contains("workflow_dispatch:"))
        #expect(header.contains("force:") && header.contains("dry_run:") && header.contains("keep:"))
        #expect(!header.contains("pull_request") && !header.contains("\n  push:"))
        #expect(nightly.contains("refs/heads/main"), "the main-only guard is missing")
        #expect(nightly.contains("group: release") && nightly.contains("cancel-in-progress: false"),
                "nightlies and releases must never overlap")
    }

    @Test("N10: nightly and release use the same shared build, and neither caller reads a secret")
    func sharedBuild() throws {
        let nightly = try text(".github/workflows/nightly.yml")
        let release = try text(".github/workflows/release.yml")
        for caller in [nightly, release] {
            #expect(caller.contains("uses: ./.github/workflows/build-and-publish.yml"))
            #expect(!caller.contains("secrets."), "callers must not touch secrets; the shared build reads them")
        }
        #expect(nightly.contains("kind: nightly") && release.contains("kind: release"))
    }

    @Test("N10: both callers pass secrets through, or the shared build's environment secrets arrive empty")
    func callersInheritSecrets() throws {
        // Found by the first dry run through the shared build: the certificate secret was empty until
        // the callers passed `secrets: inherit`. Pinned so a refactor can't silently drop it.
        for path in [".github/workflows/release.yml", ".github/workflows/nightly.yml", ".github/workflows/prerelease.yml"] {
            let caller = try text(path)
            let build = try #require(caller.components(separatedBy: "uses: ./.github/workflows/build-and-publish.yml").last?
                .components(separatedBy: "\n  prune:\n").first)
            #expect(build.contains("secrets: inherit"), "\(path) must pass secrets to the shared build")
        }
    }

    @Test("N9: a dry run publishes and prunes nothing; prune has no signing secrets and runs only after a good build")
    func dryRunAndPruneRules() throws {
        let nightly = try text(".github/workflows/nightly.yml")
        #expect(nightly.contains("dry_run: ${{ inputs.dry_run || false }}"), "a dry run must reach the shared build")

        // nightly.yml only calls the shared prune workflow, after a good build, with no secrets.
        let prune = try #require(nightly.components(separatedBy: "\n  prune:\n").last)
        #expect(prune.contains("needs: build"))
        #expect(prune.contains("needs.build.result == 'success'"), "prune only after a successful build")
        #expect(prune.contains("uses: ./.github/workflows/prune-builds.yml"))
        #expect(prune.contains("kind: nightly"))
        #expect(prune.contains("dry_run: ${{ inputs.dry_run || false }}"), "a dry run must reach the prune")
        #expect(!prune.contains("secrets.") && !prune.contains("environment:"), "pruning must not see the signing secrets")

        // The shared prune workflow: everything that changes anything is skipped for a dry run.
        let shared = try text(".github/workflows/prune-builds.yml")
        #expect(!shared.contains("secrets.") && !shared.contains("environment:"))
        let steps = shared.components(separatedBy: "\n      - ").dropFirst()
        let changing = steps.filter {
            $0.contains("git push") || $0.contains("gh release delete") || $0.contains("ref: gh-pages")
        }
        #expect(changing.count == 3, "expected the checkout, appcast and delete steps, found \(changing.count)")
        for step in changing {
            #expect(step.contains("if: ${{ !inputs.dry_run }}"), "a changing step runs on a dry run: \(step.prefix(60))")
        }
    }

    @Test("N7: the feed is pushed before any release is deleted")
    func feedBeforeReleases() throws {
        let prune = try text(".github/workflows/prune-builds.yml")
        let feed = try #require(prune.range(of: "prune-builds.sh feed"))
        let push = try #require(prune.range(of: "git push origin HEAD:gh-pages"))
        let delete = try #require(prune.range(of: "gh release delete"))
        #expect(feed.lowerBound < push.lowerBound && push.lowerBound < delete.lowerBound,
                "the appcast must never point at a download that has been deleted")
        #expect(prune.contains("--cleanup-tag"), "the tag must go with the release")
    }
}
