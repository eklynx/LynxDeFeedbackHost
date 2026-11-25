//
//  DebugSettingsDocTests.swift
//  DeFeedbackHostTests
//
//  Keeps docs/debug-settings.md complete: every defaults key the app defines must be documented.
//
//  - Tests initially created with AI with human edits, but all reviewed by human

import Foundation
import Testing

@testable import DeFeedbackHost

@MainActor
struct DebugSettingsDocTests {

    @Test("every defaults key defined in code is documented in docs/debug-settings.md")
    func everyKeyIsDocumented() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let doc = try String(contentsOf: root.appending(path: "docs/debug-settings.md"), encoding: .utf8)

        var keys: [String] = [
            HostPreferences.Key.autoRunOnStartup, HostPreferences.Key.newInstancesStartMuted,
            HostPreferences.Key.newInstancesStartBypassed, HostPreferences.Key.parallelRendering,
            HostPreferences.Key.bufferSize,
            LifecycleTuning.Key.heartbeatInterval, LifecycleTuning.Key.staleAfter,
            LifecycleTuning.Key.strikesBeforeKill,
            UpdatePreferences.Key.enabled, UpdatePreferences.Key.checkInterval,
            UpdatePreferences.Key.lastChecked,
        ]
        #if DEBUG
        keys.append(SimulatedUpdateEngine.defaultsKey)
        #endif

        for key in keys {
            #expect(doc.contains("`\(key)`"), "\(key) is not documented in docs/debug-settings.md")
        }
    }
}
