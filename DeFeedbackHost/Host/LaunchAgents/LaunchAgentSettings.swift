//
//  LaunchAgentSettings.swift
//  DeFeedbackHost
//
//  Created by Edgars Klepers on 9/20/2026.
//
//  Launch at login and restart after crash. Contract for the two launchd agents:
//  Lifecycle/LaunchSupervision.swift; spec: docs/launch-and-restart-spec.md.
//
//  Happy path: setting `launchAtLogin` or `restartAfterCrash` registers or unregisters the matching
//  agent, re-reads its status, and reports nothing.
//  Errors: if registering throws, or the status after the call is not what was asked for, `onError`
//  is called once with "Couldn't turn on|off <name> — <reason>", and the setting reads as the
//  system left it. `.requiresApproval` counts as on (registered; the user still has to allow it).

import AppKit
import Foundation
import ServiceManagement
import os

/// The two launchd-backed settings and what the UI needs to know about them.
///
/// Owned by `AudioHost`, which forwards these members so callers don't change; problems are
/// reported through `onError` rather than by reaching back into the host.
@Observable
@MainActor
final class LaunchAgentSettings {

    @ObservationIgnored private let agents: LaunchAgentControlling
    @ObservationIgnored private let supervision: LaunchSupervision

    /// Called with a user-readable message when a change fails or isn't honoured.
    @ObservationIgnored var onError: (String) -> Void = { _ in }

    private(set) var loginStatus: SMAppService.Status = .notRegistered
    private(set) var supervisorStatus: SMAppService.Status = .notRegistered

    init(agents: LaunchAgentControlling, supervision: LaunchSupervision) {
        self.agents = agents
        self.supervision = supervision
    }

    var launchAtLogin: Bool {
        get { Self.isOn(loginStatus) }
        set { setAgent(.login, enabled: newValue, name: "launch at login") }
    }

    var restartAfterCrash: Bool {
        get { Self.isOn(supervisorStatus) }
        set { setAgent(.supervisor, enabled: newValue, name: "restart after crash") }
    }

    /// Registered, but the user still has to allow it in System Settings › Login Items.
    var permissionsNeedApproval: Bool {
        loginStatus == .requiresApproval || supervisorStatus == .requiresApproval
    }

    /// Restart-after-crash is on, but this process was started outside launchd (for example from
    /// Finder before the setting was enabled), so a crash would not be restarted yet.
    var needsRelaunchToBeSupervised: Bool {
        supervisorStatus == .enabled && !supervision.isRunningUnderSupervisor
    }

    /// Quits normally and asks launchd to start the supervised copy once we are gone.
    func relaunchUnderSupervisor() {
        guard supervision.handOff(afterDelay: 2) else {
            onError("Couldn't ask the system to relaunch DeFeedbackHost — check Login Items in System Settings.") // TODO: localize string
            return
        }
        NSApp.terminate(nil)
    }

    func refreshStatus() {
        loginStatus = agents.status(of: .login)
        supervisorStatus = agents.status(of: .supervisor)
    }

    private static func isOn(_ status: SMAppService.Status) -> Bool {
        status == .enabled || status == .requiresApproval
    }

    private func setAgent(_ kind: LaunchAgentKind, enabled: Bool, name: String) {
        var failure: Error?
        do {
            try agents.setEnabled(enabled, for: kind)
        } catch {
            failure = error
            Logger.host_application.error("Error changing \(name) agent: \(error)")
        }

        refreshStatus()

        let isNowOn = Self.isOn(kind == .login ? loginStatus : supervisorStatus)
        if isNowOn != enabled {
            let reason = failure?.localizedDescription ?? "the system kept the previous setting"
            onError("Couldn't turn \(enabled ? "on" : "off") \(name) — \(reason)") // TODO: localize string
        }
    }
}
