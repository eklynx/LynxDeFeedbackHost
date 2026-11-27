//
//  SettingsView.swift
//  DeFeedbackHost
//
//  The Settings window's content: a strip of icon-over-label tabs (the look of the system Settings window)
//  and the selected tab below it. It is a hand-built strip, not `TabView`, because the `Settings` scene
//  can't be resized, a `TabView` in a regular `Window` draws a segmented control without icons, and a
//  `.toolbar` on this window drew nothing.
//  Sizing contract: SettingsTabFrame.swift. Spec: docs/settings-window-spec.md.
//

import SwiftUI

struct SettingsView: View {

    enum SettingsTab: String, CaseIterable, Identifiable {
        case general = "General"
        case webControl = "Web Control"
        case streamDeck = "StreamDeck"

        var id: Self { self }

        var systemImage: String {
            switch self {
            case .general: "gearshape"
            case .webControl: "network"
            case .streamDeck: "square.grid.3x2"
            }
        }
    }

    let host: AudioHost
    let web: WebControlService

    @State private var selection: SettingsTab = .general

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(SettingsTab.allCases) { tab in
                    tabButton(tab)
                }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(.bar)

            Divider()

            switch selection {
            case .general: GeneralSettingsView(host: host)
            case .webControl: ServerSettingsView(host: host, web: web)
            case .streamDeck: StreamDeckSettingsView()
            }
        }
        .frame(width: SettingsWindowLayout.width)
    }

    private func tabButton(_ tab: SettingsTab) -> some View {
        Button {
            selection = tab
        } label: {
            VStack(spacing: 2) {
                Image(systemName: tab.systemImage).font(.title3)
                Text(tab.rawValue).font(.caption)
            }
            .frame(minWidth: 76)
            .padding(.vertical, 2)
            .foregroundStyle(selection == tab ? Color.accentColor : Color.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.rawValue)
        .accessibilityAddTraits(selection == tab ? .isSelected : [])
    }
}
