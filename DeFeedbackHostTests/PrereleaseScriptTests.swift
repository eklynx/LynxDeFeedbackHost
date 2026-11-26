//
//  PrereleaseScriptTests.swift
//  DeFeedbackHostTests
//
//  Covers docs/prerelease-spec.md rules PRE1, PRE5, PRE7–PRE9. The version numbering rules (PRE2–PRE4,
//  PRE6) are in VersionScriptTests. Throwaway appcast files and stub tools stand in for GitHub.
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
}

private func run(_ arguments: [String], input: String? = nil, environment: [String: String] = [:]) throws -> Run {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = arguments
    process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"].merging(environment) { $1 }
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
    let url = FileManager.default.temporaryDirectory.appending(path: "PrereleaseScriptTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private let prune = repoRoot.appending(path: "scripts/ci/prune-builds.sh").path

private func text(_ path: String) throws -> String {
    try String(contentsOf: repoRoot.appending(path: path), encoding: .utf8)
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

struct PrereleaseScriptTests {

    private func select(_ lines: [String], kind: String, keep: String) throws -> Run {
        try run([prune, "select", "--kind", kind, "--keep", keep], input: lines.joined(separator: "\n") + "\n")
    }

    private var mixed: [String] {
        [
            "v1.0.0\t2026-01-01T00:00:00Z",                                       // a release
            "nightly-1.0.1-20261101030000.abc\t2026-11-01T03:00:00Z",             // nightlies
            "nightly-1.0.1-20261102030000.abc\t2026-11-02T03:00:00Z",
            "v1.1.0-beta.1\t2026-11-03T00:00:00Z",                                // pre-releases
            "v1.1.0-beta.2\t2026-11-04T00:00:00Z",
            "v1.1.0-rc.1\t2026-11-05T00:00:00Z",
            "v1.1.0-beta.3\t2026-11-06T00:00:00Z",
        ]
    }

    @Test("PRE7: only the newest N pre-releases are kept; the older ones are listed")
    func selectPrereleasesBeyondTheNewest() throws {
        let result = try select(mixed, kind: "prerelease", keep: "2")
        #expect(result.status == 0, "\(result.all)")
        #expect(result.stdout.split(separator: "\n").map(String.init) == ["v1.1.0-beta.2", "v1.1.0-beta.1"], "\(result.stdout)")
        #expect(try select(mixed, kind: "prerelease", keep: "10").stdout.isEmpty, "fewer than N: nothing to prune")
    }

    @Test("PRE8: selecting pre-releases never lists a release or a nightly, and the reverse")
    func selectKeepsKindsApart() throws {
        let prereleases = try select(mixed, kind: "prerelease", keep: "1").stdout
        #expect(!prereleases.contains("nightly-") && !prereleases.contains("v1.0.0\n"), "\(prereleases)")

        let nightlies = try select(mixed, kind: "nightly", keep: "1").stdout
        #expect(nightlies == "nightly-1.0.1-20261101030000.abc\n", "\(nightlies)")
        #expect(!nightlies.contains("beta"), "a nightly prune must not see pre-releases")
    }

    @Test("PRE7: a kind is required and keep must be 1 or more")
    func selectValidatesItsArguments() throws {
        #expect(try run([prune, "select", "--keep", "3"], input: "").status != 0, "--kind is required")
        #expect(try run([prune, "select", "--kind", "release", "--keep", "3"], input: "").status != 0, "only nightly or prerelease")
        for keep in ["0", "-2", "many", ""] {
            #expect(try select(mixed, kind: "prerelease", keep: keep).status != 0, "keep=\(keep) should be refused")
        }
    }

    @Test("PRE7: feed removes exactly the named pre-release items and keeps the XML well formed")
    func feedRemovesNamedPrereleases() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "appcast.xml")
        let keepers = [item(version: "1.0.0", tag: "v1.0.0", channel: nil),
                       item(version: "1.0.1-20261102030000.abc", tag: "nightly-1.0.1-20261102030000.abc", channel: "nightly"),
                       item(version: "1.1.0-beta.3", tag: "v1.1.0-beta.3", channel: "prerelease")]
        let doomed = [item(version: "1.1.0-beta.1", tag: "v1.1.0-beta.1", channel: "prerelease"),
                      item(version: "1.1.0-beta.2", tag: "v1.1.0-beta.2", channel: "prerelease")]
        try appcast(keepers + doomed).write(to: file, atomically: true, encoding: .utf8)

        let result = try run([prune, "feed", "--kind", "prerelease", file.path, "v1.1.0-beta.1", "v1.1.0-beta.2"])
        #expect(result.status == 0, "\(result.all)")
        #expect(result.stdout.contains("removed 2 item(s)"))
        #expect(try String(contentsOf: file, encoding: .utf8) == appcast(keepers), "only the doomed pre-releases may disappear")
        #expect(try run(["-c", "/usr/bin/xmllint --noout '\(file.path)'"]).status == 0, "the feed must stay well formed")
    }

    @Test("PRE8: feed refuses a release or nightly tag for a pre-release prune, and protects items on other channels")
    func feedProtectsEverythingElse() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "appcast.xml")
        let original = appcast([item(version: "1.0.0", tag: "v1.0.0", channel: nil),
                                item(version: "1.0.1-20261102030000.abc", tag: "nightly-1.0.1-20261102030000.abc", channel: "nightly"),
                                item(version: "1.1.0-beta.1", tag: "v1.1.0-beta.1", channel: "prerelease")])
        try original.write(to: file, atomically: true, encoding: .utf8)

        for tag in ["v1.0.0", "nightly-1.0.1-20261102030000.abc", "v1.1.0", "1.1.0-beta.1"] {
            let refused = try run([prune, "feed", "--kind", "prerelease", file.path, tag])
            #expect(refused.status != 0, "'\(tag)' must not be prunable as a pre-release")
            #expect(refused.stderr.contains("only prerelease tags may be pruned"), "\(refused.stderr)")
        }
        // A nightly prune refuses a pre-release tag just the same.
        #expect(try run([prune, "feed", "--kind", "nightly", file.path, "v1.1.0-beta.1"]).status != 0)
        #expect(try String(contentsOf: file, encoding: .utf8) == original, "nothing may change after a refusal")

        // A pre-release-looking tag whose item is NOT on the prerelease channel is left alone.
        let odd = appcast([item(version: "1.2.0-beta.1", tag: "v1.2.0-beta.1", channel: nil)])
        try odd.write(to: file, atomically: true, encoding: .utf8)
        let kept = try run([prune, "feed", "--kind", "prerelease", file.path, "v1.2.0-beta.1"])
        #expect(kept.stdout.contains("removed 0 item(s)"))
        #expect(try String(contentsOf: file, encoding: .utf8) == odd, "byte-identical when nothing matches")
    }

    // MARK: PRE5: how a pre-release is published

    @Test("PRE5: a pre-release is a GitHub pre-release, never latest, with generated notes, tagged vX.Y.Z-label.N")
    func prereleaseIsPublishedAsAPrerelease() throws {
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
        let site = dir.appending(path: "site")

        let result = try run([repoRoot.appending(path: "scripts/publish-update.sh").path, "--dmg", dmg.path,
                              "--version", "0.2.0-beta.1", "--build", "20261125030000", "--channel", "prerelease",
                              "--site-dir", site.path, "--upload"],
                             environment: ["SPARKLE_BIN": bin.path, "SPARKLE_ED_PRIVATE_KEY": "unused",
                                           "PATH": "\(bin.path):/usr/bin:/bin:/usr/sbin:/sbin"])
        #expect(result.status == 0, "\(result.all)")
        let create = try #require(try String(contentsOf: calls, encoding: .utf8).split(separator: "\n")
            .first { $0.hasPrefix("release create") }.map(String.init))
        #expect(create.contains("v0.2.0-beta.1"), "\(create)")
        #expect(create.contains("--prerelease") && create.contains("--latest=false"))
        #expect(create.contains("--generate-notes") && !create.contains("--notes "), "generated notes for a pre-release")

        let feed = try String(contentsOf: site.appending(path: "appcast.xml"), encoding: .utf8)
        #expect(feed.contains("<sparkle:channel>prerelease</sparkle:channel>"))
        #expect(feed.contains("<sparkle:shortVersionString>0.2.0-beta.1</sparkle:shortVersionString>"))
        #expect(feed.contains("/releases/download/v0.2.0-beta.1/"))
    }

    // MARK: PRE1 / PRE9 / PRE4: the workflows

    @Test("PRE1: a pre-release is manual only, runs one at a time with the other builds, and the caller reads no secret")
    func prereleaseWorkflowIsManualAndShared() throws {
        let workflow = try text(".github/workflows/prerelease.yml")
        let header = try #require(workflow.components(separatedBy: "\npermissions:").first)
        #expect(header.contains("workflow_dispatch:"))
        #expect(header.contains("bump:") && header.contains("label:") && header.contains("dry_run:") && header.contains("keep:"))
        #expect(header.contains("default: \"10\""), "the newest 10 pre-releases are kept by default")
        #expect(!header.contains("pull_request") && !header.contains("\n  push:") && !header.contains("schedule:"))
        #expect(workflow.contains("group: release") && workflow.contains("cancel-in-progress: false"))
        #expect(workflow.contains("uses: ./.github/workflows/build-and-publish.yml") && workflow.contains("kind: prerelease"))
        #expect(!workflow.contains("secrets."), "the caller must not touch secrets; the shared build reads them")

        // The shared build knows the label and still keeps the main-only guard.
        let shared = try text(".github/workflows/build-and-publish.yml")
        #expect(shared.contains("VERSION_LABEL: ${{ inputs.label }}"))
        #expect(shared.contains("refs/heads/main"))
    }

    @Test("PRE9: a dry run publishes and prunes nothing; prune runs only after a good build")
    func prereleaseDryRunAndPrune() throws {
        let workflow = try text(".github/workflows/prerelease.yml")
        let build = try #require(workflow.components(separatedBy: "\n  build:\n").last?.components(separatedBy: "\n  prune:\n").first)
        #expect(build.contains("dry_run: ${{ inputs.dry_run }}"), "a dry run must reach the shared build")

        let prune = try #require(workflow.components(separatedBy: "\n  prune:\n").last)
        #expect(prune.contains("needs: build") && prune.contains("needs.build.result == 'success'"))
        #expect(prune.contains("uses: ./.github/workflows/prune-builds.yml") && prune.contains("kind: prerelease"))
        #expect(prune.contains("keep: ${{ inputs.keep }}"))
        #expect(prune.contains("dry_run: ${{ inputs.dry_run }}"), "a dry run must reach the prune")
    }

    @Test("PRE4: the nightly's skip rule does not look at pre-release tags")
    func nightlyIgnoresPrereleaseTags() throws {
        // A pre-release at HEAD must NOT stop the nightly (the user's choice): only the newest
        // nightly or release tag count.
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = dir.appending(path: "repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let shell = "cd '\(repo.path)' && /usr/bin/git init -q && /usr/bin/git -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m a && /usr/bin/git tag v1.0.0 && /usr/bin/git -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m b && /usr/bin/git tag v1.1.0-beta.1"
        #expect(try run(["-c", shell]).status == 0)
        let decision = try run(["-c", "cd '\(repo.path)' && /bin/sh '\(repoRoot.appending(path: "scripts/ci/should-build-nightly.sh").path)'"])
        #expect(decision.stdout.contains("build=true"), "a pre-release at HEAD must not stop the nightly: \(decision.all)")
    }
}
