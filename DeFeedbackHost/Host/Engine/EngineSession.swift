//
//  EngineSession.swift
//  DeFeedbackHost
//
//  Created by Edgars Klepers on 9/20/2026.
//
//  ┌─────────────────────────────────────────────────────────────────────────────────────────┐
//  │ AI AGENTS: this file is the SOURCE OF TRUTH for starting and stopping the audio engine. │
//  └─────────────────────────────────────────────────────────────────────────────────────────┘
//
//  Happy path (`start`): checks (`StartPreflight`) -> microphone access -> bring both devices to
//  the one sample rate -> set both buffer sizes -> build the C++ engine -> claim a slot for each
//  instance -> prime with silence -> start the AUHAL I/O. `teardown` undoes it in the reverse
//  order and is safe to call after a partial start.
//  Errors: each step throws the `AudioHostError` that names it (see `StartPreflight` for the
//  first ones; then `.sampleRateUnavailable`, `.sampleRateNotApplied`, `.bufferSizeNotApplied`,
//  `.engineUnavailable`, `.maxInstancesReached`, and whatever `AudioIO` throws). The caller tears
//  down on any throw; the engine and I/O handles are kept the moment they exist so it can.

import AVFoundation
import CoreAudio
import Foundation

/// What `EngineSession` needs from the host. `AudioHost` is the only conformer.
@MainActor
protocol EngineSessionHost: AnyObject {

    /// The host's current choices; asked for afresh at each stage of `start`.
    func engineStartSettings() -> EngineStartSettings
}

/// Owns the running audio engine and its I/O, from `start` to `teardown`.
@Observable
@MainActor
final class EngineSession {

    /// The engine while audio is running (or partly started); nil otherwise.
    @ObservationIgnored private(set) var engine: CoreAudioEngineControl?
    @ObservationIgnored private var io: AudioIO?

    private(set) var runningSampleRate: Double = 0

    @ObservationIgnored private let instances: InstanceList

    /// Set by the host once it is fully initialised.
    @ObservationIgnored weak var host: (any EngineSessionHost)?

    init(instances: InstanceList) {
        self.instances = instances
    }

    func start() async throws {
        guard let host else { return }

        let (input, output) = try StartPreflight.devices(host.engineStartSettings())

        // wait for privacy setting in case waiting on user click.
        guard await Self.hasMicrophoneAccess() else {
            throw AudioHostError.microphoneAccessDenied
        }

        let sampleRate = try StartPreflight.sampleRate(host.engineStartSettings(), outputDevice: output)
        try await bringToSampleRate(sampleRate, input: input, output: output)

        let settings = host.engineStartSettings()
        let bufferSize = settings.bufferSize
        try applyBufferSize(bufferSize, input: input, output: output)

        let controller = try makeEngine(bufferSize: bufferSize, input: input, output: output,
                                        sampleRate: sampleRate)

        controller.setParallelRendering(
            host.engineStartSettings().parallelRendering,
            instanceThreshold: PluginConfiguration.parallelRenderingInstanceThreshold)

        for instance in instances.instances {
            try instances.activate(instance, in: controller)
        }
        controller.primeWithSilence(frameCount: bufferSize * 2)

        try startIO(controller, input: input, output: output, sampleRate: sampleRate,
                    maximumFrameCount: bufferSize)
    }

    // MARK: - Start steps

    private static func hasMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    private func bringToSampleRate(_ sampleRate: Double,
                                   input: AudioDevice,
                                   output: AudioDevice) async throws {
        for direction in AudioHost.AudioDirection.allCases {
            let device = direction == .input ? input : output
            guard let current = AudioHardware.nominalSampleRate(device.id) else {
                throw AudioHostError.sampleRateUnavailable(device.name)
            }
            guard !AudioHost.ratesMatch(current, sampleRate) else { continue }

            AudioHardware.setNominalSampleRate(sampleRate, for: device.id)
            // verify sample rate successfully updated
            guard await Self.awaitSampleRate(sampleRate, on: device.id) else {
                throw AudioHostError.sampleRateNotApplied(device.name, sampleRate)
            }
        }
    }

    private func applyBufferSize(_ bufferSize: Int, input: AudioDevice, output: AudioDevice) throws {
        let inputFrames = AudioHardware.setBufferFrameSize(bufferSize, for: input.id)
        let outputFrames = AudioHardware.setBufferFrameSize(bufferSize, for: output.id)

        guard let inputFrames, inputFrames == bufferSize else {
            throw AudioHostError.bufferSizeNotApplied(input.name, requested: bufferSize,
                                                      actual: inputFrames)
        }
        guard let outputFrames, outputFrames == bufferSize else {
            throw AudioHostError.bufferSizeNotApplied(output.name, requested: bufferSize,
                                                      actual: outputFrames)
        }
    }

    /// Sets up the audio engine. The handle is kept straight away so a later failure can tear it down.
    private func makeEngine(bufferSize: Int,
                            input: AudioDevice,
                            output: AudioDevice,
                            sampleRate: Double) throws -> CoreAudioEngineControl {
        guard let controller = CoreAudioEngineControl(maximumFrameCount: bufferSize,
                                        inputChannelCount: input.inputChannelCount,
                                        outputChannelCount: output.outputChannelCount,
                                        sampleRate: sampleRate) else {
            throw AudioHostError.engineUnavailable
        }
        engine = controller
        runningSampleRate = sampleRate
        return controller
    }

    /// Wires up the c++ audio.
    private func startIO(_ controller: CoreAudioEngineControl,
                         input: AudioDevice,
                         output: AudioDevice,
                         sampleRate: Double,
                         maximumFrameCount: Int) throws {
        let io = try AudioIO()
        self.io = io
        try io.start(engine: controller,
                     inputDeviceID: input.id,
                     inputChannelCount: input.inputChannelCount,
                     outputDeviceID: output.id,
                     outputChannelCount: output.outputChannelCount,
                     sampleRate: sampleRate,
                     maximumFrameCount: maximumFrameCount)
    }

    /// Waits up to `timeout` for a device to report `target` as its sample rate.
    static func awaitSampleRate(_ target: Double,
                                on device: AudioDeviceID,
                                timeout: Duration = .seconds(2)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if AudioHost.ratesMatch(AudioHardware.nominalSampleRate(device), target) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    // MARK: - Stop

    func teardown() {
        // Stop the audio IO
        io?.stop()
        io = nil

        // free plugin instances
        if let engine {
            for instance in instances.instances {
                if let slot = instance.slot {
                    engine.retire(slot)
                    engine.release(slot)
                }
                instance.slot = nil
                instance.teardownRenderResources()
            }
            engine.setInputUnit(nil)
        }

        engine = nil
        runningSampleRate = 0
    }

    // MARK: - Diagnostics

    /// Non-zero cycle counts are the difference between "the units started" and "audio is
    /// actually moving". Underruns are the audible symptom of two devices drifting apart.
    ///  - Thanks to AI for giving these meaningful metrics
    var diagnostics: EngineDiagnostics? {
        guard let engine else { return nil }

        let period = engine.bufferPeriodNanoseconds
        let smoothed = Double(engine.smoothedRenderNanoseconds)
        let peak = Double(engine.peakRenderNanoseconds)

        return EngineDiagnostics(
            captureCycles: engine.captureCycles,
            renderCycles: engine.renderCycles,
            underruns: engine.underruns,
            dspLoad: period > 0 ? smoothed / period : 0,
            peakDspLoad: period > 0 ? peak / period : 0,
            renderThreadPolicy: RealtimeThreadPolicy.read(port: engine.renderThreadPort),
            captureThreadPolicy: RealtimeThreadPolicy.read(port: engine.captureThreadPort),
            workerThreadPolicies: engine.workerThreadPolicies,
            parallelRenderingEngaged: engine.isParallelRenderingEngaged)
    }
}

extension AudioHost: EngineSessionHost {}
