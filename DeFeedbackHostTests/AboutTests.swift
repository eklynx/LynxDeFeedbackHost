//
//  AboutTests.swift
//  DeFeedbackHostTests
//
//  What the About window claims about the app and about the plugin it hosts. The layout is
//  checked by the two previews in `AboutView.swift`; these cover the facts it reads.
//
//  - Tests initially created with AI with human edits, but all reviewed by human

import AudioToolbox
import Foundation
import Testing

@testable import DeFeedbackHost

struct AppInfoTests {

    /// The whole point of reading these from the bundle is that they can't disagree with it.
    @Test func theBundleIsTheSourceOfEveryFigure() {
        let bundle = Bundle.main
        #expect(AppInfo.shortVersion
                == bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        #expect(AppInfo.build
                == bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
        #expect(AppInfo.copyright
                == bundle.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String)
    }

    /// The display name and the bundle name differ in this target — "Lynx DeFeedback Host" against
    /// "DeFeedbackHost" — and the menu bar shows the display name, so About has to as well.
    @Test func theNameIsTheOneMacOSDisplays() {
        let displayName =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        #expect(displayName != nil, "the target is expected to set a display name")
        #expect(AppInfo.name == displayName)
    }

    /// A copyright line is a claim the bundle has to be making, not one the view invents.
    @Test func theCopyrightIsCarriedByTheApp() throws {
        let copyright = try #require(AppInfo.copyright)
        #expect(copyright.contains("©"))
    }

    /// The app's copyright and the plugin's are two different claims by two different parties,
    /// which is the whole reason they sit in separate sections of the window.
    @Test func theAppAndPluginCopyrightsAreNotTheSameLine() throws {
        let appCopyright = try #require(AppInfo.copyright)
        #expect(appCopyright != PluginConfiguration.copyrightFallback)
        #expect(appCopyright != PluginConfiguration.installedPlugin?.copyright)
    }

    /// Clicking the app's name has to go somewhere, and somewhere web.
    @Test func theHomePageIsAWebAddress() {
        #expect(AppInfo.homePage.scheme == "https")
        #expect(AppInfo.homePage.host() != nil)
    }
}

struct PluginIdentityTests {

    /// `fourCharacterString` is the inverse of `fourCharacterCode`, which is what lets the codes
    /// be read off a line of `auval -a` in one direction and printed in About in the other.
    @Test func codesRoundTripBackToTheirCharacters() {
        #expect(os4CharToString(stringToOS4Char("aufx")) == "aufx")
        #expect(os4CharToString(stringToOS4Char("FbTI")) == "FbTI")
        #expect(os4CharToString(stringToOS4Char("jDSP")) == "jDSP")
        #expect(os4CharToString(kAudioUnitType_Effect) == "aufx")
    }

    /// Four characters wide whatever the bytes are: a mistyped constant should look wrong rather
    /// than look like a shorter, plausible code.
    @Test func unprintableBytesKeepTheWidth() {
        #expect(os4CharToString(0) == "????")
        #expect(os4CharToString(0x61_00_62_FF) == "a?b?")
    }

    /// The triplet About shows has to be the triplet the host actually loads.
    @Test func theIdentityDescribedIsTheOneConfigured() {
        let expected = [PluginConfiguration.componentType,
                        PluginConfiguration.componentSubType,
                        PluginConfiguration.componentManufacturer]
            .map(os4CharToString)
            .joined(separator: " ")

        #expect(PluginConfiguration.identityDescription == expected)
        #expect(PluginConfiguration.identityDescription.split(separator: " ").count == 3)
        #expect(PluginConfiguration.identityDescription.count == 14)
    }

    /// One registrar, one answer: About must not say a plugin is loaded while the window says it
    /// isn't installed, or the reverse. Written as an equivalence rather than asserting the
    /// plugin is present, so it holds on a machine without it.
    @Test func theDescriptionAgreesWithWhetherItIsInstalled() {
        #expect((PluginConfiguration.installedPlugin != nil) == PluginConfiguration.isInstalled)
    }

    /// A plugin that's there is named and versioned; nothing is fabricated for one that isn't.
    @Test func anInstalledPluginIsNamedAndVersioned() throws {
        try #require(PluginConfiguration.isInstalled,
                     "needs the configured Audio Unit registered on this machine")
        let plugin = try #require(PluginConfiguration.installedPlugin)
        #expect(!plugin.name.isEmpty)
        // The full component name, so it says who made it — not the host's own short label.
        #expect(plugin.name.contains(":"))
        // Either a real major.minor.patch or empty, never a made-up "0.0.0".
        #expect(plugin.version.split(separator: ".").count == 3 || plugin.version.isEmpty)
    }

    /// The plugin's copyright is never blank while a plugin is installed: the bundle's own line
    /// where it publishes one, the configured attribution where it doesn't.
    @Test func anInstalledPluginIsAlwaysAttributed() throws {
        try #require(PluginConfiguration.isInstalled,
                     "needs the configured Audio Unit registered on this machine")
        let plugin = try #require(PluginConfiguration.installedPlugin)
        #expect(!plugin.copyright.isEmpty)
        #expect(plugin.copyright.contains("©"))
    }

    /// A code triplet no plugin registers must match no bundle — otherwise the scan would be
    /// handing back whichever copyright it happened to read first.
    @Test func anIdentityNoBundleDeclaresFindsNothing() {
        #expect(PluginConfiguration.bundleCopyright(type: stringToOS4Char("zzzz"),
                                                    subType: stringToOS4Char("zzzz"),
                                                    manufacturer: stringToOS4Char("zzzz"))
                == nil)
    }

    /// The bundle scan is the *primary* source for the plugin's copyright, but the configured
    /// plugin publishes none — and neither does anything else that happens to be installed — so
    /// against the real directories the scan can only ever return `nil`, which looks exactly
    /// like a scan that doesn't work. So this builds a `.component` that does publish one and
    /// points the scan at it, which proves the matching and the plist read are sound on any
    /// machine rather than only on one with the right plugin installed.
    @Test func theScanReadsARealCopyrightFromAPublishingBundle() throws {
        try withComponentBundle(copyright: "Test Unit © Nobody At All.") { directory in
            #expect(PluginConfiguration.bundleCopyright(type: Self.testType,
                                                        subType: Self.testSubType,
                                                        manufacturer: Self.testManufacturer,
                                                        searching: [directory])
                    == "Test Unit © Nobody At All.")

            // Matched on identity, not on being the only bundle there: one wrong code out of the
            // three is a miss, or the scan would quote some other maker's line as this plugin's.
            #expect(PluginConfiguration.bundleCopyright(type: Self.testType,
                                                        subType: Self.testSubType,
                                                        manufacturer: stringToOS4Char("zzzz"),
                                                        searching: [directory])
                    == nil)
        }
    }

    /// The configured plugin's own situation: a bundle that registers the unit but carries no
    /// copyright key. `nil` is what sends `installedPlugin` to `copyrightFallback`, so this is
    /// the case that has to return `nil` for the right reason rather than by failing to match.
    @Test func aBundleWithNoCopyrightKeyFallsThrough() throws {
        try withComponentBundle(copyright: nil) { directory in
            #expect(PluginConfiguration.bundleCopyright(type: Self.testType,
                                                        subType: Self.testSubType,
                                                        manufacturer: Self.testManufacturer,
                                                        searching: [directory])
                    == nil)
        }
    }

    // MARK: - A throwaway plugin bundle

    // Codes no shipping unit uses, so a stray real bundle can't satisfy these tests.
    static let testType = stringToOS4Char("aufx")
    static let testSubType = stringToOS4Char("tsSb")
    static let testManufacturer = stringToOS4Char("tsMf")

    /// Builds a minimal `.component` in a temporary directory, hands its parent to `body`, and
    /// removes it afterwards.
    ///
    /// Only `Contents/Info.plist` — no executable, no resources. The scan reads the plist through
    /// `Bundle` and never loads any code, so that's the whole bundle it needs to see. A `nil`
    /// `copyright` omits the key entirely, which is not the same as an empty string: the scan
    /// rejects both, and both have to be covered.
    private func withComponentBundle(copyright: String?,
                                     _ body: (String) throws -> Void) throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PluginIdentityTests-\(UUID().uuidString)")
        let contents = directory
            .appendingPathComponent("Publishing.component")
            .appendingPathComponent("Contents")

        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var plist: [String: Any] = [
            "CFBundleIdentifier": "com.eklynx.tests.publishing-unit",
            "CFBundleName": "Publishing Unit",
            "CFBundlePackageType": "BNDL",
            // Written the way a real plugin's plist writes them — four characters, not hex —
            // which is what the scan compares against.
            "AudioComponents": [["type": os4CharToString(Self.testType),
                                 "subtype": os4CharToString(Self.testSubType),
                                 "manufacturer": os4CharToString(Self.testManufacturer),
                                 "name": "Nobody At All: Test Unit",
                                 "version": 1]],
        ]
        if let copyright { plist["NSHumanReadableCopyright"] = copyright }

        try PropertyListSerialization
            .data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))

        try body(directory.path)
    }

    /// The fallback is only reached when the plugin publishes nothing, so it has to name the
    /// plugin's maker rather than ours — an attribution that credits the wrong party is worse
    /// than a blank line.
    @Test func theFallbackAttributionNamesTheMaker() throws {
        #expect(PluginConfiguration.copyrightFallback.contains("©"))
        // No year: we don't know theirs, and a wrong one is a false claim about their work.
        #expect(PluginConfiguration.copyrightFallback.rangeOfCharacter(from: .decimalDigits) == nil)

        try #require(PluginConfiguration.isInstalled)
        let manufacturer = try #require(PluginConfiguration.installedPlugin?.name
            .split(separator: ":").first)
        #expect(PluginConfiguration.copyrightFallback
            .contains(manufacturer.trimmingCharacters(in: .whitespaces)))
    }
}
