//
//  ReleaseScriptTests.swift
//  DeFeedbackHostTests
//
//  Covers docs/release-spec.md rules R1–R6. The signing, notarization and publishing steps can only
//  be proven by a real release run, so these test what can be tested here: the notary
//  authentication logic with a stub `xcrun`, the certificate import against a throwaway keychain,
//  and the shape of the workflow file (what runs when, where secrets may appear).
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

private func run(_ executable: String, _ arguments: [String], environment: [String: String] = [:],
                 in directory: URL? = nil) throws -> Run {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let directory { process.currentDirectoryURL = directory }
    // Clean environment so a developer's own notary or signing variables can't leak into a test.
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
    let url = FileManager.default.temporaryDirectory.appending(path: "ReleaseScriptTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func script(_ path: String) -> String { repoRoot.appending(path: "scripts/\(path)").path }

struct ReleaseScriptTests {

    // MARK: R4 / R3: notary authentication and verdict

    /// A fixture with a stub `xcrun` that records its arguments and prints a chosen verdict.
    private func notaryFixture() throws -> (dir: URL, file: URL, calls: URL, bin: URL) {
        let dir = try scratch()
        let bin = dir.appending(path: "bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let calls = dir.appending(path: "calls.txt")
        let stub = bin.appending(path: "xcrun")
        try """
            #!/bin/sh
            echo "$@" >> "\(calls.path)"
            echo "  status: ${STUB_STATUS:-Accepted}"
            """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let file = dir.appending(path: "App.dmg")
        try Data("dmg".utf8).write(to: file)
        return (dir, file, calls, bin)
    }

    private func notarize(_ fixture: (dir: URL, file: URL, calls: URL, bin: URL),
                          _ extra: [String: String]) throws -> Run {
        try run("/bin/sh", [script("notarytool-submit.sh"), fixture.file.path],
                environment: ["PATH": "\(fixture.bin.path):/usr/bin:/bin:/usr/sbin:/sbin",
                              "TMPDIR": fixture.dir.path].merging(extra) { $1 })
    }

    private func recordedCalls(_ fixture: (dir: URL, file: URL, calls: URL, bin: URL)) -> String {
        (try? String(contentsOf: fixture.calls, encoding: .utf8)) ?? ""
    }

    @Test("R4: with the API key variables set, notarytool gets the key, key id and issuer")
    func notaryUsesApiKey() throws {
        let fixture = try notaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let keyFile = fixture.dir.appending(path: "AuthKey.p8")
        try Data("key".utf8).write(to: keyFile)

        let result = try notarize(fixture, ["NOTARY_KEY_PATH": keyFile.path,
                                            "NOTARY_KEY_ID": "KEY123", "NOTARY_ISSUER_ID": "ISSUER456"])
        #expect(result.status == 0, "\(result.output)")
        let calls = recordedCalls(fixture)
        #expect(calls.contains("notarytool submit \(fixture.file.path)"))
        #expect(calls.contains("--key \(keyFile.path)"))
        #expect(calls.contains("--key-id KEY123"))
        #expect(calls.contains("--issuer ISSUER456"))
        #expect(calls.contains("--wait"))
        #expect(!calls.contains("--keychain-profile"))
    }

    @Test("R4: without the API key it uses the keychain profile, default or chosen")
    func notaryUsesProfile() throws {
        let fixture = try notaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }

        #expect(try notarize(fixture, [:]).status == 0)
        #expect(recordedCalls(fixture).contains("--keychain-profile DeFeedbackHost-Notary"))

        #expect(try notarize(fixture, ["NOTARY_KEYCHAIN_PROFILE": "Other-Profile"]).status == 0)
        #expect(recordedCalls(fixture).contains("--keychain-profile Other-Profile"))
        #expect(!recordedCalls(fixture).contains("--key-id"))
    }

    @Test("R4: some but not all API key variables is an error, never a quiet fallback")
    func notaryRejectsPartialKey() throws {
        let fixture = try notaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let result = try notarize(fixture, ["NOTARY_KEY_ID": "KEY123"])
        #expect(result.status != 0)
        #expect(result.output.contains("NOTARY_KEY_PATH"))
        #expect(recordedCalls(fixture).isEmpty, "notarytool must not be called with half a credential")
    }

    @Test("R3: anything but Accepted fails, so a rejection is never mistaken for success")
    func notaryRejectionFails() throws {
        let fixture = try notaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let result = try notarize(fixture, ["STUB_STATUS": "Invalid"])
        #expect(result.status != 0)
        #expect(result.output.contains("not accepted"))

        let missing = try run("/bin/sh", [script("notarytool-submit.sh"), fixture.dir.appending(path: "nope.dmg").path])
        #expect(missing.status != 0)
    }

    // MARK: R5: signing certificate import and cleanup

    /// A throwaway self-signed .p12 in the legacy format `security import` accepts.
    private func makeP12(in dir: URL, password: String) throws -> String {
        let key = dir.appending(path: "k.pem").path, cert = dir.appending(path: "c.pem").path
        let p12 = dir.appending(path: "t.p12").path
        let made = try run("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key,
                                                "-out", cert, "-days", "2", "-subj", "/CN=Release Test Signing"])
        #expect(made.status == 0, "\(made.output)")
        let packed = try run("/usr/bin/openssl", ["pkcs12", "-export", "-inkey", key, "-in", cert, "-out", p12,
                                                  "-passout", "pass:\(password)", "-keypbe", "PBE-SHA1-3DES",
                                                  "-certpbe", "PBE-SHA1-3DES", "-macalg", "sha1"])
        #expect(packed.status == 0, "\(packed.output)")
        return try Data(contentsOf: URL(fileURLWithPath: p12)).base64EncodedString()
    }

    private func certEnv(_ dir: URL, _ extra: [String: String] = [:]) -> [String: String] {
        ["KEYCHAIN_PATH": dir.appending(path: "test.keychain-db").path, "NO_SEARCH_LIST": "1",
         "RUNNER_TEMP": dir.path, "TMPDIR": dir.path].merging(extra) { $1 }
    }

    @Test("R5: the certificate lands in a temporary keychain, and cleanup removes every trace")
    func certificateImportAndCleanup() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let base64 = try makeP12(in: dir, password: "pw-for-test")
        let keychain = dir.appending(path: "test.keychain-db")

        let imported = try run("/bin/sh", [script("ci/import-signing-cert.sh"), "import"],
                               environment: certEnv(dir, ["CERT_P12_BASE64": base64, "CERT_PASSWORD": "pw-for-test"]))
        #expect(imported.status == 0, "\(imported.output)")
        #expect(!imported.output.contains("pw-for-test"), "the password must never be printed")
        #expect(!imported.output.contains(base64.prefix(40)), "the certificate must never be printed")
        #expect(FileManager.default.fileExists(atPath: keychain.path))
        let found = try run("/usr/bin/security", ["find-certificate", "-c", "Release Test Signing", keychain.path])
        #expect(found.status == 0, "the certificate should be in the temporary keychain: \(found.output)")

        // The temporary files that held the certificate are gone straight away.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("cert.") }
        #expect(leftovers.isEmpty, "the decoded .p12 must not be left behind: \(leftovers)")

        // A second import over the same keychain is refused rather than mixed.
        let again = try run("/bin/sh", [script("ci/import-signing-cert.sh"), "import"],
                            environment: certEnv(dir, ["CERT_P12_BASE64": base64, "CERT_PASSWORD": "pw-for-test"]))
        #expect(again.status != 0)

        let cleaned = try run("/bin/sh", [script("ci/import-signing-cert.sh"), "cleanup"], environment: certEnv(dir))
        #expect(cleaned.status == 0, "\(cleaned.output)")
        #expect(!FileManager.default.fileExists(atPath: keychain.path))
        #expect(!FileManager.default.fileExists(atPath: keychain.path + ".state"), "the keychain password file must go too")

        // Cleanup is safe to run again, e.g. after a failed job.
        #expect(try run("/bin/sh", [script("ci/import-signing-cert.sh"), "cleanup"], environment: certEnv(dir)).status == 0)
    }

    @Test("R5: missing secrets fail with a clear message instead of an empty keychain")
    func importNeedsSecrets() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = try run("/bin/sh", [script("ci/import-signing-cert.sh"), "import"], environment: certEnv(dir))
        #expect(result.status != 0)
        #expect(result.output.contains("CERT_P12_BASE64"))
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "test.keychain-db").path))
    }

    // MARK: R7: the tag lands on the tested commit

    /// publish-update.sh with stub `sign_update` and `gh`; returns the `gh release create` call.
    private func publishCall(channel: String, target: String?) throws -> String {
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
        // `release view` fails (no such release yet) so the script goes on to create it.
        try stub("gh", "echo \"$@\" >> \"\(calls.path)\"\n[ \"$2\" = view ] && exit 1\nexit 0")
        let dmg = dir.appending(path: "App.dmg")
        try Data("dmg".utf8).write(to: dmg)

        var env = ["SPARKLE_BIN": bin.path, "SPARKLE_ED_PRIVATE_KEY": "unused",
                   "PATH": "\(bin.path):/usr/bin:/bin:/usr/sbin:/sbin"]
        if let target { env["RELEASE_TARGET"] = target }
        let result = try run("/bin/sh", [script("publish-update.sh"), "--dmg", dmg.path, "--version", "1.2.3",
                                         "--build", "20261125030000", "--channel", channel,
                                         "--site-dir", dir.appending(path: "site").path, "--upload"],
                             environment: env)
        #expect(result.status == 0, "\(result.output)")
        let all = (try? String(contentsOf: calls, encoding: .utf8)) ?? ""
        return all.split(separator: "\n").first { $0.hasPrefix("release create") }.map(String.init) ?? ""
    }

    @Test("R7: the release is tagged on RELEASE_TARGET, and only pre-releases are marked as such")
    func publishTagsOnTestedCommit() throws {
        let release = try publishCall(channel: "release", target: "abc1234")
        #expect(release.contains("--target abc1234"), "\(release)")
        #expect(release.contains("v1.2.3"))
        #expect(!release.contains("--prerelease"), "a release must not be marked as a pre-release")

        let nightly = try publishCall(channel: "nightly", target: "abc1234")
        #expect(nightly.contains("--target abc1234"))
        #expect(nightly.contains("--prerelease") && nightly.contains("--latest=false"))

        let untargeted = try publishCall(channel: "release", target: nil)
        #expect(!untargeted.contains("--target"), "without RELEASE_TARGET nothing is forced: \(untargeted)")
    }

    // MARK: R1 / R5 / R6: the shape of the workflow

    private func workflow() throws -> String {
        try String(contentsOf: repoRoot.appending(path: ".github/workflows/release.yml"), encoding: .utf8)
    }

    /// The text of each step of the `release` job.
    private func releaseSteps() throws -> [String] {
        let text = try workflow()
        let job = try #require(text.components(separatedBy: "\n  release:\n").last)
        return job.components(separatedBy: "\n      - ").dropFirst().map { $0 }
    }

    @Test("R1: a release is manual only, runs from main, and its secrets are in the release environment")
    func workflowIsManualAndGuarded() throws {
        let text = try workflow()
        let triggers = try #require(text.components(separatedBy: "\npermissions:").first)
        #expect(triggers.contains("workflow_dispatch:"))
        #expect(!triggers.contains("pull_request"), "a pull request must never be able to start a release")
        #expect(!triggers.contains("\n  push:"))
        #expect(!triggers.contains("schedule:"))
        #expect(text.contains("refs/heads/main"), "the main-only guard is missing")
        #expect(text.contains("already exists"), "the existing-tag guard is missing")
        #expect(text.contains("environment: release"))
        #expect(text.contains("group: release") && text.contains("cancel-in-progress: false"))
    }

    @Test("R5: secrets appear only as environment values, never in a command line")
    func secretsOnlyInEnv() throws {
        let text = try workflow()
        for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
        where line.contains("secrets.") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            #expect(trimmed.range(of: #"^[A-Z0-9_]+: \$\{\{ secrets\.[A-Z0-9_]+ \}\}$"#, options: .regularExpression) != nil,
                    "line \(number + 1) uses a secret outside an env value: \(trimmed)")
        }
        #expect(text.contains("if: always()"), "the signing material must be removed even when a step fails")
        #expect(text.contains("import-signing-cert.sh cleanup"))
    }

    @Test("R6: every step that publishes is skipped for a dry run")
    func dryRunPublishesNothing() throws {
        let steps = try releaseSteps()
        let publishing = steps.filter {
            $0.contains("publish-update.sh") || $0.contains("git push") || $0.contains("gh release")
                || $0.contains("ref: gh-pages")
        }
        #expect(publishing.count >= 3, "expected the release, checkout and push steps, found \(publishing.count)")
        for step in publishing {
            #expect(step.contains("if: ${{ !inputs.dry_run }}"),
                    "a publishing step runs on a dry run: \(step.prefix(60))")
        }
        let upload = try #require(steps.first { $0.contains("(dry run)") })
        #expect(upload.contains("if: ${{ inputs.dry_run }}"))
    }
}
