//
//  DeFeedbackHostApp.swift
//  DeFeedbackHost
//
//  Created by Edgars Klepers on 9/16/26.
//

import SwiftUI

@main
struct DeFeedbackHostApp: App {

    static let aboutWindowID = "about"

    @State private var host: AudioHost
    @State private var web: WebControlService

    init() {
        let host = AudioHost()
        _host = State(initialValue: host)
        _web = State(initialValue: WebControlService(host: host))
    }

    var body: some Scene {
        Window("DeFeedback Host", id: "host") {
            ContentView(host: host, web: web)
        }
        .defaultSize(width: 900, height: 620)
        .commands {
            CommandGroup(replacing: .appInfo) {
                AboutCommand()
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
        }
    }
}
