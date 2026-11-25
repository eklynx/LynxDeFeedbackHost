//
//  UpdateViews.swift
//  DeFeedbackHost
//
//  SwiftUI surfaces for `UpdateService`. Contract: UpdateChecking.swift.
//  Views read the service from the environment (optional, so previews need no setup).
//
import SwiftUI

/// App menu item: "Check for Updates…". Always enabled — a user-initiated check is allowed
/// whether or not background checking is on (contract rule 4).
struct CheckForUpdatesCommand: View {

    let updates: UpdateService

    var body: some View {
        Button(updates.status.isUpdateAvailable ? "Update Now…" : "Check for Updates…") {
            if updates.status.isUpdateAvailable {
                updates.installNow()
            } else {
                updates.checkForUpdates()
            }
        }
    }
}

/// Settings › General section: opt-in toggle, interval, status and the "Update Now" button.
struct UpdateSettingsSection: View {

    @Environment(UpdateService.self) private var updates: UpdateService?

    var body: some View {
        if let updates {
            @Bindable var updates = updates
            Section {
                Toggle("Check for updates automatically", isOn: $updates.isEnabled)

                Picker("Check", selection: $updates.interval) {
                    ForEach(UpdateInterval.allCases) { Text($0.label).tag($0) }
                }
                .disabled(!updates.isEnabled)

                if let version = updates.status.availableVersion {
                    HStack {
                        Label("Version \(version) is available.", systemImage: "arrow.down.circle.fill")
                            .foregroundStyle(.tint)
                        Spacer()
                        Link("Release notes", destination: updates.status.releasesPage)
                        Button("Update Now") { updates.installNow() }
                    }
                    .font(.callout)
                } else {
                    HStack {
                        Text(statusLine(updates.status))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Check Now") { updates.checkForUpdates() }
                    }
                    .font(.callout)
                }
            } header: {
                Text("Updates")
            } footer: {
                Text("""
                    Off by default. When on, the app looks for a new version at startup and on the \
                    chosen schedule, and tells you here and in the web interface. It never downloads \
                    or installs anything until you choose Update Now.
                    """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func statusLine(_ status: UpdateStatus) -> String {
        if status.isChecking { return "Checking…" }
        if let error = status.lastError { return "Couldn't check: \(error)" }
        if let last = status.lastChecked {
            return "Up to date. Last checked \(last.formatted(date: .abbreviated, time: .shortened))."
        }
        return status.isEnabled ? "Not checked yet." : "Automatic checking is off."
    }
}

/// Main-window banner shown only while an update is known.
struct UpdateBanner: View {

    @Environment(UpdateService.self) private var updates: UpdateService?

    var body: some View {
        if let updates, let version = updates.status.availableVersion {
            HStack {
                Label("Version \(version) of \(AppInfo.name) is available.",
                      systemImage: "arrow.down.circle.fill")
                Spacer()
                Link("Releases", destination: updates.status.releasesPage)
                Button("Update Now") { updates.installNow() }
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.tint.opacity(0.12))
        }
    }
}
