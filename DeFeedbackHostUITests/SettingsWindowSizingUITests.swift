//
//  SettingsWindowSizingUITests.swift
//  DeFeedbackHostUITests
//
//  Regression for issue #27, measured on the REAL Settings window (an isolated SwiftUI view's fitting size
//  does not predict it: a flexible height once made every tab open at 450 pt while the unit tests passed).
//  Covers docs/settings-window-spec.md SW1 to SW4.
//
//  - Tests initially created with AI with human edits, but all reviewed by human

import AppKit
import XCTest

final class SettingsWindowSizingUITests: XCTestCase {

    /// Keep in step with `SettingsWindowLayout` (pinned by SettingsWindowLayoutTests).
    private let width: CGFloat = 440
    private let minContentHeight: CGFloat = 200
    private let maxContentHeight: CGFloat = 800
    /// The window's title bar and tab strip around the content.
    private let chromeAllowance: CGFloat = 140

    private let bundleID = "com.eklynx.sound.DeFeedbackHost"

    override func tearDown() {
        // The window remembers the size it was left at; don't leave a test's size behind for the real app.
        UserDefaults(suiteName: bundleID)?.removeObject(forKey: "NSWindow Frame settings")
    }

    @MainActor
    private func openSettings() -> (app: XCUIApplication, window: XCUIElement) {
        UserDefaults(suiteName: bundleID)?.removeObject(forKey: "NSWindow Frame settings")
        let app = XCUIApplication()
        app.launch()
        app.activate()
        app.typeKey(",", modifierFlags: .command)
        let window = app.windows["Settings"]
        XCTAssertTrue(window.waitForExistence(timeout: 10), "⌘, should open the Settings window")
        return (app, window)
    }

    /// Drags the window's bottom edge by `delta` points (positive is down) and returns the new height.
    @MainActor
    private func dragBottomEdge(of app: XCUIApplication, by delta: CGFloat) -> CGFloat {
        let window = app.windows["Settings"]
        let edge = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1.0)).withOffset(CGVector(dx: 0, dy: -1))
        edge.click(forDuration: 0.1, thenDragTo: edge.withOffset(CGVector(dx: 0, dy: delta)))
        Thread.sleep(forTimeInterval: 1)
        return app.windows["Settings"].frame.height
    }

    @MainActor
    func testSettingsWindowIsResizableWithinLimits() throws {
        let (app, window) = openSettings()
        defer { app.terminate() }

        // SW1: a fixed width, and an initial height within the maximum plus the chrome.
        XCTAssertEqual(window.frame.width, width, accuracy: 1, "the width is fixed")
        XCTAssertLessThanOrEqual(window.frame.height, maxContentHeight + chromeAllowance, "opens taller than the maximum")

        // SW2: the window is resizable (zoom enabled) and follows a drag of the bottom edge.
        XCTAssertTrue(window.buttons[XCUIIdentifierZoomWindow].isEnabled, "the window should be resizable")
        let start = window.frame.height
        let shorter = dragBottomEdge(of: app, by: -150)
        XCTAssertLessThan(shorter, start, "dragging the bottom edge up should shorten the window")

        // SW3: it can't be dragged below the minimum, however far it is pulled.
        var smallest = shorter
        for _ in 0..<6 { smallest = dragBottomEdge(of: app, by: -(smallest - 60)) }
        XCTAssertGreaterThanOrEqual(smallest, minContentHeight, "below the minimum height")
        XCTAssertLessThanOrEqual(smallest, minContentHeight + chromeAllowance, "can't shrink to the minimum")

        // SW4: it can't be dragged above the maximum, however far it is pulled (limited by the screen).
        let room = (NSScreen.main?.visibleFrame.height ?? 1000) - smallest
        var tallest = smallest
        for _ in 0..<4 { tallest = dragBottomEdge(of: app, by: min(room, 700)) }
        XCTAssertLessThanOrEqual(tallest, maxContentHeight + chromeAllowance, "taller than the maximum")
        XCTAssertGreaterThan(tallest, shorter, "dragging the bottom edge down should lengthen the window")
    }

    @MainActor
    func testEveryTabIsReachableAndKeepsTheWindowSize() throws {
        let (app, window) = openSettings()
        defer { app.terminate() }

        let height = window.frame.height
        for tab in ["Web Control", "StreamDeck", "General"] {
            let button = window.buttons[tab]
            XCTAssertTrue(button.exists, "no \(tab) tab")
            button.click()
            XCTAssertTrue(button.waitForExistence(timeout: 2))
            XCTAssertTrue(button.isSelected, "clicking \(tab) should select it")
        }
        XCTAssertEqual(app.windows["Settings"].frame.height, height, accuracy: 1, "switching tabs must not resize the window")
    }
}
