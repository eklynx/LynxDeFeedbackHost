//
//  LifecycleTuning.swift
//  DeFeedbackHost
//
//  Timings for the single-instance heartbeat and stale-holder takeover, overridable from the CLI.
//  Contract context: LaunchSupervision.swift (edge case 6).
//
//  Each value is its own UserDefaults key (unlike the HostSettings JSON blob), so:
//
//      defaults read  com.eklynx.sound.DeFeedbackHost Lifecycle.staleAfter
//      defaults write com.eklynx.sound.DeFeedbackHost Lifecycle.staleAfter -float 30
//      defaults delete com.eklynx.sound.DeFeedbackHost Lifecycle.staleAfter     # back to default
//
//  Changes apply on the next app launch (the heartbeat timer is created at startup).
//  Out-of-range or inconsistent values are clamped, never rejected, so a typo can't brick startup.
//
import Foundation

struct LifecycleTuning: Equatable {

    enum Key {
        static let heartbeatInterval = "Lifecycle.heartbeatInterval"
        static let staleAfter = "Lifecycle.staleAfter"
        static let strikesBeforeKill = "Lifecycle.strikesBeforeKill"
    }

    static let defaultHeartbeatInterval: TimeInterval = 2
    static let defaultStaleAfter: TimeInterval = 15
    static let defaultStrikesBeforeKill = 3

    /// Seconds between holder heartbeats (0.5 ... 60).
    var heartbeatInterval: TimeInterval = defaultHeartbeatInterval
    /// Seconds without a heartbeat before a holder counts as hung. Always >= 3 heartbeats.
    var staleAfter: TimeInterval = defaultStaleAfter
    /// Consecutive supervised launches finding the lock held before a kill is allowed (1 ... 20).
    var strikesBeforeKill: Int = defaultStrikesBeforeKill

    static let standard = LifecycleTuning(from: .standard)

    init() {}

    init(from defaults: UserDefaults) {
        func number(_ key: String) -> Double? {
            defaults.object(forKey: key) == nil ? nil : defaults.double(forKey: key)
        }
        heartbeatInterval = min(60, max(0.5, number(Key.heartbeatInterval) ?? Self.defaultHeartbeatInterval))
        // A busy main thread must not look hung, so keep a margin of at least 3 ticks.
        staleAfter = max(heartbeatInterval * 3, number(Key.staleAfter) ?? Self.defaultStaleAfter)
        strikesBeforeKill = min(20, max(1, number(Key.strikesBeforeKill).map(Int.init) ?? Self.defaultStrikesBeforeKill))
    }
}
