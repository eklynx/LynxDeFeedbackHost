//
//  SystemEventsShutdown.swift
//  DeFeedbackHost
//
//  Real shutdown through System Events. Contract: SystemShutdown.swift. Needs the Automation
//  permission (entitlement com.apple.security.automation.apple-events and
//  NSAppleEventsUsageDescription); a denial is `ShutdownError.notPermitted`.
//
import Foundation

@MainActor
final class SystemEventsShutdown: SystemShutdown {

    static let script = #"tell application "System Events" to shut down"#
    /// AppleScript's number for "not authorized to send Apple events".
    static let notPermittedNumber = -1743

    let isTestMode = false
    private let runner: AppleScriptRunning

    init(runner: AppleScriptRunning? = nil) {
        self.runner = runner ?? NSAppleScriptRunner()
    }

    func perform() async throws {
        guard let failure = runner.run(Self.script) else { return }
        if failure.number == Self.notPermittedNumber {
            throw ShutdownError.notPermitted
        }
        let detail = failure.message.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentence = detail.hasSuffix(".") ? detail : detail + "."
        throw ShutdownError.failed("The Mac could not be asked to shut down: \(sentence)")
    }
}
