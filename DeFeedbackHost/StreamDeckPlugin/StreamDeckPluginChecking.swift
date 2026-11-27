//
//  StreamDeckPluginChecking.swift
//  DeFeedbackHost
//
//  ┌─────────────────────────────────────────────────────────────────────────────────────────┐
//  │ AI AGENTS: this file is the SOURCE OF TRUTH for the `StreamDeckPlugin` namespace. Spec: │
//  │ docs/streamdeck-plugin-spec.md (SP1 to SP9). Other namespaces depend on `WarningSource` │
//  │ (Warnings/AppWarning.swift) and `StreamDeckPluginService`, never on the locator.        │
//  └─────────────────────────────────────────────────────────────────────────────────────────┘
//
//  # Model
//
//  The app ships a Stream Deck plugin (`com.eklynx.sound.defeedback.streamDeckPlugin`, in the app's
//  Resources). The user installs it into the Stream Deck app, which then keeps its own copy. The two
//  copies drift: the user updates this app and the installed plugin stays old. This namespace
//  compares the two, updates the installed copy at launch (when the user allows it) and otherwise
//  reports the difference as a warning (or an error).
//
//  Happy path
//    1. Plugin not installed, or Stream Deck not installed -> `.notInstalled`; no warning, no update.
//    2. Installed version equals or is newer than the packaged one -> `.current`; no warning.
//    3. Installed is older than the packaged one            -> `.outOfDate`; one WARNING,
//                                                              id `streamDeckPlugin.outOfDate`.
//    4. Installed is older than `minimumCompatibleVersion`   -> `.incompatible`; one ERROR,
//                                                              id `streamDeckPlugin.incompatible`.
//                                                              Wins over `.outOfDate`.
//    5. The user installs the new plugin -> the next `refresh()` (app launch, the app becoming
//       active, the Stream Deck tab appearing) clears the warning.
//    10. Auto-update (`StreamDeckPluginSettings.isAutoUpdateEnabled`, ON by default): at launch, in
//       `StreamDeckPluginService.start()` only, if the installed plugin is older than the packaged one
//       the service asks a `StreamDeckPluginInstalling` to replace it, then re-checks. Nothing is shown
//       when that works. With the setting OFF nothing is installed and 3 and 4 apply.
//
//  Error / edge cases
//    11. The installer fails (`.failed`) or can't run (`.notAvailable`): the warning/error stays, and a
//       failure's reason is added to its message. The update is tried once per launch, never in a loop.
//    12. Never auto-update a plugin that isn't installed (1), is current (2) or whose packaged version
//       is unknown.
//    6. A version that can't be read or parsed (missing file, bad JSON, no `Version`, no zip tool)
//       is unknown: it reports nothing rather than a guess (as in Warnings/AppWarning.swift 4).
//    7. If only the packaged version is unknown, `.incompatible` can still be decided; `.outOfDate` can't.
//    8. Under XCTest the service uses `InertStreamDeckPluginLocator`, so tests never read the real
//       Stream Deck folder.
//    9. `minimumCompatibleVersion`: raise it only when the app/plugin protocol breaks (the same moment
//       `WebControlService.protocolVersion` is bumped). The plugin doesn't declare its protocol, so the
//       app decides from the version alone.
//
import Foundation

/// A plugin version such as `0.1.2.0`: one to four dot-separated non-negative integers. Missing parts count as 0,
/// so `0.1.2` equals `0.1.2.0`.
nonisolated struct PluginVersion: Comparable, CustomStringConvertible, Sendable {

    private let parts: [Int]

    /// Nil for an empty string, a non-numeric part, a negative part or more than four parts.
    init?(_ string: String) {
        let pieces = string.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
        let numbers = pieces.compactMap { piece in Int(piece).flatMap { $0 >= 0 ? $0 : nil } }
        guard !pieces.isEmpty, pieces.count <= 4, numbers.count == pieces.count else { return nil }
        parts = numbers
    }

    var description: String { parts.map(String.init).joined(separator: ".") }

    private var padded: [Int] { parts + Array(repeating: 0, count: 4 - parts.count) }

    static func < (lhs: PluginVersion, rhs: PluginVersion) -> Bool { lhs.padded.lexicographicallyPrecedes(rhs.padded) }
    static func == (lhs: PluginVersion, rhs: PluginVersion) -> Bool { lhs.padded == rhs.padded }
}

/// Where the two versions come from. Called off the main thread (it reads files and may run `unzip`).
/// Each returns nil when it can't say (edge case 6).
nonisolated protocol StreamDeckPluginLocating: Sendable {
    /// The version in the manifest of the plugin Stream Deck has installed, or nil if not installed.
    func installedVersion() -> PluginVersion?
    /// The version of the plugin packaged inside this app, or nil if it can't be read.
    func packagedVersion() -> PluginVersion?
}

nonisolated enum StreamDeckPluginStatus: Equatable, Sendable {
    /// Before the first check finishes. Never warns.
    case unknown
    case notInstalled
    case current(installed: PluginVersion)
    case outOfDate(installed: PluginVersion, packaged: PluginVersion)
    case incompatible(installed: PluginVersion, packaged: PluginVersion?)

    /// The lowest installed plugin version that still works with this app (edge case 9).
    static let minimumCompatibleVersion = PluginVersion("0.1.0.0")!

    /// Decides the status from the two versions (happy path 1 to 4, edge cases 6 and 7).
    static func decide(installed: PluginVersion?, packaged: PluginVersion?) -> StreamDeckPluginStatus {
        guard let installed else { return .notInstalled }
        if installed < minimumCompatibleVersion { return .incompatible(installed: installed, packaged: packaged) }
        if let packaged, installed < packaged { return .outOfDate(installed: installed, packaged: packaged) }
        return .current(installed: installed)
    }
}
