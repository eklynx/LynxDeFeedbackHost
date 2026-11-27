//
//  AutomationPrimingTests.swift
//  DeFeedbackHostTests
//
//  Covers docs/shutdown-spec.md rules SH25 to SH27 (#62). A fake authorizer and an isolated UserDefaults
//  suite, so no test asks macOS for the real permission.
//
//  - Tests initially created with AI with human edits, but all reviewed by human
//
import Foundation
import Testing

@testable import DeFeedbackHost

@MainActor
private final class RecordingAuthorizer: AutomationAuthorizing {
    var result: PermissionState = .notDetermined
    private(set) var askUserCalls: [Bool] = []
    private(set) var ensureRunningCount = 0
    private(set) var orderedCalls: [String] = []

    func state(askUser: Bool) -> PermissionState {
        askUserCalls.append(askUser)
        orderedCalls.append("state")
        return result
    }
    func ensureTargetRunning() async {
        ensureRunningCount += 1
        orderedCalls.append("ensureRunning")
    }
}

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

    @Test("SH25: with shutdown enabled and test mode off, System Events is started first, then the permission is asked for")
    func primesWhenShutdownIsPossible() async {
        let authorizer = RecordingAuthorizer()
        let priming = AutomationPriming(settings: makeSettings(enabled: true, testMode: false), authorizer: authorizer)

        #expect(await priming.primeIfNeeded() == true)
        #expect(authorizer.orderedCalls == ["ensureRunning", "state"])
        #expect(authorizer.askUserCalls == [true])
    }

    @Test("SH26: nothing is asked while shutdown is disabled or test mode is on")
    func doesNotPrimeWhenNotNeeded() async {
        for (enabled, testMode) in [(false, false), (false, true), (true, true)] {
            let authorizer = RecordingAuthorizer()
            let priming = AutomationPriming(settings: makeSettings(enabled: enabled, testMode: testMode), authorizer: authorizer)

            #expect(await priming.primeIfNeeded() == false, "enabled \(enabled), test mode \(testMode)")
            #expect(authorizer.orderedCalls.isEmpty)
        }
    }

    @Test("SH27: a denied or undetermined answer is not an error and still counts as primed")
    func denialIsNotAnError() async {
        for answer in [PermissionState.denied, .notDetermined, .unknown] {
            let authorizer = RecordingAuthorizer()
            authorizer.result = answer
            let priming = AutomationPriming(settings: makeSettings(enabled: true, testMode: false), authorizer: authorizer)

            #expect(await priming.primeIfNeeded() == true, "answer \(answer)")
            #expect(authorizer.askUserCalls.count == 1)
        }
    }
}
