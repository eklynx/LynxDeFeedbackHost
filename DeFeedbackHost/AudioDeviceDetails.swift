//
//  AudioDeviceDetails.swift
//  DeFeedbackHost
//
//  Created by Edgars Klepers on 9/19/26.
//

import CoreAudio

/// What `AudioIO` needs to know about one end of the audio path: which device, and how many
/// channels of it are in use in that direction. Nothing else: sample rate and buffer size are
/// shared by both directions and passed separately.
///
/// A device reports an input and an output channel count, and mixing them up is the one mistake
/// the compiler can't catch, so a value is only made through the initialiser that names its
/// direction.
nonisolated struct AudioDeviceDetails: Sendable, Equatable {

    let deviceID: AudioDeviceID
    let channelCount: Int

    /// The input end of `device`: its ID and its input channel count.
    init(inputOf device: AudioDevice) {
        deviceID = device.id
        channelCount = device.inputChannelCount
    }

    /// The output end of `device`: its ID and its output channel count.
    init(outputOf device: AudioDevice) {
        deviceID = device.id
        channelCount = device.outputChannelCount
    }
}
