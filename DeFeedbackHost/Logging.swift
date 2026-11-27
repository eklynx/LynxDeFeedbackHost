//
//  Logging.swift
//  DeFeedbackHost
//
//  Created by Edgars Klepers on 9/16/26.
//

import Foundation
import os

extension Logger {
    private static var subsystem = Bundle.main.bundleIdentifier ?? "com.eklynx.sound.DeFeedbackHost"

    static let ui = Logger(subsystem: subsystem, category: "UI")
    static let host_application = Logger(subsystem: subsystem, category: "HostApp")
    static let audio = Logger(subsystem: subsystem, category: "Audio")
    static let webserver = Logger(subsystem: subsystem, category: "WebServer")
}
