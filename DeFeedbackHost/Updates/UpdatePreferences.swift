//
//  UpdatePreferences.swift
//  DeFeedbackHost
//
//  Persistence for the update settings. Contract context: UpdateChecking.swift (edge case 7).
//
//  Each value is its own UserDefaults key, so they can be inspected or changed from the CLI:
//
//      defaults read  com.eklynx.sound.DeFeedbackHost Updates.enabled
//      defaults write com.eklynx.sound.DeFeedbackHost Updates.enabled -bool true
//      defaults write com.eklynx.sound.DeFeedbackHost Updates.checkInterval -int 21600
//      defaults write com.eklynx.sound.DeFeedbackHost Updates.channel -string nightly
//
//  Bad values are clamped or ignored, never rejected.
//
import Foundation

struct UpdatePreferences: Equatable {

    enum Key {
        static let enabled = "Updates.enabled"
        static let checkInterval = "Updates.checkInterval"
        static let lastChecked = "Updates.lastChecked"
        static let channel = "Updates.channel"
    }

    var isEnabled = false
    var interval: UpdateInterval = .default
    var channel: UpdateChannel = .default
    var lastChecked: Date?

    init() {}

    init(from defaults: UserDefaults) {
        isEnabled = defaults.bool(forKey: Key.enabled)   // absent == false: opt-in
        if defaults.object(forKey: Key.checkInterval) != nil {
            interval = UpdateInterval.nearest(to: defaults.double(forKey: Key.checkInterval))
        }
        channel = UpdateChannel(stored: defaults.string(forKey: Key.channel))
        if let seconds = defaults.object(forKey: Key.lastChecked) as? Double, seconds > 0 {
            lastChecked = Date(timeIntervalSince1970: seconds)
        }
    }

    func write(to defaults: UserDefaults) {
        defaults.set(isEnabled, forKey: Key.enabled)
        defaults.set(interval.rawValue, forKey: Key.checkInterval)
        defaults.set(channel.rawValue, forKey: Key.channel)
        if let lastChecked {
            defaults.set(lastChecked.timeIntervalSince1970, forKey: Key.lastChecked)
        }
    }
}
