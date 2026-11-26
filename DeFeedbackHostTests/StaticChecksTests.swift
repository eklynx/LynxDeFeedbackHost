//
//  StaticChecksTests.swift
//  DeFeedbackHostTests
//
//  Covers docs/static-checks-spec.md rules S1–S8: the shape of the SwiftLint job, the CodeQL
//  workflow (kept disabled, issue #34) and the Dependabot configuration. Textual checks on
//  purpose: the project has no YAML dependency.
//
//  - Tests initially created with AI with human edits, but all reviewed by human

import Foundation
import Testing

@testable import DeFeedbackHost

private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()

private func read(_ path: String) throws -> String {
    try String(contentsOf: repoRoot.appending(path: path), encoding: .utf8)
}

/// The lines that are not comments.
private func active(_ text: String) -> [String] {
    text.split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
}

/// The block that starts at the line `header` (e.g. "  swiftlint:") up to the next line indented the same.
private func block(_ lines: [String], from header: String) -> String {
    guard let start = lines.firstIndex(of: header) else { return "" }
    let indent = header.prefix { $0 == " " }.count
    var end = lines.count
    for index in (start + 1)..<lines.count {
        let line = lines[index]
        let lead = line.prefix { $0 == " " }.count
        if !line.trimmingCharacters(in: .whitespaces).isEmpty, lead <= indent { end = index; break }
    }
    return lines[start..<end].joined(separator: "\n")
}

@Suite("Static checks")
struct StaticChecksTests {

    // MARK: SwiftLint (S1–S4)

    @Test("S1: CI lints with --strict against the baseline")
    func lintsAgainstBaseline() throws {
        let job = block(active(try read(".github/workflows/ci.yml")), from: "  swiftlint:")
        #expect(job.contains("swiftlint lint --strict --baseline .swiftlint.baseline.json"))
    }

    @Test("S2: the SwiftLint release is pinned and its download verified")
    func swiftLintIsPinned() throws {
        let job = block(active(try read(".github/workflows/ci.yml")), from: "  swiftlint:")
        #expect(job.contains("SWIFTLINT_VERSION: \""))
        #expect(job.contains("SWIFTLINT_SHA256:"))
        #expect(job.contains("shasum -a 256 -c"))
        #expect(!job.contains("brew install"))
    }

    @Test("S3: ci-ok waits for the lint job")
    func lintGatesCiOk() throws {
        let gate = block(active(try read(".github/workflows/ci.yml")), from: "  ci-ok:")
        #expect(gate.contains("swiftlint"))
        #expect(gate.contains("needs: ["))
    }

    @Test("S4: the config skips generated code and tests, and the baseline is a JSON list")
    func configAndBaseline() throws {
        let config = try read(".swiftlint.yml")
        for path in ["build", "streamdeck", "DeFeedbackHostTests", "DeFeedbackHostUITests"] {
            #expect(config.contains("  - \(path)"), "\(path) must be excluded")
        }
        let data = try Data(contentsOf: repoRoot.appending(path: ".swiftlint.baseline.json"))
        #expect(try JSONSerialization.jsonObject(with: data) is [Any])
    }

    // MARK: CodeQL (S5, S6)

    @Test("S5: CodeQL covers Swift, JavaScript/TypeScript and Actions; only analyze may write alerts")
    func codeQLScope() throws {
        let text = try read(".github/workflows/codeql.yml")
        let lines = active(text)
        #expect(text.contains("language: [swift, javascript-typescript, actions]"))
        #expect(lines.filter { $0.contains("security-events: write") }.count == 1)
        #expect(block(lines, from: "permissions:").contains("contents: read"))
    }

    @Test("S6: CodeQL is disabled: manual trigger only (issue #34)")
    func codeQLIsDisabled() throws {
        let text = try read(".github/workflows/codeql.yml")
        let lines = active(text)
        let triggers = block(lines, from: "on:")
        #expect(triggers.contains("  workflow_dispatch:"))
        for trigger in ["  push:", "  pull_request:", "  schedule:"] {
            #expect(!lines.contains(trigger), "\(trigger) must stay commented out while CodeQL is disabled")
        }
        #expect(text.contains("issue #34"))
    }

    // MARK: Dependabot (S7, S8)

    @Test("S7: Dependabot checks Actions, npm and Swift packages weekly")
    func dependabotEcosystems() throws {
        let lines = active(try read(".github/dependabot.yml"))
        for (ecosystem, directory) in [("github-actions", "/"), ("npm", "/streamdeck"), ("swift", "/")] {
            guard let start = lines.firstIndex(of: "  - package-ecosystem: \(ecosystem)") else {
                Issue.record("missing ecosystem \(ecosystem)"); continue
            }
            let entry = lines[start..<min(start + 8, lines.count)].joined(separator: "\n")
            #expect(entry.contains("directory: \(directory)\n"), "\(ecosystem) directory")
            #expect(entry.contains("interval: weekly"), "\(ecosystem) interval")
        }
    }

    @Test("S8: minor and patch updates are grouped, so each ecosystem sends one PR")
    func dependabotGroups() throws {
        let text = try read(".github/dependabot.yml")
        #expect(text.components(separatedBy: "update-types: [minor, patch]").count - 1 == 3)
    }
}
