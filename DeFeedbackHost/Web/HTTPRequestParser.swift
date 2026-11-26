//
//  HTTPRequestParser.swift
//  DeFeedbackHost
//
//  Created by Edgars Klepers on 9/20/2026.
//

import Foundation

/// Incremental HTTP/1.1 request parsing.
///
/// Pure and synchronous — it is handed the bytes accumulated so far and says whether a request is
/// in there yet. That keeps every edge case (split packets, oversized headers, pipelining)
/// testable without a socket, which is most of why the server is shaped this way.
///
/// `parse` reads as the list of checks a request must pass, in the order they run. Each stage is a
/// small function that either returns what it found or throws a `Refusal`, which `parse` turns
/// into the one `.failed` outcome. The order matters — when a request is wrong in two ways, the
/// earlier check names the problem — and `HTTPParserCharacterizationTests` pins it.
///
/// - AI was used heavily in creation of the core http server, as I didnt want to use a library to keep this lightweight.
nonisolated enum HTTPRequestParser {

    /// Caps, because a listener on the network must not let a peer grow this process's memory by
    /// simply never sending `\r\n\r\n`.
    static let maximumHeaderBytes = 16 * 1024
    static let maximumBodyBytes = 64 * 1024

    enum Outcome {
        /// Nothing complete yet, and nothing wrong — wait for more bytes.
        case incomplete

        /// A request, plus how many bytes of the buffer it used, so anything pipelined behind it
        /// stays in the buffer for the next pass.
        case complete(HTTPRequest, consumed: Int)

        /// Unparseable or over a cap. The response is ready to send, after which the connection
        /// has to close: the framing is no longer trustworthy, so the next byte can't be located.
        case failed(HTTPResponse)
    }

    /// A stage's verdict that the request can't be served: the response to send, which always
    /// closes the connection.
    private struct Refusal: Error {
        let response: HTTPResponse

        init(_ status: Int, _ message: String) {
            response = .error(status, message, closeConnection: true)
        }
    }

    static func parse(_ buffer: [UInt8]) -> Outcome {
        do throws(Refusal) {
            guard let headerEnd = try headerBlockEnd(in: buffer) else { return .incomplete }

            let lines = try headerLines(in: buffer, upTo: headerEnd)
            let (method, target) = try requestLine(lines.first ?? "")
            let headers = try headerFields(lines.dropFirst())
            try refuseTransferEncoding(in: headers)
            let bodyLength = try declaredBodyLength(in: headers)

            let total = headerEnd + bodyLength
            guard buffer.count >= total else { return .incomplete }

            let (path, query) = splitTarget(target)

            return .complete(HTTPRequest(method: method,
                                         target: target,
                                         path: path,
                                         query: query,
                                         headers: headers,
                                         body: Data(buffer[headerEnd..<total])),
                             consumed: total)
        } catch {
            return .failed(error.response)
        }
    }

    // MARK: - Stages

    /// Where the header block ends, or nil if its terminator hasn't arrived yet.
    private static func headerBlockEnd(in buffer: [UInt8]) throws(Refusal) -> Int? {
        guard let end = indexAfterHeaderTerminator(in: buffer) else {
            if buffer.count > maximumHeaderBytes { throw headerBlockTooLarge }
            return nil
        }
        if end > maximumHeaderBytes { throw headerBlockTooLarge }
        return end
    }

    private static var headerBlockTooLarge: Refusal {
        Refusal(431, "Header block exceeds \(maximumHeaderBytes) bytes")
    }

    /// The request line and header lines, without the terminator's own `CRLFCRLF`.
    private static func headerLines(in buffer: [UInt8], upTo end: Int) throws(Refusal) -> [String] {
        guard let text = String(bytes: buffer[0..<end], encoding: .utf8) else {
            throw Refusal(400, "Header block is not valid UTF-8")
        }
        var lines = text.components(separatedBy: "\r\n")
        lines.removeLast(2)
        return lines
    }

    private static func requestLine(_ line: String) throws(Refusal) -> (method: String, target: String) {
        guard !line.isEmpty else { throw Refusal(400, "Empty request line") }

        let parts = line.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw Refusal(400, "Malformed request line") }

        guard parts[2].hasPrefix("HTTP/1.") else {
            throw Refusal(505, "Only HTTP/1.x is supported")
        }
        guard parts[1].hasPrefix("/") else {
            // Absolute-form targets are only required of proxies, which this is not.
            throw Refusal(400, "Request target must be origin-form")
        }
        return (String(parts[0]), String(parts[1]))
    }

    private static func headerFields(_ lines: ArraySlice<String>) throws(Refusal) -> HTTPHeaders {
        var headers = HTTPHeaders()
        for line in lines {
            let (name, value) = try headerField(line)
            headers.append(name, value)
        }
        return headers
    }

    private static func headerField(_ line: String) throws(Refusal) -> (name: String, value: String) {
        // Obsolete line folding: a continuation begins with whitespace. Deprecated by RFC 9112
        // and a known request-smuggling vector, so it's rejected rather than reassembled.
        if line.hasPrefix(" ") || line.hasPrefix("\t") {
            throw Refusal(400, "Obsolete header line folding")
        }
        guard let colon = line.firstIndex(of: ":") else {
            throw Refusal(400, "Malformed header line")
        }
        let name = String(line[line.startIndex..<colon])
        guard !name.isEmpty, !name.hasSuffix(" "), !name.hasSuffix("\t") else {
            throw Refusal(400, "Malformed header name")
        }
        let value = String(line[line.index(after: colon)...])
            .trimmingCharacters(in: .whitespaces)
        return (name, value)
    }

    /// Not supported, and silently ignoring the header would mean misreading the body.
    private static func refuseTransferEncoding(in headers: HTTPHeaders) throws(Refusal) {
        if let encoding = headers["Transfer-Encoding"], !encoding.isEmpty {
            throw Refusal(411, "Chunked transfer encoding is not supported")
        }
    }

    private static func declaredBodyLength(in headers: HTTPHeaders) throws(Refusal) -> Int {
        guard let raw = headers["Content-Length"] else { return 0 }
        guard let length = Int(raw.trimmingCharacters(in: .whitespaces)), length >= 0 else {
            throw Refusal(400, "Malformed Content-Length")
        }
        guard length <= maximumBodyBytes else {
            throw Refusal(413, "Body exceeds \(maximumBodyBytes) bytes")
        }
        return length
    }

    // MARK: - Helpers

    /// Index one past the `CRLFCRLF` that ends the header block, or nil if it isn't there yet.
    private static func indexAfterHeaderTerminator(in buffer: [UInt8]) -> Int? {
        guard buffer.count >= 4 else { return nil }
        let cr = UInt8(ascii: "\r"), lf = UInt8(ascii: "\n")
        for index in 0...(buffer.count - 4) where buffer[index] == cr {
            if buffer[index + 1] == lf, buffer[index + 2] == cr, buffer[index + 3] == lf {
                return index + 4
            }
        }
        return nil
    }

    /// Splits an origin-form target into a percent-decoded path and its query parameters.
    ///
    /// A path that won't percent-decode keeps its raw form rather than failing the request: it
    /// will simply match no route and get a 404, which is the right answer for it anyway.
    static func splitTarget(_ target: String) -> (path: String, query: [String: String]) {
        let head: Substring
        let tail: Substring
        if let mark = target.firstIndex(of: "?") {
            head = target[target.startIndex..<mark]
            tail = target[target.index(after: mark)...]
        } else {
            head = target[...]
            tail = ""
        }

        var query: [String: String] = [:]
        for pair in tail.split(separator: "&") where !pair.isEmpty {
            let pieces = pair.split(separator: "=", maxSplits: 1)
            let name = percentDecoded(String(pieces[0]), plusIsSpace: true)
            let value = pieces.count > 1
                ? percentDecoded(String(pieces[1]), plusIsSpace: true)
                : ""
            query[name] = value
        }

        return (percentDecoded(String(head), plusIsSpace: false), query)
    }

    /// - Parameter plusIsSpace: `+` means a space in `application/x-www-form-urlencoded` query
    ///   strings but is a literal `+` in a path. Decoding both the same way is the usual source
    ///   of that bug, so the caller has to say which one it has.
    private static func percentDecoded(_ text: String, plusIsSpace: Bool) -> String {
        let prepared = plusIsSpace ? text.replacingOccurrences(of: "+", with: " ") : text
        return prepared.removingPercentEncoding ?? prepared
    }
}
