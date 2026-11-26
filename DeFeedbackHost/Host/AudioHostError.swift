//
//  AudioHostError.swift
//  DeFeedbackHost
//
//  Created by Edgars Klepers on 9/20/2026.
//

import Foundation

enum AudioHostError: LocalizedError {
    case pluginNotInstalled
    case noDeviceSelected
    case microphoneAccessDenied
    case engineUnavailable
    case halComponentUnavailable
    case sampleRateUnavailable(String)
    case sampleRateMismatch(input: Double, output: Double)
    case sampleRateNotApplied(String, Double)
    case bufferSizeNotApplied(String, requested: Int, actual: Int?)
    case maxInstancesReached
    case coreAudio(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .pluginNotInstalled:
            return String(
                format: String(localized: locKeyErrPluginNotFoundFormat,
                              table: locTableErrors),
                PluginConfiguration.displayName)
        case .noDeviceSelected:
            return String(localized: locKeyErrNoDeviceSelected, table: locTableErrors)
        case .microphoneAccessDenied:
            return String(localized: locKeyErrMicrophoneAccessDenied, table: locTableErrors)
        case .engineUnavailable:
            return String(localized: locKeyErrEngineUnavailable, table: locTableErrors)
        case .halComponentUnavailable:
            return String(localized: locKeyErrHalComponentUnavailableFormat, table: locTableErrors)
        case .sampleRateUnavailable(let name):
            return String(
                format: String(localized: locKeyErrSampleRateUnavailableFormat,
                              table: locTableErrors),
                name)
        case .sampleRateMismatch(let input, let output):
            return String(
                format: String(localized: locKeyErrSampleRateMismatchErrFormat,
                              table: locTableErrors),
                input,
                output
            )
        case .sampleRateNotApplied(let name, let rate):
            return String(
                format: String(localized: locKeyErrSampleRateNotAppliedFormat,
                              table: locTableErrors),
                name,
                rate
            )
        case .bufferSizeNotApplied(let name, let requested, let actual):
            if let actual {
                return String(
                    format: String(localized: locKeyErrBufferSizeNotAppliedFormatActualGiven,
                                  table: locTableErrors),
                    name,
                    requested,
                    actual
                )
            }
            return String(
                format: String(localized: locKeyErrBufferSizeNotAppliedFormatNoActualGiven,
                              table: locTableErrors),
                name,
                requested
            )
        case .maxInstancesReached:
            return String(
                format: String(localized: locKeyErrMaxInstancesReachedFormat,
                              table: locTableErrors),
                PluginConfiguration.maximumInstanceCount)
        case .coreAudio(let what, let status):
            return String(
                format: String(localized: locKeyErrCoreAudioErrFormat,
                          table: locTableErrors),
            status,
            what)
        }
    }
}
