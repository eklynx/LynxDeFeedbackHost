//
//  WebStatusPayload.swift
//  DeFeedbackHost
//
//  Builds the JSON the web API reports: `GET /api/status` (also pushed on the event stream),
//  `GET /api/update` and the instance and device lists. Reads the host and nothing else, never
//  changes it. Every key `status()` emits must be documented in openapi.yaml
//  (OpenAPIConformanceTests reads this file to check).
//  Moved out of WebControlService.swift without changing behaviour (issue #41).
//
import Foundation

@MainActor
struct WebStatusPayload {

    let host: AudioHost

    /// Read-only view of update state; nil reports updates as disabled.
    let updateSource: UpdateStatusSource?

    /// Everything that has something to warn about, in source order.
    let warningSources: [WarningSource]

    /// `GET /api/update`. Never triggers a check; reports what the app already knows.
    func update() -> [String: Any] {
        let status = updateSource?.updateStatus ?? UpdateStatus()
        return [
            "enabled": status.isEnabled,
            "available": status.isUpdateAvailable,
            "version": status.availableVersion ?? NSNull(),
            "channel": status.channel.rawValue,
            "releasesURL": status.releasesPage.absoluteString,
            "releaseNotesURL": status.releaseNotesURL.absoluteString
        ]
    }

    /// The `warnings` array of the status payload: every source's current warnings, in source order.
    func warnings() -> [[String: Any]] {
        warningSources.flatMap(\.warnings).map(\.jsonObject)
    }

    /// Contract stub (issue #29): #30 reads the real `ShutdownSettings` here. Kept out of `status()`
    /// so the conformance test sees one `shutdown` key, documented through `ShutdownStatus`.
    func shutdownStatus() -> [String: Any] {
        ["enabled": false, "testMode": true, "phrase": ShutdownPhrase.defaultPhrase]
    }

    /// gets the status of the host.  All values are retrieved from the host even if they could be calculated locally.
    func status() -> [String: Any] {
        let diagnostics = host.diagnostics

        return [
            "protocol": WebControlService.protocolVersion,
            "warnings": warnings(),
            "shutdown": shutdownStatus(),
            "running": host.isRunning,
            "canStart": host.canStart,
            "blockedReason": host.startBlockedReason ?? NSNull(),
            "sampleRate": host.isRunning
                ? Self.finite(host.runningSampleRate)
                : Self.finite(host.selectedOutputSampleRate ?? 0),
            "bufferSize": host.bufferSize,
            "bufferSizeChoices": PluginConfiguration.validBufferSizes,
            "bufferSizeAccepted": host.devicesRejectingBufferSize.isEmpty,
            "pluginInstalled": host.isPluginInstalled,
            "pluginMessage": host.isPluginInstalled
                ? NSNull()
                : AudioHostError.pluginNotInstalled.localizedDescription,
            "pluginURL": PluginConfiguration.pluginHomepage.absoluteString,
            "instances": Self.instanceList(host.instances),
            "instanceCount": host.instances.count,
            "maxInstanceCount": PluginConfiguration.maximumInstanceCount,
            "inputDevice": host.selectedInputDevice?.name
                ?? host.unavailableInputDevice?.name ?? NSNull(),
            "outputDevice": host.selectedOutputDevice?.name
                ?? host.unavailableOutputDevice?.name ?? NSNull(),
            "inputDeviceUID": host.selectedInputDeviceUID ?? NSNull(),
            "outputDeviceUID": host.selectedOutputDeviceUID ?? NSNull(),
            "inputDeviceMissing": host.unavailableInputDevice != nil,
            "outputDeviceMissing": host.unavailableOutputDevice != nil,
            "inputDevices": Self.deviceList(host.inputDevices, channels: \.inputChannelCount),
            "outputDevices": Self.deviceList(host.outputDevices, channels: \.outputChannelCount),
            "inputChannelCount": host.inputChannelCount,
            "outputChannelCount": host.outputChannelCount,
            "inputSampleRate": host.selectedInputSampleRate.map(Self.finite) ?? NSNull(),
            "outputSampleRate": host.selectedOutputSampleRate.map(Self.finite) ?? NSNull(),
            "inputSampleRates": host.inputSampleRates.map(Self.finite),
            "outputSampleRates": host.outputSampleRates.map(Self.finite),
            "sampleRatesMatch": host.doSampleRatesMatch,
            "dspLoad": Self.finite(diagnostics?.dspLoad ?? 0),
            "peakDspLoad": Self.finite(diagnostics?.peakDspLoad ?? 0),
            "underruns": diagnostics?.underruns ?? 0,
            "hasRendered": diagnostics?.hasRendered ?? false,
            "realtime": diagnostics?.audioThreadsAreRealtime ?? true,
            "error": host.errorMessage ?? NSNull()
        ]
    }

    private static func deviceList(_ devices: [AudioDevice],
                                   channels: KeyPath<AudioDevice, Int>) -> [[String: Any]] {
        devices.map { device in
            ["uid": device.uid,
             "name": device.name,
             "channels": device[keyPath: channels]]
        }
    }

    static func instanceList(_ instances: [PluginInstance]) -> [[String: Any]] {
        instances.enumerated().map { index, instance in
            instanceJSON(instance, at: index)
        }
    }

    static func instanceJSON(_ instance: PluginInstance, at index: Int) -> [String: Any] {
        [
            "index": index,
            "id": instance.name,
            "pluginName": instance.displayName,
            "strength": instance.strengthPercent ?? NSNull(),
            "muted": instance.isMuted,
            "bypassed": instance.isBypassed,
            "inputChannel": instance.inputChannel,
            "outputChannel": instance.outputChannel,
            "error": instance.loadError ?? NSNull()
        ]
    }

    private static func finite(_ value: Double) -> Double {
        value.isFinite ? value : 0
    }
}
