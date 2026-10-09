//
//  AboutView.swift
//  DeFeedbackHost
//
//  Created by Edgars Klepers on 9/20/2026.
//

import AppKit
import SwiftUI

/// Application info to display on the About view.
/// Values are read from `Bundle.main` where possible.
nonisolated enum AppInfo {

    /// `CFBundleDisplayName` if the target sets one, otherwise falls back to `CFBundleName`.
    static let name = getBundleString("CFBundleDisplayName") ?? getBundleString("CFBundleName") ?? "Lynx DeFeedback Host"

    /// `CFBundleShortVersionString`, as shown to people.
    static let shortVersion = getBundleString("CFBundleShortVersionString") ?? "—"

    /// `CFBundleVersion` — the build version (unique between builds).
    static let build = getBundleString("CFBundleVersion") ?? "—"

    /// `NSHumanReadableCopyright` - copyright string exists, otherwise nil.
    static let copyright = getBundleString("NSHumanReadableCopyright")

    /// App Home page. (not in bundle)
    static let homePage = URL(string: "https://github.com/eklynx/LynxDeFeedbackHost")!

    private static func getBundleString(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty else { return nil }
        return value
    }
}

/// The About window view.
///
/// Displays information about this app, as well as the deFeedback plugin  that this app relies on.
struct AboutView: View {

    private let plugin: PluginConfiguration.InstalledPlugin?

    init(plugin: PluginConfiguration.InstalledPlugin? = PluginConfiguration.installedPlugin) {
        self.plugin = plugin
    }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            // TODO: Verify app icon when created
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                // The name is the link rather than a URL printed under it: the address adds
                // nothing a reader wants to look at, and the title is the obvious thing to click.
                Text(AppInfo.name)
                    .font(.title2.weight(.semibold))

                Link(AppInfo.homePage.absoluteString, destination: AppInfo.homePage)
                    .help(AppInfo.homePage.absoluteString)

                Text("Version: \(AppInfo.shortVersion) (\(AppInfo.build))")
                    .foregroundStyle(.secondary)

                if let copyright = AppInfo.copyright {
                    Text(copyright)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }

                Divider()
                    .padding(.vertical, 12)

                pluginSection
                
                Divider()
                    .padding(.vertical, 12)

                Text("The makers of this application are in no way associated with Alpha Labs, LLC or the DeFeedback plugin.  Any mentions or usages of images part of Alpha Labs, LLC and the DeFeedback plugin are used so users can visually identify the purpose.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 12)

            }
        }
        .padding(24)
        .textSelection(.enabled)
        .frame(width: 460, alignment: .leading)
        // Report the full wrapped height so the content-sized window shows everything.
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var pluginSection: some View {
        Text("Hosted Audio Unit")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

        if let plugin {
            Text(plugin.version.isEmpty ? plugin.name : "\(plugin.name) \(plugin.version)")
            Link(PluginConfiguration.pluginHomepage.absoluteString,
                 destination: PluginConfiguration.pluginHomepage)
                .help(PluginConfiguration.pluginHomepage.absoluteString)
        } else {
            // Plugin not installed!
            Text(PluginConfiguration.notInstalledMessage)
                .foregroundStyle(.red)
            Link(PluginConfiguration.pluginHomepage.absoluteString,
                 destination: PluginConfiguration.pluginHomepage)
                .font(.callout)
        }

        Text(PluginConfiguration.identityDescription)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)

        if let plugin {
            // Only displays if the plugin is installed.
            Text(plugin.copyright)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
    }
}

/// Replace he Application menu's "About …" item.
struct AboutCommand: View {

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("About \(AppInfo.name)") {
            openWindow(id: DeFeedbackHostApp.aboutWindowID)
        }
    }
}

#Preview {
    AboutView()
}

/// The taller of the two layouts, and the one no development machine shows by accident.
#Preview("No plugin installed") {
    AboutView(plugin: nil)
}
