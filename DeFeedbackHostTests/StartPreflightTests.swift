//
//  StartPreflightTests.swift
//  DeFeedbackHostTests
//
//  The checks that run before audio touches hardware, in the order they run. The old
//  `startAudio()` interleaved these with hardware calls and could only be tested through a real
//  device; the same refusals, in the same order, are now pure.
//
//  - Tests initially created with AI with human edits, but all reviewed by human

import Foundation
import Testing

@testable import DeFeedbackHost

private let mic = AudioDevice(id: 1, name: "Mic", uid: "in", inputChannelCount: 2, outputChannelCount: 0)
private let speakers = AudioDevice(id: 2, name: "Speakers", uid: "out", inputChannelCount: 0, outputChannelCount: 2)

private func settings(pluginInstalled: Bool = true,
                      input: AudioDevice? = mic,
                      output: AudioDevice? = speakers,
                      inputRate: Double? = 48_000,
                      outputRate: Double? = 48_000) -> EngineStartSettings {
    EngineStartSettings(pluginInstalled: pluginInstalled, input: input, output: output,
                        inputRate: inputRate, outputRate: outputRate,
                        bufferSize: 64, parallelRendering: true)
}

private func message(_ body: () throws -> Void) -> String? {
    do { try body(); return nil } catch { return error.localizedDescription }
}

@MainActor
struct StartPreflightTests {

    // MARK: - Devices

    @Test func acceptsAPluginAndTwoDevices() throws {
        let (input, output) = try StartPreflight.devices(settings())
        #expect(input == mic)
        #expect(output == speakers)
    }

    @Test func aMissingPluginIsRefusedBeforeAnythingElse() {
        let text = message { _ = try StartPreflight.devices(settings(pluginInstalled: false, input: nil)) }
        #expect(text == AudioHostError.pluginNotInstalled.localizedDescription)
    }

    @Test(arguments: [(nil as AudioDevice?, speakers as AudioDevice?), (mic, nil), (nil, nil)])
    func aMissingDeviceIsRefused(_ input: AudioDevice?, _ output: AudioDevice?) {
        let text = message { _ = try StartPreflight.devices(settings(input: input, output: output)) }
        #expect(text == AudioHostError.noDeviceSelected.localizedDescription)
    }

    // MARK: - Sample rate

    @Test func matchingRatesGiveTheOutputRate() throws {
        #expect(try StartPreflight.sampleRate(settings(inputRate: 48_000, outputRate: 48_000.4),
                                              outputDevice: speakers) == 48_000.4)
    }

    @Test(arguments: [(nil as Double?, 48_000 as Double?), (48_000, nil), (nil, nil)])
    func aMissingRateNamesTheOutputDevice(_ input: Double?, _ output: Double?) {
        let text = message {
            _ = try StartPreflight.sampleRate(settings(inputRate: input, outputRate: output),
                                              outputDevice: speakers)
        }
        #expect(text == AudioHostError.sampleRateUnavailable("Speakers").localizedDescription)
    }

    @Test func differingRatesAreRefusedWithBothValues() {
        let text = message {
            _ = try StartPreflight.sampleRate(settings(inputRate: 44_100, outputRate: 48_000),
                                              outputDevice: speakers)
        }
        #expect(text == AudioHostError.sampleRateMismatch(input: 44_100, output: 48_000).localizedDescription)
    }

    @Test func missingRatesAreReportedBeforeAMismatch() {
        // Only one rate present can't be a mismatch: it is "unavailable".
        let text = message {
            _ = try StartPreflight.sampleRate(settings(inputRate: 44_100, outputRate: nil),
                                              outputDevice: speakers)
        }
        #expect(text == AudioHostError.sampleRateUnavailable("Speakers").localizedDescription)
    }
}

// MARK: - Buffer floor at high sample rates

@MainActor
struct StartPreflightBufferTests {

    private func settings(buffer: Int) -> EngineStartSettings {
        EngineStartSettings(pluginInstalled: true, input: mic, output: speakers,
                            inputRate: 96_000, outputRate: 96_000,
                            bufferSize: buffer, parallelRendering: true)
    }

    @Test func aSmallBufferAtAHighRateIsRefusedWithTheSharedSentence() {
        let text = message { try StartPreflight.bufferSize(settings(buffer: 32), sampleRate: 96_000) }
        #expect(text == AudioHostError.bufferTooSmallForSampleRate(bufferSize: 32).localizedDescription)
        #expect(text == PluginConfiguration.highSampleRateBufferMessage(bufferSize: 32))
    }

    @Test(arguments: [64, 128, 1024])
    func theFloorAndAboveAreAccepted(_ buffer: Int) {
        #expect(message { try StartPreflight.bufferSize(settings(buffer: buffer), sampleRate: 96_000) } == nil)
    }

    @Test func aLowRateTakesTheSmallestBuffer() {
        #expect(message { try StartPreflight.bufferSize(settings(buffer: 32), sampleRate: 48_000) } == nil)
    }
}
