//
//  DeviceSelectionCharacterizationTests.swift
//  DeFeedbackHostTests
//
//  Pins how the host's device and sample-rate selection behaves, using simulated devices so no
//  hardware is queried or changed. Written before the selection logic moved out of `AudioHost`
//  (issue #41) so the move can be shown to change nothing.
//
//  - Tests initially created with AI with human edits, but all reviewed by human

import Foundation
import Testing

@testable import DeFeedbackHost

private let mic = AudioDevice(id: 101, name: "Mic", uid: "in-a", inputChannelCount: 4, outputChannelCount: 0)
private let mic2 = AudioDevice(id: 103, name: "Other Mic", uid: "in-b", inputChannelCount: 2, outputChannelCount: 0)
private let speakers = AudioDevice(id: 202, name: "Speakers", uid: "out-a", inputChannelCount: 0, outputChannelCount: 6)

@MainActor
private func makeHost(pluginInstalled: Bool = true, selecting: Bool = true) -> AudioHost {
    let suite = "DeFeedbackHostTests.\(UUID().uuidString)"
    let host = AudioHost(defaults: UserDefaults(suiteName: suite)!, pluginInstalled: pluginInstalled)
    host.setHardwareForTesting(inputDevices: [mic, mic2], outputDevices: [speakers],
                               inputSampleRates: [44_100, 48_000], outputSampleRates: [44_100, 48_000])
    if selecting {
        host.selectedInputDeviceUID = "in-a"
        host.selectedOutputDeviceUID = "out-a"
        host.selectedInputSampleRate = 48_000
        host.selectedOutputSampleRate = 48_000
    }
    return host
}

@MainActor
struct DeviceSelectionCharacterizationTests {

    // MARK: - Selection

    @Test func selectingDevicesExposesThemAndTheirChannelCounts() {
        let host = makeHost()
        #expect(host.selectedInputDevice == mic)
        #expect(host.selectedOutputDevice == speakers)
        #expect(host.selectedInputDeviceID == 101)
        #expect(host.selectedOutputDeviceID == 202)
        #expect(host.inputChannelCount == 4)
        #expect(host.outputChannelCount == 6)
        #expect(host.channelCount(for: .input) == 4)
        #expect(host.channelCount(for: .output) == 6)
    }

    @Test func selectingADeviceRemembersItsName() {
        let host = makeHost()
        #expect(host.rememberedInputDeviceName == "Mic")
        #expect(host.rememberedOutputDeviceName == "Speakers")

        host.selectedInputDeviceUID = "in-b"
        #expect(host.rememberedInputDeviceName == "Other Mic")
    }

    @Test func clearingTheSelectionForgetsTheName() {
        let host = makeHost()
        host.selectedInputDeviceUID = nil
        #expect(host.rememberedInputDeviceName == nil)
        #expect(host.selectedInputDevice == nil)
        #expect(host.inputChannelCount == 0)
    }

    @Test func aSelectedDeviceThatIsNotPresentIsUnavailableAndKeepsItsRememberedName() {
        let host = makeHost()
        host.selectedInputDeviceUID = "gone"
        // The name remembered from the previous (present) device is kept for display.
        #expect(host.unavailableInputDevice == AudioHost.UnavailableDevice(uid: "gone", name: "Mic"))
        #expect(host.unavailableDevice(.input)?.uid == "gone")
        #expect(host.unavailableOutputDevice == nil)
    }

    @Test func anUnavailableDeviceWithNoRememberedNameShowsItsUID() {
        let host = makeHost(selecting: false)
        host.selectedOutputDeviceUID = "nameless"
        #expect(host.unavailableOutputDevice == AudioHost.UnavailableDevice(uid: "nameless", name: "nameless"))
    }

    @Test func selectingNothingIsNotUnavailable() {
        let host = makeHost(selecting: false)
        #expect(host.unavailableInputDevice == nil)
    }

    // MARK: - Sample rates

    @Test func ratesAreOfferedPerDirection() {
        let host = makeHost()
        #expect(host.sampleRates(for: .input) == [44_100, 48_000])
        #expect(host.sampleRates(for: .output) == [44_100, 48_000])
        #expect(host.inputSampleRates == [44_100, 48_000])
    }

    @Test func matchingRatesAllowStartAndDifferingOnesDoNot() {
        let host = makeHost()
        #expect(host.doSampleRatesMatch)
        #expect(host.canStart)

        host.selectedOutputSampleRate = 44_100
        #expect(host.doSampleRatesMatch == false)
        #expect(host.canStart == false)
    }

    @Test func noRateSelectedCountsAsNotMatching() {
        let host = makeHost(selecting: false)
        #expect(host.doSampleRatesMatch == false)
    }

    @Test func aRateStaysRememberedAfterTheSelectionIsCleared() {
        let host = makeHost()
        host.selectedInputSampleRate = 44_100
        host.selectedInputSampleRate = nil
        #expect(host.currentSettings().inputSampleRate == 44_100)
        #expect(host.currentSettings().outputSampleRate == 48_000)
    }

    // MARK: - Start readiness

    @Test func anEverythingReadyHostCanStartWithNoReasonToBlock() {
        let host = makeHost()
        #expect(host.canStart)
        #expect(host.startBlockedReason == nil)
    }

    @Test func aMissingPluginBlocksFirst() {
        let host = makeHost(pluginInstalled: false)
        #expect(host.canStart == false)
        #expect(host.startBlockedReason == AudioHostError.pluginNotInstalled.localizedDescription)
    }

    @Test func oneAbsentDeviceIsNamedInTheSingular() {
        let host = makeHost()
        host.selectedInputDeviceUID = "gone"
        #expect(host.startBlockedReason == "\"Mic\" isn't connected")
    }

    @Test func twoAbsentDevicesAreNamedInThePlural() {
        let host = makeHost()
        host.selectedInputDeviceUID = "gone-in"
        host.selectedOutputDeviceUID = "gone-out"
        #expect(host.startBlockedReason == "\"Mic\" and \"Speakers\" aren't connected")
    }

    @Test func unselectedDevicesAskForBothToBeSet() {
        let host = makeHost(selecting: false)
        #expect(host.startBlockedReason == "Input and output devices must both be set")
    }

    @Test func differingRatesAreReportedWithBothValues() {
        let host = makeHost()
        host.selectedOutputSampleRate = 44_100
        #expect(host.startBlockedReason == "Sample rates differ between devices (48000 / 44100 Hz)")
    }

    // MARK: - Buffer-size gate (with no known device ranges)

    @Test func withoutDeviceRangesNoDeviceRejectsABufferSize() {
        let host = makeHost()
        host.bufferSize = 1
        #expect(host.devicesRejectingBufferSize.isEmpty)
        #expect(host.bufferSizeRange(for: .input) == nil)
    }
}
