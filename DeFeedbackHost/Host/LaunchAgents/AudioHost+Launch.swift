//
//  AudioHost+Launch.swift
//  DeFeedbackHost
//
//  Created by Edgars Klepers on 9/20/2026.
//
//  AudioHost's launch-at-login and restart-after-crash members. Each forwards to `LaunchAgentSettings`.

extension AudioHost {

    var launchAtLogin: Bool {
        get { launch.launchAtLogin }
        set { launch.launchAtLogin = newValue }
    }

    var restartAfterCrash: Bool {
        get { launch.restartAfterCrash }
        set { launch.restartAfterCrash = newValue }
    }

    var launchPermissionsNeedApproval: Bool { launch.permissionsNeedApproval }
    var needsRelaunchToBeSupervised: Bool { launch.needsRelaunchToBeSupervised }
    func relaunchUnderSupervisor() { launch.relaunchUnderSupervisor() }
    func refreshLaunchAgentStatus() { launch.refreshStatus() }
}
