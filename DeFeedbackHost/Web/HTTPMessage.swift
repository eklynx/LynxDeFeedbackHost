//
//  HTTPMessage.swift
//  DeFeedbackHost
//
//  Created by Edgars Klepers on 9/20/2026.
//

import Foundation

/// Case-insensitive header storage, preserving the order and casing headers were written in.
///
/// A dictionary keyed by lowercased name would be simpler, but headers that may legitimately
/// repeat (`Set-Cookie`, and `Vary` in practice) would collapse into one. Nothing here sends
/// those yet; storing pairs means it won't be a silent bug when something does.
///
/// - AI was used heavily in creation of the core http server, as I didnt want to use a library to keep this lightweight.

nonisolated struct HTTPHeaders: Sendable, Equatable {

    private var fields: [(name: String, value: String)] = []

    init() {}

    init(_ pairs: [(String, String)]) {
        fields = pairs.map { (name: $0.0, value: $0.1) }
    }

    /// First value for `name`, matched without regard to case as RFC 9110 requires.
    subscript(name: String) -> String? {
        get {
            let wanted = name.lowercased()
            return fields.first { $0.name.lowercased() == wanted }?.value
        }
        set {
            let wanted = name.lowercased()
            fields.removeAll { $0.name.lowercased() == wanted }
            if let newValue {
                fields.append((name: name, value: newValue))
            }
        }
    }

    mutating func append(_ name: String, _ value: String) {
        fields.append((name: name, value: value))
    }

    var all: [(name: String, value: String)] { fields }

    static func == (lhs: HTTPHeaders, rhs: HTTPHeaders) -> Bool {
        lhs.fields.count == rhs.fields.count
            && zip(lhs.fields, rhs.fields).allSatisfy { $0.name == $1.name && $0.value == $1.value }
    }
}

nonisolated struct HTTPRequest: Sendable, Equatable {

    var method: String

    /// The request target exactly as it arrived, query string included.
    var target: String

    /// Percent-decoded path, without the query. Always begins with `/`.
    var path: String

    var query: [String: String]

    var headers: HTTPHeaders

    var body: Data

    var isFromLoopback = false

    var wantsKeepAlive: Bool {
        guard let connection = headers["Connection"] else { return true }
        return !connection.lowercased()
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .contains("close")
    }
}

nonisolated struct HTTPResponse: Sendable {

    var status: Int
    var reason: String
    var headers: HTTPHeaders
    var body: Data

    /// Set when the response is fatal to the connection — a parse failure, or a refusal that
    /// leaves unread bytes in the pipe that can't be attributed to a request.
    var closeConnection = false

    /// A response whose body is written afterwards, indefinitely, and whose length is therefore
    /// unknowable — the SSE stream.
    ///
    /// This has to suppress `Content-Length`. Sending `Content-Length: 0` and then writing events
    /// makes the client consider the response finished at byte zero and discard everything after
    /// it, which is exactly what happened before this existed.
    var isStreaming = false

    init(status: Int,
         reason: String? = nil,
         headers: HTTPHeaders = HTTPHeaders(),
         body: Data = Data(),
         closeConnection: Bool = false,
         isStreaming: Bool = false) {
        self.status = status
        self.reason = reason ?? Self.defaultReason(for: status)
        self.headers = headers
        self.body = body
        self.closeConnection = closeConnection
        self.isStreaming = isStreaming
    }

    static func defaultReason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 411: return "Length Required"
        case 413: return "Content Too Large"
        case 415: return "Unsupported Media Type"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 503: return "Service Unavailable"
        default: return "Status \(status)"
        }
    }

    /// - Parameter includeBody: false for a `HEAD`, which must carry the headers a `GET` would —
    ///   `Content-Length` included — but no body.
    func serialized(includeBody: Bool = true) -> Data {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        if isStreaming {
            // No framing header at all, which RFC 9112 §6.3 makes close-delimited: the body runs
            // until the connection ends. `Connection: close` states that plainly so the client
            // doesn't queue another request behind a response that never finishes. The socket
            // itself stays open for as long as events keep flowing.
            head += "Connection: close\r\n"
        } else {
            head += "Content-Length: \(body.count)\r\n"
            head += "Connection: \(closeConnection ? "close" : "keep-alive")\r\n"
        }
        for field in headers.all {
            head += "\(field.name): \(field.value)\r\n"
        }
        head += "\r\n"

        var data = Data(head.utf8)
        if includeBody {
            data.append(body)
        }
        return data
    }

    // MARK: - Convenience

    static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data(#"{"error":"could not encode response"}"#.utf8)
        return HTTPResponse(status: status,
                            headers: HTTPHeaders([("Content-Type", "application/json; charset=utf-8"),
                                                  ("Cache-Control", "no-store")]),
                            body: body)
    }

    /// Errors are JSON too, so the page's fetch handling has one shape to deal with.
    static func error(_ status: Int,
                      _ message: String,
                      headers extra: [(String, String)] = [],
                      closeConnection: Bool = false) -> HTTPResponse {
        var response = json(["error": message], status: status)
        for header in extra {
            response.headers.append(header.0, header.1)
        }
        response.closeConnection = closeConnection
        return response
    }

    static func html(_ body: Data) -> HTTPResponse {
        HTTPResponse(status: 200,
                     headers: HTTPHeaders([("Content-Type", "text/html; charset=utf-8"),
                                           // The page is served from the app bundle and changes
                                           // only when the app is replaced, but a stale cached
                                           // copy talking to a newer API is worse than a refetch.
                                           ("Cache-Control", "no-cache")]),
                     body: body)
    }
}

/// Incremental HTTP/1.1 request parsing.
///
/// Pure and synchronous — it is handed the bytes accumulated so far and says whether a request is
/// in there yet. That keeps every edge case (split packets, oversized headers, pipelining)
/// testable without a socket, which is most of why the server is shaped this way.
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

    static func parse(_ buffer: [UInt8]) -> Outcome {
        guard let headerEnd = indexAfterHeaderTerminator(in: buffer) else {
            if buffer.count > maximumHeaderBytes {
                return .failed(.error(431, "Header block exceeds \(maximumHeaderBytes) bytes",
                                      closeConnection: true))
            }
            return .incomplete
        }

        if headerEnd > maximumHeaderBytes {
            return .failed(.error(431, "Header block exceeds \(maximumHeaderBytes) bytes",
                                  closeConnection: true))
        }

        guard let headerText = String(bytes: buffer[0..<headerEnd], encoding: .utf8) else {
            return .failed(.error(400, "Header block is not valid UTF-8", closeConnection: true))
        }

        // The terminator's own CRLFCRLF is not part of any line.
        var lines = headerText.components(separatedBy: "\r\n")
        lines.removeLast(2)

        guard let requestLine = lines.first, !requestLine.isEmpty else {
            return .failed(.error(400, "Empty request line", closeConnection: true))
        }

        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3 else {
            return .failed(.error(400, "Malformed request line", closeConnection: true))
        }

        let method = String(parts[0])
        let target = String(parts[1])
        let version = String(parts[2])

        guard version.hasPrefix("HTTP/1.") else {
            return .failed(.error(505, "Only HTTP/1.x is supported", closeConnection: true))
        }
        guard target.hasPrefix("/") else {
            // Absolute-form targets are only required of proxies, which this is not.
            return .failed(.error(400, "Request target must be origin-form", closeConnection: true))
        }

        var headers = HTTPHeaders()
        for line in lines.dropFirst() {
            // Obsolete line folding: a continuation begins with whitespace. Deprecated by RFC 9112
            // and a known request-smuggling vector, so it's rejected rather than reassembled.
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                return .failed(.error(400, "Obsolete header line folding", closeConnection: true))
            }
            guard let colon = line.firstIndex(of: ":") else {
                return .failed(.error(400, "Malformed header line", closeConnection: true))
            }
            let name = String(line[line.startIndex..<colon])
            guard !name.isEmpty, !name.hasSuffix(" "), !name.hasSuffix("\t") else {
                return .failed(.error(400, "Malformed header name", closeConnection: true))
            }
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            headers.append(name, value)
        }

        // Not supported, and silently ignoring the header would mean misreading the body.
        if let encoding = headers["Transfer-Encoding"], !encoding.isEmpty {
            return .failed(.error(411, "Chunked transfer encoding is not supported",
                                  closeConnection: true))
        }

        var bodyLength = 0
        if let raw = headers["Content-Length"] {
            guard let length = Int(raw.trimmingCharacters(in: .whitespaces)), length >= 0 else {
                return .failed(.error(400, "Malformed Content-Length", closeConnection: true))
            }
            guard length <= maximumBodyBytes else {
                return .failed(.error(413, "Body exceeds \(maximumBodyBytes) bytes",
                                      closeConnection: true))
            }
            bodyLength = length
        }

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
    }

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
