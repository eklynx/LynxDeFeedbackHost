//
//  StaleHolderPolicy.swift
//  DeFeedbackHost
//
//  Pure decision: what should a launch do when the single-instance lock is held by someone else?
//  Contract and context: LaunchSupervision.swift (edge case 6).
//
import Foundation

enum HolderVerdict: Equatable {
    /// The holder is healthy (or this launch isn't allowed to judge it): activate it and exit 0.
    case leaveAlone
    /// The holder looks stuck but we aren't sure yet: exit non-zero so launchd retries in ~10 s.
    case retryLater
    /// The holder is hung/orphaned: SIGKILL it and take over.
    case kill
}

enum StaleHolderPolicy {

    /// - Parameters:
    ///   - startedBySupervisor: this launch was spawned by the supervisor job. Manual launches must
    ///     NEVER kill anything (requirement 1: a second launch just activates the first).
    ///   - contendedLaunches: consecutive supervised launches (including this one) that found the lock held.
    ///   - heartbeatAge: seconds since the holder last proved it was alive; nil if unknown.
    ///   - holderIsSameApp: holder's PID verified to be this app, owned by this user.
    ///   - tuning: thresholds (CLI-overridable, see LifecycleTuning.swift).
    static func verdict(startedBySupervisor: Bool,
                        contendedLaunches: Int,
                        heartbeatAge: TimeInterval?,
                        holderIsSameApp: Bool,
                        tuning: LifecycleTuning = .standard) -> HolderVerdict {
        // Only a supervised launch may judge the holder; manual launches just activate it.
        guard startedBySupervisor else { return .leaveAlone }

        // Unknown age is NOT evidence of a hang: it could be a healthy holder we can't read.
        guard let heartbeatAge, heartbeatAge > tuning.staleAfter else { return .leaveAlone }

        // Stale. Keep retrying (launchd re-launches us) until the strike limit, and never kill
        // something that isn't verifiably this app.
        guard contendedLaunches >= tuning.strikesBeforeKill, holderIsSameApp else { return .retryLater }
        return .kill
    }
}
