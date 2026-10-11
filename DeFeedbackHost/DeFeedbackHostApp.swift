//
//  DeFeedbackHostApp.swift
//  DeFeedbackHost
//
//  Created by Edgars Klepers on 9/16/26.
//

import SwiftUI
import ServiceManagement
import os


extension Logger {
    private static var subsystem = Bundle.main.bundleIdentifier ?? "com.eklynx.sound.DeFeedbackHost"

    static let ui = Logger(subsystem: subsystem, category: "UI")
    static let host_application = Logger(subsystem: subsystem, category: "HostApp")
    static let audio = Logger(subsystem: subsystem, category: "Audio")
    static let webserver = Logger(subsystem: subsystem, category: "WebServer")
}


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

    static let agent = SMAppService.agent(plistName: "com.eklynx.sound.DeFeedbackHost.plist")

    // Sets or unsets the launch agent that auto-starts the application.
    static func SetLaunchDaemonState(active: Bool) throws {
        do {
            if active {
                try agent.register()
            } else {
                try agent.unregister()
            }
        } catch {
            Logger.host_application.error("Error registering/unregistering launch agent: \(error)")
            throw error
        }
    }

    static func GetLaunchDaemonState() -> SMAppService.Status {
            return agent.status
    }
}
