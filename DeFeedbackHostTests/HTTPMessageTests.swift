//
//  HTTPMessageTests.swift
//  DeFeedbackHostTests
//
//  The request parser is pure and synchronous precisely so the awkward cases — split packets,
//  oversized headers, pipelining — can be covered without a socket.
//
//  - Tests initially created with AI with human edits, but all reviewed by human

import Foundation
import Testing

@testable import DeFeedbackHost

private func bytes(_ text: String) -> [UInt8] {
    Array(text.utf8)
}

struct HTTPRequestParserTests {

    @Test func parsesAMinimalGet() throws {
        let outcome = HTTPRequestParser.parse(bytes(
            "GET /api/status HTTP/1.1\r\nHost: studio.local:8787\r\n\r\n"))

        guard case .complete(let request, let consumed) = outcome else {
            Issue.record("expected a complete request, got \(outcome)")
            return
        }

        #expect(request.method == "GET")
        #expect(request.path == "/api/status")
        #expect(request.headers["Host"] == "studio.local:8787")
        #expect(request.body.isEmpty)
        // 26 for the request line, 25 for the Host header, 2 for the blank line that ends the
        // block — all of it consumed, so a pipelined request behind it starts at a clean offset.
        #expect(consumed == 53)
    }

    /// TCP does not preserve message boundaries, so a request arriving in pieces is normal, not
    /// exotic — the parser has to say "not yet" rather than fail.
    @Test func waitsForARequestSplitAcrossPackets() {
        let whole = "POST /api/system HTTP/1.1\r\n"
            + "Host: x\r\nContent-Type: application/json\r\nContent-Length: 17\r\n\r\n"
            + #"{"running": true}"#

        var buffer: [UInt8] = []
        let all = bytes(whole)

        // Feed it a third at a time; only the last chunk should complete it.
        for chunk in stride(from: 0, to: all.count, by: all.count / 3 + 1) {
            let end = min(chunk + all.count / 3 + 1, all.count)
            buffer.append(contentsOf: all[chunk..<end])

            if end < all.count {
                guard case .incomplete = HTTPRequestParser.parse(buffer) else {
                    Issue.record("completed early at \(end) of \(all.count) bytes")
                    return
                }
            }
        }

        guard case .complete(let request, _) = HTTPRequestParser.parse(buffer) else {
            Issue.record("never completed")
            return
        }
        #expect(request.method == "POST")
        #expect(String(decoding: request.body, as: UTF8.self) == #"{"running": true}"#)
    }

    /// Headers complete but body still arriving — the other half of the split case, and the one
    /// that would silently hand a truncated body to the route if it were wrong.
    @Test func waitsForABodyThatHasNotArrived() {
        let head = "POST /api/system HTTP/1.1\r\nContent-Length: 10\r\n\r\n"

        guard case .incomplete = HTTPRequestParser.parse(bytes(head + "12345")) else {
            Issue.record("accepted a half-delivered body")
            return
        }

        guard case .complete(let request, _) = HTTPRequestParser.parse(bytes(head + "1234567890"))
        else {
            Issue.record("didn't complete once the body arrived")
            return
        }
        #expect(request.body.count == 10)
    }

    /// A second request already in the buffer must survive the first being taken out of it.
    @Test func leavesAPipelinedRequestInTheBuffer() throws {
        let first = "GET /a HTTP/1.1\r\nHost: x\r\n\r\n"
        let second = "GET /b HTTP/1.1\r\nHost: x\r\n\r\n"
        var buffer = bytes(first + second)

        guard case .complete(let one, let consumed) = HTTPRequestParser.parse(buffer) else {
            Issue.record("first request didn't parse")
            return
        }
        #expect(one.path == "/a")
        #expect(consumed == bytes(first).count)

        buffer.removeFirst(consumed)
        guard case .complete(let two, _) = HTTPRequestParser.parse(buffer) else {
            Issue.record("second request didn't parse")
            return
        }
        #expect(two.path == "/b")
    }

    @Test func splitsPathFromQuery() {
        let (path, query) = HTTPRequestParser.splitTarget("/api/x?one=1&two=a%20b&three=a+b&flag")
        #expect(path == "/api/x")
        #expect(query["one"] == "1")
        #expect(query["two"] == "a b")
        // `+` is a space in a query string but not in a path.
        #expect(query["three"] == "a b")
        #expect(query["flag"] == "")
    }

    @Test func percentDecodesThePathButLeavesPlusAlone() {
        let (path, _) = HTTPRequestParser.splitTarget("/a%20b+c")
        #expect(path == "/a b+c")
    }

    @Test func headerLookupIgnoresCase() {
        guard case .complete(let request, _) = HTTPRequestParser.parse(bytes(
            "GET / HTTP/1.1\r\nCONTENT-type: application/json\r\n\r\n")) else {
            Issue.record("didn't parse")
            return
        }
        #expect(request.headers["content-type"] == "application/json")
        #expect(request.headers["Content-Type"] == "application/json")
    }

    // MARK: - Refusals

    /// Without a cap, a peer that opens a connection and never sends `\r\n\r\n` grows this
    /// process's memory for as long as it likes.
    @Test func refusesAnOversizedHeaderBlock() {
        let padding = String(repeating: "x", count: HTTPRequestParser.maximumHeaderBytes + 1)
        let outcome = HTTPRequestParser.parse(bytes("GET / HTTP/1.1\r\nBig: \(padding)"))

        guard case .failed(let response) = outcome else {
            Issue.record("accepted an oversized header block")
            return
        }
        #expect(response.status == 431)
        #expect(response.closeConnection)
    }

    @Test func refusesAnOversizedBody() {
        let length = HTTPRequestParser.maximumBodyBytes + 1
        let outcome = HTTPRequestParser.parse(bytes(
            "POST /api/system HTTP/1.1\r\nContent-Length: \(length)\r\n\r\n"))

        guard case .failed(let response) = outcome else {
            Issue.record("accepted an oversized body")
            return
        }
        #expect(response.status == 413)
    }

    @Test(arguments: [
        "nonsense\r\n\r\n",
        "GET\r\n\r\n",
        "GET / HTTP/1.1\r\nNoColonHere\r\n\r\n",
        "GET / HTTP/1.1\r\n: emptyName\r\n\r\n",
        "GET / HTTP/1.1\r\nContent-Length: banana\r\n\r\n",
        "GET / HTTP/1.1\r\nContent-Length: -5\r\n\r\n",
    ])
    func refusesMalformedRequests(_ text: String) {
        guard case .failed(let response) = HTTPRequestParser.parse(bytes(text)) else {
            Issue.record("accepted malformed input: \(text.debugDescription)")
            return
        }
        #expect(response.status == 400)
        #expect(response.closeConnection)
    }

    /// Obsolete line folding is a known request-smuggling vector, so it's refused rather than
    /// reassembled.
    @Test func refusesFoldedHeaderLines() {
        let outcome = HTTPRequestParser.parse(bytes(
            "GET / HTTP/1.1\r\nX-Long: one\r\n  two\r\n\r\n"))

        guard case .failed(let response) = outcome else {
            Issue.record("accepted a folded header")
            return
        }
        #expect(response.status == 400)
    }

    /// Ignoring the header would mean reading chunk-length lines as the body.
    @Test func refusesChunkedEncoding() {
        let outcome = HTTPRequestParser.parse(bytes(
            "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"))

        guard case .failed(let response) = outcome else {
            Issue.record("accepted chunked encoding")
            return
        }
        #expect(response.status == 411)
    }

    @Test func refusesAbsoluteFormTargets() {
        let outcome = HTTPRequestParser.parse(bytes(
            "GET http://elsewhere/ HTTP/1.1\r\nHost: x\r\n\r\n"))

        guard case .failed(let response) = outcome else {
            Issue.record("accepted an absolute-form target")
            return
        }
        #expect(response.status == 400)
    }
}

struct HTTPResponseTests {

    @Test func serializesAStatusLineAndLength() {
        let response = HTTPResponse(status: 202,
                                    headers: HTTPHeaders([("X-Test", "1")]),
                                    body: Data("hello".utf8))
        let text = String(decoding: response.serialized(), as: UTF8.self)

        #expect(text.hasPrefix("HTTP/1.1 202 Accepted\r\n"))
        #expect(text.contains("Content-Length: 5\r\n"))
        #expect(text.contains("X-Test: 1\r\n"))
        #expect(text.hasSuffix("\r\n\r\nhello"))
    }

    /// A HEAD must carry the headers a GET would — `Content-Length` included — and no body.
    @Test func omitsTheBodyForHead() {
        let response = HTTPResponse(status: 200, body: Data("hello".utf8))
        let text = String(decoding: response.serialized(includeBody: false), as: UTF8.self)

        #expect(text.contains("Content-Length: 5\r\n"))
        #expect(text.hasSuffix("\r\n\r\n"))
    }

    @Test func signalsConnectionClose() {
        let open = HTTPResponse(status: 200)
        let closing = HTTPResponse(status: 400, closeConnection: true)

        #expect(String(decoding: open.serialized(), as: UTF8.self)
            .contains("Connection: keep-alive"))
        #expect(String(decoding: closing.serialized(), as: UTF8.self)
            .contains("Connection: close"))
    }

    @Test func errorsAreJSON() throws {
        let response = HTTPResponse.error(409, "Sample rates differ")
        let decoded = try JSONSerialization.jsonObject(with: response.body) as? [String: String]

        #expect(response.status == 409)
        #expect(decoded?["error"] == "Sample rates differ")
        #expect(response.headers["Content-Type"]?.hasPrefix("application/json") == true)
    }

    /// HTTP/1.1 keeps connections open unless told otherwise, so only an explicit `close` counts.
    @Test(arguments: [("close", false), ("keep-alive", true), ("Close", false),
                      ("keep-alive, Upgrade", true)])
    func readsTheConnectionHeader(_ value: String, _ expected: Bool) {
        guard case .complete(let request, _) = HTTPRequestParser.parse(bytes(
            "GET / HTTP/1.1\r\nConnection: \(value)\r\n\r\n")) else {
            Issue.record("didn't parse")
            return
        }
        #expect(request.wantsKeepAlive == expected)
    }

    @Test func defaultsToKeepAliveWithoutTheHeader() {
        guard case .complete(let request, _) = HTTPRequestParser.parse(bytes(
            "GET / HTTP/1.1\r\n\r\n")) else {
            Issue.record("didn't parse")
            return
        }
        #expect(request.wantsKeepAlive)
    }
}
