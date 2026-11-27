//
//  ShutdownSettingsSection.swift
//  DeFeedbackHost
//
//  Settings › General section for the system shutdown command. Contract: Shutdown/ShutdownSettings.swift,
//  spec docs/shutdown-spec.md (SH1 to SH5). The toggles bind straight to the defaults keys; the
//  phrase is saved only when non-empty (SH2).
//
import SwiftUI

struct ShutdownSettingsSection: View {

    @AppStorage(UserDefaultsShutdownSettings.Key.enabled)
    private var isEnabled = UserDefaultsShutdownSettings.defaultEnabled
    @AppStorage(UserDefaultsShutdownSettings.Key.testMode)
    private var isTestMode = UserDefaultsShutdownSettings.defaultTestMode

    private let settings = UserDefaultsShutdownSettings()
    @State private var draftPhrase = ""
    @State private var phraseRefused = false

    var body: some View {
        Section {
            Toggle("Allow the shutdown command", isOn: $isEnabled)
            Toggle("Test mode (don't really shut down)", isOn: $isTestMode)

            if isEnabled && isTestMode {
                Label("Test mode is on: shutdown commands are accepted but the Mac stays up.",
                      systemImage: "testtube.2")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }

            TextField("Shutdown phrase", text: $draftPhrase)
                .onSubmit(commitPhrase)
                .onChange(of: draftPhrase) { _, _ in commitPhrase() }

            if phraseRefused {
                Label("The phrase can't be empty. The last saved phrase is still in use.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }
        } header: {
            Text("Shutdown")
        } footer: {
            Text("""
                Lets the web page and the Stream Deck shut this Mac down. The command must carry the \
                phrase exactly (capitals and spaces count). The phrase prevents accidents; it is not a \
                secret and is shown on the web page. A real shutdown asks for Automation permission \
                for System Events the first time.
                """)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .onAppear { draftPhrase = settings.phrase }
    }

    private func commitPhrase() {
        // Opening the screen must not write the default phrase into the defaults.
        guard draftPhrase != settings.phrase || draftPhrase.isEmpty else {
            phraseRefused = false
            return
        }
        phraseRefused = !settings.savePhrase(draftPhrase)
    }
}
