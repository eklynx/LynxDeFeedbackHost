//
//  UpdateScheduler.swift
//  DeFeedbackHost
//
//  Pure timing policy for background probes. Contract context: UpdateChecking.swift (edge case 6).
//  No timers or I/O here, so the policy is unit-testable; `UpdateService` owns the actual sleeping.
//
import Foundation

enum UpdateScheduler {

    /// Floor for any retry, so a broken feed can never turn into a request storm.
    static let minimumDelay: TimeInterval = 60

    /// How long to wait before retrying after a failed probe (capped at the chosen interval).
    static let failureRetryDelay: TimeInterval = 15 * 60

    /// Seconds to wait before the NEXT background probe.
    ///
    /// - Parameters:
    ///   - result: how the probe that just finished went.
    ///   - interval: the user's chosen interval.
    /// - Returns: a delay of at least `minimumDelay`.
    static func delay(after result: ProbeResult, interval: UpdateInterval) -> TimeInterval {
        switch result {
        case .upToDate, .updateAvailable:
            return max(minimumDelay, interval.seconds)
        case .failed:
            // Most failures are transient (woke up offline, feed briefly down), so retry well
            // before a long interval would, but never faster than the floor, and never slower
            // than the interval the user chose.
            return min(interval.seconds, max(minimumDelay, failureRetryDelay))
        }
    }
}
