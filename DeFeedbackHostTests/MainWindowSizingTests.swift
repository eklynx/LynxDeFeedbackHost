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

    @Test("P9: the permissions banner adds to the window's required height")
    func permissionsBannerAddsToRequiredHeight() async {
        func height(denied: Bool) async -> CGFloat {
            let checker = StubChecker(.microphone, state: denied ? .denied : .granted)
            let permissions = PermissionService(checkers: [checker])
            await permissions.start()
            let host = AudioHost()
            let view = ContentView(host: host, web: WebControlService(host: host))
                .environment(permissions)
            return NSHostingView(rootView: view).fittingSize.height
        }
        let without = await height(denied: false)
        let with = await height(denied: true)
        #expect(with >= without + 20, "required height \(with) vs \(without)")
    }
}

@MainActor
final class StubChecker: PermissionChecker {
    let permission: Permission
    var state: PermissionState
    var afterRequest: PermissionState
    private(set) var checkCount = 0
    private(set) var requestCount = 0

    init(_ permission: Permission, state: PermissionState, afterRequest: PermissionState = .granted) {
        self.permission = permission
        self.state = state
        self.afterRequest = afterRequest
    }

    func check() async -> PermissionState { checkCount += 1; return state }
    func request() async -> PermissionState {
        requestCount += 1
        state = afterRequest
        return afterRequest
    }
}
