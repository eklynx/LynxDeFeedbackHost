//
//  OpenAPIConformanceTests.swift
//  DeFeedbackHostTests
//
//  Keeps `openapi.yaml` honest.
//
//  A hand-written API document rots the moment someone adds a route or a status field and doesn't
//  think to open it. These tests read both the document and `WebControlService.swift` as text and
//  fail when they disagree, so the reminder arrives at the same time as the change rather than
//  whenever a client next gets confused.
//
//  Deliberately textual rather than a real YAML parse: the project has no YAML dependency and
//  isn't going to gain one for a test. What that buys is detection of the failure that actually
//  happens — a name present in one file and absent from the other. What it can't check is
//  structure or types; `npx @redocly/cli lint openapi.yaml` covers the document's own validity.
//
//  - Tests initially created with AI with human edits, but all reviewed by human

import Foundation
import Testing

@testable import DeFeedbackHost

/// Locates the repository from this file's own path, so the tests work wherever it's checked out.
private enum Sources {

    static func text(_ relativePath: String, file: StaticString = #filePath) -> String? {
        let thisFile = URL(fileURLWithPath: "\(file)")
        // …/DeFeedbackHost/DeFeedbackHostTests/OpenAPIConformanceTests.swift → repository root
        let root = thisFile
            .deletingLastPathComponent()   // DeFeedbackHostTests
            .deletingLastPathComponent()   // repository root
        return try? String(contentsOf: root.appending(path: relativePath), encoding: .utf8)
    }

    static var document: String? { text("openapi.yaml") }

    static var service: String? {
        text("DeFeedbackHost/Web/WebControlService.swift")
    }

    /// The body of a function, from its declaration to the first line that closes it.
    static func functionBody(_ declaration: String, in source: String) -> String? {
        guard let start = source.range(of: declaration) else { return nil }
        let rest = source[start.lowerBound...]
        guard let end = rest.range(of: "\n    }") else { return nil }
        return String(rest[..<end.lowerBound])
    }
}

/// Reading the two files is the precondition for everything below. If the checkout moved, say so
/// once here rather than failing every test with the same confusing message.
private func requireSources() throws -> (document: String, service: String) {
    let document = try #require(Sources.document,
                                "openapi.yaml not found next to the project")
    let service = try #require(Sources.service,
                               "WebControlService.swift not found")
    return (document, service)
}

struct OpenAPIConformanceTests {

    /// Every key `statusPayload()` emits has to be documented under the `Status` schema.
    ///
    /// This is the one that will fire: adding a field to the payload is a one-line change and
    /// exactly the sort of thing that reaches a client undocumented.
    @Test func everyStatusFieldIsDocumented() throws {
        let (document, service) = try requireSources()

        let payload = try #require(Sources.functionBody("private func statusPayload", in: service))
        let emitted = keys(in: payload)

        #expect(!emitted.isEmpty, "couldn't read any keys out of statusPayload()")

        for key in emitted.sorted() {
            // Matched as a YAML property — `\n        key:` — rather than anywhere in the file,
            // so a passing mention in prose doesn't count as documentation.
            #expect(document.contains("\n        \(key):"),
                    "status field \"\(key)\" is not documented in openapi.yaml")
        }
    }

    /// And the reverse: a field removed from the payload must not linger in the document.
    @Test func theDocumentInventsNoStatusFields() throws {
        let (document, service) = try requireSources()

        let payload = try #require(Sources.functionBody("private func statusPayload", in: service))
        let emitted = keys(in: payload)

        let required = try #require(requiredFieldNames(in: document),
                                    "couldn't find the Status schema's required list")
        #expect(!required.isEmpty)

        for name in required.sorted() {
            #expect(emitted.contains(name),
                    "openapi.yaml requires \"\(name)\", which statusPayload() no longer emits")
        }
    }

    /// Every path in the route table has to appear in the document, and vice versa.
    @Test func everyRouteIsDocumented() throws {
        let (document, service) = try requireSources()

        let table = try #require(Sources.functionBody("private func routeEndpoint(", in: service))
        let routed = paths(in: table)

        #expect(!routed.isEmpty, "couldn't read any paths out of the route table")

        for path in routed.sorted() {
            #expect(document.contains("\n  \(path):"),
                    "route \"\(path)\" is not documented in openapi.yaml")
        }

        for path in documentedPaths(in: document).sorted() {
            #expect(routed.contains(path),
                    "openapi.yaml documents \"\(path)\", which the route table doesn't serve")
        }
    }

    /// The wire version is stated in three places; they have to agree, or a client will be told
    /// a version the payload doesn't carry.
    @Test func theProtocolVersionAgrees() throws {
        let (document, _) = try requireSources()
        let version = WebControlService.protocolVersion

        #expect(document.contains("x-protocol-version: \(version)"),
                "openapi.yaml's x-protocol-version isn't \(version)")
        #expect(document.contains("const: \(version)"),
                "the Status schema's `protocol` const isn't \(version)")
    }

    /// The limits are quoted in the document as concrete numbers, which is only useful if they're
    /// the real ones.
    @Test func thePublishedLimitsAreTheRealOnes() throws {
        let (document, _) = try requireSources()

        #expect(document.contains("\(HTTPServer.maximumConnections) concurrent connections"))
        #expect(document.contains("\(HTTPRequestParser.maximumBodyBytes / 1024) KiB of request body"))
        #expect(document.contains("\(HTTPRequestParser.maximumHeaderBytes / 1024) KiB of request headers"))
        #expect(document.contains("\(Int(HTTPServer.idleTimeout)) second idle timeout"))
        #expect(document.contains("Body exceeds \(HTTPRequestParser.maximumBodyBytes) bytes"),
                "the 413 example doesn't match the message the parser actually sends")
    }

    /// The instance cap is quoted in two places in the document — the 409 example and the
    /// `maxInstanceCount` example — and both are copied from a constant that can change.
    @Test func theDocumentedInstanceCapMatches() throws {
        let (document, _) = try requireSources()

        #expect(document.contains(AudioHostError.maxInstancesReached.localizedDescription),
                "the 409 example isn't the message the host actually sends")
        #expect(document.contains("examples: [\(PluginConfiguration.maximumInstanceCount)]"),
                "maxInstanceCount's example isn't the real cap")
    }

    /// The missing-plugin notice is quoted in the document as the sentence the host really sends
    /// — in two 409 examples and as `pluginMessage`'s — and the download link as the real one.
    /// Both come from `PluginConfiguration`, which is where the host gets repointed at another
    /// plugin, so both can change without anyone thinking about this file.
    @Test func theDocumentedPluginNoticeMatches() throws {
        let (document, _) = try requireSources()

        #expect(document.contains(PluginConfiguration.notInstalledMessage),
                "the 409 example isn't the sentence the host actually sends")
        #expect(document.contains(PluginConfiguration.pluginHomepage.absoluteString),
                "pluginURL's example isn't the address the host actually publishes")
    }

    /// The offered buffer sizes are quoted in the document three times — the `bufferSizeChoices`
    /// example, the `BufferSizeRequest` example and the 400 message — and all three are copied
    /// from one constant that can change.
    @Test func theDocumentedBufferSizesMatch() throws {
        let (document, _) = try requireSources()

        let sizes = PluginConfiguration.validBufferSizes
        let list = sizes.map(String.init).joined(separator: ", ")

        #expect(document.contains("examples: [[\(list)]]"),
                "bufferSizeChoices' example isn't the list the host actually offers")
        #expect(document.contains("The host offers \(list) frames, not"),
                "the 400 example isn't the message the service actually sends")
    }

    /// The realm appears in the document as the string a browser will display.
    @Test func theAuthenticationRealmMatches() throws {
        let (document, _) = try requireSources()
        #expect(document.contains("realm=\"\(BasicAuth.realm)"))
    }

    /// The default port in the `servers` block should be the one a fresh install listens on.
    @Test func theDocumentedDefaultPortMatches() throws {
        let (document, _) = try requireSources()
        #expect(document.contains("default: \"\(WebServerSettings().port)\""))
        #expect(document.contains("\(WebServerSettings.portRange.lowerBound)–"
                                  + "\(WebServerSettings.portRange.upperBound)"))
    }

    // MARK: - Text scanning
    //
    // Hand-rolled rather than regex: these are looking for fixed shapes in code this repository
    // controls, and a literal search says plainly what it matches.

    /// Dictionary keys — `"name":` at the start of a line.
    private func keys(in source: String) -> Set<String> {
        var found: Set<String> = []
        for line in source.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\"") else { continue }
            let afterQuote = trimmed.dropFirst()
            guard let closing = afterQuote.firstIndex(of: "\"") else { continue }
            let name = String(afterQuote[..<closing])
            guard afterQuote[closing...].dropFirst().first == ":" else { continue }
            found.insert(name)
        }
        return found
    }

    /// The `Status` schema's `required:` list — the `- name` entries that follow it.
    ///
    /// Returns nil when the list can't be located at all, which is a different failure from
    /// "the list is empty" and shouldn't be reported as every field being missing.
    private func requiredFieldNames(in document: String) -> Set<String>? {
        guard let schema = document.range(of: "\n    Status:") else { return nil }
        let rest = document[schema.upperBound...]
        guard let list = rest.range(of: "\n      required:") else { return nil }

        var found: Set<String> = []
        for line in rest[list.upperBound...].split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // The list ends at the next key — `properties:`.
            guard trimmed.hasPrefix("- ") else { break }
            found.insert(String(trimmed.dropFirst(2)))
        }
        return found
    }

    /// Paths from the route table's `("METHOD", "/path")` tuples.
    private func paths(in table: String) -> Set<String> {
        var found: Set<String> = []
        var remainder = Substring(table)

        while let quote = remainder.firstIndex(of: "\"") {
            let afterQuote = remainder[remainder.index(after: quote)...]
            guard let closing = afterQuote.firstIndex(of: "\"") else { break }
            let literal = String(afterQuote[..<closing])
            if literal.hasPrefix("/") {
                found.insert(literal)
            }
            remainder = afterQuote[afterQuote.index(after: closing)...]
        }
        return found
    }

    /// Top-level entries under `paths:` — two-space indented keys beginning with `/`.
    private func documentedPaths(in document: String) -> Set<String> {
        guard let start = document.range(of: "\npaths:") else { return [] }
        let rest = document[start.upperBound...]
        // `components:` is the next top-level key.
        let section = rest.range(of: "\ncomponents:").map { rest[..<$0.lowerBound] } ?? rest

        var found: Set<String> = []
        for line in section.split(separator: "\n") {
            guard line.hasPrefix("  /"), line.hasSuffix(":") else { continue }
            guard !line.hasPrefix("   ") else { continue }
            found.insert(String(line.dropFirst(2).dropLast()))
        }
        return found
    }
}
