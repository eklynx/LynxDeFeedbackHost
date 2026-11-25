//
//  MainWindowSizingTests.swift
//  DeFeedbackHostTests
//
//  Regression: the "update available" banner must make the main window TALLER, not squeeze the
//  gallery (it once cut off the mute/bypass buttons at the bottom). Covers docs/updates-spec.md U17.
//
//  - Tests initially created with AI with human edits, but all reviewed by human

import AppKit
import SwiftUI
import Testing

@testable import DeFeedbackHost

@MainActor
private final class AvailableEngine: UpdateEngine {
    func probe(onResult: @escaping @MainActor (ProbeResult) -> Void) {
        onResult(.updateAvailable(version: "9.9.9"))
    }
    func presentUpdate() {}
}

@MainActor
struct MainWindowSizingTests {

    private func requiredHeight(updateAvailable: Bool) async -> CGFloat {
        let name = "DeFeedbackHostTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: UpdatePreferences.Key.enabled)

        let service = UpdateService(engine: updateAvailable ? AvailableEngine() : InertUpdateEngine(),
                                    defaults: defaults)
        service.start()
        for _ in 0..<50 where service.status.isUpdateAvailable != updateAvailable { await Task.yield() }

        let host = AudioHost()
        let view = ContentView(host: host, web: WebControlService(host: host))
            .environment(service)
        return NSHostingView(rootView: view).fittingSize.height
    }

    @Test("U17: the update banner adds to the window's required height")
    func bannerAddsToRequiredHeight() async {
        let without = await requiredHeight(updateAvailable: false)
        let with = await requiredHeight(updateAvailable: true)
        #expect(with >= without + 20,
                "required height \(with) with the banner vs \(without) without: the banner is eating the gallery")
    }
}
