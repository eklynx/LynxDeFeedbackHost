//
//  StreamDeckSettingsView.swift
//  DeFeedbackHost
//
//  Created by Edgars Klepers on 10/7/26.
//

import AppKit
import SwiftUI

struct StreamDeckSettingsView: View {

    static let streamDeckBundleIdentifier = "com.elgato.StreamDeck"

    @State private var streamDeckAppURL: URL?
    @State private var pluginURL: URL?

    var body: some View {
        Form {
            Section {
                Button("Install/Update Stream Deck Plugin") {
                    installPlugin()
                }
                .disabled(streamDeckAppURL == nil || pluginURL == nil)
            } header: {
                Text("Plugin")
            } footer: {
                Text(footerText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        // Size to the full content height so the Settings window fits it without scrolling.
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: refreshSteamDeckStatus)
    }

    private var footerText: String {
        if streamDeckAppURL == nil {
            return "'Elgato Stream Deck' is not installed."
        }
        if pluginURL == nil {
            return "The Stream Deck plugin is missing; please re-download the application."
        }
        return "Installs or Updates the Stream Deck plugin to control the LynxDeFeedbackHost application."
    }

    /// Make sure the plugin is in the resources directory and the StreamDeck application is installed.
    private func refreshSteamDeckStatus() {
        streamDeckAppURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.streamDeckBundleIdentifier)
        pluginURL = Bundle.main.url(forResource: "com.eklynx.sound.defeedback", withExtension: "streamDeckPlugin")
    }

    private func installPlugin() {
        guard let streamDeckAppURL, let pluginURL else { return }
        NSWorkspace.shared.open(
            [pluginURL],
            withApplicationAt: streamDeckAppURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }
}

#Preview {
    StreamDeckSettingsView()
}
