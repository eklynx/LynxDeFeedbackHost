//
//  EngineSessionCharacterizationTests.swift
//  DeFeedbackHostTests
//
//  Pins what `AudioHost.start()` does before it reaches the hardware, and what a stopped host
//  reports. Written before the start/stop code moved out of `AudioHost` (issue #41).
//
//  The steps after the microphone check need a real audio device and the microphone permission
//  prompt, so a unit test can't drive them; those are covered by `StartPreflightTests` (the pure
//  checks) and by the hands-on checklist on the pull request.
//
//  - Tests initially created with AI with human edits, but all reviewed by human

import Foundation
import Testing

@testable import DeFeedbackHost

@MainActor
private func makeHost(pluginInstalled: Bool, withDevices: Bool) -> AudioHost {
    let suite = "DeFeedbackHostTests.\(UUID().uuidString)"
    let host = AudioHost(defaults: UserDefaults(suiteName: suite)!, pluginInstalled: pluginInstalled)
    if withDevices {
        host.setHardwareForTesting(
            inputDevices: [AudioDevice(id: 101, name: "Mic", uid: "in-a",
                                       inputChannelCount: 2, outputChannelCount: 0)],
            outputDevices: [AudioDevice(id: 202, name: "Speakers", uid: "out-a",
                                        inputChannelCount: 0, outputChannelCount: 2)],
            inputSampleRates: [48000], outputSampleRates: [48000])
        host.selectedInputDeviceUID = "in-a"
        host.selectedOutputDeviceUID = "out-a"
    }
    return host
}

@MainActor
struct EngineSessionCharacterizationTests {

    @Test func aStoppedHostReportsNothingRunning() {
        let host = makeHost(pluginInstalled: true, withDevices: true)
        #expect(host.isRunning == false)
        #expect(host.runningSampleRate == 0)
        #expect(host.diagnostics == nil)
    }

    @Test func startingWithoutThePluginFailsFirstAndStaysStopped() async {
        let host = makeHost(pluginInstalled: false, withDevices: true)
        await host.start()
        #expect(host.isRunning == false)
        #expect(host.errorMessage == AudioHostError.pluginNotInstalled.localizedDescription)
        #expect(host.runningSampleRate == 0)
    }

    @Test func startingWithoutBothDevicesSaysSo() async {
        let host = makeHost(pluginInstalled: true, withDevices: false)
        await host.start()
        #expect(host.isRunning == false)
        #expect(host.errorMessage == AudioHostError.noDeviceSelected.localizedDescription)
    }

    @Test func aFailedStartClearsAnOlderErrorBeforeTrying() async {
        let host = makeHost(pluginInstalled: true, withDevices: false)
        host.errorMessage = "old"
        await host.start()
        #expect(host.errorMessage != "old")
    }

    @Test func stoppingAStoppedHostChangesNothing() {
        let host = makeHost(pluginInstalled: true, withDevices: true)
        host.errorMessage = "kept"
        host.stop()
        #expect(host.isRunning == false)
        #expect(host.errorMessage == "kept")
    }

    @Test func toggleOnAStoppedHostTriesToStart() async {
        let host = makeHost(pluginInstalled: false, withDevices: true)
        await host.toggleRunning()
        #expect(host.errorMessage == AudioHostError.pluginNotInstalled.localizedDescription)
    }
}
