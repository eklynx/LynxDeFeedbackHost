//
//  StreamDeckPluginInstalling.swift
//  DeFeedbackHost
//
//  The seam for replacing the installed Stream Deck plugin with the packaged one, and the setting that
//  allows it. Contract: StreamDeckPluginChecking.swift (rules 10 to 12). Spec: docs/streamdeck-plugin-spec.md.
//
//  The real installer is `StreamDeckCLIInstaller` (it drives Elgato's `streamdeck` CLI). Under XCTest the app
//  uses `InertStreamDeckPluginInstaller`, so no test can touch Stream Deck.
//
import Foundation

nonisolated enum StreamDeckPluginInstallResult: Equatable, Sendable {
    /// The packaged plugin is now installed (the service re-checks to confirm).
    case installed
    /// This build can't install the plugin. Not an error for the user: the warning stays and says nothing more.
    case notAvailable
    /// It tried and failed; the reason (one short sentence) is added to the warning.
    case failed(String)
}

/// Replaces the installed plugin with the packaged one. Called at most once per launch, never while the
/// plugin is absent or current (contract 12). Never throws: every failure is a `.failed` result.
@MainActor
protocol StreamDeckPluginInstalling {
    func installPackagedPlugin() async -> StreamDeckPluginInstallResult
}

/// Does nothing. Used under XCTest so no test touches Stream Deck.
struct InertStreamDeckPluginInstaller: StreamDeckPluginInstalling {
    func installPackagedPlugin() async -> StreamDeckPluginInstallResult { .notAvailable }
}

/// The user's choice on the Stream Deck tab.
@MainActor
protocol StreamDeckPluginSettings {
    /// Whether the launch check may replace an out-of-date plugin. ON by default.
    var isAutoUpdateEnabled: Bool { get }
}

/// `UserDefaults`-backed settings. Key documented in docs/cli-settings-spec.md.
@MainActor
struct UserDefaultsStreamDeckPluginSettings: StreamDeckPluginSettings {

    enum Key {
        static let autoUpdate = "Host.streamDeckAutoUpdate"
    }

    /// Spec SP11: automatic update is on for a fresh install.
    static let defaultAutoUpdate = true

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// A real bool or the strings a `defaults write -string` user types; anything else reads as the default.
    var isAutoUpdateEnabled: Bool {
        switch defaults.object(forKey: Key.autoUpdate) {
        case let value as Bool: value
        case let value as String where ["true", "yes", "1"].contains(value.lowercased()): true
        case let value as String where ["false", "no", "0"].contains(value.lowercased()): false
        default: Self.defaultAutoUpdate
        }
    }
}
