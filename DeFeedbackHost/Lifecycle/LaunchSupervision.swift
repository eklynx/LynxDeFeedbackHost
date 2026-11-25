//
//  LaunchSupervision.swift
//  DeFeedbackHost
//
//  ┌─────────────────────────────────────────────────────────────────────────────────────────┐
//  │ AI AGENTS: this file is the SOURCE OF TRUTH for the `Lifecycle` namespace. Read the     │
//  │ contracts below before touching launch, single-instance or crash-restart behaviour.     │
//  │ Implementations live in sibling files; spec lives in docs/launch-and-restart-spec.md.   │
//  └─────────────────────────────────────────────────────────────────────────────────────────┘
//
//  # Model
//
//  launchd is the ONLY process supervisor. Two launch agents (same binary) are registered through
//  `SMAppService`, one per user-facing setting:
//
//    * login agent       (`RunAtLoad`)  — "Launch at login". Starts the app; does not supervise it.
//    * supervisor agent  (`KeepAlive`)  — "Restart after crash". Restarts the app after any exit
//                                         that is not status 0. Started only on demand.
//
//  launchd can only restart processes it spawned. So when "Restart after crash" is on, every launch
//  path (Finder, Dock, login agent) hands off to the supervisor job and exits 0 (`handOff`).
//
//  # Startup contract (`LaunchCoordinator.decide`)
//
//  Happy path
//    1. Restart-after-crash off, nobody else running  -> `.proceed`.
//    2. Restart-after-crash on, not under supervisor  -> `.handOffToSupervisor`; the process asks
//       launchd to start the supervised job, then exits 0 (never restarted).
//    3. Under the supervisor, lock free               -> `.proceed`.
//
//  Single instance (requirement 1)
//    4. Lock held by a live, heartbeating instance    -> `.activateHolderAndExit` (exit 0).
//
//  Error / edge cases
//    5. Handoff failed (agent not approved, kickstart non-zero) -> run directly (`.proceed`);
//       auto-restart simply is not active and the settings UI shows why.
//    6. Supervised launch finds lock held by an instance whose heartbeat is stale (hung/orphaned)
//       -> `.exitAndRetry` (exit non-zero so launchd retries in ~10 s). After repeated strikes
//       `StaleHolderPolicy` may order `.killHolderThenProceed`. Manual launches never kill.
//    7. Lock cannot be created at all (disk/permissions)       -> `.proceed` (fail open: better
//       a possible duplicate than an app that can't start).
//
//  Exit codes (requirement 3)
//    * Cmd+Q / menu Quit / logout / shutdown / SIGTERM  -> exit 0   -> launchd does NOT restart.
//    * Crash, SIGKILL, Force Quit, non-zero exit        -> launchd restarts (when supervised).
//
import Foundation

/// Stable launchd labels. The matching plists in the app bundle MUST use exactly these labels.
enum LaunchAgentKind: CaseIterable, Sendable {
    case login
    case supervisor

    var label: String {
        switch self {
        case .login: "com.eklynx.sound.DeFeedbackHost.login"
        case .supervisor: "com.eklynx.sound.DeFeedbackHost.supervisor"
        }
    }

    var plistName: String { "\(label).plist" }
}

/// Facts about how this process was started.
protocol LaunchSupervision: Sendable {

    /// True when launchd started this process as the supervisor job (so crashes will be restarted).
    var isRunningUnderSupervisor: Bool { get }

    /// Asks launchd to start the supervisor job.
    ///
    /// - Parameter afterDelay: seconds to wait before launchd is asked; lets a still-running
    ///   process finish quitting first (used by "Relaunch now").
    /// - Returns: `true` when the request was accepted (or scheduled, when delayed). `false` when
    ///   launchd refused (agent not approved/registered). The caller must then keep running.
    /// - Note: launchd refuses to start a job that is already running (non-zero status), so a
    ///   handoff while a supervised instance exists returns `false`; the caller then falls through
    ///   to the instance lock, which activates that instance. Extra single-instance guard.
    func handOff(afterDelay: TimeInterval) -> Bool
}
