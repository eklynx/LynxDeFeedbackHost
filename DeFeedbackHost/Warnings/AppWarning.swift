//
//  AppWarning.swift
//  DeFeedbackHost
//
//  ┌─────────────────────────────────────────────────────────────────────────────────────────┐
//  │ AI AGENTS: this file is the SOURCE OF TRUTH for the `Warnings` namespace. A warning is  │
//  │ something the user should know about that isn't an error from a command they just ran.  │
//  └─────────────────────────────────────────────────────────────────────────────────────────┘
//
//  # Model
//
//  Features that have something to say (an update is available, a permission is missing) conform
//  to `WarningSource`. The web layer collects every source into the `warnings` array of
//  `GET /api/status` (and the `status` event), so the web page needs no feature-specific code,
//  and a warning disappears from the page as soon as its source stops reporting it.
//
//  Happy path
//    1. Nothing to report          -> `warnings` is empty; the web page shows no banner.
//    2. A source has a problem     -> it returns one `AppWarning` with a STABLE `id`, so clients can
//                                     key on it. Same condition, same id, every time.
//    3. The condition clears       -> the source stops returning it. Nothing else to do.
//
//  Error / edge cases
//    4. Unknown state              -> a source reports NOTHING rather than a guess.
//    5. `link`                     -> https only. The web page can open a web page but not System
//                                     Settings, so System Settings shortcuts live in the native UI.
//    6. Ids in use                 -> `update`, `permission.microphone`, `permission.localNetwork`,
//                                     `permission.loginItems`, `permission.automation`,
//                                     `streamDeckPlugin.outOfDate`, `streamDeckPlugin.incompatible`.
//    7. `severity`                 -> `warning` (the default) is something to fix when convenient;
//                                     `error` is something that is broken now (an installed Stream Deck
//                                     plugin that can't work with this app). Clients that don't know
//                                     a severity treat it as `warning`.
//
import Foundation

struct AppWarning: Equatable, Sendable {

    enum Kind: String, Sendable {
        case updateAvailable = "update"
        case permission
        case streamDeckPlugin
    }

    enum Severity: String, Sendable {
        case warning
        case error
    }

    let id: String
    let kind: Kind
    let severity: Severity
    let message: String
    /// Optional https link with a label, e.g. the release notes for an update.
    let link: URL?
    let linkTitle: String?

    init(id: String, kind: Kind, severity: Severity = .warning, message: String,
         link: URL? = nil, linkTitle: String? = nil) {
        self.id = id
        self.kind = kind
        self.severity = severity
        self.message = message
        self.link = link
        self.linkTitle = linkTitle
    }

    /// The JSON shape used in `GET /api/status` (see the `Warning` schema in openapi.yaml).
    var jsonObject: [String: Any] {
        [
            "id": id,
            "kind": kind.rawValue,
            "severity": severity.rawValue,
            "message": message,
            "link": link?.absoluteString ?? NSNull(),
            "linkTitle": linkTitle ?? NSNull()
        ]
    }
}

@MainActor
protocol WarningSource: AnyObject {
    /// The warnings that apply right now. Cheap and side-effect free; called on every status build.
    var warnings: [AppWarning] { get }
}
