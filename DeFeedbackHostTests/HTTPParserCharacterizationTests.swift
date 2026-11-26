//
//  HTTPParserCharacterizationTests.swift
//  DeFeedbackHostTests
//
//  Pins today's behaviour of `HTTPRequestParser.parse` and `HTTPResponse.defaultReason` at the
//  edges `HTTPMessageTests` doesn't reach: which refusal wins when a request is wrong in two ways,
//  the exact messages, and the size boundaries. Written before the parser was split into stages
//  (issue #41) so the split can be shown to change nothing.
//
//  - Tests initially created with AI with human edits, but all reviewed by human

import Foundation
import Testing

@testable import DeFeedbackHost

private func bytes(_ text: String) -> [UInt8] {
    Array(text.utf8)
}

/// The refusal for `input`, or nil if it was accepted or is still incomplete.
private func refusal(_ input: [UInt8]) -> (status: Int, message: String, closes: Bool)? {
    guard case .failed(let response) = HTTPRequestParser.parse(input) else { return nil }
    let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: String]
    return (response.status, object?["error"] ?? "", response.closeConnection)
}

private func refusal(_ text: String) -> (status: Int, message: String, closes: Bool)? {
    refusal(bytes(text))
}

struct HTTPParserCharacterizationTests {

    // MARK: - Request line

    @Test func refusesAnEmptyRequestLine() {
        let result = refusal("\r\nHost: x\r\n\r\n")
        #expect(result?.status == 400)
        #expect(result?.message == "Empty request line")
        #expect(result?.closes == true)
    }

    @Test(arguments: ["GET /  HTTP/1.1\r\n\r\n", "GET / HTTP/1.1 extra\r\n\r\n", "GET /\r\n\r\n"])
    func refusesARequestLineThatIsNotThreeParts(_ text: String) {
        let result = refusal(text)
        #expect(result?.status == 400)
        #expect(result?.message == "Malformed request line")
    }

    @Test(arguments: ["HTTP/2.0", "HTTP/0.9", "SPDY/3", "http/1.1"])
    func refusesAnythingButHTTP1(_ version: String) {
        let result = refusal("GET / \(version)\r\n\r\n")
        #expect(result?.status == 505)
        #expect(result?.message == "Only HTTP/1.x is supported")
        #expect(result?.closes == true)
    }

    @Test(arguments: ["HTTP/1.0", "HTTP/1.1", "HTTP/1.9"])
    func acceptsAnyHTTP1Minor(_ version: String) {
        guard case .complete = HTTPRequestParser.parse(bytes("GET / \(version)\r\n\r\n")) else {
            Issue.record("refused \(version)")
            return
        }
    }

    @Test func refusesAnOriginFormViolationWithAMessage() {
        let result = refusal("GET nowhere HTTP/1.1\r\n\r\n")
        #expect(result?.status == 400)
        #expect(result?.message == "Request target must be origin-form")
    }

    // MARK: - Order of refusals

    @Test func versionIsCheckedBeforeTheTarget() {
        #expect(refusal("GET nowhere HTTP/2.0\r\n\r\n")?.status == 505)
    }

    @Test func requestLineIsCheckedBeforeHeaders() {
        #expect(refusal("nonsense\r\nNoColon\r\n\r\n")?.message == "Malformed request line")
    }

    @Test func foldingIsCheckedBeforeTheMissingColon() {
        let result = refusal("GET / HTTP/1.1\r\n folded without colon\r\n\r\n")
        #expect(result?.message == "Obsolete header line folding")
    }

    @Test func aBadHeaderLineWinsOverChunking() {
        let result = refusal("POST / HTTP/1.1\r\nNoColon\r\nTransfer-Encoding: chunked\r\n\r\n")
        #expect(result?.message == "Malformed header line")
    }

    @Test func chunkingIsRefusedBeforeAContentLengthIsRead() {
        let result = refusal(
            "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\nContent-Length: banana\r\n\r\n")
        #expect(result?.status == 411)
        #expect(result?.message == "Chunked transfer encoding is not supported")
    }

    // MARK: - Headers

    @Test func refusesANonUTF8HeaderBlock() {
        var input = bytes("GET / HTTP/1.1\r\nX: ")
        input.append(0xFF)
        input.append(contentsOf: bytes("\r\n\r\n"))

        let result = refusal(input)
        #expect(result?.status == 400)
        #expect(result?.message == "Header block is not valid UTF-8")
    }

    @Test func refusesTabFolding() {
        #expect(refusal("GET / HTTP/1.1\r\nX: a\r\n\tb\r\n\r\n")?.message
                == "Obsolete header line folding")
    }

    @Test(arguments: ["Name : value", "Name\t: value", ": value"])
    func refusesAMalformedHeaderName(_ line: String) {
        let result = refusal("GET / HTTP/1.1\r\n\(line)\r\n\r\n")
        #expect(result?.status == 400)
        #expect(result?.message == "Malformed header name")
    }

    @Test func refusesAHeaderWithoutAColon() {
        #expect(refusal("GET / HTTP/1.1\r\nNoColonHere\r\n\r\n")?.message == "Malformed header line")
    }

    @Test func trimsHeaderValuesAndKeepsTheirOrder() throws {
        let input = bytes("GET / HTTP/1.1\r\nA:  one \r\nB:two\r\nA: three\r\n\r\n")
        guard case .complete(let request, _) = HTTPRequestParser.parse(input) else {
            Issue.record("refused a plain request")
            return
        }
        #expect(request.headers["A"] == "one")
        #expect(request.headers["B"] == "two")
        #expect(request.headers.all.map(\.value) == ["one", "two", "three"])
    }

    @Test func anEmptyTransferEncodingIsIgnored() {
        guard case .complete = HTTPRequestParser.parse(bytes(
            "GET / HTTP/1.1\r\nTransfer-Encoding:\r\n\r\n")) else {
            Issue.record("refused an empty Transfer-Encoding")
            return
        }
    }

    // MARK: - Content-Length

    @Test func contentLengthIsTrimmedAndAccepted() throws {
        let input = bytes("POST / HTTP/1.1\r\nContent-Length:  5 \r\n\r\nhello")
        guard case .complete(let request, let consumed) = HTTPRequestParser.parse(input) else {
            Issue.record("refused a padded Content-Length")
            return
        }
        #expect(request.body == Data("hello".utf8))
        #expect(consumed == input.count)
    }

    @Test func zeroContentLengthMeansNoBody() throws {
        guard case .complete(let request, _) = HTTPRequestParser.parse(bytes(
            "POST / HTTP/1.1\r\nContent-Length: 0\r\n\r\n")) else {
            Issue.record("refused Content-Length 0")
            return
        }
        #expect(request.body.isEmpty)
    }

    @Test func malformedContentLengthHasAMessage() {
        let result = refusal("POST / HTTP/1.1\r\nContent-Length: 1.5\r\n\r\n")
        #expect(result?.status == 400)
        #expect(result?.message == "Malformed Content-Length")
    }

    @Test func aBodyExactlyAtTheCapIsAccepted() {
        let max = HTTPRequestParser.maximumBodyBytes
        let input = bytes("POST / HTTP/1.1\r\nContent-Length: \(max)\r\n\r\n")
            + [UInt8](repeating: 0x61, count: max)
        guard case .complete(let request, _) = HTTPRequestParser.parse(input) else {
            Issue.record("refused a body at the cap")
            return
        }
        #expect(request.body.count == max)
    }

    @Test func aBodyOverTheCapHasAMessage() {
        let max = HTTPRequestParser.maximumBodyBytes
        let result = refusal("POST / HTTP/1.1\r\nContent-Length: \(max + 1)\r\n\r\n")
        #expect(result?.status == 413)
        #expect(result?.message == "Body exceeds \(max) bytes")
    }

    @Test func aDeclaredBodyThatHasNotArrivedIsIncomplete() {
        guard case .incomplete = HTTPRequestParser.parse(bytes(
            "POST / HTTP/1.1\r\nContent-Length: 10\r\n\r\nabc")) else {
            Issue.record("did not wait for the rest of the body")
            return
        }
    }

    // MARK: - Header block size

    @Test func aHeaderBlockExactlyAtTheCapIsAccepted() {
        let max = HTTPRequestParser.maximumHeaderBytes
        let prefix = "GET / HTTP/1.1\r\nX: "
        let padding = String(repeating: "x", count: max - prefix.utf8.count - 4)
        guard case .complete = HTTPRequestParser.parse(bytes(prefix + padding + "\r\n\r\n")) else {
            Issue.record("refused a header block at the cap")
            return
        }
    }

    @Test func aTerminatedHeaderBlockOverTheCapIsRefused() {
        let max = HTTPRequestParser.maximumHeaderBytes
        let padding = String(repeating: "x", count: max)
        let result = refusal("GET / HTTP/1.1\r\nX: \(padding)\r\n\r\n")
        #expect(result?.status == 431)
        #expect(result?.message == "Header block exceeds \(max) bytes")
        #expect(result?.closes == true)
    }

    @Test func anUnterminatedBlockUnderTheCapWaits() {
        guard case .incomplete = HTTPRequestParser.parse(bytes("GET / HTTP/1.1\r\nHost: x\r\n")) else {
            Issue.record("did not wait")
            return
        }
    }

    // MARK: - Reason phrases

    @Test(arguments: [
        (200, "OK"), (201, "Created"), (202, "Accepted"), (204, "No Content"),
        (400, "Bad Request"), (401, "Unauthorized"), (404, "Not Found"),
        (405, "Method Not Allowed"), (409, "Conflict"), (411, "Length Required"),
        (413, "Content Too Large"), (415, "Unsupported Media Type"),
        (431, "Request Header Fields Too Large"), (500, "Internal Server Error"),
        (501, "Not Implemented"), (503, "Service Unavailable"),
        (799, "Status 799"), (505, "Status 505"),
    ])
    func defaultReasonPhrases(_ status: Int, _ phrase: String) {
        #expect(HTTPResponse.defaultReason(for: status) == phrase)
        #expect(HTTPResponse(status: status).reason == phrase)
    }

    @Test func anExplicitReasonWinsOverTheDefault() {
        #expect(HTTPResponse(status: 200, reason: "Fine").reason == "Fine")
    }
}
