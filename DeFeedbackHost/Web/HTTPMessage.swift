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

    private static let reasonPhrases: [Int: String] = [
        200: "OK",
        201: "Created",
        202: "Accepted",
        204: "No Content",
        400: "Bad Request",
        401: "Unauthorized",
        404: "Not Found",
        405: "Method Not Allowed",
        409: "Conflict",
        411: "Length Required",
        413: "Content Too Large",
        415: "Unsupported Media Type",
        431: "Request Header Fields Too Large",
        500: "Internal Server Error",
        501: "Not Implemented",
        503: "Service Unavailable"
    ]

    static func defaultReason(for status: Int) -> String {
        reasonPhrases[status] ?? "Status \(status)"
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
