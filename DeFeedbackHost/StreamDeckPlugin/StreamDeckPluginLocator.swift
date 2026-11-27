//
//  StreamDeckPluginLocator.swift
//  DeFeedbackHost
//
//  The real `StreamDeckPluginLocating`. Contract: StreamDeckPluginChecking.swift.
//
import Foundation

nonisolated struct StreamDeckPluginLocator: StreamDeckPluginLocating {

    static let pluginID = "com.eklynx.sound.defeedback"

    /// Stream Deck's folder of installed plugins, e.g. `<pluginsDirectory>/com.eklynx.sound.defeedback.sdPlugin`.
    let pluginsDirectory: URL
    /// The `.streamDeckPlugin` zip packaged in the app, or nil if the app has none.
    let packagedPlugin: URL?

    init(pluginsDirectory: URL = Self.defaultPluginsDirectory,
         packagedPlugin: URL? = Bundle.main.url(forResource: StreamDeckPluginLocator.pluginID,
                                                withExtension: "streamDeckPlugin")) {
        self.pluginsDirectory = pluginsDirectory
        self.packagedPlugin = packagedPlugin
    }

    static var defaultPluginsDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "com.elgato.StreamDeck/Plugins", directoryHint: .isDirectory)
    }

    func installedVersion() -> PluginVersion? {
        let manifest = pluginsDirectory
            .appending(path: "\(Self.pluginID).sdPlugin/manifest.json", directoryHint: .notDirectory)
        return (try? Data(contentsOf: manifest)).flatMap(Self.version(inManifest:))
    }

    func packagedVersion() -> PluginVersion? {
        guard let packagedPlugin else { return nil }
        // `.streamDeckPlugin` is a zip holding `<id>.sdPlugin/manifest.json`; unzip prints just that file.
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/unzip")
        process.arguments = ["-p", packagedPlugin.path(percentEncoded: false), "*/manifest.json"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return Self.version(inManifest: data)
    }

    /// The `Version` string of a Stream Deck `manifest.json`, parsed; nil if absent or malformed.
    static func version(inManifest data: Data) -> PluginVersion? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let string = object["Version"] as? String else { return nil }
        return PluginVersion(string)
    }
}

/// Used under XCTest so no test reads the real Stream Deck folder (contract edge case 8).
nonisolated struct InertStreamDeckPluginLocator: StreamDeckPluginLocating {
    func installedVersion() -> PluginVersion? { nil }
    func packagedVersion() -> PluginVersion? { nil }
}
