//
//  AppDelegate.swift
//  DeFeedbackHost
//
//  Created by Edgars Klepers on 10/12/26.
//

import AppKit
import ServiceManagement
import os

/// Owns the process-lifetime services and enforces launch policy: single instance, hand-off to the
/// launchd supervisor for crash restarts, and clean exit codes. The rules live in
/// `Lifecycle/LaunchSupervision.swift` (source of truth); this class only applies the decision.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    let host: AudioHost
    let web: WebControlService

    private let lock: InstanceLock = FileInstanceLock.standard()

    /// Opt-in update checking (issue #7). Contract: `Updates/UpdateChecking.swift`. Lazy because
    /// the relaunch hook needs `lock`, and so nothing Sparkle-related exists before launch policy.
    lazy var updates: UpdateService = {
        var engine: UpdateEngine
        if Self.isRunningUnderXCTest {
            engine = InertUpdateEngine()
        } else {
            // Sparkle quits this process and starts the new one; free the lock for it first.
            engine = SparkleUpdateEngine(willRelaunch: { [lock] in lock.release() })
        }
        #if DEBUG
        // Debug builds only: `defaults write … Updates.simulateVersion -string 9.9.9`.
        if !Self.isRunningUnderXCTest, let simulated = SimulatedUpdateEngine.fromDefaults() {
            engine = simulated
        }
        #endif
        return UpdateService(engine: engine)
    }()
    /// Asks for the permissions the app needs at launch and reports any that are denied (issue #14).
    /// Contract: `Permissions/PermissionChecking.swift`. Inert under XCTest so no test raises a prompt.
    /// Shutdown settings and the command's mechanism (docs/shutdown-spec.md, contract in `Shutdown/`).
    lazy var shutdownSettings = UserDefaultsShutdownSettings()
    lazy var systemShutdown: SystemShutdown = ConfiguredShutdown(settings: shutdownSettings)
    lazy var permissions: PermissionService = {
        if Self.isRunningUnderXCTest {
            return PermissionService(checkers: Permission.allCases.map(InertPermissionChecker.init))
        }
        return PermissionService(checkers: [MicrophonePermission(),
                                            LocalNetworkPermission(),
                                            LoginItemsPermission(),
                                            AutomationPermission(settings: shutdownSettings)])
    }()
    private var heartbeatTimer: Timer?
    private var sigtermSource: DispatchSourceSignal?

    override init() {
        let host = AudioHost()
        self.host = host
        self.web = WebControlService(host: host)
        super.init()
    }

    /// Unit tests run hosted inside this app. They must neither bow out to a copy the developer is
    /// running nor touch the real lock/strike counter, so the launch policy is skipped for them.
    private static let isRunningUnderXCTest =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningUnderXCTest else { return }

        // Runs before any settings are loaded, devices opened or the web port bound, so exiting
        // here cannot clobber the running instance's state. The exits below call exit() rather than
        // NSApp.terminate on purpose: nothing has been started that needs saving, and the exit
        // code must be exact (0 = never restarted, non-zero = launchd retries).
        let coordinator = LaunchCoordinator(
            lock: lock,
            supervision: LaunchdSupervision(),
            supervisorEnabled: { LaunchAgentService().status(of: .supervisor) == .enabled },
            strikes: UserDefaultsStrikeStore())

        switch coordinator.decide() {
        case .proceed:
            startHeartbeat()
            exitCleanlyOnSIGTERM()
        case .exitHandedOff:
            Logger.host_application.notice("Handed launch off to the launchd supervisor; exiting.")
            activateRunningInstance(pid: nil)
            exit(0)
        case .activateHolderAndExit(let pid):
            Logger.host_application.notice("Another instance is already running (pid \(pid ?? 0)); activating it and exiting.")
            activateRunningInstance(pid: pid)
            exit(0)
        case .exitAndRetry:
            Logger.host_application.error("Instance lock is held by an unresponsive process; exiting so launchd retries.")
            exit(1)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        web.updateSource = updates
        web.warningSources = [updates, permissions]
        web.shutdownSettings = shutdownSettings
        web.systemShutdown = systemShutdown
        if !Self.isRunningUnderXCTest {
            updates.start()   // probes now only if the user opted in

            // Ask for everything up front, so no prompt waits for a settings tab to be opened. Automation can
            // only be granted after the app has asked for it, so ask once up front (issue #62).
            Task {
                await AutomationPriming(settings: shutdownSettings).primeIfNeeded()
                await permissions.start()
            }
            // A grant made in System Settings while we run shows up when the user comes back.
            NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                   object: nil, queue: .main) { [permissions] _ in
                Task { @MainActor in await permissions.refresh() }
            }
        }

        // Started here rather than from a view so it doesn't depend on a window being shown.
        Task {
            await host.loadApplicationState()
            // make sure application state is loaded first, as it contains the web settings.
            web.reconcile()
        }
    }

    // MARK: - Liveness and exit codes

    /// Proves to later launches that our main thread is responsive; a hung process stops ticking.
    private func startHeartbeat() {
        let timer = Timer(timeInterval: LifecycleTuning.standard.heartbeatInterval, repeats: true) { [lock] _ in
            lock.heartbeat()
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer
    }

    /// SIGTERM (`kill`, shutdown, `launchctl bootout`) is an intentional stop, so it must end in a
    /// normal `terminate` (exit 0). Left alone, the default action kills the process by signal and
    /// the supervisor would treat that as a crash and restart it.
    private func exitCleanlyOnSIGTERM() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        sigtermSource = source
    }

    private func activateRunningInstance(pid: pid_t?) {
        if let pid, let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
            return
        }
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first { $0.processIdentifier != me }?
            .activate()
    }
}
