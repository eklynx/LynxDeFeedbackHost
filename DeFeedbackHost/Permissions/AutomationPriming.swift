//
//  AutomationPriming.swift
//  DeFeedbackHost
//
//  SOURCE OF TRUTH for getting the Automation (System Events) permission listed in System Settings before
//  the first real shutdown (issue #62). Spec: docs/shutdown-spec.md (SH25 to SH27), tests:
//  DeFeedbackHostTests/AutomationPrimingTests.swift. Agents: call `primeIfNeeded()` when a shutdown becomes
//  possible; don't send other Apple events to System Events to "warm up" the permission.
//
//  Why: macOS lists an app under Privacy › Automation only after it has sent an Apple event to the target.
//  Until the first real shutdown nothing did, so the user could not grant access ahead of time.
//
//  Contract of `primeIfNeeded()`:
//  - Happy path: shutdown is enabled and test mode is off, so it sends one harmless event
//    (`tell application "System Events" to get name`; it changes nothing). macOS then shows its consent prompt
//    (first time) and lists the app. Returns true.
//  - Not needed (shutdown disabled, or test mode on): sends nothing and returns false.
//  - Edge cases: a denied or failed event is not an error here; the Automation warning from
//    `AutomationPermission` already reports it. It blocks the main thread while macOS shows the consent
//    prompt, the same as the real shutdown does.
//  - Callers: the app at launch (AppDelegate) and the Shutdown settings section whenever shutdown is turned
//    on or test mode is turned off. Call `permissions.refresh()` afterwards to re-read the state.
//
import Foundation

@MainActor
final class AutomationPriming {

    /// A read-only query; it changes nothing on the Mac.
    static let script = #"tell application "System Events" to get name"#

    private let settings: ShutdownSettings
    private let runner: AppleScriptRunning

    init(settings: ShutdownSettings, runner: AppleScriptRunning? = nil) {
        self.settings = settings
        self.runner = runner ?? NSAppleScriptRunner()
    }

    /// Sends the harmless event if a real shutdown is possible right now (SH5's condition). Returns whether it did.
    @discardableResult
    func primeIfNeeded() -> Bool {
        guard settings.isEnabled, !settings.isTestMode else { return false }
        _ = runner.run(Self.script)
        return true
    }
}
