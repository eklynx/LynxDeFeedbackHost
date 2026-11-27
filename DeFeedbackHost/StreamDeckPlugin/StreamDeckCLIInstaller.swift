//
//  StreamDeckCLIInstaller.swift
//  DeFeedbackHost
//
//  The real `StreamDeckPluginInstalling`. Contract: StreamDeckPluginChecking.swift (rules 10 to 12), seam in
//  StreamDeckPluginInstalling.swift, spec docs/streamdeck-plugin-spec.md (SP14).
//
//  The sequence (Elgato's `streamdeck stop|restart <uuid>` commands, docs.elgato.com/streamdeck/cli):
//    1. Preconditions, touching nothing: the Stream Deck app is running, the packaged plugin and the CLI
//       exist, the plugin is installed. Any miss is a `.failed` with the reason.
//    2. Unpack the packaged `.streamDeckPlugin` into a scratch folder and check its manifest is there.
//    3. `streamdeck stop <uuid>`. If it fails the installed folder is NOT touched.
//    4. Swap the installed `<uuid>.sdPlugin` folder for the unpacked one (atomic replace; on failure the
//       old folder is still there).
//    5. `streamdeck restart <uuid>`, which also starts the plugin if step 3 left it stopped. If the swap
//       failed the restart is still tried, to bring the old plugin back.
//
import Foundation

/// The blocking work of one installation. Not main-actor: `StreamDeckCLIInstaller` runs it on a background task.
nonisolated struct StreamDeckPluginInstallation: Sendable {

    let pluginID: String
    let pluginsDirectory: URL
    let packagedPlugin: URL?
    let scratchDirectory: URL
    let cli: StreamDeckCLILocating
    let runner: ProcessRunning
    let streamDeckApp: StreamDeckAppDetecting

    func run() -> StreamDeckPluginInstallResult {
        guard streamDeckApp.isRunning() else { return .failed("Stream Deck isn't running.") }
        guard let packagedPlugin else { return .failed("The plugin packaged with this app is missing.") }
        guard let cliURL = cli.cliURL() else {
            return .failed("Elgato's streamdeck command-line tool wasn't found (install it with: npm install -g @elgato/cli).")
        }
        let folderName = "\(pluginID).sdPlugin"
        let installedFolder = pluginsDirectory.appending(path: folderName, directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: installedFolder.path(percentEncoded: false)) else {
            return .failed("The plugin isn't installed in Stream Deck.")
        }

        let staging = scratchDirectory.appending(path: "StreamDeckPluginInstall-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: staging) }
        let unpacked = unpack(packagedPlugin, into: staging, folderName: folderName)
        guard case .success(let newFolder) = unpacked else {
            if case .failure(let failure) = unpacked { return .failed(failure.reason) }
            return .failed("The packaged plugin couldn't be unpacked.")
        }

        // Elgato's CLI is a Node script (`#!/usr/bin/env node`), and a Finder-launched app has almost no PATH.
        let environment = ["PATH": [cliURL.deletingLastPathComponent().path,
                                    "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].joined(separator: ":"),
                           "HOME": FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)]

        let stop = runner.run(cliURL, arguments: ["stop", pluginID], environment: environment)
        guard stop.status == 0 else { return .failed("Stopping the plugin failed (\(stop.firstLine)).") }

        do {
            _ = try FileManager.default.replaceItemAt(installedFolder, withItemAt: newFolder)
        } catch {
            _ = runner.run(cliURL, arguments: ["restart", pluginID], environment: environment)
            return .failed("The plugin folder couldn't be replaced (\(error.localizedDescription)); the old plugin was left in place.")
        }

        let restart = runner.run(cliURL, arguments: ["restart", pluginID], environment: environment)
        guard restart.status == 0 else {
            return .failed("The plugin was updated, but Stream Deck couldn't start it (\(restart.firstLine)). Restart Stream Deck.")
        }
        return .installed
    }

    private struct UnpackFailure: Error { let reason: String }

    private func unpack(_ zip: URL, into staging: URL, folderName: String) -> Result<URL, UnpackFailure> {
        do { try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true) } catch {
            return .failure(UnpackFailure(reason: "A scratch folder couldn't be made (\(error.localizedDescription))."))
        }
        let unzip = runner.run(URL(filePath: "/usr/bin/unzip"),
                               arguments: ["-q", "-o", zip.path(percentEncoded: false), "-d", staging.path(percentEncoded: false)],
                               environment: [:])
        let folder = staging.appending(path: folderName, directoryHint: .isDirectory)
        guard unzip.status == 0,
              FileManager.default.fileExists(atPath: folder.appending(path: "manifest.json").path(percentEncoded: false)) else {
            return .failure(UnpackFailure(reason: "The packaged plugin couldn't be unpacked (\(unzip.firstLine))."))
        }
        return .success(folder)
    }
}

@MainActor
struct StreamDeckCLIInstaller: StreamDeckPluginInstalling {

    private let installation: StreamDeckPluginInstallation

    init(pluginsDirectory: URL = StreamDeckPluginLocator.defaultPluginsDirectory,
         packagedPlugin: URL? = Bundle.main.url(forResource: StreamDeckPluginLocator.pluginID, withExtension: "streamDeckPlugin"),
         scratchDirectory: URL = FileManager.default.temporaryDirectory,
         cli: StreamDeckCLILocating = StreamDeckCLILocator(),
         runner: ProcessRunning = SystemProcessRunner(),
         streamDeckApp: StreamDeckAppDetecting = SystemStreamDeckAppDetector()) {
        installation = StreamDeckPluginInstallation(pluginID: StreamDeckPluginLocator.pluginID,
                                                    pluginsDirectory: pluginsDirectory,
                                                    packagedPlugin: packagedPlugin,
                                                    scratchDirectory: scratchDirectory,
                                                    cli: cli, runner: runner, streamDeckApp: streamDeckApp)
    }

    func installPackagedPlugin() async -> StreamDeckPluginInstallResult {
        let installation = installation
        return await Task.detached { installation.run() }.value
    }
}
