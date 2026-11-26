//
//  AudioHost+Persistence.swift
//  DeFeedbackHost
//
//  Created by Edgars Klepers on 9/20/2026.
//
//  What `SettingsPersistence` asks of the host (`PersistableHost`): the full state to save, applying external preferences, reconciling instances.

import Foundation

extension AudioHost {

    func currentSettings() -> HostSettings {
        HostSettings(
            pluginIdentity: .configured,
            bufferSize: bufferSize,
            inputDeviceUID: selectedInputDeviceUID,
            outputDeviceUID: selectedOutputDeviceUID,
            inputDeviceName: rememberedInputDeviceName,
            outputDeviceName: rememberedOutputDeviceName,
            inputSampleRate: deviceSelection.rateToSave(.input),
            outputSampleRate: deviceSelection.rateToSave(.output),
            parallelRendering: parallelRendering,
            autoRunOnStartup: autoRunOnStartup,
            newInstancesStartMuted: newInstancesMuted,
            newInstancesStartBypassed: newInstancesBypassed,
            selectedInstanceIndex: selectedInstanceIndex,
            instances: instances.map { instance in
                InstanceSettings(
                    name: instance.name,
                    inputChannel: instance.inputChannel,
                    outputChannel: instance.outputChannel,
                    isBypassed: instance.isBypassed,
                    isMuted: instance.isMuted,
                    pluginState: PluginStateCoding.data(from: instance.pluginState),
                    parameterValues: instance.parameterValues)
            },
            webServer: webServerSettings)
    }

    /// Applies preferences read from outside the app. Buffer size and parallel rendering are
    /// locked while running, so `includingLockedWhileRunning` is false then and those wait.
    func apply(_ external: HostPreferences, includingLockedWhileRunning: Bool) {
        if external.autoRunOnStartup != autoRunOnStartup { autoRunOnStartup = external.autoRunOnStartup }
        if external.newInstancesStartMuted != newInstancesMuted { newInstancesMuted = external.newInstancesStartMuted }
        if external.newInstancesStartBypassed != newInstancesBypassed { newInstancesBypassed = external.newInstancesStartBypassed }
        guard includingLockedWhileRunning else { return }
        if external.parallelRendering != parallelRendering { parallelRendering = external.parallelRendering }
        if external.bufferSize != bufferSize { bufferSize = external.bufferSize }
    }

    func reconcileInstancesFromPlugin() {
        for instance in instances {
            instance.reconcileMuteFromPlugin()
        }
    }
}
