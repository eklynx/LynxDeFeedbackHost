//
//  InstanceList.swift
//  DeFeedbackHost
//
//  Created by Edgars Klepers on 9/20/2026.
//
//  ┌─────────────────────────────────────────────────────────────────────────────────────────┐
//  │ AI AGENTS: this file is the SOURCE OF TRUTH for the plugin instance list.               │
//  └─────────────────────────────────────────────────────────────────────────────────────────┘
//
//  Happy path
//    * `add()` creates "Instance N", gives it the next channel on each device (capped at the last
//      one), appends and selects it, loads the plugin, applies the new-instance mute/bypass
//      defaults, and, when the engine is running, claims a slot for it.
//    * `remove` takes the instance out of the list, keeps the same instance selected, and retires
//      its slot safely (after two buffers when running) before freeing the plugin.
//  Errors
//    * No plugin installed, or the 32-instance cap reached: `add()` returns nil and reports the
//      `AudioHostError` through the host's `errorMessage`.
//    * The plugin fails to load: the instance stays in the list with `loadError` set, and the
//      error is reported.
//    * A name that is empty, too long, has control characters or `/`, or clashes with another
//      instance (ignoring case): `rename` returns the `InstanceNameError` and changes nothing.

import Foundation

/// What `InstanceList` needs from the host. `AudioHost` is the only conformer.
@MainActor
protocol InstanceListHost: AnyObject {
    var isPluginInstalled: Bool { get }
    var isRunning: Bool { get }
    var inputChannelCount: Int { get }
    var outputChannelCount: Int { get }
    var newInstancesMuted: Bool { get }
    var newInstancesBypassed: Bool { get }

    /// The engine while audio is running; nil when stopped.
    var liveEngine: CoreAudioEngineControl? { get }
    var runningSampleRate: Double { get }

    /// Where problems are reported to the user.
    var errorMessage: String? { get set }

    /// Something that is saved changed.
    func settingsChanged()
}

/// The plugin instances, which one is shown, and adding, removing and renaming them.
@Observable
@MainActor
final class InstanceList {

    private(set) var instances: [PluginInstance] = []

    var selectedInstanceIndex = 0 {
        didSet { host?.settingsChanged() }
    }

    /// Set by the host once it is fully initialised.
    @ObservationIgnored weak var host: (any InstanceListHost)?

    @ObservationIgnored private let changeFlag: SettingsChangeFlag

    init(changeFlag: SettingsChangeFlag) {
        self.changeFlag = changeFlag
    }

    var selectedInstance: PluginInstance? {
        instances.indices.contains(selectedInstanceIndex) ? instances[selectedInstanceIndex] : nil
    }

    var canShowPrevious: Bool { selectedInstanceIndex > 0 }
    var canShowNext: Bool { selectedInstanceIndex < instances.count - 1 }

    /// Returns if another instance can be created.  False if plugin is not installed, or we have hit the maxiumum number of istances
    /// (this would be a hard limit due to memory allocation, not an advisory warning due to performance)
    var canAdd: Bool {
        (host?.isPluginInstalled ?? false) && instances.count < PluginConfiguration.maximumInstanceCount
    }

    // MARK: - Restoring

    func restore(from settings: HostSettings) async {
        let saved = settings.instances.prefix(PluginConfiguration.maximumInstanceCount)
        guard !saved.isEmpty else { return }

        let names = Self.restoredNames(saved.map(\.name))

        for (persisted, name) in zip(saved, names) {
            let instance = PluginInstance(name: name, changeFlag: changeFlag)
            instance.inputChannel = persisted.inputChannel
            instance.outputChannel = persisted.outputChannel
            instance.isMuted = persisted.isMuted
            instance.isBypassed = persisted.isBypassed
            instances.append(instance)

            await instance.load(restoring: PluginStateCoding.state(from: persisted.pluginState),
                                parameters: persisted.parameterValues)

            if let error = instance.loadError, host?.isPluginInstalled == true {
                host?.errorMessage = error
            }
        }

        selectedInstanceIndex = min(max(0, settings.selectedInstanceIndex),
                                    max(0, instances.count - 1))
    }

    nonisolated static func restoredNames(_ saved: [String?]) -> [String] {
        var kept: [String?] = []
        for candidate in saved {
            let name = candidate.map(InstanceName.normalized)
            if let name, InstanceName.validate(name, among: kept.compactMap { $0 }) == nil {
                kept.append(name)
            } else {
                kept.append(nil)
            }
        }

        var resolved = kept.compactMap { $0 }
        return kept.map { name in
            if let name { return name }
            let fallback = InstanceName.defaultName(among: resolved)
            resolved.append(fallback)
            return fallback
        }
    }

    // MARK: - Adding

    /// Adds an instance and loads the configured audio unit into it.
    ///
    /// - Returns: a new instance, or `nil` if we are capped. An instance whose
    ///   *plugin* failed to load is still returned, but with its `loadError` populated with the reason.
    func add() async -> PluginInstance? {
        guard let host else { return nil }
        guard host.isPluginInstalled else {
            host.errorMessage = AudioHostError.pluginNotInstalled.localizedDescription
            return nil
        }
        guard canAdd else {
            host.errorMessage = AudioHostError.maxInstancesReached.localizedDescription
            return nil
        }

        let instance = PluginInstance(name: InstanceName.defaultName(among: instances.map(\.name)),
                                      changeFlag: changeFlag)

        let next = instances.count
        instance.inputChannel = host.inputChannelCount > 0 ? min(next, host.inputChannelCount - 1) : 0
        instance.outputChannel = host.outputChannelCount > 0 ? min(next, host.outputChannelCount - 1) : 0

        instances.append(instance)
        selectedInstanceIndex = instances.count - 1
        host.settingsChanged()

        await instance.load()

        guard instances.contains(where: { $0 === instance }) else { return nil }

        guard instance.audioUnit != nil else {
            host.errorMessage = instance.loadError
            return instance
        }

        instance.isMuted = host.newInstancesMuted
        instance.isBypassed = host.newInstancesBypassed

        if host.isRunning, let engine = host.liveEngine {
            do {
                try activate(instance, in: engine)
            } catch {
                host.errorMessage = error.localizedDescription
            }
        }

        return instance
    }

    #if DEBUG
    /// Test seam (debug builds only): appends an instance that has no plugin loaded behind it.
    func addBare(name: String) -> PluginInstance {
        let instance = PluginInstance(name: name, changeFlag: changeFlag)
        instances.append(instance)
        return instance
    }
    #endif

    // MARK: - Lookup and naming

    func instance(id: UUID) -> PluginInstance? {
        instances.first { $0.id == id }
    }

    /// Looks up an instance by its unique name (case-insensitive, like the uniqueness check).
    func instance(named name: String) -> PluginInstance? {
        instances.first { InstanceName.matches($0.name, name) }
    }

    /// Checks whether `proposed` would be a valid name for `instance`, without renaming it.
    func validateName(_ proposed: String, for instance: PluginInstance) -> InstanceNameError? {
        let others = instances.filter { $0 !== instance }.map(\.name)
        return InstanceName.validate(InstanceName.normalized(proposed), among: others)
    }

    /// Renames an instance with rule checks.
    ///
    /// - Returns: nil on success (or if unchanged), else error reason.
    func rename(_ instance: PluginInstance, to proposed: String) -> InstanceNameError? {
        if let error = validateName(proposed, for: instance) {
            return error
        }
        let name = InstanceName.normalized(proposed)
        guard name != instance.name else { return nil }
        instance.name = name
        host?.settingsChanged()
        return nil
    }

    // MARK: - Removing

    func removeSelected() {
        remove(at: selectedInstanceIndex)
    }

    /// Removes an instance by instanceId.
    ///
    /// - Returns: false if instance not found, i.e. already deleted
    func remove(id: UUID) -> Bool {
        guard let index = instances.firstIndex(where: { $0.id == id }) else { return false }
        remove(at: index)
        return true
    }

    private func remove(at index: Int) {
        guard instances.indices.contains(index) else { return }
        let instance = instances.remove(at: index)

        if index < selectedInstanceIndex {
            selectedInstanceIndex -= 1
        }
        selectedInstanceIndex = min(selectedInstanceIndex, max(0, instances.count - 1))

        host?.settingsChanged()
        retire(instance)
    }

    // MARK: - Engine slots

    func activate(_ instance: PluginInstance, in engine: CoreAudioEngineControl) throws {
        guard let slot = engine.claimSlot() else { throw AudioHostError.maxInstancesReached }

        do {
            try instance.attach(to: engine, slot: slot)
        } catch {
            engine.release(slot)
            throw error
        }
    }

    /// makes sure the instance is out of the render path safely before deleting
    private func retire(_ instance: PluginInstance) {
        instance.stopObservingParameters()

        guard let engineController = host?.liveEngine, let slot = instance.slot else {
            instance.teardownRenderResources()
            return
        }

        engineController.retire(slot)
        instance.slot = nil

        let bufferSeconds = Double(engineController.maximumFrameCount) / max(host?.runningSampleRate ?? 0, 8_000)
        Task {
            try? await Task.sleep(for: .seconds(bufferSeconds * 2))
            engineController.release(slot)
            instance.teardownRenderResources()
        }
    }

    // MARK: - Paging

    func showPrevious() {
        selectedInstanceIndex = max(0, selectedInstanceIndex - 1)
    }

    func showNext() {
        selectedInstanceIndex = min(instances.count - 1, selectedInstanceIndex + 1)
    }
}

extension AudioHost: InstanceListHost {}
