//
//  UpdateService.swift
//  DeFeedbackHost
//
//  Implements the contract in UpdateChecking.swift. Owns the settings, the status and the timer.
//
import Foundation
import Observation
import os

@Observable
@MainActor
final class UpdateService: UpdateStatusSource, WarningSource {

    private(set) var status = UpdateStatus()

    var isEnabled: Bool {
        get { preferences.isEnabled }
        set {
            guard newValue != preferences.isEnabled else { return }
            preferences.isEnabled = newValue
            persist()
            reschedule(probeNow: newValue)
        }
    }

    var interval: UpdateInterval {
        get { preferences.interval }
        set {
            guard newValue != preferences.interval else { return }
            preferences.interval = newValue
            persist()
            reschedule(probeNow: false)
        }
    }

    /// Switching clears the known update (it may not exist on the new channel) and re-probes when on.
    var channel: UpdateChannel {
        get { preferences.channel }
        set {
            guard newValue != preferences.channel else { return }
            preferences.channel = newValue
            status.channel = newValue
            status.availableVersion = nil
            status.availableLink = nil
            status.lastError = nil
            persist()
            reschedule(probeNow: true)
        }
    }

    var updateStatus: UpdateStatus { status }

    /// The web page's "update available" banner (see Warnings/AppWarning.swift).
    var warnings: [AppWarning] {
        guard let version = status.availableVersion else { return [] }
        return [AppWarning(id: "update",
                           kind: .updateAvailable,
                           message: "Version \(version) is available. Install it from the app on the host Mac.",
                           link: status.releaseNotesURL,
                           linkTitle: "Release notes")]
    }

    @ObservationIgnored private var preferences: UpdatePreferences
    @ObservationIgnored private let engine: UpdateEngine
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let sleep: (TimeInterval) async throws -> Void
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var started = false

    init(engine: UpdateEngine,
         defaults: UserDefaults = .standard,
         now: @escaping () -> Date = Date.init,
         sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.engine = engine
        self.defaults = defaults
        self.now = now
        self.sleep = sleep
        self.preferences = UpdatePreferences(from: defaults)
        self.status = UpdateStatus(isEnabled: preferences.isEnabled,
                                   channel: preferences.channel,
                                   lastChecked: preferences.lastChecked)
    }

    /// Call once at application startup. Probes immediately when enabled (contract rule 2).
    func start() {
        guard !started else { return }
        started = true
        reschedule(probeNow: true)
    }

    /// Menu item: a user-initiated check, allowed even when background checking is off.
    func checkForUpdates() {
        engine.presentUpdate(channel: preferences.channel)
    }

    /// "Update Now": same hand-off, only offered while an update is known.
    func installNow() {
        guard status.isUpdateAvailable else { return }
        engine.presentUpdate(channel: preferences.channel)
    }

    // MARK: - Scheduling

    private func reschedule(probeNow: Bool) {
        timer?.cancel()
        timer = nil
        status.isEnabled = preferences.isEnabled
        guard started, preferences.isEnabled else { return }

        timer = Task { [weak self] in
            // Probe now (startup / just enabled) or after a full interval (interval changed).
            var wait: TimeInterval = probeNow ? 0 : (self?.preferences.interval.seconds ?? 0)
            while !Task.isCancelled {
                if wait > 0 { try? await self?.sleep(wait) }
                guard !Task.isCancelled, let self, self.preferences.isEnabled else { return }
                let result = await self.runProbe()
                wait = UpdateScheduler.delay(after: result, interval: self.preferences.interval)
            }
        }
    }

    private func runProbe() async -> ProbeResult {
        status.isChecking = true
        let channel = preferences.channel
        let result = await withCheckedContinuation { continuation in
            engine.probe(channel: channel) { continuation.resume(returning: $0) }
        }
        apply(result)
        return result
    }

    private func apply(_ result: ProbeResult) {
        status.isChecking = false
        status.lastChecked = now()
        preferences.lastChecked = status.lastChecked
        persist()
        switch result {
        case .updateAvailable(let version, let link):
            status.availableVersion = version
            status.availableLink = link
            status.lastError = nil
        case .upToDate:
            status.availableVersion = nil
            status.availableLink = nil
            status.lastError = nil
        case .failed(let message):
            // Keep any known update: a flaky network must not hide it (contract rule 6).
            status.lastError = message
            Logger.host_application.notice("Update check failed: \(message, privacy: .public)")
        }
    }

    private func persist() {
        preferences.write(to: defaults)
    }
}
