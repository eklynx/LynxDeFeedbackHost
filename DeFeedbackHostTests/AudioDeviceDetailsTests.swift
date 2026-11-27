//
//  AudioDeviceDetailsTests.swift
//  DeFeedbackHostTests
//
//  The input and output ends of a device must take their own channel counts. Swapping them
//  compiles and starts audio on the wrong number of channels, so it is pinned here with a device
//  whose two counts differ.
//
//  - Tests initially created with AI with human edits, but all reviewed by human

import Testing

@testable import DeFeedbackHost

struct AudioDeviceDetailsTests {

    private let interface = AudioDevice(id: 42, name: "Interface", uid: "uid-42",
                                        inputChannelCount: 8, outputChannelCount: 2)

    @Test func theInputEndUsesTheInputChannelCount() {
        let details = AudioDeviceDetails(inputOf: interface)
        #expect(details.deviceID == 42)
        #expect(details.channelCount == 8)
    }

    @Test func theOutputEndUsesTheOutputChannelCount() {
        let details = AudioDeviceDetails(outputOf: interface)
        #expect(details.deviceID == 42)
        #expect(details.channelCount == 2)
    }

    @Test func twoEndsOfTheSameDeviceDiffer() {
        #expect(AudioDeviceDetails(inputOf: interface) != AudioDeviceDetails(outputOf: interface))
    }

    @Test func separateDevicesKeepTheirOwnIDs() {
        let mic = AudioDevice(id: 7, name: "Mic", uid: "m", inputChannelCount: 1, outputChannelCount: 0)
        let speakers = AudioDevice(id: 9, name: "Speakers", uid: "s", inputChannelCount: 0, outputChannelCount: 6)
        #expect(AudioDeviceDetails(inputOf: mic) == AudioDeviceDetails(inputOf: mic))
        #expect(AudioDeviceDetails(outputOf: speakers).deviceID == 9)
        #expect(AudioDeviceDetails(outputOf: speakers).channelCount == 6)
    }
}
