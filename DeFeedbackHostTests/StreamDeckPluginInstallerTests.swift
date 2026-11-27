//
//  StreamDeckPluginInstallerTests.swift
//  DeFeedbackHostTests
//
//  Covers the auto-update half of docs/streamdeck-plugin-spec.md (SP11 to SP15). Nothing here touches the real
//  Stream Deck folder or runs Elgato's CLI: the plugin folder is a temp directory and the CLI is a scripted fake.
//  Only /usr/bin/zip and /usr/bin/unzip run for real.
//
//  - Tests initially created with AI with human edits, but all reviewed by human

import Foundation
import Testing

@testable import DeFeedbackHost

// MARK: - Fakes

private final class StubInstaller: StreamDeckPluginInstalling {
    private(set) var calls = 0
    var result: StreamDeckPluginInstallResult
    /// Runs when called, e.g. to make the fake locator report the new version.
    var onInstall: () -> Void = {}
    init(_ result: StreamDeckPluginInstallResult) { self.result = result }
    func installPackagedPlugin() async -> StreamDeckPluginInstallResult {
        calls += 1
        onInstall()
        return result
    }
}

private struct StubSettings: StreamDeckPluginSettings {
    var isAutoUpdateEnabled: Bool
}

private final class MutableLocator: StreamDeckPluginLocating, @unchecked Sendable {
    private let lock = NSLock()
    private var installed: String?
    private let packaged: String?
    init(installed: String?, packaged: String?) { self.installed = installed; self.packaged = packaged }
    func set(installed: String?) { lock.withLock { self.installed = installed } }
    func installedVersion() -> PluginVersion? { lock.withLock { installed }.flatMap(PluginVersion.init) }
    func packagedVersion() -> PluginVersion? { packaged.flatMap(PluginVersion.init) }
}

/// Answers `streamdeck <command>` from a script; `unzip` really runs. Records every call.
private final class ScriptedRunner: ProcessRunning, @unchecked Sendable {
    struct Call: Equatable { let tool: String; let arguments: [String] }
    private let lock = NSLock()
    private var recorded: [Call] = []
    private var environments: [[String: String]] = []
    var statuses: [String: Int32] = [:]   // by CLI subcommand ("stop", "restart"); default 0

    var calls: [Call] { lock.withLock { recorded } }
    var lastEnvironment: [String: String]? { lock.withLock { environments.last { $0["PATH"] != nil } } }
    var tools: [String] { calls.map { $0.tool + ($0.tool == "streamdeck" ? " " + ($0.arguments.first ?? "") : "") } }

    func run(_ executable: URL, arguments: [String], environment: [String: String]) -> ProcessOutcome {
        let tool = executable.lastPathComponent
        lock.withLock { recorded.append(Call(tool: tool, arguments: arguments)); environments.append(environment) }
        if tool == "unzip" { return SystemProcessRunner().run(executable, arguments: arguments, environment: environment) }
        let status = statuses[arguments.first ?? ""] ?? 0
        return ProcessOutcome(status: status, output: status == 0 ? "ok" : "boom from \(arguments.first ?? "")\nmore")
    }
}

private struct FixedCLI: StreamDeckCLILocating {
    let url: URL?
    func cliURL() -> URL? { url }
}

private struct FixedApp: StreamDeckAppDetecting {
    let running: Bool
    func isRunning() -> Bool { running }
}

// MARK: - Helpers

private let pluginID = StreamDeckPluginLocator.pluginID

private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "StreamDeckInstallerTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writePlugin(version: String, in directory: URL, marker: String) throws {
    let folder = directory.appending(path: "\(pluginID).sdPlugin")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try #"{"Version": "\#(version)"}"#.write(to: folder.appending(path: "manifest.json"), atomically: true, encoding: .utf8)
    try marker.write(to: folder.appending(path: "marker.txt"), atomically: true, encoding: .utf8)
}

private func zipPlugin(from directory: URL, to zip: URL) throws {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/zip")
    process.currentDirectoryURL = directory
    process.arguments = ["-qr", zip.path(percentEncoded: false), "\(pluginID).sdPlugin"]
    try process.run()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0, "the test needs /usr/bin/zip")
}

/// An installed 0.1.1.0 plugin, a packaged 0.2.0.0 zip, and a scratch folder, all in a temp directory.
private struct Fixture {
    let root: URL
    let plugins: URL
    let zip: URL
    let scratch: URL

    init() throws {
        root = try makeTempDirectory()
        plugins = root.appending(path: "Plugins")
        scratch = root.appending(path: "Scratch")
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try writePlugin(version: "0.1.1.0", in: plugins, marker: "old")
        let source = root.appending(path: "Source")
        try writePlugin(version: "0.2.0.0", in: source, marker: "new")
        zip = root.appending(path: "plugin.streamDeckPlugin")
        try zipPlugin(from: source, to: zip)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    var installedLocator: StreamDeckPluginLocator { StreamDeckPluginLocator(pluginsDirectory: plugins, packagedPlugin: nil) }
    var installedMarker: String? {
        try? String(contentsOf: plugins.appending(path: "\(pluginID).sdPlugin/marker.txt"), encoding: .utf8)
    }
    var scratchIsEmpty: Bool { ((try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? []).isEmpty }

    func installation(runner: ScriptedRunner, cli: URL? = URL(filePath: "/fake/bin/streamdeck"), running: Bool = true,
                      packaged: URL?? = nil) -> StreamDeckPluginInstallation {
        StreamDeckPluginInstallation(pluginID: pluginID, pluginsDirectory: plugins, packagedPlugin: packaged ?? zip,
                                     scratchDirectory: scratch, cli: FixedCLI(url: cli), runner: runner,
                                     streamDeckApp: FixedApp(running: running))
    }
}

// MARK: - Setting and launch flow

@MainActor
struct StreamDeckAutoUpdateFlowTests {

    private func start(installed: String?, packaged: String?, autoUpdate: Bool,
                       installer: StubInstaller, newInstalled: String? = nil) async -> StreamDeckPluginService {
        let locator = MutableLocator(installed: installed, packaged: packaged)
        if let newInstalled { installer.onInstall = { locator.set(installed: newInstalled) } }
        let service = StreamDeckPluginService(locator: locator, installer: installer,
                                              settings: StubSettings(isAutoUpdateEnabled: autoUpdate))
        await service.start()
        return service
    }

    @Test("SP11: automatic update is on by default, reads Host.streamDeckAutoUpdate, and a typo falls back to on")
    func settingDefaultsOn() {
        let name = "DeFeedbackHostTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = UserDefaultsStreamDeckPluginSettings(defaults: defaults)
        #expect(UserDefaultsStreamDeckPluginSettings.Key.autoUpdate == "Host.streamDeckAutoUpdate")
        #expect(settings.isAutoUpdateEnabled, "fresh install")
        defaults.set(false, forKey: UserDefaultsStreamDeckPluginSettings.Key.autoUpdate)
        #expect(!settings.isAutoUpdateEnabled)
        defaults.set("no", forKey: UserDefaultsStreamDeckPluginSettings.Key.autoUpdate)
        #expect(!settings.isAutoUpdateEnabled, "defaults write -string no")
        defaults.set("banana", forKey: UserDefaultsStreamDeckPluginSettings.Key.autoUpdate)
        #expect(settings.isAutoUpdateEnabled, "a typo can't change behaviour")
    }

    @Test("SP12: at launch an out-of-date plugin is replaced once, and then nothing is shown")
    func launchUpdatesOutOfDatePlugin() async {
        let installer = StubInstaller(.installed)
        let service = await start(installed: "0.1.1.0", packaged: "0.2.0.0", autoUpdate: true,
                                  installer: installer, newInstalled: "0.2.0.0")
        #expect(installer.calls == 1)
        #expect(service.status == .current(installed: PluginVersion("0.2.0.0")!))
        #expect(service.warnings.isEmpty)
        #expect(!service.isUpdating)

        await service.start()
        await service.refresh()
        #expect(installer.calls == 1, "only start() installs, and only once per launch")
    }

    @Test("SP12: an incompatible plugin is updated too, when the packaged version is known")
    func launchUpdatesIncompatiblePlugin() async {
        let installer = StubInstaller(.installed)
        _ = await start(installed: "0.0.5.0", packaged: "0.2.0.0", autoUpdate: true, installer: installer, newInstalled: "0.2.0.0")
        #expect(installer.calls == 1)
        let unknownPackaged = StubInstaller(.installed)
        _ = await start(installed: "0.0.5.0", packaged: nil, autoUpdate: true, installer: unknownPackaged)
        #expect(unknownPackaged.calls == 0, "nothing to install it from")
    }

    @Test("SP13: with the setting off nothing is installed and the warning or error shows")
    func settingOffOnlyWarns() async {
        let installer = StubInstaller(.installed)
        let outOfDate = await start(installed: "0.1.1.0", packaged: "0.2.0.0", autoUpdate: false, installer: installer)
        #expect(installer.calls == 0)
        #expect(outOfDate.warnings.map(\.id) == [StreamDeckPluginService.outOfDateID])
        let incompatible = await start(installed: "0.0.5.0", packaged: "0.2.0.0", autoUpdate: false, installer: installer)
        #expect(incompatible.warnings.map(\.id) == [StreamDeckPluginService.incompatibleID])
        #expect(installer.calls == 0)
    }

    @Test("SP12: nothing to update means no install: not installed, current or newer")
    func noInstallWhenNothingToUpdate() async {
        for (installed, packaged) in [(nil, "0.2.0.0"), ("0.2.0.0", "0.2.0.0"), ("0.3.0.0", "0.2.0.0"), ("0.1.0.0", nil)] as [(String?, String?)] {
            let installer = StubInstaller(.installed)
            _ = await start(installed: installed, packaged: packaged, autoUpdate: true, installer: installer)
            #expect(installer.calls == 0, "\(installed ?? "none") vs \(packaged ?? "unknown")")
        }
    }

    @Test("SP15: a failed update keeps the warning and says why; an unavailable one keeps it without a reason")
    func failureKeepsWarning() async throws {
        let failing = StubInstaller(.failed("Stream Deck isn't running."))
        let failed = await start(installed: "0.1.1.0", packaged: "0.2.0.0", autoUpdate: true, installer: failing)
        #expect(failing.calls == 1, "tried once, not in a loop")
        let warning = try #require(failed.warnings.first)
        #expect(warning.id == StreamDeckPluginService.outOfDateID)
        #expect(warning.message.contains("Stream Deck isn't running."))

        let unavailable = StubInstaller(.notAvailable)
        let quiet = await start(installed: "0.0.5.0", packaged: "0.2.0.0", autoUpdate: true, installer: unavailable)
        let error = try #require(quiet.warnings.first)
        #expect(error.severity == .error)
        #expect(!error.message.contains("automatic update failed"))
    }
}

// MARK: - The CLI installer

struct StreamDeckCLIInstallerTests {

    @Test("SP14: the happy path stops the plugin, replaces its folder, restarts it, and cleans up")
    func replacesInstalledPlugin() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let runner = ScriptedRunner()
        let result = fixture.installation(runner: runner).run()
        #expect(result == .installed)
        #expect(runner.tools == ["unzip", "streamdeck stop", "streamdeck restart"], "stop before the swap, restart after")
        #expect(runner.calls[1].arguments == ["stop", pluginID])
        #expect(runner.calls[2].arguments == ["restart", pluginID])
        #expect(fixture.installedLocator.installedVersion() == PluginVersion("0.2.0.0"))
        #expect(fixture.installedMarker == "new")
        #expect(fixture.scratchIsEmpty, "the unpacked copy is removed")
        let path = try #require(runner.lastEnvironment?["PATH"])
        #expect(path.hasPrefix("/fake/bin:"), "the CLI's own folder comes first so its `node` is found")
    }

    @MainActor
    @Test("SP14: the app-facing installer runs the same sequence off the main thread")
    func appFacingInstaller() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let runner = ScriptedRunner()
        let installer = StreamDeckCLIInstaller(pluginsDirectory: fixture.plugins, packagedPlugin: fixture.zip,
                                               scratchDirectory: fixture.scratch,
                                               cli: FixedCLI(url: URL(filePath: "/fake/bin/streamdeck")),
                                               runner: runner, streamDeckApp: FixedApp(running: true))
        #expect(await installer.installPackagedPlugin() == .installed)
        #expect(fixture.installedMarker == "new")
    }

    @Test("SP14: Stream Deck not running, CLI missing, packaged plugin missing or plugin not installed: failed, nothing touched")
    func preconditionsTouchNothing() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let notRunning = ScriptedRunner()
        guard case .failed(let reason1) = fixture.installation(runner: notRunning, running: false).run() else {
            Issue.record("expected a failure"); return
        }
        #expect(reason1.contains("isn't running"))

        let noCLI = ScriptedRunner()
        guard case .failed(let reason2) = fixture.installation(runner: noCLI, cli: nil).run() else {
            Issue.record("expected a failure"); return
        }
        #expect(reason2.contains("npm install -g @elgato/cli"))

        let noPackage = ScriptedRunner()
        guard case .failed = fixture.installation(runner: noPackage, packaged: .some(nil)).run() else {
            Issue.record("expected a failure"); return
        }

        #expect(notRunning.calls.isEmpty && noCLI.calls.isEmpty && noPackage.calls.isEmpty, "no process ran")
        #expect(fixture.installedMarker == "old")

        try FileManager.default.removeItem(at: fixture.plugins.appending(path: "\(pluginID).sdPlugin"))
        let notInstalled = ScriptedRunner()
        guard case .failed = fixture.installation(runner: notInstalled).run() else {
            Issue.record("expected a failure"); return
        }
        #expect(notInstalled.calls.isEmpty)
        #expect(fixture.installedMarker == nil, "an absent plugin is not created")
    }

    @Test("SP14: if stopping the plugin fails the installed folder is not touched and the plugin isn't restarted")
    func stopFailureLeavesFolder() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let runner = ScriptedRunner()
        runner.statuses["stop"] = 1
        guard case .failed(let reason) = fixture.installation(runner: runner).run() else {
            Issue.record("expected a failure"); return
        }
        #expect(reason.contains("Stopping the plugin failed") && reason.contains("boom from stop"))
        #expect(!reason.contains("more"), "only the first line of the tool's output")
        #expect(runner.tools == ["unzip", "streamdeck stop"])
        #expect(fixture.installedMarker == "old")
        #expect(fixture.installedLocator.installedVersion() == PluginVersion("0.1.1.0"))
        #expect(fixture.scratchIsEmpty)
    }

    @Test("SP14: a packaged zip that can't be unpacked fails before the plugin is stopped")
    func badZipStopsEarly() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try "not a zip".write(to: fixture.zip, atomically: true, encoding: .utf8)
        let runner = ScriptedRunner()
        guard case .failed(let reason) = fixture.installation(runner: runner).run() else {
            Issue.record("expected a failure"); return
        }
        #expect(reason.contains("couldn't be unpacked"))
        #expect(runner.tools == ["unzip"], "never stopped")
        #expect(fixture.installedMarker == "old")
        #expect(fixture.scratchIsEmpty)
    }

    @Test("SP14: if the restart fails the folder is already the new one, and the failure says to restart Stream Deck")
    func restartFailureIsReported() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let runner = ScriptedRunner()
        runner.statuses["restart"] = 1
        guard case .failed(let reason) = fixture.installation(runner: runner).run() else {
            Issue.record("expected a failure"); return
        }
        #expect(reason.contains("updated") && reason.contains("Restart Stream Deck"))
        #expect(fixture.installedMarker == "new")
    }
}

// MARK: - Finding the CLI

struct StreamDeckCLILocatorTests {

    private func makeExecutable(in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "streamdeck")
        try "#!/bin/sh\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }

    @Test("SP14: the CLI is the first executable `streamdeck` in the search directories; none is nil")
    func findsFirstExecutable() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appending(path: "a"), second = root.appending(path: "b"), empty = root.appending(path: "c")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try makeExecutable(in: second)
        #expect(StreamDeckCLILocator(searchDirectories: [first, empty]).cliURL() == nil)
        #expect(StreamDeckCLILocator(searchDirectories: [first, empty, second]).cliURL()?.deletingLastPathComponent().lastPathComponent == "b")
        try makeExecutable(in: first)
        #expect(StreamDeckCLILocator(searchDirectories: [first, second]).cliURL()?.deletingLastPathComponent().lastPathComponent == "a")
    }

    @Test("SP14: the default search is PATH first, then the usual npm locations and nvm versions, newest first, no repeats")
    func defaultSearchOrder() throws {
        let home = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        for version in ["v22.1.0", "v24.0.0", "v9.0.0"] {
            try FileManager.default.createDirectory(at: home.appending(path: ".nvm/versions/node/\(version)/bin"),
                                                    withIntermediateDirectories: true)
        }
        let paths = StreamDeckCLILocator.defaultSearchDirectories(environment: ["PATH": "/custom/bin:/opt/homebrew/bin"], home: home)
            .map { $0.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        #expect(paths.first == "custom/bin")
        #expect(paths.filter { $0 == "opt/homebrew/bin" }.count == 1)
        #expect(paths.contains("usr/local/bin"))
        let nvm = paths.filter { $0.contains(".nvm/versions/node") }.map { $0.components(separatedBy: "/node/")[1] }
        #expect(nvm == ["v24.0.0/bin", "v22.1.0/bin", "v9.0.0/bin"])
    }
}
