//
//  SimulatedUpdateEngine.swift
//  DeFeedbackHost
//
//  DEBUG BUILDS ONLY. Lets you see the "update available" UI without publishing a release:
//
//      defaults write com.eklynx.sound.DeFeedbackHost Updates.simulateVersion -string 9.9.9
//      defaults delete com.eklynx.sound.DeFeedbackHost Updates.simulateVersion
//
//  Read once at launch. Checking must still be turned on in Settings. No network, no Sparkle, no
//  install: "Update Now" just opens the releases page. The whole file is compiled out of release
//  builds (see UpdateTests.simulationIsDebugOnly).
//
#if DEBUG
import AppKit
import Foundation

@MainActor
final class SimulatedUpdateEngine: UpdateEngine {

    static let defaultsKey = "Updates.simulateVersion"

    let version: String

    init(version: String) {
        self.version = version
    }

    /// The engine to use when `Updates.simulateVersion` is set to a non-empty string, else nil.
    static func fromDefaults(_ defaults: UserDefaults = .standard) -> SimulatedUpdateEngine? {
        guard let value = defaults.string(forKey: defaultsKey)?
            .trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        return SimulatedUpdateEngine(version: value)
    }

    func probe(channel: UpdateChannel, onResult: @escaping @MainActor (ProbeResult) -> Void) {
        onResult(.updateAvailable(version: version, link: nil))
    }

    func presentUpdate(channel: UpdateChannel) {
        NSWorkspace.shared.open(UpdateLinks.releasesPage)
    }
}
#endif
