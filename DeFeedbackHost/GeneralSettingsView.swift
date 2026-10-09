//
//  GeneralSettingsView.swift
//  DeFeedbackHost
//
//  Created by Edgars Klepers on 9/17/26.
//

import SwiftUI

struct GeneralSettingsView: View {

    @Bindable var host: AudioHost

    var body: some View {
        Form {
            Section {
                Toggle("Auto-run on startup", isOn: $host.autoRunOnStartup)
            } header: {
                Text("Startup")
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
    }
}

#Preview {
    GeneralSettingsView(host: AudioHost())
}
