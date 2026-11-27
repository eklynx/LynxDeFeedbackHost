//
//  AutomationPrimingTests.swift
//  DeFeedbackHostTests
//
//  Covers docs/shutdown-spec.md rules SH25 to SH27 (#62). A fake script runner and an isolated UserDefaults
//  suite, so no test sends an Apple event to System Events.
//
//  - Tests initially created with AI with human edits, but all reviewed by human
//
import Foundation
import Testing

@testable import DeFeedbackHost

@MainActor
struct AutomationPrimingTests {

    private func makeSettings(enabled: Bool, testMode: Bool) -> UserDefaultsShutdownSettings {
        let name = "AutomationPrimingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defaults.set(enabled, forKey: UserDefaultsShutdownSettings.Key.enabled)
        defaults.set(testMode, forKey: UserDefaultsShutdownSettings.Key.testMode)
        return UserDefaultsShutdownSettings(defaults: defaults)
    }

    @Test("SH25: with shutdown enabled and test mode off, one harmless System Events event is sent")
    func primesWhenShutdownIsPossible() {
        let runner = StubRunner()
        let priming = AutomationPriming(settings: makeSettings(enabled: true, testMode: false), runner: runner)

        #expect(priming.primeIfNeeded() == true)
        #expect(runner.scripts == [AutomationPriming.script])
        #expect(!AutomationPriming.script.contains("shut down"), "priming must never be able to shut the Mac down")
    }

    @Test("SH26: nothing is sent while shutdown is disabled or test mode is on")
    func doesNotPrimeWhenNotNeeded() {
        for (enabled, testMode) in [(false, false), (false, true), (true, true)] {
            let runner = StubRunner()
            let priming = AutomationPriming(settings: makeSettings(enabled: enabled, testMode: testMode), runner: runner)

            #expect(priming.primeIfNeeded() == false, "enabled \(enabled), test mode \(testMode)")
            #expect(runner.scripts.isEmpty)
        }
    }

    @Test("SH27: a refused or failed event is not an error and still counts as primed")
    func failureIsNotAnError() {
        let runner = StubRunner()
        runner.failure = AppleScriptFailure(number: -1743, message: "Not authorized to send Apple events")
        let priming = AutomationPriming(settings: makeSettings(enabled: true, testMode: false), runner: runner)

        #expect(priming.primeIfNeeded() == true)
        #expect(runner.scripts.count == 1)
    }
}
