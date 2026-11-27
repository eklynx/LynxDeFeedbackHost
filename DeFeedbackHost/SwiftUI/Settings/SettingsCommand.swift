//
//  SettingsCommand.swift
//  DeFeedbackHost
//
//  The app menu's "Settings…" item (⌘,). Settings is a regular `Window` scene, not SwiftUI's `Settings`
//  scene, because only a `Window` can be resized (see SettingsTabFrame.swift and docs/settings-window-spec.md).
//

import SwiftUI

struct SettingsCommand: View {

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Settings…") {
            openWindow(id: DeFeedbackHostApp.settingsWindowID)
        }
        .keyboardShortcut(",")
    }
}
