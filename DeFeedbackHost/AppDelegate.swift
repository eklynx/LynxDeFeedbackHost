//
//  AppDelegate.swift
//  DeFeedbackHost
//
//  Created by Edgars Klepers on 10/12/26.
//

import AppKit
import os


/// Owns the process-lifetime services and enforces a single running instance.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    let host: AudioHost
    let web: WebControlService

    /// Set when another copy was already running, so startup is skipped while we terminate.
    private var isDuplicateInstance = false

    override init() {
        let host = AudioHost()
        self.host = host
        self.web = WebControlService(host: host)
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // `LSMultipleInstancesProhibited` only covers LaunchServices launches; the launch agent
        // execs the binary directly, so check here too. This runs before any settings are loaded,
        // devices opened or the web port bound, so terminating cannot clobber the other instance.
        guard let other = otherRunningInstance() else { return }

        isDuplicateInstance = true
        Logger.host_application.notice("Another instance is already running (pid \(other.processIdentifier)); activating it and exiting.")
        other.activate()
        NSApp.terminate(nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isDuplicateInstance else { return }

        // Started here rather than from a view so it doesn't depend on a window being shown.
        Task {
            await host.loadApplicationState()
            // make sure application state is loaded first, as it contains the web settings.
            web.reconcile()
        }
    }

    private func otherRunningInstance() -> NSRunningApplication? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first { $0.processIdentifier != currentPID }
    }
}
