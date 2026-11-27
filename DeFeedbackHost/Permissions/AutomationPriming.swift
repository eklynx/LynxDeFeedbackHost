//
//  AutomationPriming.swift
//  DeFeedbackHost
//
//  SOURCE OF TRUTH for getting the Automation (System Events) permission listed in System Settings before
//  the first real shutdown (issue #62). Spec: docs/shutdown-spec.md (SH25 to SH27), tests:
//  DeFeedbackHostTests/AutomationPrimingTests.swift. Agents: call `primeIfNeeded()` when a shutdown becomes
//  possible; don't try to "warm up" the permission by running AppleScript (see below).
//
//  Why: macOS lists an app under Privacy › Automation only after it has asked for the permission.
//  Until the first real shutdown nothing did, so the user could not grant access ahead of time.
//  Measured on a real Mac: an `NSAppleScript` `get name` returned success in 45 ms without ever reaching
//  System Events, and nothing was prompted or listed. `AEDeterminePermissionToAutomateTarget(askUser: true)`,
//  with System Events already running, is the call that prompts and lists the app.
//
//  Contract of `primeIfNeeded()`:
//  - Happy path: shutdown is enabled and test mode is off, so it starts System Events (hidden) if needed, waits
//    for it, then asks for the permission with `askUser: true`. macOS shows its consent prompt (first time)
//    and lists the app. Returns true.
//  - Not needed (shutdown disabled, or test mode on): asks nothing and returns false.
//  - Edge cases: a denied or undetermined answer is not an error here; the Automation warning from
//    `AutomationPermission` already reports it. macOS asks only once, so a user who denied it earlier gets
//    no prompt. The ask blocks the main thread while the prompt is up, as the real shutdown does.
//  - Callers: the app at launch (AppDelegate) and the Shutdown settings section whenever shutdown is turned
//    on or test mode is turned off. Call `permissions.refresh()` afterwards to re-read the state.
//
import Foundation
import os

@MainActor
final class AutomationPriming {

    private let settings: ShutdownSettings
    private let authorizer: AutomationAuthorizing

    init(settings: ShutdownSettings, authorizer: AutomationAuthorizing? = nil) {
        self.settings = settings
        self.authorizer = authorizer ?? SystemAutomationAuthorizer()
    }

    /// Asks for the permission if a real shutdown is possible right now (SH5's condition). Returns whether it did.
    @discardableResult
    func primeIfNeeded() async -> Bool {
        guard settings.isEnabled, !settings.isTestMode else {
            Logger.host_application.notice("Automation priming skipped (shutdown off or test mode on)")
            return false
        }
        await authorizer.ensureTargetRunning()
        let state = authorizer.state(askUser: true)
        Logger.host_application.notice("Automation priming: asked for the permission, state \(String(describing: state), privacy: .public)")
        return true
    }
}
