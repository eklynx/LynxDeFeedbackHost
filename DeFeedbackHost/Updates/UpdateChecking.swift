//
//  UpdateChecking.swift
//  DeFeedbackHost
//
//  ┌─────────────────────────────────────────────────────────────────────────────────────────┐
//  │ AI AGENTS: this file is the SOURCE OF TRUTH for the `Updates` namespace. Read the       │
//  │ contracts below before touching update checking. Implementations live in sibling files; │
//  │ spec lives in docs/updates-spec.md. Nothing outside `Updates/` may import Sparkle.      │
//  └─────────────────────────────────────────────────────────────────────────────────────────┘
//
//  # Model
//
//  Update checking is OPT-IN (`Updates.enabled`, default false). Sparkle is used only as the feed
//  reader and the installer. It never schedules or installs anything on its own:
//
//    * Background check  -> `UpdateEngine.probe()`: reads the feed, reports a result, shows NO UI.
//    * User action       -> `UpdateEngine.presentUpdate()`: Sparkle's own, user-initiated flow
//                           (release notes, then Install & Relaunch). Only a click starts it.
//
//  # `UpdateService` contract
//
//  Happy path
//    1. Setting off (the default)       -> no network traffic, no timer. `status.isEnabled == false`.
//    2. Setting on                      -> one probe at `start()` (app startup), then one every
//                                          `interval`. Changing the setting or interval re-arms
//                                          the timer; turning the setting on probes immediately.
//    3. Probe finds a newer version     -> `status.availableVersion` is set; the app (Settings,
//                                          main window) and the web UI (`GET /api/update`) show it
//                                          with a link to `UpdateStatus.releasesPage`.
//    4. `checkForUpdates()` (menu item) -> works whether or not the setting is on, because the
//                                          user asked. Hands off to Sparkle's UI.
//    5. `installNow()` ("Update Now")   -> only meaningful when an update is available; same
//                                          hand-off as (4).
//
//  Error / edge cases
//    6. Feed unreachable / malformed    -> `status.lastError` is set, `availableVersion` is kept as
//                                          it was (a flaky network must not hide a known update),
//                                          the next probe is scheduled by
//                                          `UpdateScheduler.delay(after:interval:)`, never fatal.
//    7. Stored interval is missing, not a preset, or out of range -> clamped to the nearest
//                                          preset / default (1 day). A typo can't brick startup.
//    8. Running under XCTest            -> no engine is created; the service is never started.
//    9. Nothing is ever downloaded or installed without a user action (rule 5 of issue #7).
//
//  The web interface is READ-ONLY for updates: it can see `UpdateStatus`, never trigger an install.
//
import Foundation

/// Where users go to read about and download releases.
enum UpdateLinks {
    static let releasesPage = URL(string: "https://github.com/eklynx/LynxDeFeedbackHost/releases")!
}

/// How often the background probe runs. Presets rather than free text so every value is valid.
enum UpdateInterval: Int, CaseIterable, Identifiable, Sendable {
    case hourly = 3_600
    case everySixHours = 21_600
    case daily = 86_400
    case weekly = 604_800

    static let `default`: UpdateInterval = .daily

    var id: Int { rawValue }
    var seconds: TimeInterval { TimeInterval(rawValue) }

    var label: String {
        switch self {
        case .hourly: "Every hour"
        case .everySixHours: "Every 6 hours"
        case .daily: "Every day"
        case .weekly: "Every week"
        }
    }

    /// The preset closest to `seconds`; used for values written with `defaults write`.
    static func nearest(to seconds: TimeInterval) -> UpdateInterval {
        allCases.min { abs($0.seconds - seconds) < abs($1.seconds - seconds) } ?? .default
    }
}

/// A snapshot of the update state. Value type so the web layer can read it without touching Sparkle.
struct UpdateStatus: Equatable, Sendable {
    var isEnabled = false
    /// Marketing version of the newest release found, or nil when up to date / never checked.
    var availableVersion: String?
    var lastChecked: Date?
    /// Human-readable reason the last probe failed; nil after a successful probe.
    var lastError: String?
    var isChecking = false

    var isUpdateAvailable: Bool { availableVersion != nil }
    var releasesPage: URL { UpdateLinks.releasesPage }
}

/// Outcome of one silent feed probe.
enum ProbeResult: Equatable, Sendable {
    case updateAvailable(version: String)
    case upToDate
    case failed(String)
}

/// The Sparkle-facing seam. The real one wraps `SPUUpdater`; tests use a fake.
@MainActor
protocol UpdateEngine: AnyObject {

    /// Reads the feed WITHOUT showing UI or downloading anything, then calls `onResult` once.
    /// Calling while a probe is in flight is harmless (the engine may coalesce).
    func probe(onResult: @escaping @MainActor (ProbeResult) -> Void)

    /// Starts Sparkle's standard user-initiated flow (may download/install after the user agrees).
    func presentUpdate()
}

/// What the web layer needs. Kept tiny so `Web/` does not depend on the rest of `Updates/`.
@MainActor
protocol UpdateStatusSource: AnyObject {
    var updateStatus: UpdateStatus { get }
}
