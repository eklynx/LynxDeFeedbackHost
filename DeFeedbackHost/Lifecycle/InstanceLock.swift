//
//  InstanceLock.swift
//  DeFeedbackHost
//
//  Contract for the "one running copy" lock. See LaunchSupervision.swift for how it is used.
//
import Foundation

/// A cross-process, crash-safe lock that proves this process is the only running instance.
///
/// Happy path: `tryAcquire()` returns `true`; the process calls `heartbeat()` periodically from its
/// main run loop for the rest of its life. The OS drops the lock automatically on any exit or crash,
/// so a stale lock file can never block a restart.
///
/// Errors / edge cases:
/// - `tryAcquire()` returns `false` when another live process holds it; `holderPID()` says who.
/// - If the lock file cannot be opened at all, `tryAcquire()` returns `true` (fail open) so a
///   filesystem problem never prevents the app from starting.
/// - A holder whose main thread is hung stops calling `heartbeat()`; `holderHeartbeatAge()` grows.
protocol InstanceLock: AnyObject {

    /// Takes the lock without waiting. Idempotent for the current holder.
    func tryAcquire() -> Bool

    /// Gives the lock up early (tests; normally the OS does it at exit).
    func release()

    /// PID recorded by the current holder, or nil when the lock is free/unreadable.
    func holderPID() -> pid_t?

    /// Marks the holder as alive. Only meaningful while this process holds the lock.
    func heartbeat()

    /// Seconds since the holder last called `heartbeat()` (or acquired); nil when unknown.
    func holderHeartbeatAge() -> TimeInterval?
}
