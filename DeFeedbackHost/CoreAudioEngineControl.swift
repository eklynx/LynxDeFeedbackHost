//
//  CoreAudioEngineControl.swift
//  DeFeedbackHost
//
//  Created by Edgars Klepers on 9/20/2026.
//

import AudioToolbox

/// Swift face of the C++ realtime engine (`DFHEngine.h`, `DFHEngine.cpp`).
///
/// `nonisolated` because `AudioHost` touches it from the main actor  with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, while CoreAudio touches the
///  engine from its own threads.
///
nonisolated final class CoreAudioEngineControl: @unchecked Sendable {

    /// One instance of the plugin lives in each slot.
    struct Slot: Equatable {
        fileprivate let handle: DFHSlotRef

        func setInputChannel(_ channel: Int) {
            dfh_slot_set_input_channel(handle, Int32(channel))
        }

        func setOutputChannel(_ channel: Int) {
            dfh_slot_set_output_channel(handle, Int32(channel))
        }

        func setMuted(_ muted: Bool) {
            dfh_slot_set_muted(handle, muted)
        }

        /// We do our own bypass by routing the input to the output.  We dont have access to the plugin's passthrough
        func setBypassed(_ bypassed: Bool) {
            dfh_slot_set_bypassed(handle, bypassed)
        }

        /// Test seam: invokes this slot's input callback the way its plugin would, keeping the
        /// copy-into-the-provided-buffer convention covered without a real plugin.
        ///   -- AI generated for testing
        @discardableResult
        func pullInput(frameCount: Int,
                       into inputData: UnsafeMutableAudioBufferListPointer) -> OSStatus {
            dfh_slot_pull_input(handle, UInt32(frameCount), inputData.unsafeMutablePointer)
        }
    }

    private let engine: DFHEngineRef

    init?(maximumFrameCount: Int,
          inputChannelCount: Int,
          outputChannelCount: Int,
          sampleRate: Double = 48_000) {
        guard let engine = dfh_engine_create(Int32(maximumFrameCount),
                                             Int32(inputChannelCount),
                                             Int32(outputChannelCount),
                                             sampleRate,
                                             Int32(PluginConfiguration.ringBufferDepthInBuffers))
        else { return nil }

        self.engine = engine
    }

    deinit {
        dfh_engine_destroy(engine)
    }

    
    // MARK: - Configuration

    var maximumFrameCount: Int { Int(dfh_engine_maximum_frame_count(engine)) }
    var sampleRate: Double { dfh_engine_sample_rate(engine) }
    var bufferPeriodNanoseconds: Double { dfh_engine_buffer_period_nanoseconds(engine) }
    static var maximumSlotCount: Int { Int(dfh_engine_maximum_slot_count()) }

    func setInputUnit(_ unit: AudioUnit?) {
        dfh_engine_set_input_unit(engine, unit)
    }

    var callbackRefContext: UnsafeMutableRawPointer {
        UnsafeMutableRawPointer(engine)
    }

    var engineHandle: DFHEngineRef { engine }

    func primeWithSilence(frameCount: Int) {
        dfh_engine_prime_with_silence(engine, Int32(frameCount))
    }

    var framesAvailable: Int { Int(dfh_engine_frames_available(engine)) }

    /// Test seam: pushes captured input into the engine's ring buffer without an input device.
    ///  - AI Generated for testing
    func writeInput(_ bufferList: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        dfh_engine_write_input(engine, bufferList.unsafePointer, Int32(frameCount))
    }

    
    // MARK: - Slots

    /// Claims an empty slot, or `nil` if table is full.
    func claimSlot() -> Slot? {
        guard let handle = dfh_engine_claim_slot(engine) else { return nil }
        return Slot(handle: handle)
    }

    /// Installs an AudioUnit in to the engine.
    func installUnit(_ unit: AudioUnit, into slot: Slot) -> Int? {
        let channels = dfh_engine_install_audiounit(engine, slot.handle, unit)
        return channels > 0 ? Int(channels) : nil
    }

    /// Installs a host-side render source. Used where there is no real plugin — the tests'
    /// stand-ins.
    ///    - AI Generated for testing
    func installFunction(_ function: DFHRenderFunction,
                         context: UnsafeMutableRawPointer?,
                         busChannelCount: Int,
                         providesOwnOutputBuffer: Bool,
                         into slot: Slot) {
        dfh_engine_install_function(engine, slot.handle, function, context,
                                    Int32(busChannelCount), providesOwnOutputBuffer)
    }

    /// Frees up an instance slot's resoureces. Caller must wait a buffer period  before
    /// releasing whatever backs it so that resources are freed properly.
    ///  -Thanks to AI for pointing on the wait needed.
    func retire(_ slot: Slot) {
        dfh_engine_retire_slot(engine, slot.handle)
    }

    /// Releases the slot back in to the free pool. Only safe once the render thread is no longer refrencing it (retire + wait).
    func release(_ slot: Slot) {
        dfh_engine_release_slot(engine, slot.handle)
    }

    
    // MARK: - Parallel rendering

    func setParallelRendering(_ enabled: Bool, instanceThreshold: Int) {
        dfh_engine_set_parallel_rendering(engine, enabled, Int32(instanceThreshold))
    }

    func startWorkers(outputUnit: AudioUnit? = nil) {
        dfh_engine_start_workers(engine, outputUnit)
    }

    func stopWorkers() {
        dfh_engine_stop_workers(engine)
    }

    var isParallelRenderingEngaged: Bool { dfh_engine_parallel_rendering_engaged(engine) }

    var workerThreadCount: Int { Int(dfh_engine_worker_thread_count(engine)) }

    var activeSlotCount: Int { Int(dfh_engine_active_slot_count(engine)) }

    /// So we can be sure that the threads are realtime processing priority
    var workerThreadPolicies: [RealtimeThreadPolicy] {
        (0..<workerThreadCount).compactMap { index in
            RealtimeThreadPolicy(worker: dfh_engine_worker_info(engine, Int32(index)))
        }
    }

    
    // MARK: - Realtime seams

    /// Drives one render cycle. Production goes straight from CoreAudio into C++; this exists so
    /// the engine can be driven from tests.
    @discardableResult
    func render(timestamp: UnsafePointer<AudioTimeStamp>,
                frameCount: UInt32,
                output: UnsafeMutableAudioBufferListPointer) -> OSStatus {
        dfh_engine_render(engine, timestamp, frameCount, output.unsafeMutablePointer)
    }

    // used for testing
    func inputChannel(_ channel: Int) -> UnsafePointer<Float>? {
        dfh_engine_input_channel(engine, Int32(channel))
    }

    
    // MARK: - Diagnostics

    var captureCycles: UInt64 { dfh_engine_capture_cycles(engine) }
    var renderCycles: UInt64 { dfh_engine_render_cycles(engine) }
    var underruns: UInt64 { dfh_engine_underruns(engine) }
    var smoothedRenderNanoseconds: UInt64 { dfh_engine_smoothed_render_nanoseconds(engine) }
    var peakRenderNanoseconds: UInt64 { dfh_engine_peak_render_nanoseconds(engine) }
    var renderThreadPort: UInt32 { dfh_engine_render_thread_port(engine) }
    var captureThreadPort: UInt32 { dfh_engine_capture_thread_port(engine) }
}
