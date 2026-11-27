//
//  HighRateBufferRuleTests.swift
//  DeFeedbackHostTests
//
//  The De-Feedback plugin can't be set up at 96 kHz or higher with a 32-frame buffer (measured
//  with the real plugin: 32 refused, 64/128/256 accepted at 96 kHz; 32 accepted at 48 kHz). The
//  host enforces a floor of 64 samples from 96 kHz up, and says why in the window, in the web
//  API's blocked reason and when a start is refused.
//
//  - Tests initially created with AI with human edits, but all reviewed by human

import Foundation
import Testing

@testable import DeFeedbackHost

struct HighRateBufferRuleTests {

    // MARK: - The rule

    @Test(arguments: [44_100.0, 48_000.0, 88_200.0, 95_000.0])
    func ratesBelowTheThresholdHaveNoFloor(_ rate: Double) {
        #expect(PluginConfiguration.minimumBufferSize(forSampleRate: rate) == nil)
        #expect(PluginConfiguration.bufferSizeProblem(bufferSize: 32, sampleRate: rate) == nil)
    }

    @Test(arguments: [95_999.7, 96_000.0, 176_400.0, 192_000.0])
    func ratesFromTheThresholdUpNeedAtLeast64(_ rate: Double) {
        #expect(PluginConfiguration.minimumBufferSize(forSampleRate: rate) == 64)
        #expect(PluginConfiguration.bufferSizeProblem(bufferSize: 32, sampleRate: rate) != nil)
    }

    @Test(arguments: [64, 128, 256, 512, 1024])
    func theFloorAndAboveAreFineAtEveryRate(_ buffer: Int) {
        for rate in [44_100.0, 48_000.0, 96_000.0, 192_000.0] {
            #expect(PluginConfiguration.bufferSizeProblem(bufferSize: buffer, sampleRate: rate) == nil)
        }
    }

    @Test func noRateYetIsNoProblem() {
        #expect(PluginConfiguration.bufferSizeProblem(bufferSize: 32, sampleRate: nil) == nil)
    }

    @Test func theSentenceNamesTheFloorAndTheCurrentSize() {
        #expect(PluginConfiguration.bufferSizeProblem(bufferSize: 32, sampleRate: 96_000)
                == "At 96000 Hz and above the buffer must be at least 64 samples; it is 32.")
    }

    @Test func theOfferedSizesIncludeTheFloor() {
        #expect(PluginConfiguration.validBufferSizes.contains(PluginConfiguration.minimumBufferAtHighSampleRate))
    }

    // MARK: - The host

    private let mic = AudioDevice(id: 101, name: "Mic", uid: "in-a", inputChannelCount: 2, outputChannelCount: 0)
    private let speakers = AudioDevice(id: 202, name: "Speakers", uid: "out-a", inputChannelCount: 0, outputChannelCount: 2)

    @MainActor
    private func host(rate: Double, buffer: Int) -> AudioHost {
        let suite = "DeFeedbackHostTests.\(UUID().uuidString)"
        let host = AudioHost(defaults: UserDefaults(suiteName: suite)!, pluginInstalled: true)
        host.setHardwareForTesting(inputDevices: [mic], outputDevices: [speakers],
                                   inputSampleRates: [44_100, 48_000, 96_000, 192_000],
                                   outputSampleRates: [44_100, 48_000, 96_000, 192_000])
        host.selectedInputDeviceUID = "in-a"
        host.selectedOutputDeviceUID = "out-a"
        host.selectedInputSampleRate = rate
        host.selectedOutputSampleRate = rate
        host.bufferSize = buffer
        return host
    }

    @Test @MainActor func aSmallBufferAt96kBlocksRunAndSaysWhy() {
        let host = host(rate: 96_000, buffer: 32)
        #expect(host.canStart == false)
        #expect(host.startBlockedReason == "At 96000 Hz and above the buffer must be at least 64 samples; it is 32.")
    }

    @Test @MainActor func raisingTheBufferToTheFloorUnblocksRun() {
        let host = host(rate: 96_000, buffer: 32)
        host.bufferSize = 64
        #expect(host.canStart)
        #expect(host.startBlockedReason == nil)
    }

    @Test @MainActor func choosingTheHighRateWhileSmallBlocksImmediately() {
        let host = host(rate: 48_000, buffer: 32)
        #expect(host.canStart)
        host.selectedInputSampleRate = 96_000
        host.selectedOutputSampleRate = 96_000
        #expect(host.canStart == false)
        #expect(host.startBlockedReason?.contains("at least 64") == true)
    }

    @Test @MainActor func aLowRateStillTakes32() {
        let host = host(rate: 48_000, buffer: 32)
        #expect(host.canStart)
        #expect(host.startBlockedReason == nil)
    }

    @Test @MainActor func aRateMismatchIsReportedBeforeTheBufferFloor() {
        let host = host(rate: 96_000, buffer: 32)
        host.selectedOutputSampleRate = 48_000
        #expect(host.startBlockedReason?.hasPrefix("Sample rates differ") == true)
    }

    // MARK: - The install error

    @Test func theInstallErrorNamesTheRateAndTheBuffer() {
        let text = PluginInstanceError.formatRejected(sampleRate: 96_000, bufferSize: 32).localizedDescription
        #expect(text.contains("96000 Hz"))
        #expect(text.contains("32-sample buffer"))
        #expect(text.contains("larger buffer"))
    }
}
