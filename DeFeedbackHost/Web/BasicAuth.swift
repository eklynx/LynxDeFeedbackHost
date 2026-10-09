//
//  BasicAuth.swift
//  DeFeedbackHost
//
//  Created by Edgars Klepers on 9/20/2026.
//

import Foundation

/// HTTP Basic authentication for the control endpoint (RFC 7617).
///
/// Basic rather than a token or a session cookie because the browser handles it: it shows its own
/// sign-in sheet on the 401 and then attaches the header to everything afterwards, including the
/// `EventSource` request — which cannot carry custom headers, and so rules out a bearer token
/// without also inventing a cookie and a CSRF defence for it.
///
/// **This is cleartext on the wire using basic auth. This is only to keep prying eyes and fingers away, not to ward off any half-way serious attack**
///
/// - AI was used heavily in creation of the core http server, as I didnt want to use a library to keep this lightweight.

nonisolated enum BasicAuth {

    static let realm = "DeFeedback Host"

    struct Credentials: Equatable, Sendable {
        var username: String
        var password: String
    }

    /// Decodes an `Authorization: Basic …` header. Returns nil for anything absent, malformed, or
    /// using a different scheme.
    static func parse(_ header: String?) -> Credentials? {
        guard let header else { return nil }

        let parts = header.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2,
              parts[0].lowercased() == "basic",
              let decoded = Data(base64Encoded: String(parts[1]).trimmingCharacters(in: .whitespaces))
        else { return nil }

        // RFC 7617 says UTF-8; some clients send Latin-1. Fallback instead of reject outright.
        let text = String(data: decoded, encoding: .utf8)
            ?? String(decoding: decoded, as: UTF8.self)

        // The password may itself contain a colon; the username may not.
        guard let separator = text.firstIndex(of: ":") else { return nil }

        return Credentials(username: String(text[text.startIndex..<separator]),
                           password: String(text[text.index(after: separator)...]))
    }

    static func matches(_ provided: Credentials?,
                        username: String,
                        password: String) -> Bool {
        guard let provided else { return false }

        // If we actually cared about auth, we'd make sure we try to make timing equal between a fail
        // and success case, verifying equals on both first, and using a special equality checker that
        // assures equal processing time.
        return provided.username == username && provided.password == password
    }


    /// The 401 that makes a browser prompt for credentials.
    static func challenge() -> HTTPResponse {
        .error(401,
               "Authentication required",
               headers: [("WWW-Authenticate", "Basic realm=\"\(realm)\", charset=\"UTF-8\"")])
    }
}

extension BasicAuth {

    /// The credentials currently being used.  This keeps a cached copy instead of looking up every request.
    /// Refreshed by `WebControlService.reconcile()`.
    nonisolated final class Guard: @unchecked Sendable {

        private let lock = NSLock()
        private var required: Credentials?
        private var allowLoopback = false

        func require(_ credentials: Credentials?, allowingLoopback: Bool = false) {
            lock.withLock {
                required = credentials
                allowLoopback = allowingLoopback
            }
        }

        func reject(_ request: HTTPRequest) -> HTTPResponse? {
            let (required, allowLoopback) = lock.withLock { (required, allowLoopback) }
            guard let required else { return nil }

            if allowLoopback, Self.isTrustedLocal(request) {
                return nil
            }

            let offered = BasicAuth.parse(request.headers["Authorization"])
            guard BasicAuth.matches(offered,
                                    username: required.username,
                                    password: required.password) else {
                return BasicAuth.challenge()
            }
            return nil
        }

        /// Check Host and Origin headers just in case it is a malicous page trying to get in.
        static func isTrustedLocal(_ request: HTTPRequest) -> Bool {
            guard request.isFromLoopback,
                  let host = request.headers["Host"],
                  isLocalHostName(extractHostName(fromHostHeader: host))
            else { return false }

            if let origin = request.headers["Origin"] {
                guard let originHost = URL(string: origin)?.host,
                      isLocalHostName(originHost)
                else { return false }
            }
            return true
        }

        /// Strips the port from a `Host` header value, keeping IPv6 literals intact.
        static func extractHostName(fromHostHeader value: String) -> String {
            let value = value.trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("["), let close = value.firstIndex(of: "]") {
                return String(value[value.index(after: value.startIndex)..<close])
            }
            return String(value.split(separator: ":", maxSplits: 1).first ?? "")
        }

        static func isLocalHostName(_ name: String) -> Bool {
            let name = name.lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            return name == "localhost" || name == "127.0.0.1" || name == "::1"
        }
    }
}
