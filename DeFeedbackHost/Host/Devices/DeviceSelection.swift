//
//  DeviceSelection.swift
//  DeFeedbackHost
//
//  Created by Edgars Klepers on 9/20/2026.
//
//  ┌─────────────────────────────────────────────────────────────────────────────────────────┐
//  │ AI AGENTS: this file is the SOURCE OF TRUTH for which audio devices, sample rates and   │
//  │ buffer sizes the host has chosen, remembered, or lost.                                  │
//  └─────────────────────────────────────────────────────────────────────────────────────────┘
//
//  Happy path
//    * `refreshDeviceList()` reads the system's devices; on first run it picks the system default
//      (or the first device). Choosing a device remembers its name, reads that device's sample
//      rates and buffer-size range, and picks the rate it is already running at.
//    * Choosing a sample rate remembers it and, when the host is stopped, sets it on the device
//      and checks that the device took it.
//  Edge cases and errors
//    * A saved device that is not connected stays selected: it shows up as `unavailableDevice`
//      (its remembered name, or its UID if no name was saved) and its rate is remembered, so both
//      come back when the device does. Choosing a present device clears that.
//    * A device that will not take the requested rate is reported through the host's
//      `errorMessage` and the options are re-read from the device.
//    * While the sample-rate menus are being refreshed from hardware, their own change hooks are
//      muted so the old value is not written back.
//    * Rates are compared with `AudioHost.ratesMatch`, never with `==`.

import CoreAudio
import Foundation

/// What `DeviceSelection` needs from the host. `AudioHost` is the only conformer.
@MainActor
protocol DeviceSelectionHost: AnyObject {

    var isRunning: Bool { get }
    var bufferSize: Int { get }

    /// Where problems are reported to the user.
    var errorMessage: String? { get set }

    /// Something that is saved changed.
    func settingsChanged()

    /// The user (or first-run selection) chose a different device: an automatic restart that was
    /// waiting for the old choice no longer applies.
    func deviceSelectionDidChange()
}

/// The audio devices on offer, which ones are chosen, their sample rates and buffer-size ranges,
/// and what is remembered about devices that are not connected right now.
@Observable
@MainActor
final class DeviceSelection {

    /// Set by the host once it is fully initialised.
    @ObservationIgnored weak var host: (any DeviceSelectionHost)?

    internal(set) var inputDevices: [AudioDevice] = []
    internal(set) var outputDevices: [AudioDevice] = []

    /// Select device by UID (avoid `AudioDeviceID` because it is ephemeral).
    var selectedInputDeviceUID: String? {
        didSet {
            guard oldValue != selectedInputDeviceUID else { return }
            deviceSelectionChanged(.input)
        }
    }

    var selectedOutputDeviceUID: String? {
        didSet {
            guard oldValue != selectedOutputDeviceUID else { return }
            deviceSelectionChanged(.output)
        }
    }

    /// Remembered name of the previously used input audio device but it is currently not available.
    private(set) var rememberedInputDeviceName: String?
    /// Remembered name of the previously used output audio device but it is currently not available.
    private(set) var rememberedOutputDeviceName: String?

    internal(set) var inputSampleRates: [Double] = []
    internal(set) var outputSampleRates: [Double] = []

    var selectedInputSampleRate: Double? {
        didSet {
            guard oldValue != selectedInputSampleRate else { return }
            if let rate = selectedInputSampleRate { rememberedInputSampleRate = rate }
            applySampleRate(.input)
            host?.settingsChanged()
        }
    }

    var selectedOutputSampleRate: Double? {
        didSet {
            guard oldValue != selectedOutputSampleRate else { return }
            if let rate = selectedOutputSampleRate { rememberedOutputSampleRate = rate }
            applySampleRate(.output)
            host?.settingsChanged()
        }
    }

    /// The last rate each direction was actually set to, kept across a device's absence (the selected value gets set to `nil` for protection)
    @ObservationIgnored private var rememberedInputSampleRate: Double?
    @ObservationIgnored private var rememberedOutputSampleRate: Double?

    /// What buffer sizes each selected device accepts; see `BufferSizeRanges`.
    private(set) var bufferRanges = BufferSizeRanges()

    /// True if the sample rate menus are being updated to match hardware, so their
    /// `didSet` hooks don't try to reset the old value.
    @ObservationIgnored private var isSyncingSampleRates = false

    #if DEBUG
    /// Set by `setHardwareForTesting`: the devices are fakes, so nothing may query or change the
    /// real hardware on their behalf (a fake device that fails to take a rate would otherwise
    /// retry forever).
    @ObservationIgnored var hardwareIsSimulated = false
    #endif

    // MARK: - Selected devices

    var selectedInputDevice: AudioDevice? {
        inputDevices.first { $0.uid == selectedInputDeviceUID }
    }

    var selectedOutputDevice: AudioDevice? {
        outputDevices.first { $0.uid == selectedOutputDeviceUID }
    }

    func unavailableDevice(_ direction: AudioHost.AudioDirection) -> AudioHost.UnavailableDevice? {
        guard let uid = selectedDeviceUID(direction), selectedDevice(direction) == nil else {
            return nil
        }
        // The name falls back to UID for a session saved before the name was persisted so something is displayed.
        return AudioHost.UnavailableDevice(uid: uid, name: rememberedDeviceName(direction) ?? uid)
    }

    private func selectedDeviceUID(_ direction: AudioHost.AudioDirection) -> String? {
        switch direction {
        case .input: return selectedInputDeviceUID
        case .output: return selectedOutputDeviceUID
        }
    }

    private func selectedDevice(_ direction: AudioHost.AudioDirection) -> AudioDevice? {
        switch direction {
        case .input: return selectedInputDevice
        case .output: return selectedOutputDevice
        }
    }

    private func rememberedDeviceName(_ direction: AudioHost.AudioDirection) -> String? {
        switch direction {
        case .input: return rememberedInputDeviceName
        case .output: return rememberedOutputDeviceName
        }
    }

    private func rememberDeviceName(_ direction: AudioHost.AudioDirection) {
        let name: String?
        if selectedDeviceUID(direction) == nil {
            name = nil
        } else if let device = selectedDevice(direction) {
            name = device.name
        } else {
            return
        }

        switch direction {
        case .input: rememberedInputDeviceName = name
        case .output: rememberedOutputDeviceName = name
        }
    }

    private func deviceSelectionChanged(_ direction: AudioHost.AudioDirection) {
        rememberDeviceName(direction)
        refreshDeviceCapabilities(direction)
        // because the user changed the selected device, this should invalidate an auto-start.
        host?.deviceSelectionDidChange()
        host?.settingsChanged()
    }

    private func deviceID(for direction: AudioHost.AudioDirection) -> AudioDeviceID? {
        selectedDevice(direction)?.id
    }

    private func deviceName(for direction: AudioHost.AudioDirection) -> String {
        switch direction {
        case .input:
            return selectedInputDevice?.name ?? rememberedInputDeviceName ?? "input device"
        case .output:
            return selectedOutputDevice?.name ?? rememberedOutputDeviceName ?? "output device"
        }
    }

    // MARK: - Refreshing from the system

    /// Re-reads the system's device list and applies the first-run default selection.
    func refreshDeviceList() {
        let all = AudioHardware.allDevices()
        inputDevices = all.filter { $0.inputChannelCount > 0 }
        outputDevices = all.filter { $0.outputChannelCount > 0 }

        // first run protection
        if selectedInputDeviceUID == nil {
            let preferred = AudioHardware.defaultDeviceID(input: true)
            selectedInputDeviceUID = (inputDevices.first { $0.id == preferred }
                                      ?? inputDevices.first)?.uid
        }
        if selectedOutputDeviceUID == nil {
            let preferred = AudioHardware.defaultDeviceID(input: false)
            selectedOutputDeviceUID = (outputDevices.first { $0.id == preferred }
                                       ?? outputDevices.first)?.uid
        }

        for direction in AudioHost.AudioDirection.allCases {
            rememberDeviceName(direction)
        }
    }

    /// Re-reads rates and buffer sizes for both devices and puts back any remembered rate.
    func refreshAllCapabilities() {
        for direction in AudioHost.AudioDirection.allCases {
            refreshDeviceCapabilities(direction)
            restoreRememberedRate(direction)
        }
    }

    /// refreshes what sample rates and buffer sizes are available for the device.
    private func refreshDeviceCapabilities(_ direction: AudioHost.AudioDirection) {
        #if DEBUG
        if hardwareIsSimulated { return }
        #endif
        guard let id = deviceID(for: direction) else {
            setSampleRates([], selection: nil, for: direction)
            bufferRanges.set(nil, for: direction)
            return
        }

        bufferRanges.set(AudioHardware.bufferFrameSizeRange(id), for: direction)

        var rates = AudioHardware.availableSampleRates(id)
        let current = AudioHardware.nominalSampleRate(id)

        // If the device doesnt get us a list of rates, at least show the current rate the device is working at
        if rates.isEmpty, let current {
            rates = [current]
        }

        setSampleRates(rates,
                       selection: AudioHost.menuSelection(forCurrent: current, from: rates),
                       for: direction)
    }

    // MARK: - Sample rates

    func sampleRates(for direction: AudioHost.AudioDirection) -> [Double] {
        switch direction {
        case .input: return inputSampleRates
        case .output: return outputSampleRates
        }
    }

    /// The rate to save for a direction: the selected one, or the last one used while the device is away.
    func rateToSave(_ direction: AudioHost.AudioDirection) -> Double? {
        switch direction {
        case .input: return selectedInputSampleRate ?? rememberedInputSampleRate
        case .output: return selectedOutputSampleRate ?? rememberedOutputSampleRate
        }
    }

    private func rememberedSampleRate(_ direction: AudioHost.AudioDirection) -> Double? {
        switch direction {
        case .input: return rememberedInputSampleRate
        case .output: return rememberedOutputSampleRate
        }
    }

    private func restoreRememberedRate(_ direction: AudioHost.AudioDirection) {
        guard let remembered = rememberedSampleRate(direction),
              deviceID(for: direction) != nil,
              sampleRates(for: direction).contains(where: { AudioHost.ratesMatch($0, remembered) })
        else { return }

        switch direction {
        case .input:
            guard !AudioHost.ratesMatch(selectedInputSampleRate, remembered) else { return }
            selectedInputSampleRate = remembered
        case .output:
            guard !AudioHost.ratesMatch(selectedOutputSampleRate, remembered) else { return }
            selectedOutputSampleRate = remembered
        }
    }

    private func setSampleRates(_ rates: [Double], selection: Double?, for direction: AudioHost.AudioDirection) {
        isSyncingSampleRates = true // blocks the system trying to set it back to the old value mid-process
        switch direction {
        case .input:
            inputSampleRates = rates
            selectedInputSampleRate = selection
        case .output:
            outputSampleRates = rates
            selectedOutputSampleRate = selection
        }
        isSyncingSampleRates = false
    }

    private func applySampleRate(_ direction: AudioHost.AudioDirection) {
        guard !isSyncingSampleRates, host?.isRunning != true else { return }
        #if DEBUG
        if hardwareIsSimulated { return }
        #endif
        guard let id = deviceID(for: direction),
              let target = direction == .input ? selectedInputSampleRate : selectedOutputSampleRate
        else { return }

        if AudioHost.ratesMatch(AudioHardware.nominalSampleRate(id), target) {
            return
        }

        let name = deviceName(for: direction)
        Task {
            AudioHardware.setNominalSampleRate(target, for: id)
            let applied = await EngineSession.awaitSampleRate(target, on: id)
            if !applied {
                host?.errorMessage = AudioHostError
                    .sampleRateNotApplied(name, target).localizedDescription
                // refresh the options for display
                refreshDeviceCapabilities(direction)
            }
        }
    }

    // MARK: - Restoring

    /// Restores the saved device choices (before the sample rates, so choosing a device doesn't reset a rate).
    func restoreDevices(from settings: HostSettings) {
        if let uid = settings.inputDeviceUID {
            rememberedInputDeviceName = settings.inputDeviceName
            selectedInputDeviceUID = uid
        }
        if let uid = settings.outputDeviceUID {
            rememberedOutputDeviceName = settings.outputDeviceName
            selectedOutputDeviceUID = uid
        }
    }

    /// Restores the saved sample rates.
    func restoreSampleRates(from settings: HostSettings) {
        // intentionally setting up sample rate after audio devices so changing audio device doesnt re-set sample rate.
        rememberedInputSampleRate = settings.inputSampleRate
        rememberedOutputSampleRate = settings.outputSampleRate
        for direction in AudioHost.AudioDirection.allCases {
            restoreRememberedRate(direction)
        }
    }
}

extension AudioHost: DeviceSelectionHost {}
