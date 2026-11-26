//
//  PluginInstance.swift
//  DeFeedbackHost
//
//  Created by Edgars Klepers on 9/17/26.
//

import AVFAudio
import AudioToolbox
import CoreAudioKit
import SwiftUI

enum PluginInstanceError: LocalizedError {
    case componentNotFound
    case formatRejected

    var errorDescription: String? {
        switch self {
        case .componentNotFound:
            return "Couldn't find the configured AU Component. Check the Plugin Configuration."
        case .formatRejected:
            return "The AU Component rejected both mono and stereo buses at the specified sample rate."
        }
    }
}

@Observable
final class PluginInstance: Identifiable {

    let id = UUID()

    var name: String {
        didSet { changeFlag.markDirty() }
    }

    private(set) var audioUnit: AVAudioUnit?
    private(set) var pluginUI: PluginUI = .loading
    private(set) var loadError: String?

    var inputChannel = 0 {
        didSet {
            slot?.setInputChannel(inputChannel)
            changeFlag.markDirty()
        }
    }

    var outputChannel = 0 {
        didSet {
            slot?.setOutputChannel(outputChannel)
            changeFlag.markDirty()
        }
    }

    var isMuted = false {
        didSet {
            guard !isReconcilingMute else { return }
            applyMute()
            changeFlag.markDirty()
        }
    }

    /// Flag that blocks trying to set mute while we are not sure state is synchronized between UI and plugin
    @ObservationIgnored private var isReconcilingMute = false

    /// We do the bypass, not the plugin, which is why it's different than mute. (we dont have access to the plugin's passthrough option)
    var isBypassed = false {
        didSet {
            slot?.setBypassed(isBypassed)
            changeFlag.markDirty()
        }
    }

    @ObservationIgnored var slot: CoreAudioEngineControl.Slot?

    @ObservationIgnored private(set) var busChannelCount = 1

    @ObservationIgnored private let changeFlag: SettingsChangeFlag

    @ObservationIgnored private var parameterObserverToken: AUParameterObserverToken?

    init(name: String = InstanceName.defaultName(among: []), changeFlag: SettingsChangeFlag) {
        self.name = name
        self.changeFlag = changeFlag
    }

    /// Cached display name for the plugin, as this shouldn't change (and do we really care if it does)
    @ObservationIgnored private var resolvedDisplayName: String?

    var displayName: String {
        if let resolvedDisplayName { return resolvedDisplayName }
        guard let name = audioUnit?.withAUAudioUnit({ $0.audioUnitName }) else { return "Audio Unit" }
        resolvedDisplayName = name
        return name
    }

    // MARK: - Watched plugin parameters

    nonisolated static let strengthParameterName = "Strength"
    nonisolated static let muteParameterName = "Mute"

    var strengthPercent: Int? {
        guard let value = strengthSnapshot.value else { return nil }
        return strength.percent(of: value)
    }

    var pluginMuted: Bool? {
        guard let value = muteSnapshot.value else { return nil }
        // The plugin gets to define its range, so high half is on, low half is off.
        return value >= mute.lowest + mute.span / 2
    }

    /// Sets the strength parameter, returns true if set, false if the plugin doesnt have a 'Strength'
    /// parameter
    @discardableResult
    func setStrengthPercent(_ percent: Int) -> Bool {
        guard let strengthParameter else { return false }

        let value = strength.value(forPercent: percent)
        strengthParameter.value = value
        strengthSnapshot.store(value)
        changeFlag.markDirty()
        return true
    }

    /// True if the plugin has a `Strength` parameter, else false.
    var publishesStrength: Bool { strengthParameter != nil }

    /// Mutes the channel
    private func applyMute() {
        guard let muteParameter else {
            slot?.setMuted(isMuted)
            return
        }

        let value = isMuted ? mute.lowest + mute.span : mute.lowest
        muteParameter.value = value
        muteSnapshot.store(value)
    }

    /// after the mute is set, this makes sure the UIs matche the actual value of the plugin
    func reconcileMuteFromPlugin() {
        guard let muted = pluginMuted, muted != isMuted else { return }
        isReconcilingMute = true
        isMuted = muted
        isReconcilingMute = false
    }

    @ObservationIgnored private let strengthSnapshot = ParameterSnapshot()
    @ObservationIgnored private let muteSnapshot = ParameterSnapshot()

    @ObservationIgnored private var strengthParameter: AUParameter?
    @ObservationIgnored private var muteParameter: AUParameter?

    @ObservationIgnored private var strength = WatchedParameter()
    @ObservationIgnored private var mute = WatchedParameter()

    private func locateWatchedParameters(on unit: AVAudioUnit) {
        let foundParam: (strength: AUParameter?, mute: AUParameter?) = unit.withAUAudioUnit { au in
            let all = au.parameterTree?.allParameters ?? []
            func find(_ name: String) -> AUParameter? {
                all.first {
                    $0.identifier.caseInsensitiveCompare(name) == .orderedSame
                        || $0.displayName.caseInsensitiveCompare(name) == .orderedSame
                }
            }
            return (find(Self.strengthParameterName), find(Self.muteParameterName))
        }

        func watch(_ parameter: AUParameter?, with snapshot: ParameterSnapshot) -> WatchedParameter {
            guard let parameter else {
                snapshot.clear()
                return WatchedParameter()
            }
            snapshot.store(parameter.value)
            return WatchedParameter(address: parameter.address,
                           lowest: parameter.minValue,
                           span: parameter.maxValue - parameter.minValue)
        }

        strength = watch(foundParam.strength, with: strengthSnapshot)
        mute = watch(foundParam.mute, with: muteSnapshot)
        strengthParameter = foundParam.strength
        muteParameter = foundParam.mute
    }

    // MARK: - Persistable plugin state

    var pluginState: [String: Any]? {
        audioUnit?.withAUAudioUnit { $0.fullState }
    }

    var parameterValues: [String: Float] {
        audioUnit?.withAUAudioUnit { au in
            var values: [String: Float] = [:]
            for param in au.parameterTree?.allParameters ?? [] {
                values[param.identifier] = param.value
            }
            return values
        } ?? [:]
    }

    private func applyPluginState(_ state: [String: Any], to unit: AVAudioUnit) {
        unit.withAUAudioUnit { $0.fullState = state }
    }

    private func applyParameterValues(_ values: [String: Float], to unit: AVAudioUnit) {
        unit.withAUAudioUnit { au in
            for param in au.parameterTree?.allParameters ?? [] {
                guard let saved = values[param.identifier] else { continue }
                param.value = min(max(saved, param.minValue), param.maxValue)
            }
        }
    }

    private func observeParameters(on unit: AVAudioUnit) {
        let flag = changeFlag
        let strengthSnapshot = self.strengthSnapshot
        let muteSnapshot = self.muteSnapshot

        let strengthParamAddress = strength.address
        let muteParamAddress = mute.address

        parameterObserverToken = unit.withAUAudioUnit { au in
            au.parameterTree?.token(byAddingParameterObserver: { address, value in
                flag.markDirty()
                if address == strengthParamAddress {
                    strengthSnapshot.store(value)
                } else if address == muteParamAddress {
                    muteSnapshot.store(value)
                }
            })
        }
    }

    func stopObservingParameters() {
        guard let token = parameterObserverToken, let unit = audioUnit else { return }
        unit.withAUAudioUnit { $0.parameterTree?.removeParameterObserver(token) }
        parameterObserverToken = nil
    }

    // MARK: - Loading

    /// Loads a plugin instance from stored values
    func load(restoring storedState: [String: Any]? = nil,
              parameters storedParams: [String: Float]? = nil) async {
        var description = PluginConfiguration.componentDescription

        guard AudioComponentFindNext(nil, &description) != nil else {
            let message = PluginInstanceError.componentNotFound.localizedDescription
            loadError = message
            pluginUI = .unavailable(message)
            return
        }

        do {
            let unit = try await instantiate(description)
            audioUnit = unit

            if let storedState {
                applyPluginState(storedState, to: unit)
            }
            if let storedParams, !storedParams.isEmpty {
                applyParameterValues(storedParams, to: unit)
            }

            locateWatchedParameters(on: unit)
            reconcileMuteFromPlugin()
            observeParameters(on: unit)
            await resolveUI(for: unit)
        } catch {
            loadError = error.localizedDescription
            pluginUI = .unavailable(error.localizedDescription)
        }
    }

    private func instantiate(_ description: AudioComponentDescription) async throws -> AVAudioUnit {
        try await withCheckedThrowingContinuation { continuation in
            AVAudioUnit.instantiate(with: description,
                                    options: PluginConfiguration.instantiationOptions) { unit, error in
                if let unit {
                    continuation.resume(returning: unit)
                } else {
                    continuation.resume(
                        throwing: error ?? PluginInstanceError.componentNotFound)
                }
            }
        }
    }

    private func resolveUI(for unit: AVAudioUnit) async {
        let boxed: UncheckedBox<NSViewController>? = await withCheckedContinuation { continuation in
            unit.withAUAudioUnit { au in
                au.requestViewController { controller in
                    continuation.resume(returning: controller.map(UncheckedBox.init))
                }
            }
        }

        if let boxed {
            // plugin provides a view
            pluginUI = .controller(boxed.value)
        } else {
            // generic view
            pluginUI = .genericView(unit.withAudioUnit { AUGenericView(audioUnit: $0) })
        }
    }

    // MARK: - Attaching to the engine

    /// Connects the AUv2 plugin to the render thread using the C++ engine.
    func attach(to engine: CoreAudioEngineControl, slot: CoreAudioEngineControl.Slot) throws {
        guard let unit = audioUnit else { throw PluginInstanceError.componentNotFound }

        let channels: Int? = unit.withAudioUnit { handle in
            engine.installUnit(handle, into: slot)
        }
        guard let channels else { throw PluginInstanceError.formatRejected }

        busChannelCount = channels
        self.slot = slot
        syncToSlot()
    }

    func teardownRenderResources() {
        audioUnit?.withAudioUnit { handle in
            _ = AudioUnitUninitialize(handle)
        }
    }

    /// Syncs the UI state to this plugin instance.
    func syncToSlot() {
        guard let slot else { return }
        slot.setInputChannel(inputChannel)
        slot.setOutputChannel(outputChannel)
        slot.setMuted(muteParameter == nil && isMuted) // cehck nil in case the plugin doesnt give us a value
        slot.setBypassed(isBypassed)
    }
}
