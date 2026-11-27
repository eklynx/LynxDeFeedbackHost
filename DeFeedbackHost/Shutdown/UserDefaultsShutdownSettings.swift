//
//  UserDefaultsShutdownSettings.swift
//  DeFeedbackHost
//
//  `UserDefaults`-backed implementation of `ShutdownSettings`. Contract: ShutdownSettings.swift;
//  spec rules SH1 to SH4 in docs/shutdown-spec.md; keys in docs/cli-settings-spec.md.
//  Every read goes to the defaults, so a `defaults write` applies to the next command.
//
import Foundation

@MainActor
final class UserDefaultsShutdownSettings: ShutdownSettings {

    enum Key {
        static let enabled = "Host.shutdownEnabled"
        static let testMode = "Host.shutdownTestMode"
        static let phrase = "Host.shutdownPhrase"
    }

    /// Spec SH1: the test-mode default of a fresh install. It is ON while the feature is being
    /// built; the final task of GitHub #29 flips this ONE constant to `false` before release.
    static let defaultTestMode = true

    /// Spec SH1: shutdown is disabled on a fresh install.
    static let defaultEnabled = false

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isEnabled: Bool {
        get { Self.bool(Key.enabled, in: defaults) ?? Self.defaultEnabled }
        set { defaults.set(newValue, forKey: Key.enabled) }
    }

    var isTestMode: Bool {
        get { Self.bool(Key.testMode, in: defaults) ?? Self.defaultTestMode }
        set { defaults.set(newValue, forKey: Key.testMode) }
    }

    /// Never empty: an empty, missing or non-string stored value reads as the default (SH2).
    var phrase: String {
        guard let stored = defaults.string(forKey: Key.phrase), ShutdownPhrase.isValid(stored) else {
            return ShutdownPhrase.defaultPhrase
        }
        return stored
    }

    /// Saves `newPhrase` unless it is empty. Returns whether it was saved (SH2).
    @discardableResult
    func savePhrase(_ newPhrase: String) -> Bool {
        guard ShutdownPhrase.isValid(newPhrase) else { return false }
        defaults.set(newPhrase, forKey: Key.phrase)
        return true
    }

    /// Accepts a real bool or the strings `defaults write -string` users type; anything else is
    /// treated as absent so a typo can't change behaviour.
    private static func bool(_ key: String, in defaults: UserDefaults) -> Bool? {
        switch defaults.object(forKey: key) {
        case let number as NSNumber:
            return number.boolValue
        case let text as String:
            switch text.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        default:
            return nil
        }
    }
}
