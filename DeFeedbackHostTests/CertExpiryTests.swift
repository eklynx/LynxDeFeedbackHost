//
//  CertExpiryTests.swift
//  DeFeedbackHostTests
//
//  Covers docs/cert-expiry.md rules C1–C9: reading a certificate's expiry from a .p12 secret, the
//  reminder issue logic (with a stub `gh`, so nothing touches GitHub), and the shape of the
//  workflow (which job may see secrets). A throwaway self-signed certificate stands in for the real
//  one, and CERT_EXPIRY_NOW moves "now" so every case is deterministic.
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

private func run(_ arguments: [String], environment: [String: String] = [:]) throws -> Run {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = arguments
    // Clean environment: nothing from a developer's shell can leak into a test.
    process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"].merging(environment) { $1 }
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    try process.run()
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return Run(status: process.terminationStatus,
               stdout: String(decoding: outData, as: UTF8.self),
               stderr: String(decoding: errData, as: UTF8.self))
}

private func scratch() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "CertExpiryTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func script(_ name: String) -> String { repoRoot.appending(path: "scripts/ci/\(name)").path }

private func openssl(_ arguments: [String]) throws -> Run {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
    process.arguments = arguments
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    try process.run()
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return Run(status: process.terminationStatus, stdout: String(decoding: outData, as: UTF8.self),
               stderr: String(decoding: errData, as: UTF8.self))
}

/// A throwaway self-signed certificate valid for `days`, as a base64 .p12 with `password`.
private struct TestCertificate {
    let base64: String
    let password: String
    /// The moment before it was created: every "now" in the tests is measured from here.
    let created: Date
    /// The certificate's real expiry date (UTC, yyyy-MM-dd), read back with openssl.
    let expiryDay: String
}

private func makeCertificate(days: Int, password: String = "pw-for-test") throws -> TestCertificate {
    let dir = try scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let key = dir.appending(path: "k.pem").path, cert = dir.appending(path: "c.pem").path
    let p12 = dir.appending(path: "t.p12").path

    let created = Date()
    let made = try openssl(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert,
                            "-days", "\(days)", "-subj", "/CN=Expiry Test"])
    #expect(made.status == 0, "\(made.stderr)")
    let packed = try openssl(["pkcs12", "-export", "-inkey", key, "-in", cert, "-out", p12,
                              "-passout", "pass:\(password)", "-keypbe", "PBE-SHA1-3DES",
                              "-certpbe", "PBE-SHA1-3DES", "-macalg", "sha1"])
    #expect(packed.status == 0, "\(packed.stderr)")

    let end = try openssl(["x509", "-in", cert, "-noout", "-enddate"]).stdout
        .trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "notAfter=", with: "")
    let parser = DateFormatter()
    parser.locale = Locale(identifier: "en_US_POSIX")
    parser.timeZone = TimeZone(identifier: "UTC")
    parser.dateFormat = "MMM d HH:mm:ss yyyy 'GMT'"
    let endDate = try #require(parser.date(from: end.replacingOccurrences(of: "  ", with: " ")), "unparsed: \(end)")
    let day = DateFormatter()
    day.locale = Locale(identifier: "en_US_POSIX")
    day.timeZone = TimeZone(identifier: "UTC")
    day.dateFormat = "yyyy-MM-dd"

    return TestCertificate(base64: try Data(contentsOf: URL(fileURLWithPath: p12)).base64EncodedString(),
                           password: password, created: created, expiryDay: day.string(from: endDate))
}

/// Runs cert-expiry.sh with "now" at `daysAfterCreation` days after the certificate was made.
private func expiry(of cert: TestCertificate, daysAfterCreation: Int, extra: [String: String] = [:]) throws -> Run {
    let now = Int(cert.created.timeIntervalSince1970) + daysAfterCreation * 86_400
    return try run([script("cert-expiry.sh")],
                   environment: ["P12_BASE64": cert.base64, "P12_PASSWORD": cert.password,
                                 "CERT_EXPIRY_NOW": "\(now)"].merging(extra) { $1 })
}

struct CertExpiryTests {

    // MARK: cert-expiry.sh (C1–C4)

    @Test("C1: reports the whole days left and the expiry date, and nothing else")
    func reportsDaysAndDate() throws {
        let cert = try makeCertificate(days: 40)
        let result = try expiry(of: cert, daysAfterCreation: 10)
        #expect(result.status == 0, "\(result.all)")
        #expect(result.stdout == "expires_in_days=30\nexpires_on=\(cert.expiryDay)\n", "\(result.stdout)")
    }

    @Test("C1: the same values are appended to $GITHUB_OUTPUT")
    func appendsToGithubOutput() throws {
        let cert = try makeCertificate(days: 40)
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "out.txt")
        try "existing=1\n".write(to: file, atomically: true, encoding: .utf8)

        let result = try expiry(of: cert, daysAfterCreation: 10, extra: ["GITHUB_OUTPUT": file.path])
        #expect(result.status == 0, "\(result.all)")
        let written = try String(contentsOf: file, encoding: .utf8)
        #expect(written == "existing=1\ndays=30\nexpires=\(cert.expiryDay)\n", "\(written)")
    }

    @Test("C2: neither the secret, the password nor the certificate is ever printed")
    func neverPrintsTheSecret() throws {
        let cert = try makeCertificate(days: 40, password: "very-secret-password-123")
        for offset in [10, 60] {   // valid, and expired
            let result = try expiry(of: cert, daysAfterCreation: offset)
            #expect(!result.all.contains("very-secret-password-123"))
            #expect(!result.all.contains(String(cert.base64.prefix(40))))
            #expect(!result.all.contains("BEGIN CERTIFICATE"))
            #expect(!result.all.contains("Expiry Test"), "even the certificate's name stays out of the log")
        }
    }

    @Test("C3: unreadable secrets fail clearly with exit 2 and no numbers")
    func unreadableSecretsFailClearly() throws {
        let cert = try makeCertificate(days: 40)
        let cases: [(env: [String: String], mention: String)] = [
            (["P12_BASE64": "", "P12_PASSWORD": cert.password], "P12_BASE64 is empty"),
            (["P12_BASE64": cert.base64, "P12_PASSWORD": ""], "P12_PASSWORD is empty"),
            (["P12_BASE64": cert.base64, "P12_PASSWORD": "wrong-password"], "wrong password"),
            (["P12_BASE64": "bm90IGEgcDEy", "P12_PASSWORD": cert.password], "could not open the .p12"),
        ]
        for (env, mention) in cases {
            let result = try run([script("cert-expiry.sh")], environment: env)
            #expect(result.status == 2, "expected exit 2 for '\(mention)', got \(result.status): \(result.all)")
            #expect(result.stderr.contains(mention), "\(result.stderr)")
            #expect(result.stdout.isEmpty, "no numbers may be reported for an unreadable secret")
        }
    }

    @Test("C4: an expired certificate still reports its numbers but fails with exit 1")
    func expiredCertificateStillReports() throws {
        let cert = try makeCertificate(days: 40)
        let result = try expiry(of: cert, daysAfterCreation: 60)
        #expect(result.status == 1, "\(result.all)")
        #expect(result.stdout == "expires_in_days=-20\nexpires_on=\(cert.expiryDay)\n", "\(result.stdout)")
        #expect(result.stderr.contains("expired"))
    }

    // MARK: remind-expiry.sh (C5–C8)

    private struct GhFixture {
        let dir: URL
        let bin: URL
        let calls: URL
    }

    /// A stub `gh` that records every call; `issue list` answers with $STUB_EXISTING.
    private func ghFixture() throws -> GhFixture {
        let dir = try scratch()
        let bin = dir.appending(path: "bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let calls = dir.appending(path: "calls.txt")
        let stub = bin.appending(path: "gh")
        try """
            #!/bin/sh
            # One line per call: the issue body spans several lines, so flatten it.
            printf '%s\n' "$*" | tr '\n' ' ' >> "\(calls.path)"; echo >> "\(calls.path)"
            if [ "$1 $2" = "issue list" ]; then echo "${STUB_EXISTING:-}"; fi
            exit 0
            """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        return GhFixture(dir: dir, bin: bin, calls: calls)
    }

    private func remind(_ fixture: GhFixture, days: String, threshold: String = "15",
                        existing: String = "", extra: [String] = []) throws -> Run {
        try run([script("remind-expiry.sh"), "--days", days, "--expires", "2027-02-01", "--threshold", threshold,
                 "--repo", "owner/repo", "--assignee", "owner"] + extra,
                environment: ["PATH": "\(fixture.bin.path):/usr/bin:/bin:/usr/sbin:/sbin", "STUB_EXISTING": existing])
    }

    private func calls(_ fixture: GhFixture) -> [String] {
        ((try? String(contentsOf: fixture.calls, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    @Test("C5: while more days are left than the threshold, nothing is opened or changed")
    func noReminderAboveThreshold() throws {
        let fixture = try ghFixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let result = try remind(fixture, days: "16")
        #expect(result.status == 0, "\(result.all)")
        #expect(result.stdout.contains("no reminder"))
        #expect(calls(fixture).isEmpty, "gh must not be called: \(calls(fixture))")
    }

    @Test("C6: at the threshold exactly one labelled, assigned issue is opened")
    func opensOneIssue() throws {
        let fixture = try ghFixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let result = try remind(fixture, days: "15")
        #expect(result.status == 0, "\(result.all)")
        let recorded = calls(fixture)
        let creates = recorded.filter { $0.hasPrefix("issue create") }
        #expect(creates.count == 1, "\(recorded)")
        let create = try #require(creates.first)
        #expect(create.contains("--repo owner/repo"))
        #expect(create.contains("--label certificate-expiry"))
        #expect(create.contains("--assignee owner"))
        #expect(create.contains("Developer ID certificate expires on 2027-02-01 (15 days left)"))
        #expect(!recorded.contains { $0.hasPrefix("issue edit") })
        #expect(recorded.contains { $0.hasPrefix("label create certificate-expiry") }, "the label is created if missing")
    }

    @Test("C7: a later run updates the open issue instead of opening a second one")
    func updatesTheExistingIssue() throws {
        let fixture = try ghFixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let result = try remind(fixture, days: "8", existing: "42")
        #expect(result.status == 0, "\(result.all)")
        let recorded = calls(fixture)
        #expect(!recorded.contains { $0.hasPrefix("issue create") }, "must not open a second issue: \(recorded)")
        let edit = try #require(recorded.first { $0.hasPrefix("issue edit 42") })
        #expect(edit.contains("(8 days left)"))
        #expect(result.stdout.contains("updated issue #42"))
    }

    @Test("C8: an expired certificate gets an 'expired on' title")
    func expiredWording() throws {
        let fixture = try ghFixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let result = try remind(fixture, days: "-3")
        #expect(result.status == 0, "\(result.all)")
        let create = try #require(calls(fixture).first { $0.hasPrefix("issue create") })
        #expect(create.contains("Developer ID certificate expired on 2027-02-01"))
        #expect(!create.contains("days left"))
    }

    @Test("C8: bad arguments are rejected without calling gh")
    func badArgumentsAreRejected() throws {
        let fixture = try ghFixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        for (days, threshold) in [("soon", "15"), ("10", "-1"), ("10", "many")] {
            let result = try remind(fixture, days: days, threshold: threshold)
            #expect(result.status != 0, "days=\(days) threshold=\(threshold) should fail")
        }
        let badDate = try run([script("remind-expiry.sh"), "--days", "5", "--expires", "tomorrow", "--threshold", "15",
                               "--repo", "owner/repo", "--assignee", "owner"],
                              environment: ["PATH": "\(fixture.bin.path):/usr/bin:/bin:/usr/sbin:/sbin"])
        #expect(badDate.status != 0)
        let missing = try run([script("remind-expiry.sh"), "--days", "5"],
                              environment: ["PATH": "\(fixture.bin.path):/usr/bin:/bin:/usr/sbin:/sbin"])
        #expect(missing.status != 0)
        #expect(calls(fixture).isEmpty, "gh must never be called for invalid input")
    }

    // MARK: the workflow (C9)

    @Test("C9: weekly and manual; only `check` sees secrets; `remind` can write issues and sees none")
    func workflowSplitsSecretsFromIssues() throws {
        let text = try String(contentsOf: repoRoot.appending(path: ".github/workflows/cert-expiry.yml"), encoding: .utf8)
        let header = try #require(text.components(separatedBy: "\njobs:\n").first)
        #expect(header.contains("cron: \"0 14 * * 1\""))
        #expect(header.contains("workflow_dispatch:"))
        #expect(header.contains("threshold_days"))
        #expect(!header.contains("pull_request"), "a pull request must never run this with the secrets")
        #expect(header.contains("\npermissions: {}"), "default to no permissions")

        let jobs = try #require(text.components(separatedBy: "\njobs:\n").last)
        let remindStart = try #require(jobs.range(of: "\n  remind:"))
        let check = String(jobs[..<remindStart.lowerBound])
        let remind = String(jobs[remindStart.lowerBound...])

        #expect(check.contains("environment: release"))
        #expect(check.contains("secrets.DEVELOPER_ID_CERT_P12") && check.contains("secrets.DEVELOPER_ID_CERT_PASSWORD"))
        #expect(!check.contains("issues: write"), "the job that sees the secrets must not be able to write issues")

        #expect(remind.contains("issues: write"))
        #expect(!remind.contains("secrets."), "the job that writes issues must not see secrets")
        #expect(!remind.contains("environment:"))

        for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
        where line.contains("secrets.") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
            #expect(line.trimmingCharacters(in: .whitespaces)
                        .range(of: #"^[A-Z0-9_]+: \$\{\{ secrets\.[A-Z0-9_]+ \}\}$"#, options: .regularExpression) != nil,
                    "line \(number + 1) uses a secret outside an env value")
        }
    }
}
