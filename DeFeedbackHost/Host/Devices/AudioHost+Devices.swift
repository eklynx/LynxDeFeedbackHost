//
//  AudioHost+Devices.swift
//  DeFeedbackHost
//
//  Created by Edgars Klepers on 9/20/2026.
//
//  AudioHost's device, sample-rate and buffer-range members. Every one of them forwards to
//  `DeviceSelection` (which holds the state and the rules); they live here so callers keep using
//  `host.selectedInputDeviceUID` and friends while the logic stays in one place.

import CoreAudio
import Foundation

extension AudioHost {

    // MARK: - Devices

    var inputDevices: [AudioDevice] { deviceSelection.inputDevices }
    var outputDevices: [AudioDevice] { deviceSelection.outputDevices }

    /// Select device by UID (avoid `AudioDeviceID` because it is ephemeral).
    var selectedInputDeviceUID: String? {
        get { deviceSelection.selectedInputDeviceUID }
        set { deviceSelection.selectedInputDeviceUID = newValue }
    }

    var selectedOutputDeviceUID: String? {
        get { deviceSelection.selectedOutputDeviceUID }
        set { deviceSelection.selectedOutputDeviceUID = newValue }
    }

    /// Remembered name of the previously used input audio device but it is currently not available.
    var rememberedInputDeviceName: String? { deviceSelection.rememberedInputDeviceName }
    /// Remembered name of the previously used output audio device but it is currently not available.
    var rememberedOutputDeviceName: String? { deviceSelection.rememberedOutputDeviceName }

    var selectedInputDevice: AudioDevice? { deviceSelection.selectedInputDevice }
    var selectedOutputDevice: AudioDevice? { deviceSelection.selectedOutputDevice }

    /// the currently selected input audio device ID.  If nil, the device is not available.
    var selectedInputDeviceID: AudioDeviceID? { deviceSelection.selectedInputDeviceID }
    /// the currently selected output audio device ID.  If nil, the device is not available.
    var selectedOutputDeviceID: AudioDeviceID? { deviceSelection.selectedOutputDeviceID }

    /// the currently selected input audio device information when it is not available in the system.
    var unavailableInputDevice: UnavailableDevice? { deviceSelection.unavailableDevice(.input) }
    /// the currently selected output audio device information when it is not available in the system.
    var unavailableOutputDevice: UnavailableDevice? { deviceSelection.unavailableDevice(.output) }

    func unavailableDevice(_ direction: AudioDirection) -> UnavailableDevice? {
        deviceSelection.unavailableDevice(direction)
    }

    var inputChannelCount: Int { deviceSelection.inputChannelCount }
    var outputChannelCount: Int { deviceSelection.outputChannelCount }

    func channelCount(for direction: AudioDirection) -> Int { deviceSelection.channelCount(for: direction) }

    // MARK: - Sample rates

    var inputSampleRates: [Double] { deviceSelection.inputSampleRates }
    var outputSampleRates: [Double] { deviceSelection.outputSampleRates }

    var selectedInputSampleRate: Double? {
        get { deviceSelection.selectedInputSampleRate }
        set { deviceSelection.selectedInputSampleRate = newValue }
    }

    var selectedOutputSampleRate: Double? {
        get { deviceSelection.selectedOutputSampleRate }
        set { deviceSelection.selectedOutputSampleRate = newValue }
    }

    var doSampleRatesMatch: Bool { deviceSelection.doSampleRatesMatch }

    func sampleRates(for direction: AudioDirection) -> [Double] { deviceSelection.sampleRates(for: direction) }

    /// Rates are `Double`, and devices report values like 44100.0 that have survived a round trip
    /// through the HAL, so they're compared with a tolerance rather than for equality. Every rate
    /// comparison in the host goes through here: 0.5 Hz swallows that drift while staying far
    /// below the gap between any two real rates (the closest standard pair is 8000 and 11025).
    /// A missing rate matches nothing, including another missing one.
    ///
    ///  - AI caught this for me!
    nonisolated static func ratesMatch(_ first: Double?, _ second: Double?) -> Bool {
        guard let first, let second else { return false }
        return abs(first - second) <= 0.5
    }

    /// Sets which sample rate should be selected in a dropdown, defaulting to first.
    nonisolated static func menuSelection(forCurrent current: Double?,
                                          from rates: [Double]) -> Double? {
        if let current, rates.contains(where: { ratesMatch($0, current) }) {
            return current
        }
        return current ?? rates.first
    }

    // MARK: - Buffer size

    var inputBufferSizeRange: ClosedRange<Int>? { deviceSelection.inputBufferSizeRange }
    var outputBufferSizeRange: ClosedRange<Int>? { deviceSelection.outputBufferSizeRange }

    func bufferSizeRange(for direction: AudioDirection) -> ClosedRange<Int>? {
        deviceSelection.bufferSizeRange(for: direction)
    }

    /// Gets a list of devices that are rejecting the selected buffer size.
    var devicesRejectingBufferSize: [String] { deviceSelection.devicesRejectingBufferSize }
}
