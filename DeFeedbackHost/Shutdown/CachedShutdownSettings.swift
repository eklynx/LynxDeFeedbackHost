//
//  CachedShutdownSettings.swift
//  DeFeedbackHost
//
//  A short-lived read-through cache over any `ShutdownSettings`, for DISPLAY only. The web status
//  snapshot is rebuilt several times a second; this keeps it from reading the three defaults keys
//  on every rebuild. Contract: ShutdownSettings.swift.
//
//  - All three values come from one snapshot, so a client never sees a half-updated mix.
//  - A snapshot is at most `maxAge` old (one second by default), so a change made in the settings
//    screen or with `defaults write` reaches the status within about a second.
//  - Never use this for a decision. The shutdown command checks the live settings, so a value
//    that changed a moment ago can never be acted on in its old form.
//
import Foundation

@MainActor
final class CachedShutdownSettings: ShutdownSettings {

    private struct Snapshot {
        let takenAt: Date
        let isEnabled: Bool
        let isTestMode: Bool
        let phrase: String
    }

    private let source: ShutdownSettings
    private let maxAge: TimeInterval
    private let now: () -> Date
    private var snapshot: Snapshot?

    init(_ source: ShutdownSettings, maxAge: TimeInterval = 1, now: @escaping () -> Date = { Date() }) {
        self.source = source
        self.maxAge = maxAge
        self.now = now
    }

    var isEnabled: Bool { current().isEnabled }
    var isTestMode: Bool { current().isTestMode }
    var phrase: String { current().phrase }

    private func current() -> Snapshot {
        let time = now()
        if let snapshot, time.timeIntervalSince(snapshot.takenAt) < maxAge, time >= snapshot.takenAt {
            return snapshot
        }
        let fresh = Snapshot(takenAt: time, isEnabled: source.isEnabled, isTestMode: source.isTestMode,
                             phrase: source.phrase)
        snapshot = fresh
        return fresh
    }
}
