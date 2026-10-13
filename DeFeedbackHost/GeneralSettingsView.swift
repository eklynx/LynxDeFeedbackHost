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
                Toggle("Launch on user login and crash", isOn: $host.launchWithSystem)
                    .disabled(!host.isInApplicationsFolder && !host.launchWithSystem)

                if !host.isInApplicationsFolder {
                    Label("DeFeedbackHost must be in /Applications for auto-launch to be enabled.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }

                if host.launchWithSystemNeedsApproval {
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
            } header: {
                Text("App Auto-Launch")
            } footer: {
                Text("""
                    Starts the application when the user logs in, as well as relaunches the application \
                    if it crashes abnormally. The app will not auto-relaunch if terminated normally.
                    """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

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
        }
        .formStyle(.grouped)
        .frame(width: 440)
        // Size to the full content height so the Settings window fits it without scrolling.
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
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
