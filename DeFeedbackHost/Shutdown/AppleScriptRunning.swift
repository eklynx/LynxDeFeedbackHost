//
//  AppleScriptRunning.swift
//  DeFeedbackHost
//
//  The seam between `SystemEventsShutdown` and the real AppleScript engine, so tests never run a
//  script. Contract: SystemShutdown.swift.
//
import Foundation

/// What went wrong when a script ran.
struct AppleScriptFailure: Equatable {
    /// The AppleScript error number, e.g. -1743 when Automation permission is denied.
    let number: Int
    let message: String
}

@MainActor
protocol AppleScriptRunning: AnyObject {
    /// Runs `source`; returns nil on success.
    func run(_ source: String) -> AppleScriptFailure?
}

/// Runs scripts with `NSAppleScript`. Must be used on the main thread, which `@MainActor` ensures.
@MainActor
final class NSAppleScriptRunner: AppleScriptRunning {

    func run(_ source: String) -> AppleScriptFailure? {
        guard let script = NSAppleScript(source: source) else {
            return AppleScriptFailure(number: 0, message: "The script could not be compiled.")
        }
        var info: NSDictionary?
        script.executeAndReturnError(&info)
        guard let info else { return nil }
        let number = (info[NSAppleScript.errorNumber] as? Int) ?? 0
        let message = (info[NSAppleScript.errorMessage] as? String) ?? "Unknown error."
        return AppleScriptFailure(number: number, message: message)
    }
}
