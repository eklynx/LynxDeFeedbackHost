//
//  StreamDeckPluginService.swift
//  DeFeedbackHost
//
//  Implements the contract in StreamDeckPluginChecking.swift. Owns the status and the warning.
//
import Observation

@Observable
@MainActor
final class StreamDeckPluginService: WarningSource {

    static let outOfDateID = "streamDeckPlugin.outOfDate"
    static let newerThanPackagedID = "streamDeckPlugin.newerThanPackaged"
    static let incompatibleID = "streamDeckPlugin.incompatible"

    private(set) var status: StreamDeckPluginStatus = .unknown

    /// True while the installer runs, so the warning doesn't flash during a successful update.
    private(set) var isUpdating = false
    /// Why the last automatic update failed, if it did (contract 11). Cleared by a later success.
    private(set) var lastUpdateFailure: String?

    @ObservationIgnored private let locator: StreamDeckPluginLocating
    @ObservationIgnored private let installer: StreamDeckPluginInstalling
    @ObservationIgnored private let settings: StreamDeckPluginSettings
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var isChecking = false
    /// A refresh arrived mid-check (e.g. the app became active while the launch check ran): run one more
    /// pass afterwards instead of losing it.
    @ObservationIgnored private var refreshRequested = false

    init(locator: StreamDeckPluginLocating,
         installer: StreamDeckPluginInstalling? = nil,
         settings: StreamDeckPluginSettings? = nil) {
        self.locator = locator
        self.installer = installer ?? InertStreamDeckPluginInstaller()
        self.settings = settings ?? UserDefaultsStreamDeckPluginSettings()
    }

    /// Call once at launch: checks, and if the setting allows it replaces an installed plugin that is older than
    /// the packaged one (contract 10 to 12), then checks again. Later calls do nothing.
    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        await refresh()
        guard settings.isAutoUpdateEnabled, needsUpdate else { return }
        isUpdating = true
        switch await installer.installPackagedPlugin() {
        case .installed: lastUpdateFailure = nil
        case .notAvailable: break
        case .failed(let reason): lastUpdateFailure = reason
        }
        await refresh()
        isUpdating = false
    }

    /// An installed plugin older than the packaged one (so not `.current`, not `.notInstalled`).
    private var needsUpdate: Bool {
        switch status {
        case .outOfDate: true
        case .incompatible(_, let packaged): packaged != nil
        case .unknown, .notInstalled, .current, .newerThanPackaged: false
        }
    }

    /// Re-reads both versions off the main thread. Checks never overlap.
    func refresh() async {
        guard !isChecking else { refreshRequested = true; return }
        isChecking = true
        repeat {
            refreshRequested = false
            let locator = locator
            status = await Task.detached {
                StreamDeckPluginStatus.decide(installed: locator.installedVersion(), packaged: locator.packagedVersion())
            }.value
        } while refreshRequested
        isChecking = false
    }

    var warnings: [AppWarning] {
        guard !isUpdating else { return [] }
        let failure = lastUpdateFailure.map { " The automatic update failed: \($0)" } ?? ""
        switch status {
        case .unknown, .notInstalled, .current:
            return []
        case let .outOfDate(installed, packaged):
            return [AppWarning(id: Self.outOfDateID, kind: .streamDeckPlugin,
                        message: "The Stream Deck plugin is out of date (installed \(installed), this app has \(packaged)). \(failure) Update it in Settings › StreamDeck.")]
        case let .newerThanPackaged(installed, packaged):
            return [AppWarning(id: Self.newerThanPackagedID, kind: .streamDeckPlugin,
                        message: "The installed Stream Deck plugin (\(installed)) is newer than the one in this app (\(packaged)). Press Install/Update Stream Deck Plugin in Settings › StreamDeck to match this app.")]
        case let .incompatible(installed, _):
            return [AppWarning(id: Self.incompatibleID, kind: .streamDeckPlugin, severity: .error,
                        message: "The installed Stream Deck plugin (\(installed)) doesn't work with this version of \(AppInfo.name).\(failure) Update it in Settings › StreamDeck.")]
        }
    }

    /// The version of the plugin Stream Deck has installed, if known (for the settings tab).
    var installedVersion: PluginVersion? {
        switch status {
        case let .current(installed), let .outOfDate(installed, _), let .newerThanPackaged(installed, _), let .incompatible(installed, _): installed
        case .unknown, .notInstalled: nil
        }
    }
}
