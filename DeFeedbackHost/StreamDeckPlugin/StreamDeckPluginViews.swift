//
//  StreamDeckPluginViews.swift
//  DeFeedbackHost
//
//  SwiftUI surfaces for `StreamDeckPluginService`. Contract: StreamDeckPluginChecking.swift.
//  Views read the service from the environment (optional, so previews need no setup).
//
import SwiftUI

extension AppWarning.Severity {
    var color: Color { self == .error ? .red : .orange }
    var icon: String { self == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill" }
}

/// Main-window banner: one row per Stream Deck plugin problem, with a way to the Settings window.
struct StreamDeckPluginBanner: View {

    @Environment(StreamDeckPluginService.self) private var plugin: StreamDeckPluginService?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let plugin, !plugin.warnings.isEmpty {
            VStack(spacing: 0) {
                ForEach(plugin.warnings, id: \.id) { warning in
                    HStack {
                        Label(warning.message, systemImage: warning.severity.icon)
                            .foregroundStyle(warning.severity.color)
                        Spacer()
                        Button("Open Settings") { openWindow(id: DeFeedbackHostApp.settingsWindowID) }
                    }
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(warning.severity.color.opacity(0.12))
                }
            }
        }
    }
}

/// Rows for the Stream Deck settings tab: the plugin's warning or error, if any.
struct StreamDeckPluginStatusRows: View {

    @Environment(StreamDeckPluginService.self) private var plugin: StreamDeckPluginService?

    var body: some View {
        if let plugin {
            ForEach(plugin.warnings, id: \.id) { warning in
                Label(warning.message, systemImage: warning.severity.icon)
                    .foregroundStyle(warning.severity.color)
                    .font(.callout)
            }
        }
    }
}
