//
//  WebShutdownPageTests.swift
//  DeFeedbackHostTests
//
//  Spec rule SH12 (docs/shutdown-spec.md). The page's phrase check is one small pure function
//  between BEGIN/END markers in index.html. This test pulls that text out of the shipped page and
//  runs it in JavaScriptCore, so no browser or node is needed and the test cannot drift from the
//  page. It must agree with `ShutdownPhrase.matches`.
//
import Foundation
import JavaScriptCore
import Testing

@testable import DeFeedbackHost

struct WebShutdownPageTests {

    private func pageSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: root.appending(path: "DeFeedbackHost/Web/Resources/index.html"), encoding: .utf8)
    }

    private func phraseMatcher() throws -> JSValue {
        let page = try pageSource()
        // Start on the line after the marker, whose trailing comment is not JavaScript.
        let marker = try #require(page.range(of: "// BEGIN shutdownPhraseMatches"))
        let begin = try #require(page.range(of: "\n", range: marker.upperBound..<page.endIndex))
        let end = try #require(page.range(of: "// END shutdownPhraseMatches"))
        let context = try #require(JSContext())
        context.evaluateScript(String(page[begin.upperBound..<end.lowerBound]))
        let function = try #require(context.objectForKeyedSubscript("shutdownPhraseMatches"))
        try #require(function.isObject, "the extracted text did not define the function")
        return function
    }

    @Test("the web page matches the shutdown phrase exactly, like ShutdownPhrase.matches")
    func webPhraseMatch() throws {
        let matcher = try phraseMatcher()
        let phrase = ShutdownPhrase.defaultPhrase
        let cases = [
            phrase, "Shutdown now", "SHUTDOWN NOW", " shutdown now", "shutdown now ", "shutdown  now",
            "shutdown now\n", "", "shutdown", "shutdown nowe", "shutdown\u{00A0}now",
        ]
        for typed in cases {
            let web = matcher.call(withArguments: [typed, phrase])?.toBool()
            #expect(web == ShutdownPhrase.matches(typed, expected: phrase), "typed: \(typed.debugDescription)")
        }
        #expect(matcher.call(withArguments: [phrase, phrase])?.toBool() == true)
        #expect(matcher.call(withArguments: ["", ""])?.toBool() == true, "mirrors ==; the server never has an empty phrase")
    }
}
