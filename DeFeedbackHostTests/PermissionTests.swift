//
//  PermissionTests.swift
//  DeFeedbackHostTests
//
//  Covers docs/permissions-spec.md rules P1–P8 (P9 lives in MainWindowSizingTests). Fake checkers
//  stand in for the system, so no test can raise a real permission prompt.
//
//  - Tests initially created with AI with human edits, but all reviewed by human

import AVFoundation
import Foundation
import Network
import ServiceManagement
import Testing

@testable import DeFeedbackHost

@MainActor
struct PermissionTests {

    @Test("P1: start asks only for permissions that have never been asked, once, in order")
    func startRequestsOnlyUndetermined() async {
        let mic = StubChecker(.microphone, state: .notDetermined)
        let network = StubChecker(.localNetwork, state: .granted)
        let login = StubChecker(.loginItems, state: .denied)
        let service = PermissionService(checkers: [mic, network, login])

        await service.start()
        await service.start()   // a second call is ignored

        #expect(mic.requestCount == 1)
        #expect(network.requestCount == 0)
        #expect(login.requestCount == 0, "a denied permission is never re-asked")
        #expect(mic.checkCount == 1)
        #expect(service.states[.microphone] == .granted)
    }

    @Test("P2: nothing warns before the first check finishes, or when state is unknown")
    func unknownNeverWarns() async {
        let checker = StubChecker(.localNetwork, state: .unknown)
        let service = PermissionService(checkers: [checker])
        #expect(service.warnings.isEmpty)
        await service.start()
        #expect(service.states[.localNetwork] == .unknown)
        #expect(service.warnings.isEmpty)
        #expect(service.problems.isEmpty)
    }

    @Test("P3: a denied permission produces one stable warning; granted produces none")
    func deniedProducesWarning() async {
        let service = PermissionService(checkers: [
            StubChecker(.microphone, state: .denied),
            StubChecker(.localNetwork, state: .granted),
        ])
        await service.start()
        #expect(service.problems == [.microphone])
        #expect(service.warnings.map(\.id) == ["permission.microphone"])
        let warning = service.warnings[0]
        #expect(warning.kind == .permission)
        #expect(warning.message.contains("Microphone"))
        #expect(warning.message.contains("System Settings"))
        #expect(warning.link == nil, "System Settings can't be opened from the web page")
    }

    @Test("P4: refresh re-checks without asking, and a later grant clears the warning")
    func refreshClearsAfterGrant() async {
        let checker = StubChecker(.microphone, state: .denied)
        let service = PermissionService(checkers: [checker])
        await service.refresh()
        #expect(checker.checkCount == 0, "refresh before start does nothing")

        await service.start()
        #expect(service.warnings.count == 1)

        checker.state = .granted   // the user flips it in System Settings
        await service.refresh()
        #expect(service.warnings.isEmpty)
        #expect(checker.requestCount == 0)
    }

    @Test("P4: a refresh during a check never overlaps it, and is not lost")
    func refreshDuringCheckIsQueued() async {
        final class Slow: PermissionChecker {
            let permission = Permission.localNetwork
            var checkCount = 0
            var running = 0
            var maxRunning = 0
            func check() async -> PermissionState {
                checkCount += 1
                running += 1
                maxRunning = max(maxRunning, running)
                for _ in 0..<5 { await Task.yield() }
                running -= 1
                return .granted
            }
            func request() async -> PermissionState { .granted }
        }
        let slow = Slow()
        let service = PermissionService(checkers: [slow])
        let launch = Task { await service.start() }
        await Task.yield()
        await service.refresh()          // the app became active mid-launch-check
        await launch.value
        #expect(slow.maxRunning == 1, "probes must never overlap")
        #expect(slow.checkCount == 2, "the mid-check refresh runs once, after the launch check")
        await service.refresh()
        #expect(slow.checkCount == 3)
    }

    @Test("P10: a denied microphone shows one bar: the error banner defers to the permissions banner")
    func microphoneErrorNotDuplicated() {
        let denied = AudioHostError.microphoneAccessDenied.localizedDescription
        // Permission already flagged: the error banner stays hidden.
        #expect(ContentView.visibleError(denied, microphoneNeedsPermission: true) == nil)
        // No permissions banner (e.g. unknown state): the error is still shown.
        #expect(ContentView.visibleError(denied, microphoneNeedsPermission: false) == denied)
        // Other errors are never hidden.
        #expect(ContentView.visibleError("Something else", microphoneNeedsPermission: true) == "Something else")
        #expect(ContentView.visibleError(nil, microphoneNeedsPermission: true) == nil)
    }

    @Test("P5: Login Items reports only agents awaiting approval and never registers anything")
    func loginItemsReportsOnly() async {
        final class Agents: LaunchAgentControlling {
            var statuses: [LaunchAgentKind: SMAppService.Status] = [.login: .notRegistered, .supervisor: .notRegistered]
            var setEnabledCalls = 0
            func status(of kind: LaunchAgentKind) -> SMAppService.Status { statuses[kind] ?? .notRegistered }
            func setEnabled(_ enabled: Bool, for kind: LaunchAgentKind) throws { setEnabledCalls += 1 }
        }
        let agents = Agents()
        let checker = LoginItemsPermission(agents: agents)

        #expect(await checker.check() == .granted, "nothing turned on: nothing to approve")
        agents.statuses[.supervisor] = .enabled
        #expect(await checker.check() == .granted)
        agents.statuses[.login] = .requiresApproval
        #expect(await checker.check() == .denied)
        #expect(await checker.request() == .denied)
        #expect(agents.setEnabledCalls == 0, "requesting must not switch the user's settings on")
    }

    @Test("P6: Local Network states map from the browser state")
    func localNetworkMapping() {
        let denied = NWError.dns(LocalNetworkPermission.policyDenied)
        #expect(LocalNetworkPermission.state(for: .ready) == .granted)
        #expect(LocalNetworkPermission.state(for: .waiting(denied)) == .denied)
        #expect(LocalNetworkPermission.state(for: .failed(denied)) == .denied)
        #expect(LocalNetworkPermission.state(for: .waiting(.dns(-65537))) == nil, "other waits keep waiting")
        #expect(LocalNetworkPermission.state(for: .failed(.dns(-65537))) == .unknown)
        #expect(LocalNetworkPermission.state(for: .setup) == nil)
        #expect(LocalNetworkPermission.state(for: .cancelled) == nil)
    }

    @Test("P6: Microphone authorisation maps to permission states")
    func microphoneMapping() {
        #expect(MicrophonePermission.state(for: .authorized) == .granted)
        #expect(MicrophonePermission.state(for: .notDetermined) == .notDetermined)
        #expect(MicrophonePermission.state(for: .denied) == .denied)
        #expect(MicrophonePermission.state(for: .restricted) == .denied)
    }

    @Test("P7: the inert checkers never prompt and never warn")
    func inertCheckersNeverWarn() async {
        let service = PermissionService(checkers: Permission.allCases.map(InertPermissionChecker.init))
        await service.start()
        #expect(service.warnings.isEmpty)
        #expect(Permission.allCases.allSatisfy { service.states[$0] == .unknown })
    }

    @Test("P8: /api/status carries update and permission warnings in one list")
    func statusCarriesWarnings() async throws {
        let permissions = PermissionService(checkers: [StubChecker(.localNetwork, state: .denied)])
        await permissions.start()

        final class Engine: UpdateEngine {
            func probe(channel: UpdateChannel, onResult: @escaping @MainActor (ProbeResult) -> Void) {
                onResult(.updateAvailable(version: "4.0", link: URL(string: "https://example.com/releases/tag/v4.0")))
            }
            func presentUpdate(channel: UpdateChannel) {}
        }
        let name = "DeFeedbackHostTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: UpdatePreferences.Key.enabled)
        let updates = UpdateService(engine: Engine(), defaults: defaults, sleep: { _ in try await Task.sleep(for: .seconds(100_000)) })
        updates.start()
        for _ in 0..<200 where !updates.status.isUpdateAvailable { await Task.yield() }

        let web = WebControlService(host: AudioHost())
        #expect(web.warningPayload().isEmpty, "no sources: nothing to warn about")

        web.warningSources = [updates, permissions]
        let warnings = web.warningPayload()
        #expect(warnings.compactMap { $0["id"] as? String } == ["update", "permission.localNetwork"])
        let update = try #require(warnings.first)
        #expect(update["kind"] as? String == "update")
        #expect(update["link"] as? String == "https://example.com/releases/tag/v4.0",
                "the update warning links to that release's own page")
        let permission = try #require(warnings.last)
        #expect(permission["kind"] as? String == "permission")
        #expect(permission["link"] is NSNull)

        // A cleared condition disappears from the very next payload.
        web.warningSources = [permissions]
        #expect(web.warningPayload().compactMap { $0["id"] as? String } == ["permission.localNetwork"])
    }

    // MARK: Local Network probe lifetime and settling (P6)

    /// A fake browse that delivers `states` on the probe's queue, `gap` seconds apart.
    private func fakeBrowse(_ states: [NWBrowser.State], gap: TimeInterval = 0.02) -> LocalNetworkPermission.Browse {
        { queue, onState in
            for (index, state) in states.enumerated() {
                queue.asyncAfter(deadline: .now() + gap * Double(index + 1)) { onState(state) }
            }
            return {}
        }
    }

    @Test("P6: a probe delivers its result even though nothing else holds it (regression: hung forever)")
    func probeDeliversResult() async {
        let checker = LocalNetworkPermission(timeout: 2, settle: 0.05, browse: fakeBrowse([.setup, .ready]))
        #expect(await checker.check() == .granted)
    }

    @Test("P6: .ready followed by a denial is denied, not granted")
    func readyThenDeniedIsDenied() async {
        let denied = NWError.dns(LocalNetworkPermission.policyDenied)
        let checker = LocalNetworkPermission(timeout: 2, settle: 0.5,
                                             browse: fakeBrowse([.ready, .waiting(denied)]))
        #expect(await checker.check() == .denied)
    }

    @Test("P6: no decision before the timeout is unknown, never a warning")
    func silentProbeIsUnknown() async {
        let checker = LocalNetworkPermission(timeout: 0.2, settle: 0.05, browse: fakeBrowse([.setup]))
        #expect(await checker.check() == .unknown)
    }
}
