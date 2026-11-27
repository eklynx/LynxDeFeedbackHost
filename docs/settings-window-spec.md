# Settings window sizing: spec

Source of truth in code: `DeFeedbackHost/SwiftUI/Settings/SettingsTabFrame.swift` (`SettingsWindowLayout`,
`settingsTabFrame()`), `SettingsView.swift` (the tab strip) and the `Window` scene in `DeFeedbackHostApp.swift`.
Tests: `DeFeedbackHostUITests/SettingsWindowSizingUITests.swift` (SW1–SW4, measured on the real window) and
`DeFeedbackHostTests/SettingsWindowLayoutTests.swift` (pins the numbers). Origin: GitHub issue #27 (the
Settings window grew taller than the screen).

## Model

Settings is a regular `Window` scene opened by "Settings…" (⌘,), not SwiftUI's `Settings` scene. At the top is
a strip of icon-over-label tabs (General, Web Control, StreamDeck); below it is the selected tab, a grouped
`Form` wrapped by `.settingsTabFrame()`.

- The width is fixed at **440 pt**.
- The height is user-resizable between **200 pt** (`minContentHeight`) and **800 pt** (`maxContentHeight`) of
  content; the window adds about 90 pt of title bar and tab strip. A tab with more content than the window is
  tall scrolls inside the window; General always does at the maximum.
- Switching tabs keeps the window's size. The window remembers the size the user left it at.
- Optional warning rows (Login Items approval, relaunch under supervision, an update available, a denied
  permission, shutdown test mode, an empty shutdown phrase) only add to the scrolled content; they never grow
  the window past the maximum.

Why a `Window` and a hand-built tab strip (investigated for #27): SwiftUI's `Settings` scene window can't be
resized (zoom stays disabled, dragging the edge does nothing, with or without `.windowResizability` or
`.resizable` set from AppKit) and sizes itself only from fixed-height tab content; a flexible height made it
ignore the tabs and open at 450 pt. In a regular `Window`, `TabView` draws a segmented control without icons
and a `.toolbar` tab strip drew nothing, hence the strip in the window content.

Why 800: the window first came out at 450 pt (too small); about double that was asked for. No smallest
supported display is documented. On a laptop with roughly 860 pt of usable height a window at the maximum
(about 890) is slightly over, but the user can drag it shorter and the size is remembered; lower the constant
if that matters.

Not covered here: the main window (`ContentView`, minimum height 900 pt) has its own sizing rule, U17 in
`docs/updates-spec.md`.

## Rules

| Id | Rule | Test |
|----|------|------|
| SW1 | The window is 440 wide and opens no taller than the maximum plus its chrome. The limits are pinned at 440, 200 and 800. | `testSettingsWindowIsResizableWithinLimits`, `agreedLimits` |
| SW2 | The window is resizable in height: dragging the bottom edge changes it. | `testSettingsWindowIsResizableWithinLimits` |
| SW3 | It can't be dragged shorter than the minimum. | `testSettingsWindowIsResizableWithinLimits` |
| SW4 | It can't be dragged taller than the maximum. Every tab is reachable from the strip and switching tabs keeps the window's size. | `testSettingsWindowIsResizableWithinLimits`, `testEveryTabIsReachableAndKeepsTheWindowSize` |
