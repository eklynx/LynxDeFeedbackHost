//
//  GeneralSettingsView.swift
//  DeFeedbackHost
//
//  Created by Edgars Klepers on 9/17/26.
//

import AppKit
import ServiceManagement
import SwiftUI

struct GeneralSettingsView: View {

    @Bindable var host: AudioHost

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $host.launchAtLogin)
                Toggle("Restart after a crash", isOn: $host.restartAfterCrash)

                if host.launchPermissionsNeedApproval {
                    HStack {
                        Label("Launch permissions need approval. Allow DeFeedbackHost to launch in System Settings › General › Login Items & Extensions.",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Open System Settings") {
                            SMAppService.openSystemSettingsLoginItems()
                        }
                    }
                    .font(.callout)
                }

                if host.needsRelaunchToBeSupervised {
                    HStack {
                        Label("This copy was started outside the system's launch service, so a crash won't restart it yet.",
                              systemImage: "arrow.clockwise.circle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Relaunch Now") {
                            host.relaunchUnderSupervisor()
                        }
                    }
                    .font(.callout)
                }
            } header: {
                Text("App Auto-Launch")
            } footer: {
                Text("""
                    Launch at login starts the application when the user logs in. Restart after a crash \
                    relaunches it if it quits abnormally, however it was started. Quitting normally \
                    (including Quit, logout and shutdown) never restarts it. If you move the app, turn \
                    these settings off and on again.
                    """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            PermissionSettingsSection()

            Section {
                Toggle("Auto-run host on application startup", isOn: $host.autoRunOnStartup)
            } header: {
                Text("App Startup State")
            } footer: {
                Text("""
                    On application start, assuming all the devices are connected and configured properly, \
                    the plugin host will automatically run.
                    """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Start new instances muted", isOn: $host.newInstancesMuted)
                Toggle("Start new instances bypassed", isOn: $host.newInstancesBypassed)
            } header: {
                Text("New Instances")
            } footer: {
                Text("""
                    When adding a new instance, should those instances start muted (silent) and/or bypassed (pass-through).
                    """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            ShutdownSettingsSection()

            UpdateSettingsSection()
        }
        .formStyle(.grouped)
        .settingsTabFrame()
        // The user can change Login Items in System Settings at any time, and the app isn't told,
        // so re-read the status whenever the settings show up or the app comes back to the front.
        .task {
            host.refreshLaunchAgentStatus()
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                host.refreshLaunchAgentStatus()
            }
        }
    }
}

#Preview {
    GeneralSettingsView(host: AudioHost())
}
