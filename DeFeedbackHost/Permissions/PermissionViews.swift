//
//  PermissionViews.swift
//  DeFeedbackHost
//
//  SwiftUI surfaces for `PermissionService`. Contract: PermissionChecking.swift.
//  Views read the service from the environment (optional, so previews need no setup).
//
import SwiftUI

/// Main-window banner: one row per permission that needs attention, with a shortcut to fix it.
struct PermissionsBanner: View {

    @Environment(PermissionService.self) private var permissions: PermissionService?

    var body: some View {
        if let permissions, !permissions.problems.isEmpty {
            VStack(spacing: 0) {
                ForEach(permissions.problems) { permission in
                    HStack {
                        Label("\(permission.consequence) Allow it in \(permission.settingsPath).",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Open System Settings") {
                            permissions.openSystemSettings(for: permission)
                        }
                    }
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.orange.opacity(0.12))
                }
            }
        }
    }
}

/// Settings › General section: every permission and its state.
struct PermissionSettingsSection: View {

    @Environment(PermissionService.self) private var permissions: PermissionService?

    var body: some View {
        if let permissions {
            Section {
                ForEach(Permission.allCases.filter { shows($0) }) { permission in
                    let state = permissions.states[permission] ?? .unknown
                    HStack {
                        Label(permission.label, systemImage: icon(for: state))
                            .foregroundStyle(color(for: state))
                        Spacer()
                        Text(text(for: state)).foregroundStyle(.secondary)
                        if state.needsAttention {
                            Button("Open System Settings") {
                                permissions.openSystemSettings(for: permission)
                            }
                        }
                    }
                    .font(.callout)
                }
            } header: {
                Text("Permissions")
            } footer: {
                Text("""
                    DeFeedbackHost asks for these when it starts. Anything not allowed is flagged here, \
                    in the main window and on the web page, and clears when you allow it.
                    """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    /// Automation only matters for a real shutdown, so its row appears only when it needs attention.
    private func shows(_ permission: Permission) -> Bool {
        permission != .automation || permissions?.states[.automation]?.needsAttention == true
    }

    private func icon(for state: PermissionState) -> String {
        switch state {
        case .granted: "checkmark.circle.fill"
        case .denied, .notDetermined: "exclamationmark.triangle.fill"
        case .unknown: "questionmark.circle"
        }
    }

    private func color(for state: PermissionState) -> Color {
        switch state {
        case .granted: .green
        case .denied, .notDetermined: .orange
        case .unknown: .secondary
        }
    }

    private func text(for state: PermissionState) -> String {
        switch state {
        case .granted: "Allowed"
        case .denied: "Not allowed"
        case .notDetermined: "Not asked yet"
        case .unknown: "Checking…"
        }
    }
}
