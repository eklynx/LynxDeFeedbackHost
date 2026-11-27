//
//  StreamDeckCLI.swift
//  DeFeedbackHost
//
//  The three outside-world seams the installer needs: finding Elgato's `streamdeck` command-line tool,
//  running a process, and asking whether the Stream Deck app is running. Each has a real implementation
//  here and a fake in the tests. Contract: StreamDeckPluginChecking.swift; installer: StreamDeckCLIInstaller.swift.
//
import AppKit
import Foundation

nonisolated struct ProcessOutcome: Equatable, Sendable {
    /// The exit status; -1 when the process couldn't start or was stopped for taking too long.
    let status: Int32
    /// Standard output and error together.
    let output: String

    /// The first non-empty line of the output, for putting a reason in a message.
    var firstLine: String {
        output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? "exit status \(status)"
    }
}

/// Runs a program to completion. Blocks, so call it off the main thread. Never throws.
nonisolated protocol ProcessRunning: Sendable {
    func run(_ executable: URL, arguments: [String], environment: [String: String]) -> ProcessOutcome
}

/// Finds Elgato's `streamdeck` CLI, or nil if it isn't installed anywhere we know to look.
nonisolated protocol StreamDeckCLILocating: Sendable {
    func cliURL() -> URL?
}

nonisolated protocol StreamDeckAppDetecting: Sendable {
    func isRunning() -> Bool
}

nonisolated struct SystemProcessRunner: ProcessRunning {

    /// A hung tool must not hold the launch-time update forever.
    let timeout: TimeInterval

    init(timeout: TimeInterval = 30) {
        self.timeout = timeout
    }

    func run(_ executable: URL, arguments: [String], environment: [String: String]) -> ProcessOutcome {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch {
            return ProcessOutcome(status: -1, output: "Couldn't start \(executable.lastPathComponent): \(error.localizedDescription)")
        }
        var timedOut = false
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            _ = finished.wait(timeout: .now() + 2)
        }
        let output = String(bytes: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return timedOut ? ProcessOutcome(status: -1, output: "\(executable.lastPathComponent) took too long") :
            ProcessOutcome(status: process.terminationStatus, output: output)
    }
}

/// Looks for an executable `streamdeck` in `searchDirectories`, in order.
nonisolated struct StreamDeckCLILocator: StreamDeckCLILocating {

    let searchDirectories: [URL]

    init(searchDirectories: [URL] = Self.defaultSearchDirectories()) {
        self.searchDirectories = searchDirectories
    }

    func cliURL() -> URL? {
        searchDirectories.map { $0.appending(path: "streamdeck", directoryHint: .notDirectory) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path(percentEncoded: false)) }
    }

    /// The app's own PATH is short (a Finder launch has almost nothing), so after `PATH` come the usual npm
    /// global locations: Homebrew, `/usr/local`, a user npm prefix, Volta, and every nvm Node version (newest first).
    static func defaultSearchDirectories(environment: [String: String] = ProcessInfo.processInfo.environment,
                                         home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let fromPath = (environment["PATH"] ?? "").split(separator: ":").map { URL(filePath: String($0), directoryHint: .isDirectory) }
        let nvmRoot = home.appending(path: ".nvm/versions/node", directoryHint: .isDirectory)
        let nvm = ((try? FileManager.default.contentsOfDirectory(atPath: nvmRoot.path(percentEncoded: false))) ?? [])
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { nvmRoot.appending(path: "\($0)/bin", directoryHint: .isDirectory) }
        let usual = ["/opt/homebrew/bin", "/usr/local/bin"].map { URL(filePath: $0, directoryHint: .isDirectory) }
            + [".npm-global/bin", ".volta/bin", ".local/bin"].map { home.appending(path: $0, directoryHint: .isDirectory) }
        var seen = Set<String>()
        return (fromPath + usual + nvm).filter { seen.insert($0.path(percentEncoded: false)).inserted }
    }
}

nonisolated struct SystemStreamDeckAppDetector: StreamDeckAppDetecting {
    func isRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.elgato.StreamDeck").isEmpty
    }
}
