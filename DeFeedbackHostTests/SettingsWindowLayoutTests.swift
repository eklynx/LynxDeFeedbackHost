//
//  SettingsWindowLayoutTests.swift
//  DeFeedbackHostTests
//
//  Pins the agreed Settings window limits. The real window is measured by
//  DeFeedbackHostUITests/SettingsWindowSizingUITests.swift, which can't see app code, so it hard-codes the
//  same numbers; this test fails when the two could drift apart. Covers docs/settings-window-spec.md SW1, SW2.
//
//  - Tests initially created with AI with human edits, but all reviewed by human

import Testing

@testable import DeFeedbackHost

struct SettingsWindowLayoutTests {

    @Test("SW1: the agreed limits are 440 wide, 200 to 800 tall (update SettingsWindowSizingUITests with them)")
    func agreedLimits() {
        #expect(SettingsWindowLayout.width == 440)
        #expect(SettingsWindowLayout.minContentHeight == 200)
        #expect(SettingsWindowLayout.maxContentHeight == 800)
    }
}
