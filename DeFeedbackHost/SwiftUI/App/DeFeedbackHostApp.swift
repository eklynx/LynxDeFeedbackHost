//
//  DeFeedbackHostApp.swift
//  DeFeedbackHost
//
//  Created by Edgars Klepers on 9/16/26.
//

import SwiftUI
import os

@main
struct DeFeedbackHostApp: App {

    static let aboutWindowID = "about"
    static let settingsWindowID = "settings"

    /// The delegate owns the host and web services (and the launch policy); scenes just borrow them.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private var host: AudioHost { appDelegate.host }
    private var web: WebControlService { appDelegate.web }

    var body: some Scene {
        Window("DeFeedback Host", id: "host") {
            ContentView(host: host, web: web)
                .environment(appDelegate.updates)
                .environment(appDelegate.permissions)
        }
        .defaultSize(width: 900, height: 620)
        .commands {
            CommandGroup(replacing: .appInfo) {
                AboutCommand()
                CheckForUpdatesCommand(updates: appDelegate.updates)
            }
            CommandGroup(replacing: .appSettings) {
                SettingsCommand()
            }
        }

        Window("About \(AppInfo.name)", id: Self.aboutWindowID) {
            AboutView()
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .commandsRemoved()

        Window("Settings", id: Self.settingsWindowID) {
            SettingsView(host: host, web: web)
            .environment(appDelegate.updates)
            .environment(appDelegate.permissions)
        }
        // Fixed width, height resizable between the tabs' limits (see SettingsTabFrame.swift).
        .windowResizability(.contentSize)
        .defaultSize(width: SettingsWindowLayout.width, height: SettingsWindowLayout.maxContentHeight)
    }
}
