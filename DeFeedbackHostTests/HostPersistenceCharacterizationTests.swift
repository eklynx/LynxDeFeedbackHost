//
//  HostPersistenceCharacterizationTests.swift
//  DeFeedbackHostTests
//
//  Pins how `AudioHost` saves, restores and reacts to external edits of its settings, and how it
//  reports launch-agent changes. Written before those responsibilities were moved out of the class
//  (issue #41) so the move can be shown to change nothing.
//
//  - Tests initially created with AI with human edits, but all reviewed by human

import Foundation
import ServiceManagement
import Testing

@testable import DeFeedbackHost

@MainActor
private func withDefaults(_ body: (UserDefaults) async throws -> Void) async rethrows {
    let name = "DeFeedbackHostTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    try await body(defaults)
}

/// Stands in for the system's launch-agent registration.
private final class FakeAgents: LaunchAgentControlling, @unchecked Sendable {
    var statuses: [LaunchAgentKind: SMAppService.Status] = [.login: .notRegistered,
                                                            .supervisor: .notRegistered]
    /// What a `setEnabled` call does to the status: nil leaves it unchanged (the system "kept the
    /// previous setting").
    var statusAfterEnabling: SMAppService.Status? = .enabled
    var failure: Error?
    var calls: [(kind: LaunchAgentKind, enabled: Bool)] = []

    func status(of kind: LaunchAgentKind) -> SMAppService.Status { statuses[kind] ?? .notRegistered }

    func setEnabled(_ enabled: Bool, for kind: LaunchAgentKind) throws {
        calls.append((kind, enabled))
        if let failure { throw failure }
        if enabled, let statusAfterEnabling {
            statuses[kind] = statusAfterEnabling
        } else if !enabled {
            statuses[kind] = .notRegistered
        }
    }
}

private struct FakeSupervision: LaunchSupervision {
    var isRunningUnderSupervisor = false
    var accepts = true
    func handOff(afterDelay: TimeInterval) -> Bool { accepts }
}

private struct Refused: LocalizedError {
    var errorDescription: String? { "not approved" }
}

struct HostPersistenceCharacterizationTests {

    // MARK: - Saving

    @Test @MainActor func nothingIsSavedBeforeStartupHasFinishedRestoring() async {
        await withDefaults { defaults in
            let host = AudioHost(defaults: defaults)
            host.bufferSize = 64
            host.saveSettings()
            #expect(defaults.data(forKey: SettingsStore.defaultsKey) == nil)
            #expect(defaults.object(forKey: "Host.bufferSize") == nil)
        }
    }

    @Test @MainActor func savingWithNothingChangedWritesNothing() async {
        await withDefaults { defaults in
            let host = AudioHost(defaults: defaults)
            await host.loadApplicationState()
            // The first save can differ from what was loaded (first-run device selection), so
            // settle that first.
            host.saveSettings()

            let sentinel = Data("sentinel".utf8)
            defaults.set(sentinel, forKey: SettingsStore.defaultsKey)
            host.saveSettings()
            #expect(defaults.data(forKey: SettingsStore.defaultsKey) == sentinel)
        }
    }

    @Test @MainActor func aChangedSettingIsWrittenOnSave() async {
        await withDefaults { defaults in
            let host = AudioHost(defaults: defaults)
            await host.loadApplicationState()

            host.bufferSize = 64
            host.saveSettings()
            #expect(defaults.integer(forKey: "Host.bufferSize") == 64)
        }
    }

    // MARK: - External edits

    @Test @MainActor func anInvalidExternalValueIsIgnored() async {
        await withDefaults { defaults in
            let host = AudioHost(defaults: defaults)
            await host.loadApplicationState()
            let before = host.bufferSize

            defaults.set(999, forKey: "Host.bufferSize")
            host.applyExternalPreferences()
            #expect(host.bufferSize == before)
        }
    }

    @Test @MainActor func anAppliedExternalEditCountsAsSaved() async {
        await withDefaults { defaults in
            let host = AudioHost(defaults: defaults)
            await host.loadApplicationState()

            defaults.set(256, forKey: "Host.bufferSize")
            host.applyExternalPreferences()
            #expect(host.bufferSize == 256)

            // The host already holds what the key holds, so saving must not write it again.
            defaults.removeObject(forKey: "Host.bufferSize")
            host.saveSettings()
            #expect(defaults.object(forKey: "Host.bufferSize") == nil)
        }
    }

    @Test @MainActor func externalEditsAreIgnoredWhileRestoring() async {
        await withDefaults { defaults in
            let host = AudioHost(defaults: defaults)
            defaults.set(256, forKey: "Host.bufferSize")
            host.applyExternalPreferences()
            #expect(host.bufferSize == PluginConfiguration.defaultBufferSize)
        }
    }

    // MARK: - Launch agents

    @Test @MainActor func turningLaunchAtLoginOnRegistersTheLoginAgent() async {
        await withDefaults { defaults in
            let agents = FakeAgents()
            let host = AudioHost(defaults: defaults, launchAgents: agents)

            host.launchAtLogin = true
            #expect(agents.calls.map(\.kind) == [.login])
            #expect(agents.calls.map(\.enabled) == [true])
            #expect(host.launchAtLogin)
            #expect(host.restartAfterCrash == false)
            #expect(host.errorMessage == nil)
        }
    }

    @Test @MainActor func restartAfterCrashUsesTheSupervisorAgent() async {
        await withDefaults { defaults in
            let agents = FakeAgents()
            let host = AudioHost(defaults: defaults, launchAgents: agents)

            host.restartAfterCrash = true
            #expect(agents.calls.map(\.kind) == [.supervisor])
            #expect(host.restartAfterCrash)
            #expect(host.launchAtLogin == false)
        }
    }

    @Test @MainActor func aRefusedChangeSaysWhyAndLeavesTheSettingOff() async {
        await withDefaults { defaults in
            let agents = FakeAgents()
            agents.failure = Refused()
            let host = AudioHost(defaults: defaults, launchAgents: agents)

            host.launchAtLogin = true
            #expect(host.launchAtLogin == false)
            #expect(host.errorMessage == "Couldn't turn on launch at login — not approved")
        }
    }

    @Test @MainActor func aSilentlyIgnoredChangeIsReported() async {
        await withDefaults { defaults in
            let agents = FakeAgents()
            agents.statusAfterEnabling = nil
            let host = AudioHost(defaults: defaults, launchAgents: agents)

            host.restartAfterCrash = true
            #expect(host.errorMessage
                    == "Couldn't turn on restart after crash — the system kept the previous setting")
        }
    }

    @Test @MainActor func awaitingApprovalCountsAsOnAndAsNeedingApproval() async {
        await withDefaults { defaults in
            let agents = FakeAgents()
            agents.statusAfterEnabling = .requiresApproval
            let host = AudioHost(defaults: defaults, launchAgents: agents)

            #expect(host.launchPermissionsNeedApproval == false)
            host.launchAtLogin = true
            #expect(host.launchAtLogin)
            #expect(host.launchPermissionsNeedApproval)
            #expect(host.errorMessage == nil)
        }
    }

    @Test @MainActor func refreshPicksUpAChangeMadeInSystemSettings() async {
        await withDefaults { defaults in
            let agents = FakeAgents()
            let host = AudioHost(defaults: defaults, launchAgents: agents)
            #expect(host.launchAtLogin == false)

            agents.statuses[.login] = .enabled
            host.refreshLaunchAgentStatus()
            #expect(host.launchAtLogin)
        }
    }

    @Test @MainActor func relaunchIsOfferedOnlyWhenSupervisedRestartIsOnButNotInEffect() async {
        await withDefaults { defaults in
            let agents = FakeAgents()
            agents.statuses[.supervisor] = .enabled

            let outside = AudioHost(defaults: defaults, launchAgents: agents,
                                    supervision: FakeSupervision(isRunningUnderSupervisor: false))
            outside.refreshLaunchAgentStatus()
            #expect(outside.needsRelaunchToBeSupervised)

            let inside = AudioHost(defaults: defaults, launchAgents: agents,
                                   supervision: FakeSupervision(isRunningUnderSupervisor: true))
            inside.refreshLaunchAgentStatus()
            #expect(inside.needsRelaunchToBeSupervised == false)
        }
    }

    @Test @MainActor func aRefusedRelaunchKeepsRunningAndSaysSo() async {
        await withDefaults { defaults in
            let host = AudioHost(defaults: defaults,
                                 supervision: FakeSupervision(accepts: false))
            host.relaunchUnderSupervisor()
            #expect(host.errorMessage?.hasPrefix("Couldn't ask the system to relaunch") == true)
        }
    }
}
