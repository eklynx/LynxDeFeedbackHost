//
//  ConfiguredShutdown.swift
//  DeFeedbackHost
//
//  The `SystemShutdown` the app hands out: picks the real or the test implementation from
//  `ShutdownSettings.isTestMode` at call time, so flipping the setting applies to the next command.
//  Contract: SystemShutdown.swift.
//
import Foundation

@MainActor
final class ConfiguredShutdown: SystemShutdown {

    private let settings: ShutdownSettings
    private let real: SystemShutdown
    private let test: SystemShutdown

    init(settings: ShutdownSettings,
         real: SystemShutdown? = nil,
         test: SystemShutdown? = nil) {
        self.settings = settings
        self.real = real ?? SystemEventsShutdown()
        self.test = test ?? TestShutdown()
    }

    var isTestMode: Bool { settings.isTestMode }

    func perform() async throws {
        // One read, so the choice can't change halfway through.
        let useTest = settings.isTestMode
        try await (useTest ? test : real).perform()
    }
}
