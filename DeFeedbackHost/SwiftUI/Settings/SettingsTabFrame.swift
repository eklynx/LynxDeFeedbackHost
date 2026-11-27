//
//  SettingsTabFrame.swift
//  DeFeedbackHost
//
//  SOURCE OF TRUTH for how tall the Settings window may get. Spec: docs/settings-window-spec.md (SW1 to SW3),
//  tests: DeFeedbackHostUITests/SettingsWindowSizingUITests.swift (measures the real window) and
//  DeFeedbackHostTests/SettingsWindowLayoutTests.swift. Agents: put `.settingsTabFrame()` on every Settings
//  tab's root `Form`; do not hand-roll `.frame(width:)`, `.scrollDisabled` or `.fixedSize` there.
//
//  Contract of `settingsTabFrame()`:
//  - Happy path: the Settings window opens at a sensible height, the tab's content scrolls inside it, and the
//    user can drag the window's height between `minContentHeight` and `maxContentHeight`. The width is fixed.
//    The window remembers the size the user left it at.
//  - Edge cases: optional warning rows (Login Items approval, relaunch under supervision, update
//    available, denied permission, shutdown test mode) only add to the scrolled content. They can never
//    make the window taller than the maximum.
//  - Why a custom `Window` scene and not SwiftUI's `Settings` scene (issue #27): the `Settings` scene's window
//    can't be resized, and it sizes itself only from fixed-height content. Don't move this back to `Settings`
//    without re-checking the resizing; see docs/settings-window-spec.md.
//

import SwiftUI

enum SettingsWindowLayout {
    /// Every Settings tab is this wide.
    static let width: CGFloat = 440
    /// The agreed maximum content height of a Settings tab, in points; the window is this plus its title bar and
    /// tab strip (about 90 pt), and the user can't drag it taller. Below it the tab scrolls.
    static let maxContentHeight: CGFloat = 800
    /// The shortest the user can drag a Settings tab, in points.
    static let minContentHeight: CGFloat = 200
}

extension View {
    /// Sizes a Settings tab's `Form`: fixed width, a height the user can drag between the agreed minimum and
    /// maximum, opening at the content's height, and scrolling inside the window when it doesn't all fit.
    func settingsTabFrame() -> some View {
        modifier(SettingsTabFrame())
    }
}

private struct SettingsTabFrame: ViewModifier {

    /// The form's natural height, measured after layout; the window's opening height comes from it.
    /// Zero only until the first layout pass.
    @State private var contentHeight: CGFloat = 0

    func body(content: Content) -> some View {
        // The form keeps its full natural height (no scrolling of its own) so it can be measured; the
        // ScrollView around it takes over when the window is shorter than that.
        ScrollView {
            content
                .scrollDisabled(true)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { contentHeight = $0 })
        }
        .frame(width: SettingsWindowLayout.width)
        .frame(minHeight: SettingsWindowLayout.minContentHeight,
               idealHeight: min(max(contentHeight, SettingsWindowLayout.minContentHeight), SettingsWindowLayout.maxContentHeight),
               maxHeight: SettingsWindowLayout.maxContentHeight)
    }
}
