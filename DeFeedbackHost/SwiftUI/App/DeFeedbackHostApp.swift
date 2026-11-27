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
        }

        Window("About \(AppInfo.name)", id: Self.aboutWindowID) {
            AboutView()
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .commandsRemoved()

        Settings {
            TabView {
                Tab("General", systemImage: "gearshape") {
                    GeneralSettingsView(host: host)
                }
                Tab("Web Control", systemImage: "network") {
                    ServerSettingsView(host: host, web: web)
                }
                Tab("StreamDeck", systemImage: "square.grid.3x2") {
                    StreamDeckSettingsView()
                }
            }
            .environment(appDelegate.updates)
            .environment(appDelegate.permissions)
        }
    }
}
