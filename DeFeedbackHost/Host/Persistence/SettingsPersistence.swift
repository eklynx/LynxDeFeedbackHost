//
//  SettingsPersistence.swift
//  DeFeedbackHost
//
//  Created by Edgars Klepers on 9/20/2026.
//
//
//  ┌─────────────────────────────────────────────────────────────────────────────────────────┐
//  │ AI AGENTS: this file is the SOURCE OF TRUTH for how the host saves its settings.        │
//  └─────────────────────────────────────────────────────────────────────────────────────────┘
//
//  Happy path
//    1. `AudioHost` restores its state, then calls `finishRestoring(with:)`; from then on changes
//       mark the settings dirty and a one-second autosave writes them (also on `save()`,
//       `saveNow()` and app termination).
//    2. `defaults write` edits to the five preference keys are applied to the running host.
//  Edge cases
//    * While restoring, `markDirty` and `save` do nothing, so a half-restored host is never saved.
//    * A save whose settings equal the last saved ones writes nothing.
//    * An invalid external value is ignored. Buffer size and parallel rendering are locked while
//      the host runs: those edits wait, and are re-checked when it stops.
//    * An applied external edit counts as saved, so the next save doesn't rewrite it.

import AppKit
import Foundation

/// What `SettingsPersistence` needs from the host. `AudioHost` is the only conformer.
@MainActor
protocol PersistableHost: AnyObject {

    var isRunning: Bool { get }

    /// The host's full state as it would be saved now.
    func currentSettings() -> HostSettings

    /// Applies preferences read from outside the app; the locked pair (buffer size, parallel
    /// rendering) only when `includingLockedWhileRunning` is true.
    func apply(_ external: HostPreferences, includingLockedWhileRunning: Bool)

    /// Re-reads each instance's mute from its plugin, after the plugin changed it.
    func reconcileInstancesFromPlugin()
}

/// Dirty tracking, autosave, save-on-quit and live `defaults write` handling for `AudioHost`.
@MainActor
final class SettingsPersistence {

    private let defaults: UserDefaults
    private let changeFlag: SettingsChangeFlag

    /// Set by the host once it is fully initialised.
    weak var host: (any PersistableHost)?

    /// Don't try to save settings while the host is still restoring, so we never persist a
    /// half-way done state.
    private var isRestoring = true

    private var isDirty = false
    private var lastSaved: HostSettings?
    private var autosaveTask: Task<Void, Never>?
    private var appTerminationObserver: NSObjectProtocol?
    private var defaultsObserver: NSObjectProtocol?

    init(defaults: UserDefaults, changeFlag: SettingsChangeFlag) {
        self.defaults = defaults
        self.changeFlag = changeFlag
    }

    /// Restoring is done: `settings` is what was loaded, and counts as already saved.
    func finishRestoring(with settings: HostSettings) {
        isRestoring = false
        lastSaved = settings
        watchExternalPreferenceChanges()
        startAutosaveTask()
        saveOnTermination()
    }

    func markDirty() {
        guard !isRestoring else { return }
        isDirty = true
    }

    /// Marks the settings dirty and saves immediately, e.g. at a natural save point like Stop.
    func saveNow() {
        isDirty = true
        save()
    }

    func save() {
        guard !isRestoring, let host else { return }

        let settings = host.currentSettings()
        isDirty = false

        guard settings != lastSaved else { return }

        SettingsStore.save(settings, previous: lastSaved, to: defaults)
        lastSaved = settings
    }

    // MARK: - Autosave

    /// check for settings to save every second.
    private func startAutosaveTask() {
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.saveIfNeeded()
            }
        }
    }

    private func saveIfNeeded() {
        let instancesAreDirty = changeFlag.consume()

        if instancesAreDirty {
            host?.reconcileInstancesFromPlugin()
        }

        guard isDirty || instancesAreDirty else { return }
        save()
    }

    private func saveOnTermination() {
        appTerminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        }
    }

    // MARK: - External preference changes (defaults write)

    private func watchExternalPreferenceChanges() {
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyExternalPreferences() }
        }
    }

    /// Applies edits made to the individual preference keys (for example `defaults write`) to the
    /// running host. Buffer size and parallel rendering are locked while running, so those wait and
    /// are re-checked when the host stops. Invalid values are ignored.
    func applyExternalPreferences() {
        guard !isRestoring, let host else { return }

        let current = host.currentSettings().preferences
        let external = HostPreferences.read(from: defaults, fallback: current)
        guard external != current else { return }

        var applied = lastSaved?.preferences ?? current

        let unlocked = !host.isRunning
        host.apply(external, includingLockedWhileRunning: unlocked)

        applied.autoRunOnStartup = external.autoRunOnStartup
        applied.newInstancesStartMuted = external.newInstancesStartMuted
        applied.newInstancesStartBypassed = external.newInstancesStartBypassed
        if unlocked {
            applied.parallelRendering = external.parallelRendering
            applied.bufferSize = external.bufferSize
        }

        // What the defaults now hold counts as saved, so the next save doesn't rewrite it.
        lastSaved?.preferences = applied
    }
}

extension AudioHost: PersistableHost {}
