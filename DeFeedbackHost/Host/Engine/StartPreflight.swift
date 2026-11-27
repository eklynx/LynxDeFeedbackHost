//
//  StartPreflight.swift
//  DeFeedbackHost
//
//  Created by Edgars Klepers on 9/20/2026.
//
//  The checks that decide whether audio can start, before anything touches hardware. Pure functions
//  of `EngineStartSettings`, so every refusal and its order can be tested without a device.
//
//  Order (the first failing check wins; `EngineSession.start` runs them in this order, with the
//  microphone permission prompt between the two stages):
//    1. `devices`: plugin not installed -> `.pluginNotInstalled`; either device missing ->
//       `.noDeviceSelected`.
//    2. (microphone access, asked by the session) -> `.microphoneAccessDenied`.
//    3. `sampleRate`: either rate missing -> `.sampleRateUnavailable(<output device name>)`; the two
//       rates differing by more than 0.5 Hz -> `.sampleRateMismatch`; otherwise the output rate.
//    4. `bufferSize`: 96 kHz or higher with a buffer under 64 samples -> `.bufferTooSmallForSampleRate`
//       (the plugin cannot be set up like that).

import Foundation

/// A snapshot of the host's choices that starting audio depends on. The session asks the host for
/// a fresh one at each stage, because the first stage can wait on a permission prompt.
struct EngineStartSettings {
    let pluginInstalled: Bool
    let input: AudioDevice?
    let output: AudioDevice?
    let inputRate: Double?
    let outputRate: Double?
    let bufferSize: Int
    let parallelRendering: Bool
}

enum StartPreflight {

    static func devices(_ settings: EngineStartSettings) throws -> (input: AudioDevice, output: AudioDevice) {
        guard settings.pluginInstalled else {
            throw AudioHostError.pluginNotInstalled
        }

        guard let input = settings.input, let output = settings.output else {
            throw AudioHostError.noDeviceSelected
        }
        return (input, output)
    }

    /// The one sample rate both devices will run at.
    static func sampleRate(_ settings: EngineStartSettings, outputDevice: AudioDevice) throws -> Double {
        guard let inputRate = settings.inputRate,
              let outputRate = settings.outputRate else {
            throw AudioHostError.sampleRateUnavailable(outputDevice.name)
        }
        guard AudioHost.ratesMatch(inputRate, outputRate) else {
            throw AudioHostError.sampleRateMismatch(input: inputRate, output: outputRate)
        }
        return outputRate
    }

    /// The plugin refuses a small buffer at a high sample rate, so refuse before touching hardware
    /// rather than after changing the devices.
    static func bufferSize(_ settings: EngineStartSettings, sampleRate: Double) throws {
        if PluginConfiguration.bufferSizeProblem(bufferSize: settings.bufferSize,
                                                 sampleRate: sampleRate) != nil {
            throw AudioHostError.bufferTooSmallForSampleRate(bufferSize: settings.bufferSize)
        }
    }
}
