//
//  StreamDeckPluginTests.swift
//  DeFeedbackHostTests
//
//  Covers docs/streamdeck-plugin-spec.md (SP1 to SP10). Never touches the real Stream Deck folder:
//  versions come from stubs or from temp directories.
//
//  - Tests initially created with AI with human edits, but all reviewed by human

import Foundation
import SwiftUI
import Testing

@testable import DeFeedbackHost

/// A locator whose answers the test can change between refreshes.
private final class StubLocator: StreamDeckPluginLocating, @unchecked Sendable {
    private let lock = NSLock()
    private var installed: PluginVersion?
    private var packaged: PluginVersion?

    init(installed: String?, packaged: String?) {
        self.installed = installed.flatMap(PluginVersion.init)
        self.packaged = packaged.flatMap(PluginVersion.init)
    }

    func set(installed: String?) { lock.withLock { self.installed = installed.flatMap(PluginVersion.init) } }
    func installedVersion() -> PluginVersion? { lock.withLock { installed } }
    func packagedVersion() -> PluginVersion? { lock.withLock { packaged } }
}

@MainActor
private func service(installed: String?, packaged: String?) async -> StreamDeckPluginService {
    let service = StreamDeckPluginService(locator: StubLocator(installed: installed, packaged: packaged))
    await service.refresh()
    return service
}

/// A fresh temp directory, removed by the caller.
private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "StreamDeckPluginTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

struct StreamDeckPluginVersionTests {

    @Test("SP1: versions compare part by part, numerically, with missing parts as zero")
    func versionComparison() throws {
        let v = { try #require(PluginVersion($0)) }
        #expect(try v("0.1.2.0") == v("0.1.2"))
        #expect(try v("0.1.10.0") > v("0.1.9.0"), "numeric, not alphabetical")
        #expect(try v("0.1.2.1") > v("0.1.2.0"))
        #expect(try v("1.0.0.0") > v("0.99.99.99"))
        #expect(try v("0.1.2.0").description == "0.1.2.0")
    }

    @Test("SP1: text that isn't a version is rejected")
    func invalidVersions() {
        for text in ["", "abc", "1.x", "1..2", "-1.0", "1.2.3.4.5"] {
            #expect(PluginVersion(text) == nil, "\(text) must not parse")
        }
    }
}

struct StreamDeckPluginLocatorTests {

    private func writeManifest(_ json: String, into directory: URL, plugin: String) throws {
        let folder = directory.appending(path: "\(plugin).sdPlugin")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try json.write(to: folder.appending(path: "manifest.json"), atomically: true, encoding: .utf8)
    }

    @Test("SP2: the installed version is read from the plugin's manifest; missing or malformed is unknown")
    func installedVersionFromManifest() throws {
        let plugins = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: plugins) }
        let locator = StreamDeckPluginLocator(pluginsDirectory: plugins, packagedPlugin: nil)
        #expect(locator.installedVersion() == nil, "not installed")

        try writeManifest(#"{"Version": "0.1.1.0"}"#, into: plugins, plugin: StreamDeckPluginLocator.pluginID)
        #expect(locator.installedVersion() == PluginVersion("0.1.1.0"))

        try writeManifest("not json", into: plugins, plugin: StreamDeckPluginLocator.pluginID)
        #expect(locator.installedVersion() == nil, "bad JSON is unknown, not a guess")
        try writeManifest(#"{"Name": "x"}"#, into: plugins, plugin: StreamDeckPluginLocator.pluginID)
        #expect(locator.installedVersion() == nil, "no Version key")
    }

    @Test("SP2: the packaged version is read from the manifest inside the .streamDeckPlugin zip")
    func packagedVersionFromZip() throws {
        let work = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        try writeManifest(#"{"Version": "0.2.0.0"}"#, into: work, plugin: StreamDeckPluginLocator.pluginID)
        let zip = work.appending(path: "plugin.streamDeckPlugin")
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/zip")
        process.currentDirectoryURL = work
        process.arguments = ["-qr", zip.path(percentEncoded: false), "\(StreamDeckPluginLocator.pluginID).sdPlugin"]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "the test needs /usr/bin/zip")

        let plugins = work.appending(path: "none")
        #expect(StreamDeckPluginLocator(pluginsDirectory: plugins, packagedPlugin: zip).packagedVersion()
                == PluginVersion("0.2.0.0"))
        #expect(StreamDeckPluginLocator(pluginsDirectory: plugins, packagedPlugin: nil).packagedVersion() == nil)
        #expect(StreamDeckPluginLocator(pluginsDirectory: plugins,
                                        packagedPlugin: work.appending(path: "missing.streamDeckPlugin"))
                    .packagedVersion() == nil, "a missing or unreadable zip is unknown")
    }

    @Test("SP2: the bundled plugin's own manifest declares a parseable version")
    func repositoryManifestParses() throws {
        let manifest = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "streamdeck/com.eklynx.sound.defeedback.sdPlugin/manifest.json")
        let version = StreamDeckPluginLocator.version(inManifest: try Data(contentsOf: manifest))
        let parsed = try #require(version)
        #expect(parsed >= StreamDeckPluginStatus.minimumCompatibleVersion,
                "the plugin we ship must not be flagged incompatible by our own app")
    }
}

@MainActor
struct StreamDeckPluginServiceTests {

    @Test("SP3: nothing installed, or nothing known yet, never warns")
    func notInstalledNeverWarns() async {
        #expect(StreamDeckPluginService(locator: StubLocator(installed: "0.1.0.0", packaged: "9.0")).warnings.isEmpty,
                "before the first check")
        let none = await service(installed: nil, packaged: "0.1.2.0")
        #expect(none.status == .notInstalled)
        #expect(none.warnings.isEmpty)
    }

    @Test("SP4: an installed plugin older than the packaged one gives one warning")
    func outOfDateWarns() async throws {
        let plugin = await service(installed: "0.1.1.0", packaged: "0.1.2.0")
        #expect(plugin.warnings.map(\.id) == [StreamDeckPluginService.outOfDateID])
        let warning = try #require(plugin.warnings.first)
        #expect(warning.kind == .streamDeckPlugin)
        #expect(warning.severity == .warning)
        #expect(warning.message.contains("0.1.1.0") && warning.message.contains("0.1.2.0"))
    }

    @Test("SP5: an installed plugin below the minimum compatible version is an error, and wins over out of date")
    func incompatibleIsAnError() async throws {
        let plugin = await service(installed: "0.0.9.0", packaged: "0.1.2.0")
        #expect(plugin.warnings.map(\.id) == [StreamDeckPluginService.incompatibleID])
        #expect(try #require(plugin.warnings.first).severity == .error)

        let unknownPackaged = await service(installed: "0.0.9.0", packaged: nil)
        #expect(unknownPackaged.warnings.map(\.id) == [StreamDeckPluginService.incompatibleID],
                "incompatibility doesn't need the packaged version")
    }

    @Test("SP6: an equal or newer installed plugin, or an unknown packaged version, gives no warning")
    func currentNeverWarns() async {
        for (installed, packaged) in [("0.1.2.0", "0.1.2.0"), ("0.3.0.0", "0.1.2.0"), ("0.1.2.0", nil)] as [(String, String?)] {
            let plugin = await service(installed: installed, packaged: packaged)
            #expect(plugin.warnings.isEmpty, "\(installed) vs \(packaged ?? "unknown")")
        }
    }

    @Test("SP8: a refresh after the user installs the new plugin clears the warning")
    func refreshClearsAfterUpdate() async {
        let locator = StubLocator(installed: "0.1.1.0", packaged: "0.1.2.0")
        let plugin = StreamDeckPluginService(locator: locator)
        await plugin.refresh()
        #expect(plugin.warnings.count == 1)
        locator.set(installed: "0.1.2.0")
        await plugin.refresh()
        #expect(plugin.warnings.isEmpty)
        #expect(plugin.installedVersion == PluginVersion("0.1.2.0"))
    }

    @Test("SP8: a refresh that arrives mid-check runs once more afterwards")
    func overlappingRefreshIsQueued() async {
        let locator = StubLocator(installed: "0.1.1.0", packaged: "0.1.2.0")
        let plugin = StreamDeckPluginService(locator: locator)
        async let first: Void = plugin.refresh()
        locator.set(installed: "0.1.2.0")
        async let second: Void = plugin.refresh()
        _ = await (first, second)
        #expect(plugin.warnings.isEmpty, "the later answer wins")
    }

    @Test("SP9: the inert locator, used under XCTest, never warns")
    func inertLocatorNeverWarns() async {
        let plugin = StreamDeckPluginService(locator: InertStreamDeckPluginLocator())
        await plugin.refresh()
        #expect(plugin.warnings.isEmpty)
    }

    @Test("SP7: /api/status carries the plugin warning with a severity, and every warning has one")
    func statusCarriesSeverity() async throws {
        let permissions = PermissionService(checkers: [StubChecker(.localNetwork, state: .denied)])
        await permissions.start()
        let plugin = await service(installed: "0.0.9.0", packaged: "0.1.2.0")

        let web = WebControlService(host: AudioHost())
        web.warningSources = [permissions, plugin]
        let warnings = web.warningPayload()
        #expect(warnings.compactMap { $0["id"] as? String }
                == ["permission.localNetwork", StreamDeckPluginService.incompatibleID])
        #expect(warnings.compactMap { $0["severity"] as? String } == ["warning", "error"])
        #expect(warnings.last?["kind"] as? String == "streamDeckPlugin")
    }

    @Test("SP7: openapi.yaml documents the severity and the new kind")
    func openAPIDocumentsSeverity() throws {
        let document = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().appending(path: "openapi.yaml")
        let text = try String(contentsOf: document, encoding: .utf8)
        #expect(text.contains("required: [id, kind, severity, message, link, linkTitle]"))
        #expect(text.contains("enum: [warning, error]"))
        #expect(text.contains("enum: [update, permission, streamDeckPlugin]"))
        #expect(text.contains(StreamDeckPluginService.outOfDateID) && text.contains(StreamDeckPluginService.incompatibleID))
    }

    @Test("SP10: the plugin banner adds to the main window's required height")
    func bannerAddsToRequiredHeight() async {
        func height(installed: String) async -> CGFloat {
            let plugin = await service(installed: installed, packaged: "0.1.2.0")
            let host = AudioHost()
            let view = ContentView(host: host, web: WebControlService(host: host)).environment(plugin)
            return NSHostingView(rootView: view).fittingSize.height
        }
        let without = await height(installed: "0.1.2.0")
        let with = await height(installed: "0.1.1.0")
        #expect(with >= without + 20, "required height \(with) with the banner vs \(without) without")
    }
}
