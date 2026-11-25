//
//  LaunchCoordinator.swift
//  DeFeedbackHost
//
//  Startup decision logic (contract: LaunchSupervision.swift, "Startup contract").
//  Everything with side effects is injected so the decision matrix is unit-testable.
//
import AppKit
import Foundation

enum StartupAction: Equatable {
    /// This process is the instance: load state, bind ports, show UI.
    case proceed
    /// Launchd was asked to start the supervised job; exit 0 without touching any state.
    case exitHandedOff
    /// Another healthy instance exists: activate it (pid if known) and exit 0.
    case activateHolderAndExit(pid_t?)
    /// Exit non-zero so launchd retries this supervised launch shortly.
    case exitAndRetry
}

/// Remembers how many supervised launches in a row found the lock held.
protocol StrikeStore: AnyObject {
    var count: Int { get set }
}

final class UserDefaultsStrikeStore: StrikeStore {
    private let defaults: UserDefaults
    private let key = "Lifecycle.contendedSupervisedLaunches"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var count: Int {
        get { defaults.integer(forKey: key) }
        set { defaults.set(newValue, forKey: key) }
    }
}

struct LaunchCoordinator {

    let lock: InstanceLock
    let supervision: LaunchSupervision
    let supervisorEnabled: () -> Bool
    let strikes: StrikeStore
    var isSameApp: (pid_t) -> Bool = LaunchCoordinator.processIsThisApp
    var kill: (pid_t) -> Void = { _ = Foundation.kill($0, SIGKILL) }
    var tuning: LifecycleTuning = .standard
    var pause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }

    /// How long a supervised launch waits for a previous instance to finish quitting.
    var supervisedLockWait: TimeInterval = 3
    var afterKillLockWait: TimeInterval = 2

    func decide() -> StartupAction {
        let supervised = supervision.isRunningUnderSupervisor

        // Crash restart only works for processes launchd spawned, so route every launch through it.
        // If launchd refuses (not approved, or the job is already running) fall through: the lock
        // below then either makes us the instance (restart simply isn't active) or activates the
        // instance that is already running.
        if supervisorEnabled() && !supervised && supervision.handOff(afterDelay: 0) {
            return .exitHandedOff
        }

        if acquire(waiting: supervised ? supervisedLockWait : 0) {
            strikes.count = 0
            return .proceed
        }

        let holder = lock.holderPID()
        guard supervised else { return .activateHolderAndExit(holder) }

        strikes.count += 1
        let verdict = StaleHolderPolicy.verdict(
            startedBySupervisor: true,
            contendedLaunches: strikes.count,
            heartbeatAge: lock.holderHeartbeatAge(),
            holderIsSameApp: holder.map(isSameApp) ?? false,
            tuning: tuning)

        switch verdict {
        case .leaveAlone:
            strikes.count = 0
            return .activateHolderAndExit(holder)
        case .retryLater:
            return .exitAndRetry
        case .kill:
            guard let holder, isSameApp(holder) else { return .exitAndRetry }
            kill(holder)
            guard acquire(waiting: afterKillLockWait) else { return .exitAndRetry }
            strikes.count = 0
            return .proceed
        }
    }

    private func acquire(waiting: TimeInterval) -> Bool {
        var waited: TimeInterval = 0
        while true {
            if lock.tryAcquire() { return true }
            guard waited < waiting else { return false }
            pause(0.1)
            waited += 0.1
        }
    }

    /// True when `pid` is a running copy of this app (same bundle ID). Same-user is implied by
    /// `kill(2)` permission: signalling another user's process fails harmlessly.
    static func processIsThisApp(_ pid: pid_t) -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier,
              let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return app.bundleIdentifier == bundleID
    }
}
