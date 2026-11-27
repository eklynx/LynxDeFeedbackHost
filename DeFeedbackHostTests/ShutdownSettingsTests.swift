//
//  ShutdownSettingsTests.swift
//  DeFeedbackHostTests
//
//  Covers docs/shutdown-spec.md rules SH1 to SH5 (#31). Isolated UserDefaults suites and fake
//  scripts/authorizers, so no test touches the real defaults, System Events or the Mac's power.
//
import Foundation
import Testing

@testable import DeFeedbackHost

@MainActor
struct ShutdownSettingsTests {

    private func makeDefaults() -> UserDefaults {
        let name = "ShutdownSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("SH1: a fresh install is disabled with test mode off")
    func settingsDefaults() {
        let settings = UserDefaultsShutdownSettings(defaults: makeDefaults())
        #expect(settings.isEnabled == false)
        #expect(settings.isTestMode == UserDefaultsShutdownSettings.defaultTestMode)
        #expect(settings.isTestMode == false, "test mode is opt-in: a fresh install really shuts down once enabled")
        #expect(settings.phrase == "shutdown now")
    }

    @Test("SH2: the phrase is never empty and an empty one is refused")
    func phraseNeverEmpty() {
        let defaults = makeDefaults()
        let settings = UserDefaultsShutdownSettings(defaults: defaults)
        #expect(settings.phrase == ShutdownPhrase.defaultPhrase)

        defaults.set("", forKey: UserDefaultsShutdownSettings.Key.phrase)
        #expect(settings.phrase == ShutdownPhrase.defaultPhrase, "an empty stored value reads as the default")

        #expect(settings.savePhrase("") == false)
        #expect(defaults.string(forKey: UserDefaultsShutdownSettings.Key.phrase) == "", "refused save writes nothing")

        #expect(settings.savePhrase("power down") == true)
        #expect(settings.phrase == "power down")
        #expect(settings.savePhrase("") == false)
        #expect(settings.phrase == "power down", "a refused save keeps the previous phrase")
    }

    @Test("SH3: phrase matching is exact")
    func phraseMatchesExactly() {
        let expected = "shutdown now"
        #expect(ShutdownPhrase.matches("shutdown now", expected: expected))
        #expect(!ShutdownPhrase.matches("Shutdown now", expected: expected))
        #expect(!ShutdownPhrase.matches(" shutdown now", expected: expected))
        #expect(!ShutdownPhrase.matches("shutdown now ", expected: expected))
        #expect(!ShutdownPhrase.matches("", expected: expected))
    }

    @Test("SH4: settings are individual defaults keys, read live")
    func settingsAreDefaultsKeys() {
        let defaults = makeDefaults()
        let settings = UserDefaultsShutdownSettings(defaults: defaults)

        defaults.set(true, forKey: "Host.shutdownEnabled")
        defaults.set(false, forKey: "Host.shutdownTestMode")
        defaults.set("bye", forKey: "Host.shutdownPhrase")
        #expect(settings.isEnabled)
        #expect(!settings.isTestMode)
        #expect(settings.phrase == "bye")

        defaults.set("yes", forKey: "Host.shutdownEnabled")   // `defaults write -string`
        defaults.set("garbage", forKey: "Host.shutdownTestMode")
        #expect(settings.isEnabled)
        #expect(settings.isTestMode == UserDefaultsShutdownSettings.defaultTestMode, "a typo falls back to the default")

        settings.isEnabled = false
        settings.isTestMode = true
        #expect(defaults.bool(forKey: "Host.shutdownEnabled") == false)
        #expect(defaults.bool(forKey: "Host.shutdownTestMode") == true)
        #expect(settings.savePhrase("again"))
        #expect(defaults.string(forKey: "Host.shutdownPhrase") == "again")
    }

    @Test("SH5: Automation warns only while shutdown is enabled and test mode is off")
    func automationWarnsOnlyWhenNeeded() async {
        let cases: [(enabled: Bool, test: Bool, warns: Bool)] = [
            (false, false, false), (false, true, false), (true, true, false), (true, false, true)
        ]
        for scenario in cases {
            let settings = UserDefaultsShutdownSettings(defaults: makeDefaults())
            settings.isEnabled = scenario.enabled
            settings.isTestMode = scenario.test
            let authorizer = StubAuthorizer(.denied)
            let service = PermissionService(checkers: [AutomationPermission(settings: settings, authorizer: authorizer)])
            await service.start()
            #expect(service.warnings.map(\.id) == (scenario.warns ? ["permission.automation"] : []),
                    "enabled \(scenario.enabled), test \(scenario.test)")
        }

        // Granted, or unknown, never warns even when needed; turning test mode on clears a warning.
        let settings = UserDefaultsShutdownSettings(defaults: makeDefaults())
        settings.isEnabled = true
        settings.isTestMode = false
        let authorizer = StubAuthorizer(.denied)
        let service = PermissionService(checkers: [AutomationPermission(settings: settings, authorizer: authorizer)])
        await service.start()
        #expect(service.warnings.count == 1)
        settings.isTestMode = true
        await service.refresh()
        #expect(service.warnings.isEmpty)
        settings.isTestMode = false
        authorizer.result = .unknown
        await service.refresh()
        #expect(service.warnings.isEmpty)
    }

    @Test("The configured shutdown follows test mode at call time; real failures map to ShutdownError")
    func shutdownImplementations() async throws {
        let settings = UserDefaultsShutdownSettings(defaults: makeDefaults())
        let runner = StubRunner()
        let configured = ConfiguredShutdown(settings: settings, real: SystemEventsShutdown(runner: runner))

        settings.isTestMode = true
        #expect(configured.isTestMode)
        try await configured.perform()
        #expect(runner.scripts.isEmpty, "test mode never runs the script")

        settings.isTestMode = false
        #expect(!configured.isTestMode)
        try await configured.perform()
        #expect(runner.scripts == [SystemEventsShutdown.script])

        runner.failure = AppleScriptFailure(number: -1743, message: "Not authorized")
        await #expect(throws: ShutdownError.notPermitted) { try await configured.perform() }

        runner.failure = AppleScriptFailure(number: -600, message: "Application isn't running")
        await #expect(throws: ShutdownError.failed("The Mac could not be asked to shut down: Application isn't running.")) {
            try await configured.perform()
        }
    }
}

@MainActor
private final class StubAuthorizer: AutomationAuthorizing {
    var result: PermissionState
    init(_ result: PermissionState) { self.result = result }
    func state(askUser: Bool) -> PermissionState { result }
}

@MainActor
private final class StubRunner: AppleScriptRunning {
    var failure: AppleScriptFailure?
    private(set) var scripts: [String] = []
    func run(_ source: String) -> AppleScriptFailure? {
        scripts.append(source)
        return failure
    }
}
